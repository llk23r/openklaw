#!/bin/bash
set -euo pipefail

# ============================================================
# OpenKlaw — Railway Entrypoint
# Generates config from env vars, validates, starts gateway.
# ============================================================

CONFIG_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
CANVAS_DIR="$CONFIG_DIR/canvas"
PORT="${PORT:-8080}"

# --- Step 1: Init volume dirs + fix permissions ---
mkdir -p "$CONFIG_DIR" /data/workspace "$CANVAS_DIR"
chown -R node:node /data

# --- Step 2: Validate env vars ---
echo ""
echo "Checking configuration..."
ERRORS=0

check_required() {
  local name="$1" val="${!1:-}"
  if [ -n "$val" ]; then
    echo "  [ok] $name"
  else
    echo "  [!!] $name is not set"
    ERRORS=$((ERRORS + 1))
  fi
}

check_optional() {
  local name="$1" val="${!1:-}" fallback="$2"
  if [ -n "$val" ]; then
    echo "  [ok] $name"
  else
    echo "  [--] $name ($fallback)"
  fi
}

check_required MOONSHOT_API_KEY
check_required GATEWAY_TOKEN
check_optional TELEGRAM_BOT_TOKEN "not set — Telegram disabled"
check_optional TELEGRAM_USER_ID "not set — using pairing mode"
check_optional SYSTEM_PROMPT "using default"
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
  401|403)
    echo "  [!!] API key rejected ($HTTP_CODE)"
    echo "  Get a valid key at https://build.nvidia.com"
    exit 1
    ;;
  000)
    echo "  [warn] API unreachable (timeout) — continuing anyway"
    ;;
  *)
    echo "  [warn] Unexpected response ($HTTP_CODE) — continuing anyway"
    ;;
esac
echo ""

# --- Step 4: Generate openclaw.json ---

# Detect first boot vs restart
if [ -f "$CONFIG_FILE" ]; then
  echo "Restart detected — regenerating config, preserving state."
else
  echo "First boot — generating config."
fi

# Build Telegram config block
TELEGRAM_BLOCK=""
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  if [ -n "${TELEGRAM_USER_ID:-}" ]; then
    TELEGRAM_BLOCK=$(cat <<TGEOF
  "channels": {
    "telegram": {
      "enabled": true,
      "dmPolicy": "allowlist",
      "allowFrom": ["$TELEGRAM_USER_ID"]
    }
  },
TGEOF
)
  else
    TELEGRAM_BLOCK=$(cat <<TGEOF
  "channels": {
    "telegram": {
      "enabled": true,
      "dmPolicy": "pairing"
    }
  },
TGEOF
)
  fi
fi

