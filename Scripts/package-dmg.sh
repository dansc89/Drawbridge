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

TMP_DIR="$(mktemp -d)"
STAGING_DIR="$TMP_DIR/staging"
RW_DMG="$TMP_DIR/temp-rw.dmg"
MOUNT_DIR="$TMP_DIR/mnt"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR" "$MOUNT_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$OUTPUT_DMG"
mkdir -p "$(dirname "$OUTPUT_DMG")"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$RW_DMG" >/dev/null

hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse >/dev/null

# Style Finder window for the conventional drag-to-Applications install flow.
osascript <<EOF >/dev/null || true
tell application "Finder"
  set dmgFolder to POSIX file "$MOUNT_DIR" as alias
  open dmgFolder
  set current view of container window of dmgFolder to icon view
  set toolbar visible of container window of dmgFolder to false
  set statusbar visible of container window of dmgFolder to false
  set bounds of container window of dmgFolder to {120, 120, 720, 480}
  set theViewOptions to the icon view options of container window of dmgFolder
  set arrangement of theViewOptions to not arranged
  set icon size of theViewOptions to 128
  set text size of theViewOptions to 12
  set position of item "$APP_BASENAME" of container window of dmgFolder to {170, 190}
  set position of item "Applications" of container window of dmgFolder to {430, 190}
  close container window of dmgFolder
  open dmgFolder
  update without registering applications
  delay 1
end tell
EOF

sync
hdiutil detach "$MOUNT_DIR" >/dev/null

hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$OUTPUT_DMG" >/dev/null

echo "Created DMG: $OUTPUT_DMG"
