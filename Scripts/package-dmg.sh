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
STAGING_DIR="$TMP_DIR/staging"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
cat > "$STAGING_DIR/Drag Drawbridge to Applications.txt" <<TXT
Install Drawbridge:
1) Drag Drawbridge.app to Applications
2) Open Drawbridge from Applications
TXT
rm -f "$OUTPUT_DMG"
mkdir -p "$(dirname "$OUTPUT_DMG")"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$OUTPUT_DMG" >/dev/null

echo "Created DMG: $OUTPUT_DMG"
