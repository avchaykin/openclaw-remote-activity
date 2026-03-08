# OpenClaw Remote Activity Monitor

Real-time activity monitor for [OpenClaw](https://openclaw.ai) agents — a local API server + macOS menu bar client.

![demo](https://img.shields.io/badge/macOS-14%2B-blue) ![license](https://img.shields.io/badge/license-MIT-green)

## Components

### 🖥 Activity Server (`openclaw-activity-server`)

A lightweight Node.js service that connects to your OpenClaw Gateway via WebSocket and exposes a simple REST API with current agent activity status.

- Connects to Gateway WS as an operator
- Tracks active sessions, running tools, pending requests
- Exposes `GET /api/status` on `localhost:19789`

### 🔴 Menu Bar Client (`OpenClawActivity.app`)

A native macOS menu bar app that shows agent activity at a glance.

- **Red pulsing dot** — agent is actively processing (tool running, generating response)
- **Gray dot** — all sessions idle
- Click to see session details
- Minimal resource usage (~5MB RAM)

## Installation

### Via Homebrew

```bash
# Add the tap
brew tap avchaykin/openclaw-remote-activity https://github.com/avchaykin/openclaw-remote-activity

# Install server + client
brew install openclaw-activity-server
brew install --cask openclaw-activity-bar

# Start the server as a background service
brew services start openclaw-activity-server

# Launch the menu bar app (auto-starts on login)
open /Applications/OpenClawActivity.app
```

### Manual

```bash
# Server
cd server && npm install && npm run build
OPENCLAW_GATEWAY_URL=ws://127.0.0.1:18789 \
OPENCLAW_GATEWAY_TOKEN=your_token \
  node dist/index.js

# Client
cd client && swift build -c release
cp .build/release/OpenClawActivity /usr/local/bin/
```

## Configuration

### Server

Environment variables (or `.env` file):

| Variable | Default | Description |
|---|---|---|
| `OPENCLAW_GATEWAY_URL` | `ws://127.0.0.1:18789` | Gateway WebSocket URL |
| `OPENCLAW_GATEWAY_TOKEN` | — | Gateway auth token |
| `ACTIVITY_PORT` | `19789` | HTTP API port |
| `ACTIVITY_POLL_INTERVAL` | `3000` | Status poll interval (ms) |

### Client

The menu bar app connects to `http://localhost:19789` by default. To change:

```bash
defaults write com.openclaw.activity serverURL "http://localhost:19789"
```

## API

### `GET /api/status`

```json
{
  "active": true,
  "sessions": [
    {
      "key": "agent:main:telegram:direct:129208069",
      "agentId": "main",
      "kind": "direct",
      "ageMs": 5200,
      "active": true
    }
  ],
  "summary": {
    "totalSessions": 3,
    "activeSessions": 1,
    "idleSessions": 2
  },
  "ts": 1772977633446
}
```

### `GET /api/health`

```json
{ "ok": true, "gateway": "connected", "uptime": 3600 }
```

## License

MIT
