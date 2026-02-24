import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import http from "node:http";
import express from "express";
import cors from "cors";
import morgan from "morgan";
import jwt from "jsonwebtoken";
import bcrypt from "bcryptjs";
import multer from "multer";
import { v4 as uuidv4 } from "uuid";
import { WebSocketServer } from "ws";
import { config } from "./config.js";
import { db } from "./db.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
app.use(cors({ origin: config.corsOrigin === "*" ? true : config.corsOrigin }));
app.use(express.json({ limit: "2mb" }));
app.use(morgan("dev"));

const uploadTmpDir = path.resolve(__dirname, "../storage/tmp");
const documentRoot = path.resolve(config.storageRoot, "documents");
fs.mkdirSync(uploadTmpDir, { recursive: true });
fs.mkdirSync(documentRoot, { recursive: true });

const upload = multer({
  dest: uploadTmpDir,
  limits: { fileSize: config.maxUploadBytes }
});

function signToken(user) {
  return jwt.sign(
    {
      sub: user.id,
      username: user.username,
      displayName: user.display_name || null
    },
    config.jwtSecret,
    { expiresIn: "14d" }
  );
}

function authRequired(req, res, next) {
  const authHeader = req.headers.authorization || "";
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    return res.status(401).json({ error: "Missing bearer token" });
  }
  try {
    const decoded = jwt.verify(match[1], config.jwtSecret);
    req.auth = decoded;
    return next();
  } catch {
    return res.status(401).json({ error: "Invalid token" });
  }
}

function userById(userId) {
  return db.prepare("SELECT id, username, display_name, created_at FROM users WHERE id = ?").get(userId);
}

function ensureProjectMembership(projectId, userId) {
  return db
    .prepare(
      `SELECT pm.role
       FROM project_members pm
       WHERE pm.project_id = ? AND pm.user_id = ?`
    )
    .get(projectId, userId);
}

function ensureDocumentMembership(documentId, userId) {
  return db
    .prepare(
      `SELECT d.*, pm.role as project_role
       FROM documents d
       JOIN project_members pm ON pm.project_id = d.project_id
       WHERE d.id = ? AND pm.user_id = ?`
    )
    .get(documentId, userId);
}

function ensureSessionMembership(sessionId, userId) {
  return db
    .prepare(
      `SELECT s.*, sm.role as session_role
       FROM sessions s
       JOIN session_members sm ON sm.session_id = s.id
       WHERE s.id = ? AND sm.user_id = ? AND sm.left_at IS NULL`
    )
    .get(sessionId, userId);
}

