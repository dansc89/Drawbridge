#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <tag> [dmg_path]"
  echo "Example: $0 v0.1.23 dist/Drawbridge-v0.1.23.dmg"
  exit 1
fi

TAG="$1"
DMG_PATH="${2:-dist/Drawbridge-${TAG}.dmg}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH"
  exit 1
fi

if gh release view "$TAG" --repo "dansc89/Drawbridge" >/dev/null 2>&1; then
  echo "Release $TAG already exists. Uploading/replacing asset..."
  gh release upload "$TAG" "$DMG_PATH" --clobber --repo "dansc89/Drawbridge"
else
  echo "Creating release $TAG and uploading DMG..."
  gh release create "$TAG" "$DMG_PATH" --generate-notes --repo "dansc89/Drawbridge"
fi

echo "Done: https://github.com/dansc89/Drawbridge/releases/tag/$TAG"
