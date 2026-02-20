#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.drawbridge.nightly-stress.plist"

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.drawbridge.nightly-stress</string>
  <key>ProgramArguments</key>
  <array>
    <string>$ROOT_DIR/Scripts/nightly-stress-suite.sh</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$ROOT_DIR</string>
  <key>RunAtLoad</key>
  <false/>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>2</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>$ROOT_DIR/dist/stress/nightly/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$ROOT_DIR/dist/stress/nightly/launchd.err.log</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl load "$PLIST"
echo "Installed and loaded: $PLIST"

