#!/usr/bin/env node

import http from "node:http";
import crypto from "node:crypto";
import { WebSocket } from "ws";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const GATEWAY_URL = process.env.OPENCLAW_GATEWAY_URL ?? "ws://127.0.0.1:18789";
const GATEWAY_TOKEN = process.env.OPENCLAW_GATEWAY_TOKEN ?? "";
const PORT = parseInt(process.env.ACTIVITY_PORT ?? "19789", 10);
const POLL_INTERVAL = parseInt(process.env.ACTIVITY_POLL_INTERVAL ?? "3000", 10);
const ACTIVE_THRESHOLD_MS = parseInt(process.env.ACTIVITY_THRESHOLD_MS ?? "15000", 10);

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

interface SessionInfo {
  key: string;
  agentId: string;
  kind: string;
  ageMs: number;
  active: boolean;
  model?: string;
}

interface ActivityState {
  connected: boolean;
  active: boolean;
  sessions: SessionInfo[];
  summary: { totalSessions: number; activeSessions: number; idleSessions: number };
  ts: number;
  gatewayEvents: number;
}

const state: ActivityState = {
  connected: false,
  active: false,
  sessions: [],
  summary: { totalSessions: 0, activeSessions: 0, idleSessions: 0 },
  ts: Date.now(),
  gatewayEvents: 0,
};

const startTime = Date.now();

// ---------------------------------------------------------------------------
// Device identity (ephemeral keypair for this server instance)
// ---------------------------------------------------------------------------

const deviceKeyPair = crypto.generateKeyPairSync("ed25519");
const pubKeyRaw = deviceKeyPair.publicKey.export({ type: "spki", format: "der" });
const deviceId = crypto.createHash("sha256").update(pubKeyRaw).digest("hex").slice(0, 32);

function signPayload(payload: string): string {
  const sig = crypto.sign(null, Buffer.from(payload), deviceKeyPair.privateKey);
  return sig.toString("base64");
}

// ---------------------------------------------------------------------------
// Gateway WS connection
// ---------------------------------------------------------------------------

let ws: WebSocket | null = null;
let reqId = 0;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let pendingChallenge: { nonce: string; ts: number } | null = null;
let pollTimer: ReturnType<typeof setInterval> | null = null;

function nextId(): string {
  return `activity-${++reqId}`;
}

function connectGateway(): void {
  if (ws) {
    try { ws.close(); } catch {}
  }

  console.log(`[gateway] connecting to ${GATEWAY_URL}...`);
  ws = new WebSocket(GATEWAY_URL);

  ws.on("open", () => {
    console.log("[gateway] WebSocket open, waiting for challenge...");
  });

  ws.on("message", (data) => {
    try {
      const msg = JSON.parse(data.toString());
      handleGatewayMessage(msg);
    } catch (e) {
      console.error("[gateway] failed to parse message:", e);
    }
  });

  ws.on("close", (code, reason) => {
    console.log(`[gateway] closed: ${code} ${reason}`);
    state.connected = false;
    state.active = false;
    stopPolling();
    scheduleReconnect();
  });

  ws.on("error", (err) => {
    console.error("[gateway] error:", err.message);
    state.connected = false;
  });
}

function scheduleReconnect(): void {
  if (reconnectTimer) return;
  const delay = 5000;
  console.log(`[gateway] reconnecting in ${delay}ms...`);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectGateway();
  }, delay);
}

