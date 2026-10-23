#!/usr/bin/env bash
# Signs QueueMaster.app and zips it.
#
# With the Developer ID secrets (MAC_CERTS_P12[_2], MAC_CERTS_PASSWORD) the
# app is signed with "Developer ID Application" + hardened runtime +
# timestamp, ready for notarize.sh. Without them it is ad-hoc signed, so
# builds keep working (Gatekeeper will ask on first open).
#
#   ci/sign.sh build/QueueMaster.app
set -euo pipefail
APP="$1"
OUT_ZIP="build/QueueMaster.zip"
APP_ID=""

if [ -n "${MAC_CERTS_P12:-}" ] && [ -n "${MAC_CERTS_PASSWORD:-}" ]; then
  KC="${RUNNER_TEMP:-/tmp}/qm-signing.keychain-db"; KCPW=$(openssl rand -hex 16)
  security delete-keychain "$KC" 2>/dev/null || true
  security create-keychain -p "$KCPW" "$KC"
  security set-keychain-settings -lut 21600 "$KC"
  security unlock-keychain -p "$KCPW" "$KC"
  i=0
  for v in "${MAC_CERTS_P12:-}" "${MAC_CERTS_P12_2:-}"; do
    [ -n "$v" ] || continue
    i=$((i+1)); P12="${RUNNER_TEMP:-/tmp}/qm-cert$i.p12"
    printf '%s' "$v" | base64 --decode > "$P12"
    security import "$P12" -k "$KC" -P "$MAC_CERTS_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    rm -f "$P12"
  done
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
  APP_ID=$(security find-identity -v -p codesigning "$KC" | awk -F'"' '/Developer ID Application/{print $2; exit}')
  echo "Application identity: ${APP_ID:-(none)}"
  [ -n "$APP_ID" ] || { echo "::error::No 'Developer ID Application' identity in MAC_CERTS_P12"; exit 1; }
  # The workflow's cleanup step removes this keychain (the runner is ours,
  # so nothing should be left behind).
  echo "keychain=$KC" >> "${GITHUB_OUTPUT:-/dev/null}"
fi

if [ -n "$APP_ID" ]; then
  codesign --force --options runtime --timestamp --entitlements ci/QueueMaster.entitlements --sign "$APP_ID" "$APP"
  codesign --verify --strict --deep --verbose=2 "$APP"
else
  echo "::warning::Developer ID secrets not set - ad-hoc signing (Gatekeeper prompts, no notarization)"
  codesign --force --sign - "$APP"
fi

rm -f "$OUT_ZIP"
ditto -c -k --keepParent "$APP" "$OUT_ZIP"
echo "signed=$([ -n "$APP_ID" ] && echo yes || echo no)" >> "${GITHUB_OUTPUT:-/dev/null}"
