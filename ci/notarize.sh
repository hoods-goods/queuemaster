#!/usr/bin/env bash
# Notarizes QueueMaster.app with Apple's notary service (an automated scan,
# usually a few minutes), staples the ticket and re-zips.
# Needs NOTARY_KEY_P8 (base64 of the .p8, or the raw text), NOTARY_KEY_ID, NOTARY_ISSUER_ID.
set -euo pipefail
APP=build/QueueMaster.app
ZIP=build/QueueMaster.zip
KEY="${RUNNER_TEMP:-/tmp}/qm-notary.p8"
printf '%s' "$NOTARY_KEY_P8" | base64 --decode > "$KEY" 2>/dev/null || true
grep -q 'BEGIN PRIVATE KEY' "$KEY" || printf '%s\n' "$NOTARY_KEY_P8" > "$KEY"
trap 'rm -f "$KEY"' EXIT

OUT=$(xcrun notarytool submit "$ZIP" --key "$KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
        --wait --timeout 45m --output-format json) || true
echo "$OUT"
ID=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
STATUS=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)
if [ "$STATUS" != "Accepted" ]; then
  echo "::error::Notarization status: ${STATUS:-unknown}"
  [ -n "$ID" ] && xcrun notarytool log "$ID" --key "$KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" || true
  exit 1
fi
for i in 1 2 3 4 5 6; do
  xcrun stapler staple "$APP" && break
  [ "$i" = 6 ] && { echo "::error::stapler failed after retries"; exit 1; }
  echo "stapler attempt $i failed - retrying in 30s"; sleep 30
done
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute -vv "$APP" || true
