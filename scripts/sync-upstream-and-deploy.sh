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
DEPLOY_BRANCH="deploy/snapshot"

# Open fix branches — one per open PR.
# Remove an entry when its PR is merged upstream (confirm with: git log origin/main | grep <keyword>)
FIX_BRANCHES=(
  "fix/discord-free-channel-no-auto-thread"   # PR #9650
  "fix/discord-reply-to-mode-yaml-config"     # PR #9837
)

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

if ! command -v gh &>/dev/null; then
  echo "  ⚠ gh CLI not found — skipping PR check"
elif ! gh auth status &>/dev/null 2>&1; then
  echo "  ⚠ gh not authenticated — skipping PR check"
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
    BRANCHES_TO_DELETE=()
    CURRENT_BRANCH_NOW="$(git rev-parse --abbrev-ref HEAD)"

    while IFS= read -r pr; do
      number="$(echo "$pr" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['number'])")"
      title="$(echo  "$pr" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['title'][:48])")"
      state="$(echo  "$pr" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['state'])")"
      branch="$(echo "$pr" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['headRefName'][:28])")"

      case "$state" in
        MERGED)
          icon="[MERGED]"
          if [[ "$branch" != "$CURRENT_BRANCH_NOW" ]] && git show-ref --verify --quiet "refs/heads/$branch"; then
            BRANCHES_TO_DELETE+=("$branch")
          fi
          ;;
        OPEN)   icon="[OPEN]  "; HAS_OPEN=true ;;
        CLOSED) icon="[CLOSED]" ;;
        *)      icon="[$state]" ;;
      esac

      printf "  #%-5s %-10s %-30s %s\n" "$number" "$icon" "$branch" "$title"
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
        # Also remove from FIX_BRANCHES tracking (informational)
        echo "  ⚠ Remember to remove '$b' from FIX_BRANCHES in this script."
      done
      echo "──────────────────────────────────────────────────────────────────────"
    fi
    echo ""
  fi
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
  for branch in "${FIX_BRANCHES[@]}"; do
    branch="${branch%% *}"
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

# ── Step 2: Rebase each fix branch + push to fork ────────────────────────────
ACTIVE_BRANCHES=()

for branch in "${FIX_BRANCHES[@]}"; do
  branch="${branch%% *}"

  if ! git rev-parse --verify "$branch" &>/dev/null; then
    echo "  ⚠ Branch '$branch' not found locally — skipping"
    continue
  fi

  # Check if already fully merged into upstream
  pending="$(git cherry -v "$UPSTREAM_REF" "$branch" 2>/dev/null | grep -c '^+' || true)"
  if [[ "$pending" -eq 0 ]]; then
    echo "  ⏩ $branch — already merged in upstream, skipping"
    continue
  fi

  echo "▶ Rebasing $branch on $UPSTREAM_REF ($pending patch(es))..."
  git checkout "$branch"

  if ! git rebase "$UPSTREAM_REF"; then
    echo ""
    echo "✗ Rebase conflict on $branch."
    echo "  Known safe resolutions:"
    echo "    package-lock.json, run_agent.py → git checkout --theirs <file>"
    echo "    gateway/platforms/discord.py    → git checkout --ours <file>"
    echo "  Then: git rebase --continue && re-run this script"
    git rebase --abort 2>/dev/null || true
    git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true
    exit 1
  fi
  echo "  ✓ Rebase complete"

  echo "  ▶ Pushing $branch to $FORK_REMOTE..."
  git push "$FORK_REMOTE" "$branch" --force
  echo "  ✓ Fork updated"

  ACTIVE_BRANCHES+=("$branch")
done

git checkout "$ORIGINAL_BRANCH" 2>/dev/null || git checkout main

if [[ ${#ACTIVE_BRANCHES[@]} -eq 0 ]]; then
  echo "ℹ No active patch branches — nothing to deploy beyond upstream main."
fi

# Print patch summary
echo ""
echo "── Patch stack ───────────────────────────────────────────────────────"
for branch in "${ACTIVE_BRANCHES[@]}"; do
  echo "  [$branch]"
  git log --oneline "$UPSTREAM_REF".."$branch" | sed 's/^/    /'
done
echo "──────────────────────────────────────────────────────────────────────"

# ── Step 3: Syntax check ──────────────────────────────────────────────────────
echo "▶ Verifying Python syntax..."
python3 -m py_compile gateway/run.py && echo "  ✓ Syntax OK"

$DO_DEPLOY || { echo ""; echo "ℹ Deploy skipped. Run when ready: ./scripts/deploy-remote.sh"; exit 0; }

# ── Step 4: Build deploy snapshot ────────────────────────────────────────────
echo "▶ Building deploy snapshot: $DEPLOY_BRANCH..."

git checkout main
git reset --hard "$UPSTREAM_REF"

git branch -D "$DEPLOY_BRANCH" 2>/dev/null || true
git checkout -b "$DEPLOY_BRANCH"

for branch in "${ACTIVE_BRANCHES[@]}"; do
  echo "  Merging $branch..."
  if git merge --no-ff --no-edit "$branch"; then
    continue
  fi
  # Auto-resolve add/add conflicts in scripts/ (same file added by multiple branches)
  conflicts="$(git diff --name-only --diff-filter=U 2>/dev/null || true)"
  unresolved=()
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if [[ "$file" == scripts/* ]]; then
      git checkout --ours -- "$file"
      git add "$file"
      echo "  ✓ auto-resolved (ours): $file"
    else
      unresolved+=("$file")
    fi
  done <<< "$conflicts"
  if [[ ${#unresolved[@]} -gt 0 ]]; then
    echo "✗ Unresolvable merge conflict in $branch: ${unresolved[*]}"
    git merge --abort 2>/dev/null || true
    git checkout "$ORIGINAL_BRANCH"
    git branch -D "$DEPLOY_BRANCH" 2>/dev/null || true
    exit 1
  fi
  git commit --no-edit
done

# ── Step 5: Deploy ────────────────────────────────────────────────────────────
echo ""
echo "▶ Deploying snapshot to VPS..."

# Load deploy credentials from .env.local if present
ENV_LOCAL="$REPO_ROOT/.env.local"
if [[ -f "$ENV_LOCAL" ]]; then
  set -a; source "$ENV_LOCAL"; set +a
fi

bash "$SCRIPT_DIR/deploy-remote.sh"

# ── Cleanup ───────────────────────────────────────────────────────────────────
git checkout "$ORIGINAL_BRANCH"
git branch -D "$DEPLOY_BRANCH" 2>/dev/null || true
echo "✓ Done. Back on: $ORIGINAL_BRANCH"
