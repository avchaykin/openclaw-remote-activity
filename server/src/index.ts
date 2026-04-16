#!/usr/bin/env node

import http from "node:http";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile, execFileSync } from "node:child_process";
import { WebSocket } from "ws";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const GATEWAY_URL = process.env.OPENCLAW_GATEWAY_URL ?? "ws://127.0.0.1:18789";
const GATEWAY_TOKEN = resolveGatewayToken();
const PORT = parseInt(process.env.ACTIVITY_PORT ?? "19789", 10);
const POLL_INTERVAL = parseInt(process.env.ACTIVITY_POLL_INTERVAL ?? "3000", 10);
const ACTIVE_THRESHOLD_MS = parseInt(process.env.ACTIVITY_THRESHOLD_MS ?? "15000", 10);
const OPENCLAW_BIN = resolveOpenClawBin();

function resolveGatewayToken(): string {
  const envToken = process.env.OPENCLAW_GATEWAY_TOKEN?.trim();
  if (envToken) return envToken;

  const configToken = readGatewayTokenFromConfigFile();
  if (configToken) return configToken;

  return "";
}

function readGatewayTokenFromConfigFile(): string | null {
  try {
    const configPath = path.join(os.homedir(), ".openclaw", "openclaw.json");
    if (!fs.existsSync(configPath)) return null;

    const raw = fs.readFileSync(configPath, "utf8");
    const parsed = JSON.parse(raw);
    const token = parsed?.gateway?.auth?.token;

    if (typeof token === "string" && token.trim().length > 0 && !looksRedactedToken(token)) {
      return token.trim();
    }
  } catch {
    // ignore and fall back
  }

  return null;
}

function resolveOpenClawBin(): string {
  const candidates = [
    process.env.OPENCLAW_BIN,
    "openclaw",
    "/opt/homebrew/bin/openclaw",
    "/usr/local/bin/openclaw",
  ].filter((x): x is string => Boolean(x));

  for (const bin of candidates) {
    try {
      execFileSync(bin, ["--version"], { stdio: "ignore" });
      return bin;
    } catch {
      // keep trying
    }
  }

  return "openclaw";
}

function looksRedactedToken(value: string): boolean {
  const normalized = value.trim().toUpperCase();
  return normalized.includes("REDACTED");
}

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

interface ToolActivity {
  ts: number;
  sessionKey?: string;
  tool: string;
  phase: string;
}

interface ActivityState {
  connected: boolean;
  active: boolean;
  currentPhase: "idle" | "tooling" | "thinking" | "responding";
  phaseTs: number;
  sessions: SessionInfo[];
  summary: { totalSessions: number; activeSessions: number; idleSessions: number };
  ts: number;
  gatewayEvents: number;
  toolLog: ToolActivity[];
  mode: "websocket" | "cli-fallback";
}

const state: ActivityState = {
  connected: false,
  active: false,
  currentPhase: "idle",
  phaseTs: Date.now(),
  sessions: [],
  summary: { totalSessions: 0, activeSessions: 0, idleSessions: 0 },
  ts: Date.now(),
  gatewayEvents: 0,
  toolLog: [],
  mode: "cli-fallback",
};

const startTime = Date.now();

function setPhase(phase: ActivityState["currentPhase"]): void {
  if (state.currentPhase === phase) return;
  state.currentPhase = phase;
  state.phaseTs = Date.now();
}

// ---------------------------------------------------------------------------
// Device identity (ephemeral keypair for this server instance)
// ---------------------------------------------------------------------------

const deviceKeyPair = crypto.generateKeyPairSync("ed25519");
const pubKeyDer = deviceKeyPair.publicKey.export({ type: "spki", format: "der" });
// Ed25519 SPKI DER = 12-byte prefix + 32-byte raw key
const ED25519_SPKI_PREFIX_LEN = 12;
const pubKeyRaw = pubKeyDer.subarray(ED25519_SPKI_PREFIX_LEN);
// Device ID = SHA-256 of raw 32-byte public key (full hex, not truncated)
const deviceId = crypto.createHash("sha256").update(pubKeyRaw).digest("hex");

function signPayload(payload: string): string {
  const sig = crypto.sign(null, Buffer.from(payload), deviceKeyPair.privateKey);
  return base64UrlEncode(sig);
}

