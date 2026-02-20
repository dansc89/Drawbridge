#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CHECKPOINTS_DIR="dist/checkpoints"
APPS_DIR="$CHECKPOINTS_DIR/apps"
SRC_DIR="$CHECKPOINTS_DIR/src"
LATEST_APP="$CHECKPOINTS_DIR/latest.app"
LATEST_NAME_FILE="$CHECKPOINTS_DIR/latest.txt"
DEFAULT_APP_PATH="dist/Drawbridge.app"
KEEP_COUNT="${DRAWBRIDGE_CHECKPOINT_KEEP:-30}"

usage() {
  cat <<EOF
Usage:
  ./Scripts/checkpoint.sh create [label]
  ./Scripts/checkpoint.sh list
  ./Scripts/checkpoint.sh restore <checkpoint-name>
  ./Scripts/checkpoint.sh restore-source <checkpoint-name>

Examples:
  ./Scripts/checkpoint.sh create "stable-zoom-fix"
  ./Scripts/checkpoint.sh list
  ./Scripts/checkpoint.sh restore 20260220-103422-stable-zoom-fix
EOF
}

slugify() {
  local raw="$1"
  raw="$(echo "$raw" | tr '[:upper:]' '[:lower:]')"
  raw="$(echo "$raw" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  echo "$raw"
}

timestamp_id() {
  date "+%Y%m%d-%H%M%S"
}

ensure_dirs() {
  mkdir -p "$CHECKPOINTS_DIR" "$APPS_DIR" "$SRC_DIR"
}

prune_old_checkpoints() {
  local entries
  entries="$(ls -1 "$APPS_DIR" 2>/dev/null | sed -E 's/\.app$//' | sort || true)"
  local count
  count="$(echo "$entries" | sed '/^$/d' | wc -l | tr -d ' ')"
  if (( count <= KEEP_COUNT )); then
    return
  fi
  local to_remove=$((count - KEEP_COUNT))
  local i=0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if (( i >= to_remove )); then
      break
    fi
    rm -rf "$APPS_DIR/$name.app"
    rm -f "$SRC_DIR/$name.tar.gz"
    i=$((i + 1))
  done <<< "$entries"
}

create_checkpoint() {
  local label="${1:-}"
  local slug=""
  if [[ -n "$label" ]]; then
    slug="$(slugify "$label")"
  fi

  local id
  id="$(timestamp_id)"
  local name="$id"
  if [[ -n "$slug" ]]; then
    name="$name-$slug"
  fi

  if [[ ! -d "$DEFAULT_APP_PATH" ]]; then
    echo "App bundle not found: $DEFAULT_APP_PATH"
    echo "Build/package first: ./Scripts/package-app.sh"
    exit 1
  fi

  ensure_dirs

  local app_target="$APPS_DIR/$name.app"
  echo "Creating app checkpoint: $app_target"
  cp -R "$DEFAULT_APP_PATH" "$app_target"

  rm -rf "$LATEST_APP"
  cp -R "$app_target" "$LATEST_APP"
  echo "$name" > "$LATEST_NAME_FILE"

  # Lightweight source snapshot for true rollback of code state.
  local src_target="$SRC_DIR/$name.tar.gz"
  echo "Creating source snapshot: $src_target"
  tar -czf "$src_target" \
    --exclude='.build' \
    --exclude='dist' \
    Package.swift README.md Sources Scripts Assets

  prune_old_checkpoints
  echo "Checkpoint created: $name"
}

list_checkpoints() {
  ensure_dirs
  echo "Available checkpoints:"
  local entries
  entries="$(ls -1 "$APPS_DIR" 2>/dev/null | sed -E 's/\.app$//' | sort || true)"
  if [[ -z "$(echo "$entries" | sed '/^$/d')" ]]; then
    echo "  (none)"
    return
  fi
  local latest_name=""
  if [[ -f "$LATEST_NAME_FILE" ]]; then
    latest_name="$(cat "$LATEST_NAME_FILE")"
  fi
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local marker=" "
    if [[ "$name" == "$latest_name" ]]; then
      marker="*"
    fi
    echo "  $marker $name"
  done <<< "$entries"
}

restore_checkpoint() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "Missing checkpoint name."
    usage
    exit 1
  fi
  local app_source="$APPS_DIR/$name.app"
  if [[ ! -d "$app_source" ]]; then
    echo "Checkpoint not found: $name"
    exit 1
  fi

  echo "Restoring app checkpoint: $name"
  rm -rf "$DEFAULT_APP_PATH" "$LATEST_APP"
  cp -R "$app_source" "$DEFAULT_APP_PATH"
  cp -R "$app_source" "$LATEST_APP"
  echo "$name" > "$LATEST_NAME_FILE"
  echo "Restored to:"
  echo "  $DEFAULT_APP_PATH"
}

restore_source() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "Missing checkpoint name."
    usage
    exit 1
  fi
  local src_archive="$SRC_DIR/$name.tar.gz"
  if [[ ! -f "$src_archive" ]]; then
    echo "Source snapshot not found: $name"
    exit 1
  fi

  echo "Restoring source snapshot: $name"
  rm -rf Sources Scripts Assets Package.swift README.md
  tar -xzf "$src_archive"
  echo "Source restored from $src_archive"
}

main() {
  local command="${1:-}"
  case "$command" in
    create)
      shift || true
      create_checkpoint "${1:-}"
      ;;
    list)
      list_checkpoints
      ;;
    restore)
      shift || true
      restore_checkpoint "${1:-}"
      ;;
    restore-source)
      shift || true
      restore_source "${1:-}"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
