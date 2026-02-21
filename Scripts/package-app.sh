#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Drawbridge"
BUNDLE_ID="com.drawbridge.app"
BUILD_DIR=".build/arm64-apple-macosx/release"
BIN_PATH="$BUILD_DIR/$APP_NAME"
DIST_DIR="dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
ICONSET_DIR="Assets/AppIcon.iconset"
ICON_FILE_NAME="Drawbridge"
ICON_ICNS_PATH="$RESOURCES_DIR/$ICON_FILE_NAME.icns"
VERSION_TAG="${DRAWBRIDGE_VERSION_TAG:-$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")}"
APP_VERSION="${VERSION_TAG#v}"
if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  APP_VERSION="0.0.0"
fi
BUILD_NUMBER="${DRAWBRIDGE_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo "1")}"

echo "Building release binary..."
swift build -c release

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Expected binary not found at $BIN_PATH"
  exit 1
fi

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

echo "Generating app icon..."
if [[ ! -f "$ICONSET_DIR/icon_1024x1024.png" ]]; then
  swift Scripts/generate-icon.swift
fi
for sz in 16 32 64 128 256 512; do
  sips -z "$sz" "$sz" "$ICONSET_DIR/icon_1024x1024.png" --out "$ICONSET_DIR/icon_${sz}x${sz}.png" >/dev/null
done
cp "$ICONSET_DIR/icon_32x32.png" "$ICONSET_DIR/icon_16x16@2x.png"
cp "$ICONSET_DIR/icon_64x64.png" "$ICONSET_DIR/icon_32x32@2x.png"
cp "$ICONSET_DIR/icon_256x256.png" "$ICONSET_DIR/icon_128x128@2x.png"
cp "$ICONSET_DIR/icon_512x512.png" "$ICONSET_DIR/icon_256x256@2x.png"
cp "$ICONSET_DIR/icon_1024x1024.png" "$ICONSET_DIR/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS_PATH"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_FILE_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>PDF Document</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>pdf</string>
      </array>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.adobe.pdf</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
EOF

echo "Ad-hoc signing app bundle..."
codesign --force --deep --sign - "$APP_DIR"

# Automatically create a checkpoint for quick rollback.
CHECKPOINT_LABEL="${CHECKPOINT_LABEL:-}"
if [[ -n "$CHECKPOINT_LABEL" ]]; then
  ./Scripts/checkpoint.sh create "$CHECKPOINT_LABEL"
else
  ./Scripts/checkpoint.sh create "$VERSION_TAG"
fi

echo "Done: $APP_DIR"
echo "Launch with: open \"$APP_DIR\""