function base64UrlEncode(buf: Buffer): string {
  return buf.toString("base64").replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/g, "");
}

const publicKeyBase64Url = base64UrlEncode(Buffer.from(pubKeyRaw));

// ---------------------------------------------------------------------------
// Gateway WS connection
// ---------------------------------------------------------------------------

let ws: WebSocket | null = null;
let reqId = 0;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let pendingChallenge: { nonce: string; ts: number } | null = null;
let pollTimer: ReturnType<typeof setInterval> | null = null;
let sessionsSubscribed = false;
const subscribedSessionKeys = new Set<string>();

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
    setPhase("idle");
    sessionsSubscribed = false;
    subscribedSessionKeys.clear();
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

function pushToolActivity(entry: ToolActivity): void {
  state.toolLog.unshift(entry);
  state.toolLog = state.toolLog
    .filter((item, idx, arr) => idx === arr.findIndex((x) => x.ts === item.ts && x.tool === item.tool && x.phase === item.phase && x.sessionKey === item.sessionKey))
    .slice(0, 8);
}

function extractToolName(payload: any): string | null {
  const p = payload?.payload ?? payload;
  const d = p?.data;
  return (
    d?.toolName ??
    d?.tool ??
    d?.name ??
    d?.recipient_name ??
    d?.recipientName ??
    p?.toolName ??
    p?.tool ??
    p?.name ??
    p?.recipient_name ??
    p?.recipientName ??
    p?.request?.recipient_name ??
    p?.request?.recipientName ??
    p?.call?.toolName ??
    p?.call?.tool ??
    p?.toolCall?.name ??
    null
  );
}

function extractEventName(msg: any): string {
  return (
    msg?.event ??
    msg?.name ??
    msg?.method ??
    msg?.payload?.event ??
    ""
  );
}

function extractSessionKey(payload: any): string | undefined {
  const p = payload?.payload ?? payload;
  return p?.sessionKey ?? p?.key ?? p?.session?.key ?? p?.data?.sessionKey;
}

function extractPhase(eventName: string, payload: any): string {
  const p = payload?.payload ?? payload;
  const dataPhase = p?.data?.phase;
  if (typeof dataPhase === "string" && dataPhase.trim()) return dataPhase;
  return String(eventName).split(".").slice(-1)[0] ?? "event";
}

function handleGatewayMessage(msg: any): void {
  state.gatewayEvents++;
  const eventName = String(extractEventName(msg));
  const payload = msg?.payload;
  const tool = extractToolName(payload);

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
    state.mode = "websocket";
    setPhase("thinking");

    subscribeSessionEvents();

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

  // Response to sessions preview
  if (msg.type === "res" && msg.ok && msg.id?.startsWith("preview-")) {
    handleSessionPreviewResponse(msg.payload);
    return;
  }

  // Any event = potential activity signal
  if (msg.type === "event") {
    // Events like agent.run.start, tool.call, etc. indicate activity
    if (eventName.includes("agent") || eventName.includes("tool") || eventName.includes("run") || eventName.includes("session.message")) {
      state.active = true;
      state.ts = Date.now();
    }

    if (eventName.includes("tool") || tool) {
      const toolName = tool ?? eventName;
      const phase = extractPhase(eventName, payload);
      pushToolActivity({
        ts: Date.now(),
        sessionKey: extractSessionKey(payload),
        tool: toolName,
        phase,
      });
      setPhase("tooling");
    } else if (eventName.includes("session.message")) {
      const role = String(payload?.message?.role ?? payload?.role ?? "").toLowerCase();
      if (role === "assistant") {
        setPhase("responding");
      } else {
        setPhase("thinking");
      }
    } else if (eventName.includes("agent") || eventName.includes("run")) {
      setPhase("thinking");
    }
  }
}

