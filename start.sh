#!/bin/bash
set -e

CONFIG_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"

# Ensure directories exist (volume mount starts empty)
mkdir -p "$CONFIG_DIR" /data/workspace
chown -R node:node /data

# Preserve auth token across deploys
if [ -f "$CONFIG_FILE" ]; then
  EXISTING_TOKEN=$(su -s /bin/bash node -c "node -e \"try{console.log(JSON.parse(require('fs').readFileSync('$CONFIG_FILE','utf8')).gateway?.auth?.token||'')}catch{console.log('')}\"" 2>/dev/null)
fi

echo "Initializing OpenClaw config..."
cp /tmp/openclaw.json "$CONFIG_FILE"
chown node:node "$CONFIG_FILE"

# Restore auth token if we had one
if [ -n "$EXISTING_TOKEN" ]; then
  su -s /bin/bash node -c "node -e \"
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf8'));
    cfg.gateway = cfg.gateway || {};
    cfg.gateway.auth = cfg.gateway.auth || {};
    cfg.gateway.auth.token = '$EXISTING_TOKEN';
    fs.writeFileSync('$CONFIG_FILE', JSON.stringify(cfg, null, 2));
  \""
  echo "Auth token restored from previous deploy."
fi

# Start the gateway as node user
PORT="${PORT:-8080}"
echo "Starting OpenClaw gateway on port $PORT..."
exec su -s /bin/bash node -c "openclaw gateway --port $PORT"
