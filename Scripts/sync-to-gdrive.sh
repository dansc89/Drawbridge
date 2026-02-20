#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${1:-$ROOT_DIR}"

DRIVE_PRIMARY="$HOME/Library/CloudStorage/GoogleDrive-dnguyen@aerocollective.com/My Drive"
DRIVE_FALLBACK="$HOME/Google Drive"

if [[ -d "$DRIVE_PRIMARY" ]]; then
  DRIVE_ROOT="$DRIVE_PRIMARY"
elif [[ -d "$DRIVE_FALLBACK" ]]; then
  DRIVE_ROOT="$DRIVE_FALLBACK"
else
  echo "Google Drive folder not found."
  echo "Checked:"
  echo "  $DRIVE_PRIMARY"
  echo "  $DRIVE_FALLBACK"
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
  "$SRC_DIR/" "$DST_DIR/"

echo "Done."
