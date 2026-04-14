#!/usr/bin/env bash
# sync-upstream-and-deploy.sh — PR housekeeping, rebase patch branches, push fork, deploy
#
# Usage:
#   ./scripts/sync-upstream-and-deploy.sh               # pr-check + rebase + deploy
#   ./scripts/sync-upstream-and-deploy.sh --no-deploy   # pr-check + rebase only
#   ./scripts/sync-upstream-and-deploy.sh --check       # dry-run: show what would happen
#   ./scripts/sync-upstream-and-deploy.sh --pr-check    # only PR status, then exit

set -euo pipefail

UPSTREAM_REMOTE="origin"
UPSTREAM_REPO="NousResearch/hermes-agent"
FORK_REMOTE="fork"
UPSTREAM_BRANCH="main"
# Cumulative patch branch — carries ALL local patches (infra + fixes).
# PR branches (fix/*) are submission-only: rebased & pushed to fork but NOT deployed from.
PATCH_BRANCH="feat/local-patches"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

DO_DEPLOY=true
DRY_RUN=false
PR_CHECK_ONLY=false

for arg in "$@"; do
  case $arg in
    --no-deploy) DO_DEPLOY=false ;;
    --check)     DRY_RUN=true; DO_DEPLOY=false ;;
    --pr-check)  PR_CHECK_ONLY=true ;;
    --help|-h)   sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

cd "$REPO_ROOT"

# ── Step 0: PR status check ───────────────────────────────────────────────────
echo "▶ Checking our upstream PRs on $UPSTREAM_REPO..."

# Active branches derived dynamically from open PRs (no hardcoded array).
# Populated below if gh is available; stays empty otherwise → rebase skipped gracefully.
ACTIVE_BRANCHES=()
BRANCHES_TO_DELETE=()

if ! command -v gh &>/dev/null; then
  echo "  ⚠ gh CLI not found — skipping PR check, ACTIVE_BRANCHES empty"
elif ! gh auth status &>/dev/null 2>&1; then
  echo "  ⚠ gh not authenticated — skipping PR check, ACTIVE_BRANCHES empty"
