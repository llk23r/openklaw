const http = require("http");
const { spawn } = require("child_process");
const { createHash, randomBytes } = require("crypto");
const net = require("net");
const url = require("url");
const fs = require("fs");

const PORT = parseInt(process.env.PORT || "8080", 10);
const INTERNAL_PORT = 18789;
const SETUP_PASSWORD = process.env.SETUP_PASSWORD || "";
const CONFIG_DIR = process.env.OPENCLAW_STATE_DIR || "/data/.openclaw";
const CONFIG_FILE = `${CONFIG_DIR}/openclaw.json`;

let gatewayProcess = null;

// --- Helpers ---

function jsonRes(res, status, data) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

function requireAuth(req, res) {
  if (!SETUP_PASSWORD) {
    jsonRes(res, 503, { error: "SETUP_PASSWORD env var not set" });
    return false;
  }
  const auth = req.headers.authorization || "";
  const token = auth.replace(/^Bearer\s+/i, "");
  if (token !== SETUP_PASSWORD) {
    jsonRes(res, 401, { error: "Invalid setup password" });
    return false;
  }
  return true;
}

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString()));
  });
}

function runCli(args) {
  return new Promise((resolve) => {
    const proc = spawn("openclaw", args, {
      env: { ...process.env, OPENCLAW_STATE_DIR: CONFIG_DIR },
      timeout: 15000,
    });
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (d) => (stdout += d));
    proc.stderr.on("data", (d) => (stderr += d));
    proc.on("close", (code) => resolve({ code, stdout, stderr }));
    proc.on("error", (err) => resolve({ code: 1, stdout: "", stderr: err.message }));
  });
}

function getAuthToken() {
  try {
    const cfg = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
    return cfg.gateway?.auth?.token || null;
  } catch {
    return null;
  }
}

// --- Admin routes ---

async function handleAdmin(req, res) {
  const parsed = url.parse(req.url, true);
  const path = parsed.pathname;

  if (!requireAuth(req, res)) return;

  // GET /admin/status
  if (path === "/admin/status" && req.method === "GET") {
    const token = getAuthToken();
    return jsonRes(res, 200, {
      gateway: gatewayProcess && !gatewayProcess.killed ? "running" : "stopped",
      authToken: token,
      internalPort: INTERNAL_PORT,
    });
  }

  // GET /admin/token
  if (path === "/admin/token" && req.method === "GET") {
    const token = getAuthToken();
    return jsonRes(res, 200, { token });
  }

  // GET /admin/pairing/list
  if (path === "/admin/pairing/list" && req.method === "GET") {
    const result = await runCli(["pairing", "list"]);
    return jsonRes(res, result.code === 0 ? 200 : 500, {
      output: result.stdout || result.stderr,
    });
  }

  // POST /admin/pairing/approve { channel, code }
  if (path === "/admin/pairing/approve" && req.method === "POST") {
    const body = JSON.parse(await readBody(req));
    const { channel, code } = body;
    if (!channel || !code) {
      return jsonRes(res, 400, { error: "channel and code are required" });
    }
    const result = await runCli(["pairing", "approve", channel, code]);
    return jsonRes(res, result.code === 0 ? 200 : 500, {
      output: result.stdout || result.stderr,
    });
  }

  // GET /admin/devices
  if (path === "/admin/devices" && req.method === "GET") {
    const result = await runCli(["devices", "list"]);
    return jsonRes(res, result.code === 0 ? 200 : 500, {
      output: result.stdout || result.stderr,
    });
  }

  // POST /admin/devices/approve { requestId }
  if (path === "/admin/devices/approve" && req.method === "POST") {
    const body = JSON.parse(await readBody(req));
    const { requestId } = body;
    if (!requestId) {
      return jsonRes(res, 400, { error: "requestId is required" });
    }
    const result = await runCli(["devices", "approve", requestId]);
    return jsonRes(res, result.code === 0 ? 200 : 500, {
      output: result.stdout || result.stderr,
    });
  }

  // GET /admin/logs - read gateway's internal log
  if (path === "/admin/logs" && req.method === "GET") {
    const lines = parseInt(parsed.query.lines || "100", 10);
    const today = new Date().toISOString().split("T")[0];
    const logFile = `/tmp/openclaw/openclaw-${today}.log`;
    try {
      const content = fs.readFileSync(logFile, "utf8");
      const allLines = content.split("\n");
      const tail = allLines.slice(-lines).join("\n");
      return jsonRes(res, 200, { log: tail });
    } catch (e) {
      return jsonRes(res, 500, { error: `Cannot read ${logFile}: ${e.message}` });
    }
  }

  // GET /admin/config - read actual config file on disk
  if (path === "/admin/config" && req.method === "GET") {
    try {
      const cfg = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
      // Redact sensitive values
      if (cfg.gateway?.auth?.token) cfg.gateway.auth.token = "[REDACTED]";
      if (cfg.channels?.telegram?.botToken) cfg.channels.telegram.botToken = "[REDACTED]";
      if (cfg.models?.providers) {
        for (const p of Object.values(cfg.models.providers)) {
          if (p.apiKey) p.apiKey = "[REDACTED]";
        }
      }
      return jsonRes(res, 200, cfg);
    } catch (e) {
      return jsonRes(res, 500, { error: e.message });
    }
  }

  // GET /admin/telegram-test - test Telegram API from inside the container
  if (path === "/admin/telegram-test" && req.method === "GET") {
    const token = process.env.TELEGRAM_BOT_TOKEN;
    if (!token) return jsonRes(res, 500, { error: "TELEGRAM_BOT_TOKEN not set" });
    const https = require("https");
    const testUrl = `https://api.telegram.org/bot${token}/getUpdates?timeout=3&limit=5`;
    https.get(testUrl, (resp) => {
      let data = "";
      resp.on("data", (c) => data += c);
      resp.on("end", () => {
        try { jsonRes(res, 200, JSON.parse(data)); }
        catch { jsonRes(res, 200, { raw: data }); }
      });
    }).on("error", (e) => jsonRes(res, 500, { error: e.message }));
    return;
  }

  // GET /admin/env - check if key env vars are set (not their values)
  if (path === "/admin/env" && req.method === "GET") {
    return jsonRes(res, 200, {
      TELEGRAM_BOT_TOKEN: !!process.env.TELEGRAM_BOT_TOKEN ? "set" : "missing",
      MOONSHOT_API_KEY: !!process.env.MOONSHOT_API_KEY ? "set" : "missing",
      SETUP_PASSWORD: !!process.env.SETUP_PASSWORD ? "set" : "missing",
    });
  }

  jsonRes(res, 404, { error: "Not found" });
}

