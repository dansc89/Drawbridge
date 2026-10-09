#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <profile_name> <apple_id> <team_id>"
  echo "notarytool prompts for the app-specific password and stores it in Keychain."
  exit 1
fi

xcrun notarytool store-credentials "$1" --apple-id "$2" --team-id "$3"
echo "Stored notarization profile: $1"
