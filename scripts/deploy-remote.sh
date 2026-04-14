#!/usr/bin/env bash
# Deploy local hermes-agent working tree to VPS and restart the gateway service.
set -euo pipefail

REMOTE_HOST="hypnosis@87.106.215.151"
REMOTE_PATH="~/.hermes/hermes-agent/"
SSH_KEY="$HOME/.ssh/hypnoclaw-id_rsa"
LOCAL_PATH="$(cd "$(dirname "$0")/.." && pwd)/"

echo "Syncing to $REMOTE_HOST:$REMOTE_PATH ..."
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
  "$LOCAL_PATH" \
  "$REMOTE_HOST:$REMOTE_PATH"

echo "Restarting hermes-gateway ..."
ssh -i "$SSH_KEY" "$REMOTE_HOST" "systemctl --user restart hermes-gateway"

echo "Status:"
ssh -i "$SSH_KEY" "$REMOTE_HOST" "systemctl --user is-active hermes-gateway"
