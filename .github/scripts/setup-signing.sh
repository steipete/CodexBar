#!/bin/bash
set -euo pipefail
set +x
umask 077
: "${MACOS_SIGNING_P12:?Missing MACOS_SIGNING_P12}"
: "${MACOS_SIGNING_P12_PASSWORD:?Missing MACOS_SIGNING_P12_PASSWORD}"
keychain="$RUNNER_TEMP/release.keychain-db"
password=$(openssl rand -hex 32)
printf '%s' "$MACOS_SIGNING_P12" | base64 --decode > "$RUNNER_TEMP/signing.p12"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$RUNNER_TEMP/signing.p12" -k "$keychain" -P "$MACOS_SIGNING_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user > "$RUNNER_TEMP/original-keychains"
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
security find-identity -v -p codesigning "$keychain" | grep -F 'Developer ID Application: Peter Steinberger (Y5PE65HELJ)'
rm "$RUNNER_TEMP/signing.p12"
