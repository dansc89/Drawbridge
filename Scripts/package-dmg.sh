#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <app_path> <output_dmg> [volume_name]"
  exit 1
fi

APP_PATH="$1"
OUTPUT_DMG="$2"
VOLUME_NAME="${3:-Drawbridge}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cp -R "$APP_PATH" "$TMP_DIR/"
rm -f "$OUTPUT_DMG"
mkdir -p "$(dirname "$OUTPUT_DMG")"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$TMP_DIR" \
  -ov \
  -format UDZO \
  "$OUTPUT_DMG"

echo "Created DMG: $OUTPUT_DMG"