function handleGatewayMessage(msg: any): void {
  state.gatewayEvents++;

  // Challenge from gateway
  if (msg.type === "event" && msg.event === "connect.challenge") {
    pendingChallenge = msg.payload;
    sendConnect(msg.payload);
    return;
  }

  // Response to connect
  if (msg.type === "res" && msg.payload?.type === "hello-ok") {
    console.log("[gateway] connected as operator ✓");
    state.connected = true;

    // Start polling sessions
    startPolling();
    return;
  }

  // Error response
  if (msg.type === "res" && !msg.ok) {
    console.error("[gateway] error response:", JSON.stringify(msg.error));
    return;
  }

  // Response to sessions list
  if (msg.type === "res" && msg.ok && msg.id?.startsWith("poll-")) {
    handleSessionsResponse(msg.payload);
    return;
  }

  // Any event = potential activity signal
  if (msg.type === "event") {
    // Events like agent.run.start, tool.call, etc. indicate activity
    if (msg.event?.includes("agent") || msg.event?.includes("tool") || msg.event?.includes("run")) {
      state.active = true;
      state.ts = Date.now();
    }
  }
}

function sendConnect(challenge: { nonce: string; ts: number }): void {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  const signedAt = Date.now();
  const nonce = challenge.nonce;

  // v3 signature payload
  const payloadParts = [
    `device:${deviceId}`,
    `client:openclaw-activity-server`,
    `role:operator`,
    `scopes:operator.read`,
    `token:${GATEWAY_TOKEN}`,
    `nonce:${nonce}`,
    `platform:macos`,
    `deviceFamily:server`,
  ];
  const signaturePayload = payloadParts.join("\n");
  const signature = signPayload(signaturePayload);
  const publicKeyBase64 = pubKeyRaw.toString("base64");

  const connectMsg = {
    type: "req",
    id: nextId(),
    method: "connect",
    params: {
      minProtocol: 3,
      maxProtocol: 3,
      client: {
        id: "openclaw-activity-server",
        version: "0.1.0",
        platform: "macos",
        mode: "operator",
      },
      role: "operator",
      scopes: ["operator.read"],
      caps: [],
      commands: [],
      permissions: {},
      auth: { token: GATEWAY_TOKEN },
      locale: "en-US",
      userAgent: "openclaw-activity-server/0.1.0",
      device: {
        id: deviceId,
        publicKey: publicKeyBase64,
        signature,
        signedAt,
        nonce,
      },
    },
  };

  ws.send(JSON.stringify(connectMsg));
}

// ---------------------------------------------------------------------------
// Session polling via WS (tools.invoke sessions_list)
// ---------------------------------------------------------------------------

function startPolling(): void {
  if (pollTimer) return;
  pollSessions(); // immediate
  pollTimer = setInterval(pollSessions, POLL_INTERVAL);
}

function stopPolling(): void {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
}

function pollSessions(): void {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  // Use the sessions.list method over WS
  const msg = {
    type: "req",
    id: `poll-${nextId()}`,
    method: "sessions.list",
    params: {
      activeMinutes: 5,
    },
  };
  ws.send(JSON.stringify(msg));
}

function handleSessionsResponse(payload: any): void {
  const now = Date.now();
  const sessions: SessionInfo[] = [];

  // The response might be an array or have a sessions field
  const rawSessions = Array.isArray(payload) ? payload : (payload?.sessions ?? payload?.list ?? []);

  for (const s of rawSessions) {
    const ageMs = s.age ?? s.ageMs ?? (s.updatedAt ? now - s.updatedAt : Infinity);
    const isActive = ageMs < ACTIVE_THRESHOLD_MS;

    sessions.push({
      key: s.key ?? s.sessionKey ?? "unknown",
      agentId: s.agentId ?? "main",
      kind: s.kind ?? "unknown",
      ageMs,
      active: isActive,
      model: s.model,
    });
  }

  const activeSessions = sessions.filter((s) => s.active).length;

  state.sessions = sessions;
  state.active = activeSessions > 0;
  state.summary = {
    totalSessions: sessions.length,
    activeSessions,
    idleSessions: sessions.length - activeSessions,
  };
  state.ts = now;
}

// ---------------------------------------------------------------------------
// Fallback: poll via openclaw status CLI
// ---------------------------------------------------------------------------

import { execFile } from "node:child_process";

let useCliFallback = false;
let cliPollTimer: ReturnType<typeof setInterval> | null = null;

