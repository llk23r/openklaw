# OpenKlaw

Security-hardened [OpenClaw](https://openclaw.ai) on Railway with NVIDIA NIM (Kimi K2.5) and Telegram.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/template/openklaw?referralCode=openklaw)

## Deploy

Click the button above, then fill in:

| Variable | Required | Description |
|---|---|---|
| `MOONSHOT_API_KEY` | Yes | NVIDIA NIM API key — [get one here](https://build.nvidia.com) |
| `GATEWAY_TOKEN` | Yes | Any secret string for Control UI access |
| `TELEGRAM_BOT_TOKEN` | No | From [@BotFather](https://t.me/BotFather) |
| `TELEGRAM_USER_ID` | No | Your numeric Telegram ID (message [@userinfobot](https://t.me/userinfobot) to find it) |
| `SYSTEM_PROMPT` | No | Custom agent personality |

## How it works

```
User clicks "Deploy on Railway"
  |
  v
Railway prompts for env vars
  |
  v
Container starts:
  1. Validates env vars (fail-fast)
  2. Pre-flights NVIDIA NIM API key
  3. Generates config from templates
  4. Generates welcome page
  5. Starts gateway on $PORT
  |
  v
User visits https://<app>.up.railway.app
  -> Enters GATEWAY_TOKEN
  -> Chats via Control UI
  |
  v
(Optional) Messages Telegram bot
  -> Immediate if TELEGRAM_USER_ID set
  -> Pairing mode if not
```

## Security

Baked in, not configurable:

- Token auth for all gateway access
- Tool profile: `messaging` (minimal surface)
- Denied: automation, runtime, session spawning, gateway modification, cron
- Filesystem: workspace-only
- Exec: denied
- Elevated mode: off
- Session isolation: per-channel-peer
- mDNS: off
