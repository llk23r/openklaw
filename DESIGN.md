# OpenKlaw Railway Template — Design Doc

## Overview

A minimal, security-hardened Railway template for deploying OpenClaw with NVIDIA NIM (Kimi K2.5) and Telegram. Two files, fully driven by environment variables.

---

## Architecture

```
                        INTERNET
                           |
                    [ Railway Proxy ]
                     (TLS termination)
                           |
                  :8080 (PORT)
                           |
              +------------------------+
              |   OpenClaw Gateway     |
              |                        |
              |  - Control UI (web)    |
              |  - WebSocket API       |
              |  - Telegram polling    |
              |  - Agent engine        |
              +------------------------+
                    |            |
          +---------+            +-----------+
          |                                  |
  [ /data volume ]              [ NVIDIA NIM API ]
  (persistent state,            (Kimi K2.5 model)
   auth token,                  integrate.api.nvidia.com
   workspace,
   session memory)
```

### Components

| Component | What it does |
|---|---|
| **Railway Proxy** | TLS termination, routes traffic to container port 8080 |
| **OpenClaw Gateway** | Core runtime — serves Control UI, runs agents, polls Telegram |
| **Volume `/data`** | Persists config, auth token, agent memory, workspace across deploys |
| **NVIDIA NIM** | LLM inference endpoint for Kimi K2.5 |
| **Telegram Bot API** | Long-polling connection for receiving/sending messages |

### Files

| File | Purpose |
|---|---|
| `Dockerfile` | Base image + inline entrypoint that generates config from env vars |
| `railway.toml` | Volume mount, deploy settings, healthcheck |

---

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `MOONSHOT_API_KEY` | Yes | NVIDIA NIM API key (nvapi-...) |
| `GATEWAY_TOKEN` | Yes | Auth token for Control UI access (user chooses) |
| `TELEGRAM_BOT_TOKEN` | No | Bot token from @BotFather |
| `TELEGRAM_USER_ID` | No | Numeric Telegram user ID for allowlist |
| `PORT` | Auto | Set by Railway (default 8080) |

---

## Sequence Diagrams

### 1. Container Startup

```
Railway                  Container                    Volume /data
  |                         |                             |
  |-- start container ----->|                             |
  |                         |-- mkdir -p /data/.openclaw ->|
  |                         |                             |
  |                         |-- read existing auth token ->|
  |                         |   (if volume has prior data) |
  |                         |                             |
  |                         |-- generate openclaw.json --->|
  |                         |   (from env vars,            |
  |                         |    restore token if exists)  |
  |                         |                             |
  |                         |-- exec openclaw gateway ---->|
  |                         |   (binds 0.0.0.0:PORT)      |
  |                         |                             |
  |                         |----------- poll ----------->| Telegram API
  |                         |                             |
  |<-- healthy (PORT open)--|                             |
```

### 2. User Connects via Control UI

```
Browser                 Railway Proxy              Gateway
  |                         |                         |
  |-- GET / (HTTPS) ------->|                         |
  |                         |-- proxy HTTP :8080 ----->|
  |<-- Control UI HTML -----|<-- OpenClaw dashboard ---|
  |                         |                         |
  |-- WSS + GATEWAY_TOKEN ->|                         |
  |                         |-- WS + token :8080 ----->|
  |                         |                         |-- validate token
  |<-- connected ----------|<-- ws established -------|
  |                         |                         |
  |-- send message -------->|------------------------>|
  |                         |                         |-- invoke Kimi K2.5
  |                         |                         |   (NVIDIA NIM API)
  |<-- agent response ------|<------------------------|
```

### 3. Telegram Message Flow

```
User (Telegram)        Telegram API              Gateway              NVIDIA NIM
  |                         |                       |                      |
  |-- send message -------->|                       |                      |
  |                         |<-- getUpdates poll ---|                      |
  |                         |--- return message --->|                      |
  |                         |                       |-- check allowlist    |
  |                         |                       |   (TELEGRAM_USER_ID) |
  |                         |                       |                      |
  |                         |                       |-- POST /v1/chat ---->|
  |                         |                       |   (Kimi K2.5)        |
  |                         |                       |<-- completion -------|
  |                         |                       |                      |
  |                         |<-- sendMessage -------|                      |
  |<-- bot reply -----------|                       |                      |
```

---

## Security Hardening (Baked In)

| Measure | Setting | Why |
|---|---|---|
| Auth mode | `token` (user-provided) | No auto-generated secrets to fish out of logs |
| Tool profile | `messaging` | Minimal tool surface for chat use case |
| Denied tools | automation, runtime, sessions, gateway, cron | Prevent agent from modifying its own config or spawning processes |
| Filesystem | `workspaceOnly: true` | Agent can't read /etc/passwd, env files, etc. |
| Exec | `deny` | No shell command execution by the agent |
| Elevated mode | `off` | No privilege escalation |
| Sandbox | `off` | Railway container IS the sandbox (no Docker-in-Docker) |
| Bind | `lan` | Required for Railway proxy, but auth protects access |
| Trusted proxies | `100.64.0.0/10` | Railway's internal CGNAT range only |
| Device auth | `on` (default) | Browser must be approved; token auth gates initial access |
| mDNS | `off` | No service broadcasting |
| Session scope | `per-channel-peer` | Users can't see each other's conversations |

---

## Template Deploy Flow

```
User clicks "Deploy on Railway"
  |
  v
Railway prompts for env vars:
  - MOONSHOT_API_KEY (required)
  - GATEWAY_TOKEN (required)
  - TELEGRAM_BOT_TOKEN (optional)
  - TELEGRAM_USER_ID (optional)
  |
  v
Railway builds Dockerfile
  |
  v
Railway creates volume at /data
  |
  v
Container starts, entrypoint:
  1. Creates /data/.openclaw
  2. Generates config JSON from env vars
  3. Starts gateway on $PORT
  |
  v
User visits https://<app>.up.railway.app
  -> Enters GATEWAY_TOKEN
  -> Chats via Control UI
  |
  v
(Optional) User messages Telegram bot
  -> Immediately works if TELEGRAM_USER_ID was set
```
