#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${1:-$ROOT_DIR}"

# Explicit destination avoids embedding a developer's work account in source.
DRIVE_ROOT="${DRAWBRIDGE_SYNC_ROOT:-}"
if [[ -z "$DRIVE_ROOT" || ! -d "$DRIVE_ROOT" ]]; then
  echo "Set DRAWBRIDGE_SYNC_ROOT to an existing Google Drive destination folder."
  exit 1
fi

PROJECT_NAME="$(basename "$SRC_DIR")"
DST_DIR="$DRIVE_ROOT/$PROJECT_NAME"

DELETE_MODE=0
if [[ "${2:-}" == "--mirror" || "${SYNC_DELETE:-0}" == "1" ]]; then
  DELETE_MODE=1
fi

echo "Syncing:"
echo "  from: $SRC_DIR"
echo "    to: $DST_DIR"
if (( DELETE_MODE == 1 )); then
  echo "  mode: mirror (deletes files in destination that were removed in source)"
else
  echo "  mode: safe copy (no destination deletes)"
fi

mkdir -p "$DST_DIR"

RSYNC_FLAGS=(-a --progress --stats)
if (( DELETE_MODE == 1 )); then
  RSYNC_FLAGS+=(--delete)
fi

rsync "${RSYNC_FLAGS[@]}" \
  --exclude '.build/' \
  --exclude '.DS_Store' \
  --exclude '.git/' \
  --exclude '.env*' \
  --exclude '*.p12' \
  --exclude '*.p8' \
  --exclude '*.pem' \
  --exclude '*.key' \
  --exclude 'tmp/' \
  --exclude 'local-test/' \
  --exclude 'private-fixtures/' \
  --exclude 'verified-*/' \
  --exclude 'Backend/data/' \
  --exclude 'Backend/storage/' \
  "$SRC_DIR/" "$DST_DIR/"

echo "Done."
