# OpenKlaw — Template Deploy Flow

```
User clicks "Deploy on Railway"
  |
  v
Railway prompts for env vars:
  - MOONSHOT_API_KEY (required)
  - GATEWAY_TOKEN (required)
  - TELEGRAM_BOT_TOKEN (optional)
  - TELEGRAM_USER_ID (optional)
  - SYSTEM_PROMPT (optional)
  |
  v
Railway builds Dockerfile
  |
  v
Railway creates volume at /data
  |
  v
Container starts, entrypoint:
  1. Validates env vars (fail-fast)
  2. Pre-flights NVIDIA NIM API key
  3. Generates config from env vars + templates
  4. Generates welcome page
  5. Starts gateway on $PORT
  |
  v
User visits https://<app>.up.railway.app
  -> Enters GATEWAY_TOKEN
  -> Chats via Control UI
  |
  v
(Optional) User messages Telegram bot
  -> Immediately works if TELEGRAM_USER_ID was set
  -> Pairing mode if not
```
