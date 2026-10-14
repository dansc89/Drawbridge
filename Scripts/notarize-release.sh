#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <app_path> [dmg_path]"
  exit 1
fi

APP_PATH="$1"
DMG_PATH="${2:-}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH"
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required"
  exit 1
fi

NOTARY_PROFILE="${DRAWBRIDGE_NOTARY_PROFILE:-}"
APPLE_ID="${DRAWBRIDGE_NOTARY_APPLE_ID:-}"
TEAM_ID="${DRAWBRIDGE_NOTARY_TEAM_ID:-}"
APP_PASSWORD="${DRAWBRIDGE_NOTARY_APP_PASSWORD:-}"

NOTARY_ARGS=()
if [[ -n "$NOTARY_PROFILE" ]]; then
  NOTARY_ARGS+=(--keychain-profile "$NOTARY_PROFILE")
else
  if [[ -z "$APPLE_ID" || -z "$TEAM_ID" || -z "$APP_PASSWORD" ]]; then
    echo "Set DRAWBRIDGE_NOTARY_PROFILE or all of DRAWBRIDGE_NOTARY_APPLE_ID / DRAWBRIDGE_NOTARY_TEAM_ID / DRAWBRIDGE_NOTARY_APP_PASSWORD"
    exit 1
  fi
  NOTARY_ARGS+=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

APP_ZIP="$TMP_DIR/$(basename "$APP_PATH").zip"

echo "Preparing app zip for notarization..."
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"

echo "Submitting app for notarization..."
xcrun notarytool submit "$APP_ZIP" "${NOTARY_ARGS[@]}" --wait

ticket_operation_with_retry() {
  local operation="$1"
  local target="$2"
  local attempt
  for attempt in 1 2 3 4 5; do
    if xcrun stapler "$operation" "$target"; then
      return 0
    fi
    if [[ "$attempt" -lt 5 ]]; then
      echo "Ticket $operation failed; retrying in 10 seconds ($attempt/5)..."
      sleep 10
    fi
  done
  return 1
}

echo "Stapling app ticket..."
ticket_operation_with_retry staple "$APP_PATH"

echo "Validating app ticket..."
ticket_operation_with_retry validate "$APP_PATH"

if [[ -n "$DMG_PATH" ]]; then
  if [[ ! -f "$DMG_PATH" ]]; then
    echo "DMG not found: $DMG_PATH"
    exit 1
  fi
  echo "Submitting DMG for notarization..."
  xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait

  echo "Stapling DMG ticket..."
  ticket_operation_with_retry staple "$DMG_PATH"

  echo "Validating DMG ticket..."
  ticket_operation_with_retry validate "$DMG_PATH"
fi

echo "Notarization complete."
