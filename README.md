# OpenClaw Remote Activity Monitor

Real-time activity monitor for [OpenClaw](https://openclaw.ai):

- a local API server (`openclaw-activity-server`)
- a macOS menu bar client (`OpenClawActivity`)

## Features

### Server

- Tracks OpenClaw session activity
- Exposes simple HTTP endpoints:
  - `GET /api/status`
  - `GET /api/health`
  - `GET /api/stream` (SSE)
- WebSocket gateway mode (best effort)
- Automatic CLI fallback mode (`openclaw status --json`) when WS auth is unavailable

### Menu bar client

- **White dot** = connected
- **White dot + ripple animation** = activity in progress
- **Red dot** = disconnected from API server
- Ripple color shows phase (for visual feedback):
  - **Cyan** = tooling
  - **Purple** = thinking
  - **Orange** = responding
- Popover shows activity summary, tool activity, and current phase
- Right-click the menu bar icon and open **Settings...** to configure API URL and gateway token

---

## Install with Homebrew

```bash
brew tap avchaykin/openclaw-remote-activity https://github.com/avchaykin/openclaw-remote-activity

brew install openclaw-activity-server
brew install openclaw-activity-bar
```

Start server as a background service:

```bash
brew services start openclaw-activity-server
```

Launch client:

```bash
openclaw-activity-bar
# or (if app bundle is present)
open /Applications/OpenClawActivity.app
```

> Note: `openclaw-activity-bar` is built with Swift. Xcode Command Line Tools are enough.

---

## Manual install

### Server

```bash
cd server
npm install
npm run build

# Local-only API:
node dist/index.js

# LAN-accessible API:
ACTIVITY_BIND_HOST=0.0.0.0 node dist/index.js
```

### Client

```bash
cd client
swift build -c release --disable-sandbox
./.build/release/OpenClawActivity
```

---

## Configuration

### Server environment variables

| Variable | Default | Description |
|---|---|---|
| `OPENCLAW_GATEWAY_URL` | `ws://127.0.0.1:18789` | OpenClaw Gateway WS URL |
| `OPENCLAW_GATEWAY_TOKEN` | empty | Gateway auth token |
| `ACTIVITY_PORT` | `19789` | API port |
| `ACTIVITY_BIND_HOST` | `0.0.0.0` | Bind host (`127.0.0.1` for local-only) |
| `ACTIVITY_POLL_INTERVAL` | `3000` | Poll interval (ms) |
| `ACTIVITY_THRESHOLD_MS` | `15000` | Session age threshold considered “active” |

If `OPENCLAW_GATEWAY_TOKEN` is empty, server also tries `~/.openclaw/openclaw.json` (`gateway.auth.token`).

### Client API URL selection order

The client resolves API URL in this order:

1. `OPENCLAW_ACTIVITY_SERVER_URL` environment variable
2. `defaults` domain `com.openclaw.activity` key `serverURL`
3. `defaults` domains `OpenClawActivity` and `openclaw-activity-bar` key `serverURL`
4. standard defaults key `serverURL`
5. fallback: `http://localhost:19789`

Set a remote server URL:

```bash
defaults write com.openclaw.activity serverURL "http://192.168.1.121:19789"
```

Restart client after changes.

### Menu bar settings

In **Settings...** you can configure:

- **Activity API URL** (client endpoint)
- **OpenClaw gateway token** (saved to `~/.openclaw/openclaw.json` as `gateway.auth.token`)

After changing token, restart the server:

```bash
brew services restart openclaw-activity-server
```

---

## API examples

### `GET /api/health`

```json
{ "ok": true, "gateway": "connected", "uptime": 3600, "mode": "cli-fallback" }
```

### `GET /api/status`

```json
{
  "connected": true,
  "active": true,
  "currentPhase": "tooling",
  "phaseTs": 1776335000000,
  "sessions": [
    {
      "key": "agent:main:telegram:direct:129208069",
      "agentId": "main",
      "kind": "direct",
      "ageMs": 5200,
      "active": true,
      "model": "claude-opus-4-6"
    }
  ],
  "summary": {
    "totalSessions": 3,
    "activeSessions": 1,
    "idleSessions": 2
  },
  "toolLog": [
    {
      "ts": 1776334999000,
      "sessionKey": "agent:main:telegram:direct:129208069",
      "tool": "read",
      "phase": "start"
    }
  ],
  "ts": 1772977633446,
  "gatewayEvents": 42,
  "mode": "websocket"
}
```

---

## License

MIT