function sendConnect(challenge: { nonce: string; ts: number }): void {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  const signedAt = Date.now();
  const nonce = challenge.nonce;

  // v3 signature payload: fields joined by "|"
  const signaturePayload = [
    "v3",
    deviceId,
    "gateway-client",   // clientId
    "backend",           // clientMode
    "operator",          // role
    "operator.read",     // scopes (comma-separated)
    String(signedAt),    // signedAtMs
    GATEWAY_TOKEN,       // token
    nonce,               // nonce from challenge
    "macos",             // platform
    "server",            // deviceFamily
  ].join("|");
  const signature = signPayload(signaturePayload);
  const connectMsg = {
    type: "req",
    id: nextId(),
    method: "connect",
    params: {
      minProtocol: 3,
      maxProtocol: 3,
      client: {
        id: "gateway-client",
        version: "0.1.0",
        platform: "macos",
        deviceFamily: "server",
        mode: "backend",
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
        publicKey: publicKeyBase64Url,
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

function subscribeSessionEvents(): void {
  if (!ws || ws.readyState !== WebSocket.OPEN || sessionsSubscribed) return;
  sessionsSubscribed = true;
  const msg = {
    type: "req",
    id: `sub-${nextId()}`,
    method: "sessions.subscribe",
    params: {},
  };
  ws.send(JSON.stringify(msg));
}

function subscribeSessionMessages(sessionKey: string): void {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  if (!sessionKey || subscribedSessionKeys.has(sessionKey)) return;
  subscribedSessionKeys.add(sessionKey);
  const msg = {
    type: "req",
    id: `submsg-${nextId()}`,
    method: "sessions.messages.subscribe",
    params: { sessionKey },
  };
  ws.send(JSON.stringify(msg));
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

function pollSessionPreviews(sessionKeys: string[]): void {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  const keys = Array.from(new Set(sessionKeys.filter(Boolean))).slice(0, 24);
  if (keys.length === 0) return;

  const msg = {
    type: "req",
    id: `preview-${nextId()}`,
    method: "sessions.preview",
    params: {
      keys,
      limit: 20,
      maxChars: 220,
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

    if (s.key || s.sessionKey) {
      subscribeSessionMessages(s.key ?? s.sessionKey);
    }
  }

  const sessionKeys = sessions.map((s) => s.key).filter((k) => k && k !== "unknown");
  pollSessionPreviews(sessionKeys);

  const activeSessions = sessions.filter((s) => s.active).length;

  state.sessions = sessions;
  state.active = activeSessions > 0;
  state.summary = {
    totalSessions: sessions.length,
    activeSessions,
    idleSessions: sessions.length - activeSessions,
  };

  if (activeSessions === 0) {
    setPhase("idle");
  } else {
    const sincePhaseMs = Date.now() - state.phaseTs;
    if (state.currentPhase === "tooling" && sincePhaseMs > 4500) {
      setPhase("thinking");
    }
  }

  state.ts = now;
}

function handleSessionPreviewResponse(payload: any): void {
  const previews = Array.isArray(payload?.previews) ? payload.previews : [];
  const now = Date.now();

  for (const preview of previews) {
    const sessionKey = typeof preview?.key === "string" ? preview.key : undefined;
    const items = Array.isArray(preview?.items) ? preview.items : [];

    for (const item of items) {
      const text = typeof item?.text === "string" ? item.text.trim() : "";
      if (!text) continue;
      if (!text.toLowerCase().startsWith("call ")) continue;

      const parsed = text.replace(/^call\s+/i, "").trim();
      if (!parsed) continue;

      for (const rawTool of parsed.split(",")) {
        const tool = rawTool.trim().replace(/\s*\+\d+$/, "").trim();
        if (tool.startsWith("+")) continue;
        if (!tool) continue;
        pushToolActivity({
          ts: now,
          sessionKey,
          tool,
          phase: "preview",
        });
        if (state.active) {
          setPhase("tooling");
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Fallback: poll via openclaw status CLI
// ---------------------------------------------------------------------------

let useCliFallback = false;
let cliPollTimer: ReturnType<typeof setInterval> | null = null;

function startCliFallback(): void {
  if (cliPollTimer) return;
  useCliFallback = true;
  state.mode = "cli-fallback";
  setPhase("thinking");
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
  execFile(OPENCLAW_BIN, ["status", "--json"], { timeout: 10000 }, (err, stdout) => {
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
      if (activeSessions === 0) {
        setPhase("idle");
      } else if (state.currentPhase === "idle") {
        setPhase("thinking");
      }
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

const BIND_HOST = process.env.ACTIVITY_BIND_HOST ?? "0.0.0.0";

server.listen(PORT, BIND_HOST, () => {
  console.log(`[server] listening on http://${BIND_HOST}:${PORT}`);
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