function appendMarkupOp({ documentId, sessionId, authorUserId, opType, payload, clientOpId = null }) {
  const payloadJson = JSON.stringify(payload || {});
  const opId = uuidv4();
  let inserted;
  const tx = db.transaction(() => {
    const maxSeqRow = db
      .prepare("SELECT COALESCE(MAX(seq), 0) AS max_seq FROM markup_ops WHERE document_id = ?")
      .get(documentId);
    const nextSeq = Number(maxSeqRow.max_seq || 0) + 1;
    db.prepare(
      `INSERT INTO markup_ops (id, document_id, session_id, author_user_id, op_type, payload_json, client_op_id, seq)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
    ).run(opId, documentId, sessionId, authorUserId, opType, payloadJson, clientOpId, nextSeq);

    inserted = db
      .prepare(
        `SELECT id, document_id, session_id, author_user_id, op_type, payload_json, client_op_id, seq, created_at
         FROM markup_ops
         WHERE id = ?`
      )
      .get(opId);
  });
  tx();
  return {
    ...inserted,
    payload: JSON.parse(inserted.payload_json)
  };
}

app.get("/health", (_, res) => {
  res.json({ ok: true, service: "drawbridge-sync-backend" });
});

app.post("/v1/auth/register", (req, res) => {
  const username = String(req.body?.username || "").trim().toLowerCase();
  const displayName = String(req.body?.displayName || "").trim();
  const password = String(req.body?.password || "");

  if (!/^[a-z0-9._-]{3,32}$/.test(username)) {
    return res.status(400).json({ error: "Username must be 3-32 chars: a-z, 0-9, ., _, -" });
  }
  if (password.length < 8) {
    return res.status(400).json({ error: "Password must be at least 8 characters" });
  }

  const exists = db.prepare("SELECT id FROM users WHERE username = ?").get(username);
  if (exists) {
    return res.status(409).json({ error: "Username already exists" });
  }

  const userId = uuidv4();
  const hash = bcrypt.hashSync(password, 12);
  db.prepare(
    `INSERT INTO users (id, username, password_hash, display_name)
     VALUES (?, ?, ?, ?)`
  ).run(userId, username, hash, displayName || null);

  const user = userById(userId);
  const token = signToken({ id: userId, username, display_name: displayName || null });
  return res.status(201).json({ token, user });
});

app.post("/v1/auth/login", (req, res) => {
  const username = String(req.body?.username || "").trim().toLowerCase();
  const password = String(req.body?.password || "");

  const user = db.prepare("SELECT * FROM users WHERE username = ?").get(username);
  if (!user || !bcrypt.compareSync(password, user.password_hash)) {
    return res.status(401).json({ error: "Invalid username or password" });
  }

  const token = signToken(user);
  return res.json({
    token,
    user: {
      id: user.id,
      username: user.username,
      display_name: user.display_name,
      created_at: user.created_at
    }
  });
});

app.get("/v1/auth/me", authRequired, (req, res) => {
  const user = userById(req.auth.sub);
  if (!user) {
    return res.status(404).json({ error: "User not found" });
  }
  return res.json({ user });
});

app.post("/v1/projects", authRequired, (req, res) => {
  const name = String(req.body?.name || "").trim();
  if (!name) {
    return res.status(400).json({ error: "Project name required" });
  }

  const projectId = uuidv4();
  const userId = req.auth.sub;
  const tx = db.transaction(() => {
    db.prepare(
      `INSERT INTO projects (id, name, owner_user_id)
       VALUES (?, ?, ?)`
    ).run(projectId, name, userId);
    db.prepare(
      `INSERT INTO project_members (project_id, user_id, role)
       VALUES (?, ?, 'owner')`
    ).run(projectId, userId);
  });
  tx();

  const project = db.prepare("SELECT * FROM projects WHERE id = ?").get(projectId);
  res.status(201).json({ project });
});

app.get("/v1/projects", authRequired, (req, res) => {
  const rows = db
    .prepare(
      `SELECT p.*, pm.role
       FROM projects p
       JOIN project_members pm ON pm.project_id = p.id
       WHERE pm.user_id = ?
       ORDER BY p.updated_at DESC`
    )
    .all(req.auth.sub);
  res.json({ projects: rows });
});

app.post("/v1/projects/:projectId/members", authRequired, (req, res) => {
  const { projectId } = req.params;
  const requesterRole = ensureProjectMembership(projectId, req.auth.sub);
  if (!requesterRole || (requesterRole.role !== "owner" && requesterRole.role !== "admin")) {
    return res.status(403).json({ error: "Only owner/admin can add members" });
  }

  const username = String(req.body?.username || "").trim().toLowerCase();
  const role = String(req.body?.role || "editor").trim().toLowerCase();
  if (!["viewer", "editor", "admin"].includes(role)) {
    return res.status(400).json({ error: "Invalid role" });
  }

  const user = db.prepare("SELECT id, username FROM users WHERE username = ?").get(username);
  if (!user) {
    return res.status(404).json({ error: "User not found" });
  }

  db.prepare(
    `INSERT INTO project_members (project_id, user_id, role)
     VALUES (?, ?, ?)
     ON CONFLICT(project_id, user_id) DO UPDATE SET role = excluded.role`
  ).run(projectId, user.id, role);

  res.json({ ok: true, added: { projectId, userId: user.id, role } });
});

app.post("/v1/projects/:projectId/documents", authRequired, (req, res) => {
  const { projectId } = req.params;
  const role = ensureProjectMembership(projectId, req.auth.sub);
  if (!role) {
    return res.status(403).json({ error: "No access to project" });
  }
  if (!["owner", "admin", "editor"].includes(role.role)) {
    return res.status(403).json({ error: "Project role cannot create documents" });
  }

  const name = String(req.body?.name || "").trim();
  if (!name) {
    return res.status(400).json({ error: "Document name required" });
  }

  const documentId = uuidv4();
  db.prepare(
    `INSERT INTO documents (id, project_id, name, created_by_user_id)
     VALUES (?, ?, ?, ?)`
  ).run(documentId, projectId, name, req.auth.sub);

  const document = db.prepare("SELECT * FROM documents WHERE id = ?").get(documentId);
  res.status(201).json({ document });
});

app.get("/v1/projects/:projectId/documents", authRequired, (req, res) => {
  const { projectId } = req.params;
  const role = ensureProjectMembership(projectId, req.auth.sub);
  if (!role) {
    return res.status(403).json({ error: "No access to project" });
  }

  const documents = db
    .prepare(
      `SELECT d.*
       FROM documents d
       WHERE d.project_id = ?
       ORDER BY d.updated_at DESC`
    )
    .all(projectId);
  res.json({ documents });
});

app.post("/v1/documents/:documentId/upload", authRequired, (req, res, next) => {
  const doc = ensureDocumentMembership(req.params.documentId, req.auth.sub);
  if (!doc) {
    return res.status(403).json({ error: "No access to document" });
  }
  if (!["owner", "admin", "editor"].includes(doc.project_role)) {
    return res.status(403).json({ error: "Project role cannot upload" });
  }
  req.document = doc;
  return next();
}, upload.single("file"), (req, res) => {
  if (!req.file) {
    return res.status(400).json({ error: "Expected multipart file field named 'file'" });
  }

  const documentId = req.params.documentId;
  const docDir = path.resolve(documentRoot, documentId);
  fs.mkdirSync(docDir, { recursive: true });

  const safeOriginalName = (req.file.originalname || "document.pdf").replace(/[^a-zA-Z0-9._-]/g, "_");
  const finalName = `${Date.now()}-${safeOriginalName}`;
  const finalPath = path.resolve(docDir, finalName);

  fs.renameSync(req.file.path, finalPath);
  const fileBuffer = fs.readFileSync(finalPath);
  const sha256 = crypto.createHash("sha256").update(fileBuffer).digest("hex");

  db.prepare(
    `UPDATE documents
     SET file_path = ?, file_size = ?, file_sha256 = ?, content_type = ?, updated_at = CURRENT_TIMESTAMP
     WHERE id = ?`
  ).run(finalPath, req.file.size, sha256, req.file.mimetype || null, documentId);

  db.prepare(
    `INSERT INTO file_uploads (id, document_id, uploaded_by_user_id, file_path, content_type, file_size, file_sha256)
     VALUES (?, ?, ?, ?, ?, ?, ?)`
  ).run(uuidv4(), documentId, req.auth.sub, finalPath, req.file.mimetype || null, req.file.size, sha256);

  const document = db.prepare("SELECT * FROM documents WHERE id = ?").get(documentId);
  res.json({
    document,
    upload: {
      contentType: req.file.mimetype,
      fileSize: req.file.size,
      sha256
    }
  });
});

app.get("/v1/documents/:documentId/download", authRequired, (req, res) => {
  const doc = ensureDocumentMembership(req.params.documentId, req.auth.sub);
  if (!doc) {
    return res.status(403).json({ error: "No access to document" });
  }
  if (!doc.file_path || !fs.existsSync(doc.file_path)) {
    return res.status(404).json({ error: "No uploaded file" });
  }
  return res.download(doc.file_path, doc.name);
});

app.post("/v1/documents/:documentId/sessions", authRequired, (req, res) => {
  const doc = ensureDocumentMembership(req.params.documentId, req.auth.sub);
  if (!doc) {
    return res.status(403).json({ error: "No access to document" });
  }
  if (!["owner", "admin", "editor"].includes(doc.project_role)) {
    return res.status(403).json({ error: "Project role cannot create sessions" });
  }

  const name = String(req.body?.name || "").trim() || `Session ${new Date().toISOString()}`;
  const sessionId = uuidv4();
  const tx = db.transaction(() => {
    db.prepare(
      `INSERT INTO sessions (id, project_id, document_id, name, created_by_user_id)
       VALUES (?, ?, ?, ?, ?)`
    ).run(sessionId, doc.project_id, doc.id, name, req.auth.sub);
    db.prepare(
      `INSERT INTO session_members (session_id, user_id, role)
       VALUES (?, ?, 'owner')`
    ).run(sessionId, req.auth.sub);
  });
  tx();

  const session = db.prepare("SELECT * FROM sessions WHERE id = ?").get(sessionId);
  res.status(201).json({ session });
});

app.post("/v1/sessions/:sessionId/join", authRequired, (req, res) => {
  const session = db.prepare("SELECT * FROM sessions WHERE id = ?").get(req.params.sessionId);
  if (!session) {
    return res.status(404).json({ error: "Session not found" });
  }
  const doc = ensureDocumentMembership(session.document_id, req.auth.sub);
  if (!doc) {
    return res.status(403).json({ error: "No access to session document" });
  }

  const role = doc.project_role === "viewer" ? "viewer" : "editor";
  db.prepare(
    `INSERT INTO session_members (session_id, user_id, role, left_at)
     VALUES (?, ?, ?, NULL)
     ON CONFLICT(session_id, user_id)
     DO UPDATE SET role = excluded.role, left_at = NULL, last_seen_at = CURRENT_TIMESTAMP`
  ).run(session.id, req.auth.sub, role);

  res.json({ ok: true, sessionId: session.id, role });
});

app.post("/v1/sessions/:sessionId/leave", authRequired, (req, res) => {
  const membership = ensureSessionMembership(req.params.sessionId, req.auth.sub);
  if (!membership) {
    return res.status(404).json({ error: "Not in session" });
  }
  db.prepare(
    `UPDATE session_members
     SET left_at = CURRENT_TIMESTAMP, last_seen_at = CURRENT_TIMESTAMP
     WHERE session_id = ? AND user_id = ?`
  ).run(req.params.sessionId, req.auth.sub);
  res.json({ ok: true });
});

app.get("/v1/documents/:documentId/ops", authRequired, (req, res) => {
  const doc = ensureDocumentMembership(req.params.documentId, req.auth.sub);
  if (!doc) {
    return res.status(403).json({ error: "No access to document" });
  }

  const afterSeq = Number(req.query.afterSeq || 0);
  const limit = Math.min(2000, Math.max(1, Number(req.query.limit || 500)));
  const ops = db
    .prepare(
      `SELECT id, document_id, session_id, author_user_id, op_type, payload_json, client_op_id, seq, created_at
       FROM markup_ops
       WHERE document_id = ? AND seq > ?
       ORDER BY seq ASC
       LIMIT ?`
    )
    .all(doc.id, afterSeq, limit)
    .map((row) => ({ ...row, payload: JSON.parse(row.payload_json) }));

  const latest = db
    .prepare("SELECT COALESCE(MAX(seq), 0) AS latest_seq FROM markup_ops WHERE document_id = ?")
    .get(doc.id);

  res.json({
    documentId: doc.id,
    afterSeq,
    latestSeq: Number(latest.latest_seq || 0),
    ops
  });
});

app.post("/v1/documents/:documentId/ops", authRequired, (req, res) => {
  const doc = ensureDocumentMembership(req.params.documentId, req.auth.sub);
  if (!doc) {
    return res.status(403).json({ error: "No access to document" });
  }
  const sessionId = String(req.body?.sessionId || "");
  const opType = String(req.body?.opType || "").trim();
  const payload = req.body?.payload || {};
  const clientOpId = req.body?.clientOpId ? String(req.body.clientOpId) : null;

  if (!sessionId || !opType) {
    return res.status(400).json({ error: "sessionId and opType are required" });
  }
  const membership = ensureSessionMembership(sessionId, req.auth.sub);
  if (!membership || membership.document_id !== doc.id) {
    return res.status(403).json({ error: "Must join session before appending ops" });
  }
  if (membership.session_role === "viewer") {
    return res.status(403).json({ error: "Viewer cannot append ops" });
  }

  try {
    const op = appendMarkupOp({
      documentId: doc.id,
      sessionId,
      authorUserId: req.auth.sub,
      opType,
      payload,
      clientOpId
    });
    broadcastDocumentOp(doc.id, {
      type: "op_appended",
      documentId: doc.id,
      op
    });
    res.status(201).json({ op });
  } catch (error) {
    if (String(error.message || "").includes("UNIQUE constraint failed: markup_ops.document_id, markup_ops.author_user_id, markup_ops.client_op_id")) {
      const existing = db
        .prepare(
          `SELECT id, document_id, session_id, author_user_id, op_type, payload_json, client_op_id, seq, created_at
           FROM markup_ops
           WHERE document_id = ? AND author_user_id = ? AND client_op_id = ?`
        )
        .get(doc.id, req.auth.sub, clientOpId);
      return res.status(200).json({ op: { ...existing, payload: JSON.parse(existing.payload_json) }, duplicate: true });
    }
    throw error;
  }
});

app.get("/v1/sessions/:sessionId/presence", authRequired, (req, res) => {
  const membership = ensureSessionMembership(req.params.sessionId, req.auth.sub);
  if (!membership) {
    return res.status(403).json({ error: "No access to session" });
  }

  const members = db
    .prepare(
      `SELECT u.id, u.username, u.display_name, sm.role, sm.joined_at, sm.last_seen_at
       FROM session_members sm
       JOIN users u ON u.id = sm.user_id
       WHERE sm.session_id = ? AND sm.left_at IS NULL
       ORDER BY sm.joined_at ASC`
    )
    .all(req.params.sessionId);

  res.json({ sessionId: req.params.sessionId, members });
});

app.use((err, _req, res, _next) => {
  console.error(err);
  if (err?.code === "LIMIT_FILE_SIZE") {
    return res.status(413).json({ error: `Upload exceeds ${Math.floor(config.maxUploadBytes / (1024 * 1024))} MB limit` });
  }
  return res.status(500).json({ error: "Internal server error" });
});

const server = http.createServer(app);
const wss = new WebSocketServer({ noServer: true });

const clientState = new Map();
const subscribersByDocument = new Map();

function trackSubscription(documentId, ws) {
  if (!subscribersByDocument.has(documentId)) {
    subscribersByDocument.set(documentId, new Set());
  }
  subscribersByDocument.get(documentId).add(ws);
}

function untrackAll(ws) {
  const state = clientState.get(ws);
  if (!state) {
    return;
  }
  for (const documentId of state.subscribedDocuments) {
    const set = subscribersByDocument.get(documentId);
    if (!set) continue;
    set.delete(ws);
    if (set.size === 0) {
      subscribersByDocument.delete(documentId);
    }
  }
  clientState.delete(ws);
}

function sendWs(ws, payload) {
  if (ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(payload));
  }
}

function broadcastDocumentOp(documentId, payload) {
  const set = subscribersByDocument.get(documentId);
  if (!set) return;
  for (const ws of set) {
    sendWs(ws, payload);
  }
}

function parseTokenFromReq(req) {
  const u = new URL(req.url, "http://localhost");
  const token = u.searchParams.get("token");
  return token;
}

server.on("upgrade", (req, socket, head) => {
  if (!req.url?.startsWith("/ws")) {
    socket.destroy();
    return;
  }

  const token = parseTokenFromReq(req);
  if (!token) {
    socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
    socket.destroy();
    return;
  }

  try {
    const decoded = jwt.verify(token, config.jwtSecret);
    req.auth = decoded;
    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit("connection", ws, req);
    });
  } catch {
    socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
    socket.destroy();
  }
});

wss.on("connection", (ws, req) => {
  const state = {
    userId: req.auth.sub,
    subscribedDocuments: new Set(),
    joinedSessions: new Set()
  };
  clientState.set(ws, state);

  sendWs(ws, { type: "connected", userId: state.userId });

  ws.on("message", (msgBuffer) => {
    let msg;
    try {
      msg = JSON.parse(String(msgBuffer));
    } catch {
      sendWs(ws, { type: "error", error: "Invalid JSON" });
      return;
    }

    if (msg.type === "subscribe") {
      const sessionId = String(msg.sessionId || "");
      const documentId = String(msg.documentId || "");
      const membership = ensureSessionMembership(sessionId, state.userId);
      if (!membership || membership.document_id !== documentId) {
        sendWs(ws, { type: "error", error: "Not joined to requested session/document" });
        return;
      }
      state.joinedSessions.add(sessionId);
      state.subscribedDocuments.add(documentId);
      trackSubscription(documentId, ws);
      db.prepare(
        `UPDATE session_members SET last_seen_at = CURRENT_TIMESTAMP
         WHERE session_id = ? AND user_id = ?`
      ).run(sessionId, state.userId);
      sendWs(ws, { type: "subscribed", sessionId, documentId });
      return;
    }

    if (msg.type === "presence_ping") {
      const sessionId = String(msg.sessionId || "");
      if (!state.joinedSessions.has(sessionId)) {
        sendWs(ws, { type: "error", error: "Session not joined" });
        return;
      }
      db.prepare(
        `UPDATE session_members SET last_seen_at = CURRENT_TIMESTAMP
         WHERE session_id = ? AND user_id = ?`
      ).run(sessionId, state.userId);
      sendWs(ws, { type: "presence_ack", sessionId, at: new Date().toISOString() });
      return;
    }

    if (msg.type === "op_append") {
      const sessionId = String(msg.sessionId || "");
      const documentId = String(msg.documentId || "");
      const opType = String(msg.opType || "").trim();
      const payload = msg.payload || {};
      const clientOpId = msg.clientOpId ? String(msg.clientOpId) : null;

      if (!sessionId || !documentId || !opType) {
        sendWs(ws, { type: "error", error: "sessionId, documentId, opType required" });
        return;
      }
      const membership = ensureSessionMembership(sessionId, state.userId);
      if (!membership || membership.document_id !== documentId) {
        sendWs(ws, { type: "error", error: "No session membership" });
        return;
      }
      if (membership.session_role === "viewer") {
        sendWs(ws, { type: "error", error: "Viewer cannot append ops" });
        return;
      }

      try {
        const op = appendMarkupOp({
          documentId,
          sessionId,
          authorUserId: state.userId,
          opType,
          payload,
          clientOpId
        });
        broadcastDocumentOp(documentId, { type: "op_appended", documentId, op });
      } catch (error) {
        sendWs(ws, { type: "error", error: String(error.message || "append failed") });
      }
      return;
    }

    sendWs(ws, { type: "error", error: `Unsupported message type: ${msg.type}` });
  });

  ws.on("close", () => {
    untrackAll(ws);
  });

  ws.on("error", () => {
    untrackAll(ws);
  });
});

server.listen(config.port, () => {
  console.log(`Drawbridge backend listening on :${config.port}`);
  console.log(`DB path: ${config.dbPath}`);
  console.log(`Storage root: ${config.storageRoot}`);
});
