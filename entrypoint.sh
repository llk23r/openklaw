#!/bin/bash
set -euo pipefail

# ============================================================
# OpenKlaw — Railway Entrypoint
# Validates env vars, optionally starts Tailscale,
# generates config from templates, starts gateway.
# ============================================================

CONFIG_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
CANVAS_DIR="$CONFIG_DIR/canvas"
PORT="${PORT:-8080}"
TAILSCALE_ENABLED="${TS_AUTHKEY:+true}"

# --- Step 1: Init volume dirs + fix permissions ---
mkdir -p "$CONFIG_DIR" /data/workspace "$CANVAS_DIR" /data/tailscale
chown -R node:node /data

# --- Step 2: Validate env vars ---
echo ""
echo "Checking configuration..."
ERRORS=0

check_required() {
  local name="$1" val="${!1:-}"
  if [ -n "$val" ]; then echo "  [ok] $name"
  else echo "  [!!] $name is not set"; ERRORS=$((ERRORS + 1)); fi
}

check_optional() {
  local name="$1" val="${!1:-}" fallback="$2"
  if [ -n "$val" ]; then echo "  [ok] $name"
  else echo "  [--] $name ($fallback)"; fi
}

check_required MOONSHOT_API_KEY
check_required GATEWAY_TOKEN
check_optional TS_AUTHKEY "not set — public mode (no Tailscale)"
check_optional TELEGRAM_BOT_TOKEN "not set — Telegram disabled"
check_optional TELEGRAM_USER_ID "not set — using pairing mode"
check_optional SYSTEM_PROMPT "using default"
check_optional NODE_MAX_HEAP "default: 384 MB"
echo ""

if [ "$ERRORS" -gt 0 ]; then
  echo "Missing $ERRORS required variable(s). Set them in the Railway dashboard."
  echo ""
  echo "  MOONSHOT_API_KEY  — Get one at https://build.nvidia.com"
  echo "  GATEWAY_TOKEN     — Choose any secret string for Control UI access"
  echo ""
  exit 1
fi

# --- Step 3: Pre-flight NVIDIA NIM validation ---
echo "Validating NVIDIA NIM API key..."
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $MOONSHOT_API_KEY" \
  --max-time 10 \
  "https://integrate.api.nvidia.com/v1/models" 2>/dev/null || echo "000")

case "$HTTP_CODE" in
  200) echo "  [ok] API key valid" ;;
  401|403) echo "  [!!] API key rejected ($HTTP_CODE)"; echo "  Get a valid key at https://build.nvidia.com"; exit 1 ;;
  000)     echo "  [warn] API unreachable (timeout) — continuing anyway" ;;
  *)       echo "  [warn] Unexpected response ($HTTP_CODE) — continuing anyway" ;;
esac
echo ""

# --- Step 4: Start Tailscale (if configured) ---
TS_URL=""
if [ -n "$TAILSCALE_ENABLED" ]; then
  echo "Starting Tailscale (userspace networking)..."

  # Copy serve config to volume (must be a directory mount for Tailscale to detect changes)
  mkdir -p /data/tailscale/config
  cp /app/templates/ts-serve.json /data/tailscale/config/serve.json

  # Start tailscaled with serve config
  TS_SERVE_CONFIG=/data/tailscale/config/serve.json \
  tailscaled \
    --state=/data/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock \
    --tun=userspace-networking &

  # Wait for socket
  for i in $(seq 1 20); do
    [ -S /var/run/tailscale/tailscaled.sock ] && break
    sleep 0.5
  done

  if [ ! -S /var/run/tailscale/tailscaled.sock ]; then
    echo "  [!!] tailscaled failed to start"
    exit 1
  fi

  # Authenticate and bring up the network
  tailscale up \
    --authkey="$TS_AUTHKEY" \
    --hostname="${TS_HOSTNAME:-openklaw}" \
    --accept-routes=false

  # Get Tailscale URL
  TS_URL=$(tailscale status --json 2>/dev/null \
    | node -e "try{const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));console.log('https://'+d.Self.DNSName.replace(/\.$/,''))}catch{}" 2>/dev/null || echo "")

  if [ -n "$TS_URL" ]; then
    echo "  [ok] Tailscale connected: $TS_URL"
  else
    echo "  [warn] Tailscale connected but could not determine URL"
  fi
  echo ""
fi

# --- Step 5: Generate openclaw.json from template ---
if [ -f "$CONFIG_FILE" ]; then echo "Restart detected — regenerating config, preserving state."
else echo "First boot — generating config."; fi

node /app/templates/config.cjs > "$CONFIG_FILE"
chown node:node "$CONFIG_FILE"
echo "  Config written to $CONFIG_FILE"
echo ""

# --- Step 6: Generate welcome page from template ---
BOT_LINK=""
BOT_HTML=""
TG_STATUS="Not configured"

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  BOT_USERNAME=$(curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null \
    | node -e "try{const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));console.log(d.result.username)}catch{}" 2>/dev/null || echo "")
  if [ -n "$BOT_USERNAME" ]; then
    BOT_LINK="https://t.me/$BOT_USERNAME"
    BOT_HTML="<a href=\"$BOT_LINK\" class=\"btn tg\">Open in Telegram → @$BOT_USERNAME</a>"
  fi
  if [ -n "${TELEGRAM_USER_ID:-}" ]; then TG_STATUS="Allowlist (user $TELEGRAM_USER_ID)"
  else TG_STATUS="Pairing mode (message the bot for a code)"; fi
fi

sed -e "s|{{TELEGRAM_BUTTON}}|$BOT_HTML|g" \
    -e "s|{{TELEGRAM_STATUS}}|$TG_STATUS|g" \
    /app/templates/welcome.html > "$CANVAS_DIR/index.html"
chown node:node "$CANVAS_DIR/index.html"

# --- Step 7: Print startup banner ---
DOMAIN="${RAILWAY_PUBLIC_DOMAIN:-}"
ACCESS_MODE="public (token-auth)"
DASHBOARD_URL=""

if [ -n "$TAILSCALE_ENABLED" ] && [ -n "$TS_URL" ]; then
  DASHBOARD_URL="$TS_URL"
  ACCESS_MODE="tailscale-only (zero public exposure)"
elif [ -n "$DOMAIN" ]; then
  DASHBOARD_URL="https://$DOMAIN"
else
  DASHBOARD_URL="http://localhost:$PORT"
fi

echo "=========================================="
echo ""
echo "  OpenKlaw is live!"
echo ""
echo "  Dashboard : $DASHBOARD_URL"
if [ -n "$BOT_LINK" ]; then echo "  Telegram  : $BOT_LINK"; fi
echo ""
echo "  Model     : Kimi K2.5 (NVIDIA NIM)"
echo "  Access    : $ACCESS_MODE"
echo ""
echo "=========================================="
echo ""

# --- Step 8: Start gateway (as node user) ---
export PORT
export NODE_OPTIONS="--max-old-space-size=${NODE_MAX_HEAP:-384} ${NODE_OPTIONS:-}"
exec su -s /bin/bash node -c 'exec openclaw gateway --port "$PORT"'
