#!/usr/bin/env bash
# Notarizes the QueueMaster installer with Apple's notary service (an
# automated scan, usually a few minutes), then staples the ticket to both the
# .pkg and the app inside build/, and re-zips the app.
# Needs NOTARY_KEY_P8 (base64 of the .p8, or the raw text), NOTARY_KEY_ID, NOTARY_ISSUER_ID.
#
#   ci/notarize.sh build/QueueMaster-<version>.pkg
set -euo pipefail
PKG="$1"
APP=build/QueueMaster.app
ZIP=build/QueueMaster.zip
KEY="${RUNNER_TEMP:-/tmp}/qm-notary.p8"
printf '%s' "$NOTARY_KEY_P8" | base64 --decode > "$KEY" 2>/dev/null || true
grep -q 'BEGIN PRIVATE KEY' "$KEY" || printf '%s\n' "$NOTARY_KEY_P8" > "$KEY"
trap 'rm -f "$KEY"' EXIT

# Notarizing the package also notarizes the app inside it.
OUT=$(xcrun notarytool submit "$PKG" --key "$KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
        --wait --timeout 45m --output-format json) || true
echo "$OUT"
ID=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
STATUS=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)
if [ "$STATUS" != "Accepted" ]; then
  echo "::error::Notarization status: ${STATUS:-unknown}"
  [ -n "$ID" ] && xcrun notarytool log "$ID" --key "$KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" || true
  exit 1
fi

# Apple sometimes takes a minute to publish the ticket after "Accepted".
staple() {
  for i in 1 2 3 4 5 6; do
    xcrun stapler staple "$1" && return 0
    echo "stapler attempt $i on $1 failed - retrying in 30s"; sleep 30
  done
  echo "::error::stapler failed for $1"; return 1
}
staple "$PKG"
staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type install -vv "$PKG" || true
spctl --assess --type execute -vv "$APP" || true
