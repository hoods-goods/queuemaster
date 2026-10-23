#!/usr/bin/env bash
# Signs QueueMaster.app, builds QueueMaster-<version>.pkg and zips the app.
#
# With the Developer ID secrets (MAC_CERTS_P12[_2], MAC_CERTS_PASSWORD) the
# app is signed with "Developer ID Application" + hardened runtime +
# timestamp and the .pkg with "Developer ID Installer", ready for
# notarize.sh. Without them the app is ad-hoc signed and the .pkg unsigned,
# so builds keep working (Gatekeeper will ask, and the in-app updater won't
# install unsigned packages).
#
#   ci/sign.sh build/QueueMaster.app <version>
set -euo pipefail
APP="$1"; VERSION="$2"
PKG="build/QueueMaster-$VERSION.pkg"
ZIP="build/QueueMaster.zip"
APP_ID=""; INST_ID=""

if [ -n "${MAC_CERTS_P12:-}" ] && [ -n "${MAC_CERTS_PASSWORD:-}" ]; then
  KC="${RUNNER_TEMP:-/tmp}/qm-signing.keychain-db"; KCPW=$(openssl rand -hex 16)
  security delete-keychain "$KC" 2>/dev/null || true
  security create-keychain -p "$KCPW" "$KC"
  security set-keychain-settings -lut 21600 "$KC"
  security unlock-keychain -p "$KCPW" "$KC"
  # The workflow's cleanup step removes this keychain (the runner is ours).
  echo "keychain=$KC" >> "${GITHUB_OUTPUT:-/dev/null}"
  i=0
  for v in "${MAC_CERTS_P12:-}" "${MAC_CERTS_P12_2:-}"; do
    [ -n "$v" ] || continue
    i=$((i+1)); P12="${RUNNER_TEMP:-/tmp}/qm-cert$i.p12"
    printf '%s' "$v" | base64 --decode > "$P12"
    security import "$P12" -k "$KC" -P "$MAC_CERTS_PASSWORD" \
      -T /usr/bin/codesign -T /usr/bin/productsign -T /usr/bin/pkgbuild -T /usr/bin/security >/dev/null
    rm -f "$P12"
  done
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
  APP_ID=$(security find-identity -v -p codesigning "$KC" | awk -F'"' '/Developer ID Application/{print $2; exit}')
  INST_ID=$(security find-identity -v "$KC" | awk -F'"' '/Developer ID Installer/{print $2; exit}')
  echo "Application identity: ${APP_ID:-(none)}"
  echo "Installer identity:   ${INST_ID:-(none)}"
  [ -n "$APP_ID" ] || { echo "::error::No 'Developer ID Application' identity in MAC_CERTS_P12"; exit 1; }
  [ -n "$INST_ID" ] || echo "::warning::No 'Developer ID Installer' identity (MAC_CERTS_P12_2?) - the .pkg will be unsigned"
fi

# --- App ---
if [ -n "$APP_ID" ]; then
  codesign --force --options runtime --timestamp --entitlements ci/QueueMaster.entitlements --sign "$APP_ID" "$APP"
  codesign --verify --strict --deep --verbose=2 "$APP"
else
  echo "::warning::Developer ID secrets not set - ad-hoc signing (Gatekeeper prompts, no notarization)"
  codesign --force --sign - "$APP"
fi

# --- Installer package ---
# Installs to /Applications. BundleIsRelocatable=NO so an update always lands
# in /Applications even if someone moved an older copy elsewhere.
ROOT=build/pkg-root
rm -rf "$ROOT" && mkdir -p "$ROOT/Applications"
ditto "$APP" "$ROOT/Applications/QueueMaster.app"
pkgbuild --analyze --root "$ROOT" build/component.plist >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO build/component.plist
SIGN_ARGS=()
[ -n "$INST_ID" ] && SIGN_ARGS=(--sign "$INST_ID" --timestamp)
rm -f "$PKG"
pkgbuild --root "$ROOT" --component-plist build/component.plist \
  --identifier com.hgcellular.queuemaster --version "$VERSION" --install-location / \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$PKG"
[ -n "$INST_ID" ] && pkgutil --check-signature "$PKG" | head -5

# --- Zip (drag-to-Applications copy) ---
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "pkg=$PKG" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "signed=$([ -n "$APP_ID" ] && echo yes || echo no)" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "pkg_signed=$([ -n "$INST_ID" ] && echo yes || echo no)" >> "${GITHUB_OUTPUT:-/dev/null}"
