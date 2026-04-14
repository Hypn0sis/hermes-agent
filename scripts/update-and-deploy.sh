#!/usr/bin/env bash
# update-and-deploy.sh
#
# Full update + deploy pipeline:
#   1. Fetch upstream (origin/main)
#   2. Fast-forward local main
#   3. For each open fix branch:
#      - Skip if already merged into origin/main
#      - Otherwise rebase onto new main (auto-resolve known safe files)
#   4. Build a temporary deploy branch (main + all unmerged fixes)
#   5. rsync working tree to VPS + restart hermes-gateway
#   6. Clean up temp branch
#
# Intended to be run by Claude. Stops with clear output on conflicts or errors.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

REMOTE_HOST="hypnosis@87.106.215.151"
REMOTE_PATH="~/.hermes/hermes-agent/"
SSH_KEY="$HOME/.ssh/hypnoclaw-id_rsa"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_BRANCH="deploy/snapshot"

# Open fix branches to track (add/remove as PRs are opened/merged)
FIX_BRANCHES=(
  "fix/discord-free-channel-no-auto-thread"   # PR #9650
  "fix/discord-reply-to-mode-yaml-config"     # PR #9837
)

# Files where upstream always wins during rebase conflicts (generated/large files)
THEIRS_ON_CONFLICT=(
  "package-lock.json"
  "package.json"
  "run_agent.py"
  "gateway/run.py"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'

info()    { echo -e "${GREEN}[update-deploy]${NC} $*"; }
warn()    { echo -e "${YELLOW}[update-deploy] WARN:${NC} $*"; }
fail()    { echo -e "${RED}[update-deploy] FAIL:${NC} $*" >&2; exit 1; }

# Returns 0 if branch has no unique commits vs origin/main (i.e. already merged)
branch_is_merged() {
  local branch="$1"
  local pending
  pending=$(git cherry -v origin/main "$branch" 2>/dev/null | grep -c '^+' || true)
  [[ "$pending" -eq 0 ]]
}

# Auto-resolve conflicts: take upstream for known safe files, keep ours for the rest.
# Returns 1 if unresolvable conflicts remain.
auto_resolve_conflicts() {
  local conflicts
  conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
  if [[ -z "$conflicts" ]]; then return 0; fi

  local unresolved=()
  while IFS= read -r file; do
    local safe=false
    for pattern in "${THEIRS_ON_CONFLICT[@]}"; do
      if [[ "$file" == *"$pattern"* ]]; then
        safe=true; break
      fi
    done
    if $safe; then
      info "  auto-resolve (take upstream): $file"
      git checkout --theirs -- "$file"
      git add "$file"
    else
      unresolved+=("$file")
    fi
  done <<< "$conflicts"

  if [[ ${#unresolved[@]} -gt 0 ]]; then
    warn "Unresolvable conflicts in:"
    for f in "${unresolved[@]}"; do echo "    $f"; done
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Step 1 — Fetch & fast-forward main
# ---------------------------------------------------------------------------

cd "$REPO_ROOT"

info "Fetching origin ..."
git fetch origin

ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
info "Currently on: $ORIGINAL_BRANCH"

info "Fast-forwarding main to origin/main ..."
git checkout main
git reset --hard origin/main
info "main → $(git rev-parse --short HEAD)"

# ---------------------------------------------------------------------------
# Step 2 — Rebase each fix branch onto new main
# ---------------------------------------------------------------------------

UNMERGED_BRANCHES=()

for branch in "${FIX_BRANCHES[@]}"; do
  # Extract just the branch name (strip inline comment if present)
  branch="${branch%% *}"

  if ! git rev-parse --verify "$branch" &>/dev/null; then
    warn "Branch '$branch' not found locally — skipping"
    continue
  fi

  if branch_is_merged "$branch"; then
    info "Branch '$branch' already merged in origin/main — skipping"
    continue
  fi

  info "Rebasing $branch onto main ..."
  git checkout "$branch"

  if git rebase main; then
    info "$branch rebased cleanly"
    UNMERGED_BRANCHES+=("$branch")
    continue
  fi

  # Rebase hit conflicts — try auto-resolve
  warn "Conflicts on $branch — attempting auto-resolve ..."
  if auto_resolve_conflicts; then
    git rebase --continue
    info "$branch rebased after auto-resolve"
    UNMERGED_BRANCHES+=("$branch")
  else
    git rebase --abort
    fail "Could not auto-resolve conflicts on '$branch'. Aborting. Fix manually then re-run."
  fi
done

# ---------------------------------------------------------------------------
# Step 3 — Build deploy snapshot
# ---------------------------------------------------------------------------

info "Building deploy snapshot branch: $DEPLOY_BRANCH ..."
git checkout main

# Delete previous snapshot if it exists
git branch -D "$DEPLOY_BRANCH" 2>/dev/null || true
git checkout -b "$DEPLOY_BRANCH"

for branch in "${UNMERGED_BRANCHES[@]}"; do
  info "Merging $branch into snapshot ..."
  if git merge --no-ff --no-edit "$branch"; then
    continue
  fi
  # Auto-resolve add/add conflicts in scripts/ — same file added by multiple branches
  conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
  unresolved=()
  while IFS= read -r file; do
    if [[ "$file" == scripts/* ]]; then
      info "  auto-resolve merge conflict (take ours): $file"
      git checkout --ours -- "$file"
      git add "$file"
    else
      unresolved+=("$file")
    fi
  done <<< "$conflicts"
  if [[ ${#unresolved[@]} -gt 0 ]]; then
    fail "Merge conflict in '$branch' (unresolvable files: ${unresolved[*]}). Inspect and re-run."
  fi
  git merge --continue --no-edit
done

info "Snapshot: $(git log --oneline -5)"

# ---------------------------------------------------------------------------
# Step 4 — rsync to VPS
# ---------------------------------------------------------------------------

info "Syncing to $REMOTE_HOST ..."
/usr/bin/rsync -az --delete \
  --exclude='.git/' \
  --exclude='venv/' \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='.env' \
  --exclude='node_modules/' \
  --exclude='my-docs/' \
  --exclude='.planning/' \
  --exclude='.claude/' \
  -e "ssh -i $SSH_KEY" \
  "$REPO_ROOT/" \
  "$REMOTE_HOST:$REMOTE_PATH"

# ---------------------------------------------------------------------------
# Step 5 — Restart service
# ---------------------------------------------------------------------------

info "Restarting hermes-gateway ..."
ssh -i "$SSH_KEY" "$REMOTE_HOST" "systemctl --user restart hermes-gateway"
sleep 2
STATUS=$(ssh -i "$SSH_KEY" "$REMOTE_HOST" "systemctl --user is-active hermes-gateway" 2>&1 || true)

if [[ "$STATUS" == "active" ]]; then
  info "hermes-gateway is active ✓"
else
  fail "hermes-gateway status: $STATUS — check VPS logs"
fi

# ---------------------------------------------------------------------------
# Step 6 — Cleanup
# ---------------------------------------------------------------------------

git checkout "$ORIGINAL_BRANCH"
git branch -D "$DEPLOY_BRANCH"
info "Cleanup done. Back on: $ORIGINAL_BRANCH"
info "Deploy complete."
