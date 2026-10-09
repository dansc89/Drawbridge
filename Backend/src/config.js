import path from "node:path";
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";

dotenv.config();

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const backendRoot = path.resolve(__dirname, "..");

function resolveFromBackend(value, fallback) {
  const resolved = value || fallback;
  return path.isAbsolute(resolved)
    ? resolved
    : path.resolve(backendRoot, resolved);
}

export const config = {
  nodeEnv: process.env.NODE_ENV || "development",
  port: Number(process.env.PORT || 8787),
  host: process.env.HOST || "127.0.0.1",
  jwtSecret: process.env.JWT_SECRET || "",
  dbPath: resolveFromBackend(process.env.DB_PATH, "./data/drawbridge.db"),
  storageRoot: resolveFromBackend(process.env.STORAGE_ROOT, "./storage"),
  maxUploadBytes: Number(process.env.MAX_UPLOAD_MB || 200) * 1024 * 1024,
  corsOrigin: process.env.CORS_ORIGIN || "http://localhost:3000"
};

if (config.jwtSecret.length < 64 || /replace|change-me|dev-only/i.test(config.jwtSecret)) {
  throw new Error("JWT_SECRET must be a generated secret of at least 64 characters (openssl rand -hex 32)");
}
