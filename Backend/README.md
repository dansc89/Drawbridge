# Drawbridge Sync Backend

Account-based backend for Drawbridge collaboration, cloud uploads, and realtime session sync.

## Features
- Username/password account registration and login
- JWT auth and authenticated API access
- Project/document ACLs (`owner/admin/editor/viewer`)
- PDF upload/download endpoints
- Session create/join/leave flow
- Realtime operation sync over WebSocket
- Append-only operation log with per-document sequence numbers

## Quick Start (local)

```bash
cd /Users/danielnguyen/Drawbridge/Backend
cp .env.example .env
npm install
npm run start
```

Health check:

```bash
curl http://localhost:8787/health
```

## API Overview

### Auth
- `POST /v1/auth/register` `{ username, password, displayName? }`
- `POST /v1/auth/login` `{ username, password }`
- `GET /v1/auth/me` (bearer token)

### Projects / Members
- `POST /v1/projects` `{ name }`
- `GET /v1/projects`
- `POST /v1/projects/:projectId/members` `{ username, role }`

### Documents
- `POST /v1/projects/:projectId/documents` `{ name }`
- `GET /v1/projects/:projectId/documents`
- `POST /v1/documents/:documentId/upload` multipart `file`
- `GET /v1/documents/:documentId/download`

### Sessions
- `POST /v1/documents/:documentId/sessions` `{ name? }`
- `POST /v1/sessions/:sessionId/join`
- `POST /v1/sessions/:sessionId/leave`
- `GET /v1/sessions/:sessionId/presence`

### Sync Ops
- `GET /v1/documents/:documentId/ops?afterSeq=<n>&limit=<n>`
- `POST /v1/documents/:documentId/ops`

Request body for append:

```json
{
  "sessionId": "<uuid>",
  "opType": "annotation.add",
  "payload": { "annotation": {} },
  "clientOpId": "optional-idempotency-key"
}
```

## WebSocket

Connect:

```text
ws://localhost:8787/ws?token=<jwt>
```

Message types:
- client -> server: `subscribe`, `presence_ping`, `op_append`
- server -> client: `connected`, `subscribed`, `presence_ack`, `op_appended`, `error`

Example subscribe:

```json
{
  "type": "subscribe",
  "sessionId": "<session-id>",
  "documentId": "<document-id>"
}
```

## Orange Pi Deployment

### Option A: systemd
1. Copy backend to `/opt/drawbridge/Backend`
2. Create Linux user `drawbridge`
3. Set `/opt/drawbridge/Backend/.env`
4. Install service file from `deploy/systemd/drawbridge-sync.service`

```bash
sudo cp deploy/systemd/drawbridge-sync.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now drawbridge-sync
```

### Option B: Docker Compose

```bash
cd /opt/drawbridge/Backend
cp .env.example .env
docker compose up -d --build
```

## Notes
- V1 uses SQLite for fast setup and low ops overhead on Orange Pi.
- For higher concurrency, migrate to PostgreSQL + Redis while keeping the same API contract.
