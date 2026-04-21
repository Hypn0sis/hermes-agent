#!/usr/bin/env bash
# deploy-remote.sh — Rsync working tree to VPS and restart hermes-gateway
#
# Credentials are read from env vars (set via .env.local or parent script).
# Defaults match the known VPS config if vars are unset.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

# Load .env.local if called directly (not via sync-upstream-and-deploy.sh)
ENV_LOCAL="$REPO_ROOT/.env.local"
if [[ -f "$ENV_LOCAL" ]]; then
  set -a; source "$ENV_LOCAL"; set +a
fi

REMOTE_USER="${DEPLOY_USER:-hypnosis}"
REMOTE_HOST="${DEPLOY_HOST:-87.106.215.151}"
REMOTE_SSH_KEY="${DEPLOY_SSH_KEY:-$HOME/.ssh/hypnoclaw-id_rsa}"
REMOTE_SERVICE="${DEPLOY_SERVICE:-hermes-gateway}"
REMOTE_PATH="\$HOME/.hermes/hermes-agent/"
DEPLOY_SHA_FILE="$REPO_ROOT/.last-deploy-sha"

SSH_CMD="ssh -i $REMOTE_SSH_KEY"

# Skip deploy if HEAD SHA matches last deployed SHA
CURRENT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
if [[ -f "$DEPLOY_SHA_FILE" ]] && [[ "$(cat "$DEPLOY_SHA_FILE")" == "$CURRENT_SHA" ]]; then
  echo "✓ Already deployed ($CURRENT_SHA) — nothing to do."
  exit 0
fi

echo "▶ Stopping $REMOTE_SERVICE on $REMOTE_USER@$REMOTE_HOST..."
$SSH_CMD "$REMOTE_USER@$REMOTE_HOST" "systemctl --user stop $REMOTE_SERVICE 2>/dev/null || true"
echo "  ✓ Stopped"

echo "▶ Syncing files..."
/usr/bin/rsync -az --delete \
  -e "$SSH_CMD" \
  --exclude='.git/' \
  --exclude='venv/' \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='.env' \
  --exclude='.env.local' \
  --exclude='node_modules/' \
  --exclude='my-docs/' \
  --exclude='.planning/' \
  --exclude='.claude/' \
  "$REPO_ROOT/" \
  "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH"
echo "  ✓ Files synced"

echo "▶ Starting $REMOTE_SERVICE..."
$SSH_CMD "$REMOTE_USER@$REMOTE_HOST" "systemctl --user start $REMOTE_SERVICE"
sleep 2

STATUS="$($SSH_CMD "$REMOTE_USER@$REMOTE_HOST" "systemctl --user is-active $REMOTE_SERVICE" 2>&1 || true)"
if [[ "$STATUS" == "active" ]]; then
  echo "  ✓ $REMOTE_SERVICE is active"
else
  echo "  ✗ $REMOTE_SERVICE status: $STATUS"
  echo "    Check: journalctl --user -u $REMOTE_SERVICE -n 50"
  exit 1
fi

echo "$CURRENT_SHA" > "$DEPLOY_SHA_FILE"

echo ""
echo "✓ Deploy complete → $REMOTE_USER@$REMOTE_HOST"
