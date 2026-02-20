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
mkdir -p "$STAGING_DIR/.background"
swift Scripts/generate-dmg-background.swift "$STAGING_DIR/.background/background.png"
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

# Best-effort Finder styling for classic drag-to-install visuals.
osascript <<EOF >/dev/null 2>/dev/null || true
tell application "Finder"
  set dmgFolder to POSIX file "$MOUNT_DIR" as alias
  open dmgFolder
  delay 0.5
  set wnd to container window of dmgFolder
  try
    set current view of wnd to icon view
  end try
  try
    set toolbar visible of wnd to false
  end try
  try
    set statusbar visible of wnd to false
  end try
  try
    set bounds of wnd to {100, 100, 960, 620}
  end try
  set theViewOptions to the icon view options of wnd
  try
    set arrangement of theViewOptions to not arranged
  end try
  try
    set icon size of theViewOptions to 128
  end try
  try
    set text size of theViewOptions to 12
  end try
  try
    set background picture of theViewOptions to file ".background:background.png"
  end try
  try
    set position of item "$APP_BASENAME" of wnd to {220, 280}
  end try
  try
    set position of item "Applications" of wnd to {700, 280}
  end try
  update without registering applications
  delay 1
  close wnd
end tell
EOF

sync
hdiutil detach "$MOUNT_DIR" -force >/dev/null

hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$OUTPUT_DMG" >/dev/null

echo "Created DMG: $OUTPUT_DMG"
