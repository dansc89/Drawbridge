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
  jwtSecret: process.env.JWT_SECRET || "dev-only-secret-change-me",
  dbPath: resolveFromBackend(process.env.DB_PATH, "./data/drawbridge.db"),
  storageRoot: resolveFromBackend(process.env.STORAGE_ROOT, "./storage"),
  maxUploadBytes: Number(process.env.MAX_UPLOAD_MB || 200) * 1024 * 1024,
  corsOrigin: process.env.CORS_ORIGIN || "*"
};

if (config.jwtSecret === "dev-only-secret-change-me" && config.nodeEnv !== "development") {
  throw new Error("JWT_SECRET must be set outside development");
}
