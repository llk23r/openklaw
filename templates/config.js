#!/usr/bin/env node
// Generates openclaw.json from environment variables.
// Usage: node config.js > /data/.openclaw/openclaw.json

const env = process.env;

const config = {
  gateway: {
    mode: "local",
    bind: "lan",
    trustedProxies: ["100.64.0.0/10"],
    auth: {
      mode: "token",
      token: env.GATEWAY_TOKEN,
    },
    controlUi: {
      ...(env.RAILWAY_PUBLIC_DOMAIN && {
        allowedOrigins: [`https://${env.RAILWAY_PUBLIC_DOMAIN}`],
      }),
      dangerouslyDisableDeviceAuth: false,
    },
  },
  session: { dmScope: "per-channel-peer" },
  tools: {
    profile: "messaging",
    deny: [
      "group:automation",
      "group:runtime",
      "sessions_spawn",
      "sessions_send",
      "gateway",
      "cron",
    ],
    fs: { workspaceOnly: true },
    exec: { security: "deny", ask: "always" },
    elevated: { enabled: false },
  },
  discovery: { mdns: { mode: "off" } },
  logging: { redactSensitive: "tools" },
  models: {
    mode: "merge",
    providers: {
      "nvidia-nim": {
        baseUrl: "https://integrate.api.nvidia.com/v1",
        apiKey: "${MOONSHOT_API_KEY}",
        api: "openai-completions",
        models: [
          {
            id: "moonshotai/kimi-k2.5",
            name: "Kimi K2.5 (NVIDIA)",
            reasoning: false,
            input: ["text"],
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
            contextWindow: 200000,
            maxTokens: 8192,
          },
        ],
      },
    },
  },
  agents: {
    defaults: {
      ...(env.SYSTEM_PROMPT && { systemPrompt: env.SYSTEM_PROMPT }),
      model: { primary: "nvidia-nim/moonshotai/kimi-k2.5" },
      sandbox: { mode: "off" },
    },
  },
};

// Telegram (only if bot token is set)
if (env.TELEGRAM_BOT_TOKEN) {
  config.channels = {
    telegram: {
      enabled: true,
      ...(env.TELEGRAM_USER_ID
        ? { dmPolicy: "allowlist", allowFrom: [env.TELEGRAM_USER_ID] }
        : { dmPolicy: "pairing" }),
    },
  };
}

process.stdout.write(JSON.stringify(config, null, 2) + "\n");