else
  PRS_JSON="$(gh pr list \
    --repo "$UPSTREAM_REPO" \
    --author "@me" \
    --state all \
    --limit 50 \
    --json number,title,state,mergedAt,headRefName \
    2>/dev/null || echo '[]')"

  if [[ "$PRS_JSON" == "[]" ]] || [[ -z "$PRS_JSON" ]]; then
    echo "  ℹ No PRs found authored by you on $UPSTREAM_REPO"
  else
    echo ""
    echo "── Our PRs on $UPSTREAM_REPO ─────────────────────────────────────────"
    printf "  %-6s %-10s %-30s %s\n" "PR" "STATUS" "BRANCH" "TITLE"
    echo "  ──────────────────────────────────────────────────────────────────"

    HAS_OPEN=false
    CURRENT_BRANCH_NOW="$(git rev-parse --abbrev-ref HEAD)"

    while IFS= read -r pr; do
      number="$(echo "$pr" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['number'])")"
      title="$(echo  "$pr" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['title'][:48])")"
      state="$(echo  "$pr" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['state'])")"
      branch="$(echo "$pr" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['headRefName'])")"
      branch_short="${branch:0:28}"

      case "$state" in
        MERGED)
          icon="[MERGED]"
          if [[ "$branch" != "$CURRENT_BRANCH_NOW" ]] && git show-ref --verify --quiet "refs/heads/$branch"; then
            BRANCHES_TO_DELETE+=("$branch")
          fi
          ;;
        OPEN)
          icon="[OPEN]  "
          HAS_OPEN=true
          # Only track branches that exist locally
          if git show-ref --verify --quiet "refs/heads/$branch"; then
            ACTIVE_BRANCHES+=("$branch")
          fi
          ;;
        CLOSED) icon="[CLOSED]" ;;
        *)      icon="[$state]" ;;
      esac

      printf "  #%-5s %-10s %-30s %s\n" "$number" "$icon" "$branch_short" "$title"
    done < <(echo "$PRS_JSON" | python3 -c "
import sys, json
for pr in json.load(sys.stdin):
    print(json.dumps(pr))
")

    echo "  ──────────────────────────────────────────────────────────────────"
    if $HAS_OPEN; then
      echo "  ⚠ Some PRs still open — carrying those patches locally."
    else
      echo "  ✓ All PRs merged — patch stack will be empty after rebase."
    fi

    # Clean up local + fork branches for merged PRs
    if [[ ${#BRANCHES_TO_DELETE[@]} -gt 0 ]]; then
      echo ""
      echo "── Cleaning up merged branches ───────────────────────────────────────"
      for b in "${BRANCHES_TO_DELETE[@]}"; do
        git branch -D "$b" 2>/dev/null && echo "  ✓ Deleted local: $b"
        git push "$FORK_REMOTE" --delete "$b" 2>/dev/null \
          && echo "  ✓ Deleted fork:  $b" \
          || echo "  ℹ Fork branch already gone: $b"
      done
      echo "──────────────────────────────────────────────────────────────────────"
    fi
    echo ""
  fi
fi

# ── Patch reality check via git cherry ───────────────────────────────────────
# Authoritative: checks actual code diff, not just PR state.
# Catches squash-merges and closed-without-merge where PR state lies.
if [[ ${#ACTIVE_BRANCHES[@]} -gt 0 ]]; then
  # Fetch quietly here so cherry is accurate even under --pr-check (exits before Step 1)
  git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" --quiet 2>/dev/null || true

  echo "── Patch stack vs upstream (git cherry) ─────────────────────────────────"
  for branch in "${ACTIVE_BRANCHES[@]}"; do
    echo "  [$branch]"
    CHERRY_OUT="$(git cherry -v "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" "$branch" 2>/dev/null || true)"
    if [[ -z "$CHERRY_OUT" ]]; then
      echo "    ✓ No local patches — branch is identical to upstream"
    else
      ABSORBED=0
      while IFS= read -r line; do
        marker="${line:0:1}"
        msg="${line:2}"
        if [[ "$marker" == "-" ]]; then
          echo "    - [ABSORBED] $msg"
          ABSORBED=$((ABSORBED + 1))
        else
          echo "    + [PENDING ] $msg"
        fi
      done <<< "$CHERRY_OUT"
      if [[ $ABSORBED -gt 0 ]]; then
        echo "    ⚠ $ABSORBED commit(s) already absorbed by upstream — rebase will drop them."
      fi
    fi
  done
  echo "─────────────────────────────────────────────────────────────────────────"
  echo ""
fi

$PR_CHECK_ONLY && exit 0

# ── Sanity checks ─────────────────────────────────────────────────────────────
ORIGINAL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

if ! $DRY_RUN && [[ -n "$(git status --porcelain | grep -v '^??')" ]]; then
  echo "✗ Uncommitted changes detected. Stash or commit first."
  exit 1
fi

# ── Step 1: Fetch upstream ────────────────────────────────────────────────────
echo "▶ Fetching $UPSTREAM_REMOTE/$UPSTREAM_BRANCH..."
git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"

UPSTREAM_REF="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
UPSTREAM_SHA="$(git rev-parse "$UPSTREAM_REF")"

if $DRY_RUN; then
  echo ""
  echo "── Dry run ───────────────────────────────────────────────────────────"
  echo "  Upstream HEAD: $(git rev-parse --short "$UPSTREAM_SHA")  $(git log --oneline -1 "$UPSTREAM_REF")"
  echo ""
  if [[ ${#ACTIVE_BRANCHES[@]} -eq 0 ]]; then
    echo "  No active branches found from open PRs."
  fi
  for branch in "${ACTIVE_BRANCHES[@]}"; do
    if ! git rev-parse --verify "$branch" &>/dev/null; then
      echo "  [$branch] not found locally"
      continue
    fi
    patches="$(git log --oneline "$UPSTREAM_REF".."$branch" 2>/dev/null)"
    count="$(echo "$patches" | grep -c . || true)"
    base="$(git merge-base "$branch" "$UPSTREAM_REF")"
    echo "  [$branch] $count patch(es) ahead of upstream (base: $(git rev-parse --short "$base"))"
    echo "$patches" | sed 's/^/    /'
  done
  echo "──────────────────────────────────────────────────────────────────────"
  exit 0
fi

# ── Step 2a: Rebase cumulative patch branch (primary — deploys from here) ─────
echo "▶ Rebasing $PATCH_BRANCH on $UPSTREAM_REF..."
git checkout "$PATCH_BRANCH"
if ! git rebase "$UPSTREAM_REF"; then
  echo ""
  echo "✗ Rebase conflict on $PATCH_BRANCH."
  echo "  Known safe resolutions:"
  echo "    package-lock.json, run_agent.py → git checkout --theirs <file>"
  echo "    gateway/platforms/discord.py    → git checkout --ours <file>"
  echo "  Then: git rebase --continue && re-run this script"
  git rebase --abort 2>/dev/null || true
  git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true
  exit 1
fi
echo "  ✓ Rebase complete"
git push "$FORK_REMOTE" "$PATCH_BRANCH" --force
echo "  ✓ Fork updated ($PATCH_BRANCH)"

# Print cumulative patch stack
echo ""
echo "── Patch stack ($PATCH_BRANCH) ───────────────────────────────────────────"
git log --oneline "$UPSTREAM_REF"..HEAD
echo "──────────────────────────────────────────────────────────────────────────"

# ── Step 2b: Rebase PR branches (keeps open PRs up-to-date on fork) ──────────
# These branches are submission-only — not deployed from.
for branch in "${ACTIVE_BRANCHES[@]}"; do
  [[ "$branch" == "$PATCH_BRANCH" ]] && continue
  if ! git rev-parse --verify "$branch" &>/dev/null; then
    echo "  ⚠ PR branch '$branch' not found locally — skipping"
    continue
  fi
  pending="$(git cherry -v "$UPSTREAM_REF" "$branch" 2>/dev/null | grep -c '^+' || true)"
  if [[ "$pending" -eq 0 ]]; then
    echo "  ⏩ $branch — already merged in upstream, skipping"
    continue
  fi
  echo "▶ Rebasing PR branch $branch ($pending patch(es))..."
  git checkout "$branch"
  if ! git rebase "$UPSTREAM_REF"; then
    echo "  ⚠ Conflict on $branch — skipping (fix separately, then re-run)"
    git rebase --abort 2>/dev/null || true
  else
    git push "$FORK_REMOTE" "$branch" --force
    echo "  ✓ $branch pushed to fork"
  fi
done

git checkout "$PATCH_BRANCH"

# ── Step 3: Syntax check ──────────────────────────────────────────────────────
echo "▶ Verifying Python syntax..."
python3 -m py_compile gateway/run.py && echo "  ✓ Syntax OK"

if ! $DO_DEPLOY; then
  echo ""
  echo "ℹ Deploy skipped (on $PATCH_BRANCH). Run when ready: ./scripts/deploy-remote.sh"
  git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true
  exit 0
fi

# ── Step 4: Deploy ────────────────────────────────────────────────────────────
echo ""
echo "▶ Deploying from $PATCH_BRANCH to VPS..."

ENV_LOCAL="$REPO_ROOT/.env.local"
if [[ -f "$ENV_LOCAL" ]]; then
  set -a; source "$ENV_LOCAL"; set +a
fi

bash "$SCRIPT_DIR/deploy-remote.sh"

# ── Return to original branch ─────────────────────────────────────────────────
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true
echo "✓ Done. Back on: $ORIGINAL_BRANCH"
