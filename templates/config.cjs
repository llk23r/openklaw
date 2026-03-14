#!/usr/bin/env node
// Reads openclaw.json base config and injects environment-specific values.
// Usage: node config.js > /data/.openclaw/openclaw.json

const fs = require("fs");
const path = require("path");

const env = process.env;
const base = JSON.parse(
  fs.readFileSync(path.join(__dirname, "openclaw.json"), "utf8")
);

// --- Auth ---
base.gateway.auth.token = env.GATEWAY_TOKEN;

// --- Allowed origins (platform-specific) ---
if (env.RAILWAY_PUBLIC_DOMAIN) {
  base.gateway.controlUi.allowedOrigins = [
    `https://${env.RAILWAY_PUBLIC_DOMAIN}`,
  ];
}

// --- System prompt ---
if (env.SYSTEM_PROMPT) {
  base.agents.defaults.systemPrompt = env.SYSTEM_PROMPT;
}

// --- Telegram (only if bot token is set) ---
if (env.TELEGRAM_BOT_TOKEN) {
  base.channels = {
    telegram: {
      enabled: true,
      ...(env.TELEGRAM_USER_ID
        ? { dmPolicy: "allowlist", allowFrom: [env.TELEGRAM_USER_ID] }
        : { dmPolicy: "pairing" }),
    },
  };
}

process.stdout.write(JSON.stringify(base, null, 2) + "\n");