// --- Setup page ---

function handleSetupPage(req, res) {
  res.writeHead(200, { "Content-Type": "text/html" });
  res.end(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>OpenKlaw Setup</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:system-ui,sans-serif;background:#1a1a2e;color:#eee;padding:2rem;max-width:640px;margin:0 auto}
    h1{color:#e74c3c;margin-bottom:1rem}
    h2{margin:1.5rem 0 .5rem;color:#ccc;font-size:1.1rem}
    input,button{padding:.6rem 1rem;border-radius:6px;border:1px solid #333;background:#16213e;color:#eee;font-size:.95rem;width:100%}
    button{background:#e74c3c;border:none;cursor:pointer;margin-top:.5rem;font-weight:600}
    button:hover{background:#c0392b}
    .card{background:#16213e;border-radius:8px;padding:1.2rem;margin:.8rem 0}
    .mono{font-family:monospace;word-break:break-all;color:#2ecc71;padding:.4rem;background:#0f0f23;border-radius:4px;display:block;margin-top:.3rem}
    .result{margin-top:.8rem;padding:.8rem;background:#0f0f23;border-radius:6px;white-space:pre-wrap;font-family:monospace;font-size:.85rem;max-height:200px;overflow:auto}
    .row{display:flex;gap:.5rem;align-items:center}
    .row input{flex:1}
    .row button{width:auto;flex-shrink:0}
    label{display:block;margin-bottom:.3rem;font-size:.85rem;color:#999}
  </style>
</head>
<body>
  <h1>OpenKlaw Setup</h1>

  <div class="card">
    <label>Setup Password</label>
    <input type="password" id="pw" placeholder="Enter SETUP_PASSWORD">
  </div>

  <h2>Gateway Token</h2>
  <div class="card">
    <button onclick="getToken()">Reveal Auth Token</button>
    <div id="tokenOut" class="result" style="display:none"></div>
  </div>

  <h2>Telegram Pairing</h2>
  <div class="card">
    <button onclick="listPairing()">List Pending Requests</button>
    <div id="pairList" class="result" style="display:none"></div>
    <div style="margin-top:.8rem">
      <label>Pairing Code</label>
      <div class="row">
        <input id="pairCode" placeholder="e.g. 76X7WUD7">
        <button onclick="approvePair()" style="width:120px">Approve</button>
      </div>
    </div>
    <div id="pairResult" class="result" style="display:none"></div>
  </div>

  <h2>Device Pairing</h2>
  <div class="card">
    <button onclick="listDevices()">List Device Requests</button>
    <div id="devList" class="result" style="display:none"></div>
    <div style="margin-top:.8rem">
      <label>Request ID</label>
      <div class="row">
        <input id="devId" placeholder="Device request ID">
        <button onclick="approveDev()" style="width:120px">Approve</button>
      </div>
    </div>
    <div id="devResult" class="result" style="display:none"></div>
  </div>

  <h2>Control UI</h2>
  <div class="card">
    <p style="font-size:.9rem">Once you have the auth token, connect at:</p>
    <span class="mono" id="wsUrl"></span>
  </div>

  <script>
    document.getElementById('wsUrl').textContent = location.origin.replace('http','ws');
    function hdr(){return{Authorization:'Bearer '+document.getElementById('pw').value,'Content-Type':'application/json'}}
    function show(id,text){const el=document.getElementById(id);el.style.display='block';el.textContent=text}
    async function getToken(){
      const r=await fetch('/admin/token',{headers:hdr()});const d=await r.json();
      show('tokenOut',r.ok?d.token:'Error: '+d.error)
    }
    async function listPairing(){
      const r=await fetch('/admin/pairing/list',{headers:hdr()});const d=await r.json();
      show('pairList',r.ok?d.output:'Error: '+d.error)
    }
    async function approvePair(){
      const code=document.getElementById('pairCode').value.trim();if(!code)return;
      const r=await fetch('/admin/pairing/approve',{method:'POST',headers:hdr(),body:JSON.stringify({channel:'telegram',code})});
      const d=await r.json();show('pairResult',r.ok?d.output:'Error: '+(d.error||d.output))
    }
    async function listDevices(){
      const r=await fetch('/admin/devices',{headers:hdr()});const d=await r.json();
      show('devList',r.ok?d.output:'Error: '+d.error)
    }
    async function approveDev(){
      const id=document.getElementById('devId').value.trim();if(!id)return;
      const r=await fetch('/admin/devices/approve',{method:'POST',headers:hdr(),body:JSON.stringify({requestId:id})});
      const d=await r.json();show('devResult',r.ok?d.output:'Error: '+(d.error||d.output))
    }
  </script>
</body>
</html>`);
}

// --- Health check ---

function handleHealth(req, res) {
  jsonRes(res, 200, { status: "ok" });
}

// --- Proxy to gateway ---

function proxyRequest(req, res) {
  const opts = {
    hostname: "127.0.0.1",
    port: INTERNAL_PORT,
    path: req.url,
    method: req.method,
    headers: { ...req.headers, host: `127.0.0.1:${INTERNAL_PORT}` },
  };

  const proxy = http.request(opts, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res, { end: true });
  });

  proxy.on("error", () => {
    jsonRes(res, 502, { error: "Gateway not available" });
  });

  req.pipe(proxy, { end: true });
}

// --- WebSocket upgrade proxy ---

function proxyUpgrade(req, socket, head) {
  const proxySocket = net.connect(INTERNAL_PORT, "127.0.0.1", () => {
    const reqLine = `${req.method} ${req.url} HTTP/1.1\r\n`;
    const headers = Object.entries(req.headers)
      .map(([k, v]) => `${k}: ${v}`)
      .join("\r\n");
    proxySocket.write(`${reqLine}${headers}\r\n\r\n`);
    if (head.length) proxySocket.write(head);
    proxySocket.pipe(socket);
    socket.pipe(proxySocket);
  });

  proxySocket.on("error", () => socket.destroy());
  socket.on("error", () => proxySocket.destroy());
}

// --- Start gateway ---

function startGateway() {
  console.log(`Starting OpenClaw gateway on internal port ${INTERNAL_PORT}...`);
  gatewayProcess = spawn("openclaw", ["gateway", "--port", String(INTERNAL_PORT)], {
    env: { ...process.env, OPENCLAW_STATE_DIR: CONFIG_DIR },
    stdio: "inherit",
  });

  gatewayProcess.on("exit", (code) => {
    console.error(`Gateway exited with code ${code}, restarting in 3s...`);
    setTimeout(startGateway, 3000);
  });
}

// --- Init config ---

function initConfig() {
  const configDir = CONFIG_DIR;
  const templateFile = "/tmp/openclaw.json";

  // Ensure dirs exist
  fs.mkdirSync(configDir, { recursive: true });
  fs.mkdirSync("/data/workspace", { recursive: true });

  // Preserve existing auth token
  let existingToken = null;
  try {
    const existing = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
    existingToken = existing.gateway?.auth?.token || null;
  } catch {}

  // Copy template config
  console.log("Initializing OpenClaw config...");
  fs.copyFileSync(templateFile, CONFIG_FILE);

  // Restore token
  if (existingToken) {
    const cfg = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
    cfg.gateway = cfg.gateway || {};
    cfg.gateway.auth = cfg.gateway.auth || {};
    cfg.gateway.auth.token = existingToken;
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2));
    console.log("Auth token restored from previous deploy.");
  }
}

// --- Main ---

initConfig();
startGateway();

const server = http.createServer((req, res) => {
  const path = url.parse(req.url).pathname;

  if (path === "/healthz") return handleHealth(req, res);
  if (path === "/setup") return handleSetupPage(req, res);
  if (path.startsWith("/admin/")) return handleAdmin(req, res);

  // Everything else proxied to gateway
  proxyRequest(req, res);
});

server.on("upgrade", proxyUpgrade);

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Proxy server listening on 0.0.0.0:${PORT}`);
  console.log(`Setup UI: https://openklaw-production-15df.up.railway.app/setup`);
});
