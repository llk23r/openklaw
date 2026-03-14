# OpenKlaw

[OpenClaw](https://openclaw.ai) on Railway with NVIDIA NIM (Kimi K2.5) and Telegram. Optional Tailscale for zero public exposure.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/openklaw)

## Deploy

Click the button above, then fill in:

| Variable | Required | Description |
|---|---|---|
| `MOONSHOT_API_KEY` | Yes | NVIDIA NIM API key -- [get one here](https://build.nvidia.com/settings/api-keys) |
| `GATEWAY_TOKEN` | Yes | Any secret string for Control UI access |
| `TELEGRAM_BOT_TOKEN` | No | From [@BotFather](https://t.me/BotFather) |
| `TELEGRAM_USER_ID` | No | Your numeric Telegram ID (message [@userinfobot](https://t.me/userinfobot) to find it) |
| `SYSTEM_PROMPT` | No | Custom agent personality |
| `TS_AUTHKEY` | No | Tailscale auth key -- [generate one here](https://login.tailscale.com/admin/settings/keys) |
| `TS_HOSTNAME` | No | Tailscale machine name (default: `openklaw`) |

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
  3. Starts Tailscale (if TS_AUTHKEY set)
  4. Generates config from templates
  5. Generates welcome page
  6. Starts gateway
  |
  v
Without Tailscale:
  User visits https://<app>.up.railway.app
  -> Enters GATEWAY_TOKEN -> Chats via Control UI

With Tailscale:
  User visits https://openklaw.<tailnet>.ts.net
  -> Authenticated via Tailscale identity
  -> Zero public exposure
```

## Security

**Public mode** (no Tailscale) -- hardened:

- Token auth for all gateway access
- Tool profile: `messaging` (minimal surface)
- Denied: automation, runtime, session spawning, gateway modification, cron
- Filesystem: workspace-only
- Exec: denied
- Elevated mode: off
- Session isolation: per-channel-peer

**Tailscale mode** -- network-level trust:

- Gateway binds to loopback only (not publicly reachable)
- Tailscale identity used for auth
- Tool restrictions relaxed (exec allowed with confirmation)
- Filesystem: still workspace-only
- Elevated mode: still off
