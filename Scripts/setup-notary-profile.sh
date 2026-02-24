#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <profile_name> <apple_id> <team_id> <app_specific_password>"
  exit 1
fi

PROFILE_NAME="$1"
APPLE_ID="$2"
TEAM_ID="$3"
APP_PASSWORD="$4"

xcrun notarytool store-credentials "$PROFILE_NAME" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD"

echo "Stored notarization profile: $PROFILE_NAME"
