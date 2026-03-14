#!/usr/bin/env bash
set -euo pipefail

PROFILE_NAME="${1:-drawbridge-notary}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

echo "Checking codesigning identities..."
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
echo "$IDENTITIES"

if ! grep -q "Developer ID Application:" <<<"$IDENTITIES"; then
  echo
  echo "Missing Developer ID Application identity."
  echo "Create or import a Developer ID Application certificate with its private key into:"
  echo "  $KEYCHAIN"
fi

echo
echo "Checking for common Apple signing certificates in login keychain..."
for name in "Developer ID Application" "Apple Distribution" "Apple Development"; do
  if [[ -n "$(security find-certificate -a -c "$name" "$KEYCHAIN" 2>/dev/null || true)" ]]; then
    echo "Found certificate(s): $name"
  else
    echo "No certificate found: $name"
  fi
done

echo
echo "Checking notary profile: $PROFILE_NAME"
if xcrun notarytool history --keychain-profile "$PROFILE_NAME" >/dev/null 2>&1; then
  echo "Notary profile is usable: $PROFILE_NAME"
else
  echo "Notary profile missing or invalid: $PROFILE_NAME"
  echo "Recreate it with:"
  echo "  ./Scripts/setup-notary-profile.sh $PROFILE_NAME <apple-id-email> <TEAMID> <app-specific-password>"
fi