# Build system prompt block
AGENT_SYSTEM_PROMPT=""
if [ -n "${SYSTEM_PROMPT:-}" ]; then
  # Escape quotes and newlines for JSON
  ESCAPED_PROMPT=$(echo "$SYSTEM_PROMPT" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n' | sed 's/\\n$//')
  AGENT_SYSTEM_PROMPT="\"systemPrompt\": \"$ESCAPED_PROMPT\","
fi

# Detect Railway domain for allowed origins
DOMAIN="${RAILWAY_PUBLIC_DOMAIN:-}"
ORIGINS_BLOCK=""
if [ -n "$DOMAIN" ]; then
  ORIGINS_BLOCK="\"allowedOrigins\": [\"https://$DOMAIN\"],"
fi

cat > "$CONFIG_FILE" <<CFGEOF
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "trustedProxies": ["100.64.0.0/10"],
    "auth": {
      "mode": "token",
      "token": "$GATEWAY_TOKEN"
    },
    "controlUi": {
      $ORIGINS_BLOCK
      "dangerouslyDisableDeviceAuth": false
    }
  },
  "session": {
    "dmScope": "per-channel-peer"
  },
  "tools": {
    "profile": "messaging",
    "deny": [
      "group:automation", "group:runtime",
      "sessions_spawn", "sessions_send",
      "gateway", "cron"
    ],
    "fs": { "workspaceOnly": true },
    "exec": { "security": "deny", "ask": "always" },
    "elevated": { "enabled": false }
  },
  "discovery": { "mdns": { "mode": "off" } },
  "logging": { "redactSensitive": "tools" },
  $TELEGRAM_BLOCK
  "models": {
    "mode": "merge",
    "providers": {
      "nvidia-nim": {
        "baseUrl": "https://integrate.api.nvidia.com/v1",
        "apiKey": "\${MOONSHOT_API_KEY}",
        "api": "openai-completions",
        "models": [
          {
            "id": "moonshotai/kimi-k2.5",
            "name": "Kimi K2.5 (NVIDIA)",
            "reasoning": false,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 200000,
            "maxTokens": 8192
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      $AGENT_SYSTEM_PROMPT
      "model": { "primary": "nvidia-nim/moonshotai/kimi-k2.5" },
      "sandbox": { "mode": "off" }
    }
  }
}
CFGEOF

echo "  Config written to $CONFIG_FILE"
echo ""

# --- Step 5: Generate welcome page ---

# Detect Telegram bot username if configured
BOT_LINK=""
BOT_HTML=""
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  BOT_USERNAME=$(curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null \
    | node -e "try{const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));console.log(d.result.username)}catch{}" 2>/dev/null || echo "")
  if [ -n "$BOT_USERNAME" ]; then
    BOT_LINK="https://t.me/$BOT_USERNAME"
    BOT_HTML="<a href=\"$BOT_LINK\" class=\"btn tg\">Open in Telegram &rarr; @$BOT_USERNAME</a>"
  fi
fi

# Telegram status
TG_STATUS="Not configured"
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  if [ -n "${TELEGRAM_USER_ID:-}" ]; then
    TG_STATUS="Allowlist (user $TELEGRAM_USER_ID)"
  else
    TG_STATUS="Pairing mode (message the bot for a code)"
  fi
fi

cat > "$CANVAS_DIR/index.html" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>OpenKlaw</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:system-ui,sans-serif;background:#1a1a2e;color:#e0e0e0;display:flex;justify-content:center;align-items:center;min-height:100vh;padding:1rem}
.card{background:#16213e;border-radius:12px;padding:2rem;max-width:480px;width:100%;text-align:center}
h1{color:#e74c3c;font-size:1.6rem;margin-bottom:.3rem}
.sub{color:#888;margin-bottom:1.5rem}
.btn{display:block;padding:.8rem 1.2rem;border-radius:8px;text-decoration:none;font-weight:600;margin:.5rem 0;font-size:.95rem}
.dash{background:#e74c3c;color:#fff}
.dash:hover{background:#c0392b}
.tg{background:#0088cc;color:#fff}
.tg:hover{background:#006da3}
.status{margin-top:1.5rem;text-align:left;font-size:.85rem;border-top:1px solid #2a2a4a;padding-top:1rem}
.status div{display:flex;justify-content:space-between;padding:.3rem 0}
.status .val{color:#2ecc71}
.status .warn{color:#f39c12}
</style>
</head>
<body>
<div class="card">
<h1>OpenKlaw</h1>
<p class="sub">Your AI agent is running</p>
<a href="/" class="btn dash">Open Dashboard</a>
$BOT_HTML
<div class="status">
<div><span>Model</span><span class="val">Kimi K2.5 (NVIDIA NIM)</span></div>
<div><span>Telegram</span><span class="${TG_STATUS:+val}">${TG_STATUS}</span></div>
<div><span>Security</span><span class="val">Token auth + hardened</span></div>
</div>
</div>
</body>
</html>
HTMLEOF

# --- Step 6: Print startup banner ---

echo "=========================================="
echo ""
if [ -n "$DOMAIN" ]; then
  echo "  OpenKlaw is live!"
  echo ""
  echo "  Dashboard : https://$DOMAIN"
else
  echo "  OpenKlaw is starting!"
  echo ""
  echo "  Dashboard : http://localhost:$PORT"
fi

if [ -n "$BOT_LINK" ]; then
  echo "  Telegram  : $BOT_LINK"
fi

echo ""
echo "  Model     : Kimi K2.5 (NVIDIA NIM)"
echo "  Security  : token-auth, tools-restricted"
echo ""
echo "=========================================="
echo ""

# --- Step 7: Start gateway (as node user) ---
# Export PORT so the child shell sees it
export PORT
exec su -s /bin/bash node -c 'exec openclaw gateway --port "$PORT"'