function startCliFallback(): void {
  if (cliPollTimer) return;
  useCliFallback = true;
  console.log("[fallback] using CLI polling");
  pollCli();
  cliPollTimer = setInterval(pollCli, POLL_INTERVAL);
}

function stopCliFallback(): void {
  if (cliPollTimer) {
    clearInterval(cliPollTimer);
    cliPollTimer = null;
  }
  useCliFallback = false;
}

function pollCli(): void {
  execFile("openclaw", ["status", "--json"], { timeout: 10000 }, (err, stdout) => {
    if (err) {
      console.error("[fallback] cli error:", err.message);
      return;
    }
    try {
      // Strip non-JSON lines (e.g. [memory] warnings)
      const jsonStr = stdout.split("\n").filter((l) => !l.startsWith("[")).join("\n");
      const data = JSON.parse(jsonStr);
      const now = Date.now();
      const sessions: SessionInfo[] = [];

      for (const s of data.sessions?.recent ?? []) {
        const ageMs = s.age ?? (s.updatedAt ? now - s.updatedAt : Infinity);
        const isActive = ageMs < ACTIVE_THRESHOLD_MS;

        sessions.push({
          key: s.key ?? "unknown",
          agentId: s.agentId ?? "main",
          kind: s.kind ?? "unknown",
          ageMs,
          active: isActive,
          model: s.model,
        });
      }

      const activeSessions = sessions.filter((s) => s.active).length;
      state.connected = true;
      state.sessions = sessions;
      state.active = activeSessions > 0;
      state.summary = {
        totalSessions: data.sessions?.count ?? sessions.length,
        activeSessions,
        idleSessions: sessions.length - activeSessions,
      };
      state.ts = now;
    } catch (e: any) {
      console.error("[fallback] parse error:", e.message);
    }
  });
}

// ---------------------------------------------------------------------------
// HTTP Server
// ---------------------------------------------------------------------------

const server = http.createServer((req, res) => {
  // CORS headers for local development
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");

  if (req.method === "OPTIONS") {
    res.writeHead(204);
    res.end();
    return;
  }

  const url = new URL(req.url ?? "/", `http://localhost:${PORT}`);

  if (url.pathname === "/api/status" && req.method === "GET") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(state));
    return;
  }

  if (url.pathname === "/api/health" && req.method === "GET") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        ok: true,
        gateway: state.connected ? "connected" : "disconnected",
        uptime: Math.floor((Date.now() - startTime) / 1000),
        mode: useCliFallback ? "cli-fallback" : "websocket",
      })
    );
    return;
  }

  // SSE endpoint for real-time updates
  if (url.pathname === "/api/stream" && req.method === "GET") {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    });

    const interval = setInterval(() => {
      res.write(`data: ${JSON.stringify(state)}\n\n`);
    }, 1000);

    req.on("close", () => clearInterval(interval));
    return;
  }

  res.writeHead(404, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: "not found" }));
});

// ---------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------

server.listen(PORT, "127.0.0.1", () => {
  console.log(`[server] listening on http://127.0.0.1:${PORT}`);
  console.log(`[server] endpoints: /api/status, /api/health, /api/stream`);

  if (GATEWAY_TOKEN) {
    connectGateway();

    // If WS connection fails after 10s, fall back to CLI polling
    setTimeout(() => {
      if (!state.connected) {
        console.log("[gateway] WS connection failed, falling back to CLI polling");
        startCliFallback();
      }
    }, 10000);
  } else {
    console.log("[server] no OPENCLAW_GATEWAY_TOKEN set, using CLI fallback");
    startCliFallback();
  }
});

// Graceful shutdown
process.on("SIGINT", () => {
  console.log("\n[server] shutting down...");
  stopPolling();
  stopCliFallback();
  if (ws) ws.close();
  server.close(() => process.exit(0));
});

process.on("SIGTERM", () => {
  stopPolling();
  stopCliFallback();
  if (ws) ws.close();
  server.close(() => process.exit(0));
});
