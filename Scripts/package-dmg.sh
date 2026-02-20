#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <app_path> <output_dmg> [volume_name]"
  exit 1
fi

APP_PATH="$1"
OUTPUT_DMG="$2"
VOLUME_NAME="${3:-Drawbridge}"
APP_BASENAME="$(basename "$APP_PATH")"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH"
  exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "create-dmg is required. Install with: brew install create-dmg"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
STAGING_DIR="$TMP_DIR/staging"
BACKGROUND_PATH="$TMP_DIR/background.png"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
swift Scripts/generate-dmg-background.swift "$BACKGROUND_PATH"

rm -f "$OUTPUT_DMG"
mkdir -p "$(dirname "$OUTPUT_DMG")"

create-dmg \
  --volname "$VOLUME_NAME" \
  --window-pos 120 120 \
  --window-size 860 520 \
  --background "$BACKGROUND_PATH" \
  --icon-size 128 \
  --icon "$APP_BASENAME" 200 285 \
  --hide-extension "$APP_BASENAME" \
  --app-drop-link 650 285 \
  "$OUTPUT_DMG" \
  "$STAGING_DIR"

echo "Created DMG: $OUTPUT_DMG"
