#!/usr/bin/env bash
# Builds QueueMaster.app from the Swift package.
#
#   ci/build-app.sh [version] [build-number]
#
# Output: build/QueueMaster.app (unsigned; ci/sign.sh signs it).
# Works the same on a dev Mac: ci/build-app.sh && open build/QueueMaster.app
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
BUILD="${2:-1}"
APP=build/QueueMaster.app

ARCH_ARGS=(--arch arm64)
[ "${UNIVERSAL:-0}" = "1" ] && ARCH_ARGS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCH_ARGS[@]}"
BIN_DIR=$(swift build -c release "${ARCH_ARGS[@]}" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/QueueMaster" "$APP/Contents/MacOS/QueueMaster"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon from the 1024px master.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "Built $APP ($VERSION build $BUILD)"
