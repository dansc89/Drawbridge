# Drawbridge Cloud Backend V1 Architecture

## Goals
- Enable account-based collaboration with simple username/password auth.
- Support Bluebeam Sessions-like live multi-user markup updates.
- Preserve offline-first behavior by syncing append-only markup operations.
- Handle PDF uploads/downloads and document ownership within projects.

## Core Domain Model
- `users`: account records (`username`, password hash, display name).
- `projects`: shared spaces containing documents.
- `project_members`: ACL for each project (`owner`, `admin`, `editor`, `viewer`).
- `documents`: PDFs and metadata.
- `sessions`: active collaboration rooms on one document.
- `session_members`: room participants and per-session role.
- `markup_ops`: ordered operation log (`seq` per document) for deterministic sync.
- `file_uploads`: immutable upload history and integrity hashes.

## Sync Model
- Every markup mutation is an operation event written to `markup_ops`.
- Server assigns a monotonically increasing `seq` for each document.
- Clients fetch missed ops using `GET /v1/documents/:documentId/ops?afterSeq=N`.
- Clients can append ops via REST or websocket `op_append`.
- `clientOpId` provides idempotency to avoid duplicate writes on retries.

## Realtime Collaboration
- WebSocket endpoint: `/ws?token=<jwt>`.
- Client joins a session/document channel with `subscribe`.
- New ops are broadcast as `op_appended` to all subscribed participants.
- Presence heartbeat (`presence_ping`) updates `last_seen_at`.

## Auth and Security
- Passwords hashed with bcrypt (`cost=12`).
- JWT bearer auth for all protected endpoints.
- Permission checks at project/document/session boundaries.
- Upload size caps and file hashing (sha256).

## Storage
- V1 local persistence:
  - SQLite DB: `./data/drawbridge.db`
  - Uploaded files: `./storage/documents/...`
- Docker compose includes MinIO for next-step object-store migration.

## Orange Pi 5 Deployment Shape
- Run backend under systemd or Docker Compose.
- Reverse proxy with Caddy/Nginx for TLS and stable DNS.
- Keep `data/` and `storage/` on persistent disk (not tmpfs).
- Optional later upgrades:
  - PostgreSQL (stronger concurrent write handling)
  - Redis (presence fanout + queueing)
  - MinIO/S3 (document object storage)

## Drawbridge Client Integration Contract
- Authenticate once, store JWT securely.
- Create/select project and document from API.
- Start or join active session for selected document.
- Push local markup actions as operations with `clientOpId`.
- Pull and apply missing ops ordered by `seq`.
- Keep websocket connected for low-latency updates; fall back to polling.
