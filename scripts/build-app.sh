#!/usr/bin/env bash
# Builds OwnRecord.app into ./build.
#
#   scripts/build-app.sh            # release build
#   scripts/build-app.sh debug      # debug build
#   SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh
#
# Without SIGN_IDENTITY the app is ad-hoc signed with a bundle-ID designated requirement so
# macOS keeps the Screen Recording permission across rebuilds. Use a real identity for
# anything you distribute.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/OwnRecord.app"
ICONSET="$ROOT/build/AppIcon.iconset"
ICNS="$ROOT/build/AppIcon.icns"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/OwnRecord"

if [[ ! -f "$ICNS" || "$ROOT/scripts/make-icon.swift" -nt "$ICNS" ]]; then
    rm -rf "$ICONSET"
    swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
    iconutil -c icns "$ICONSET" -o "$ICNS"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OwnRecord"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
    # Ad-hoc signatures default to a hash-based requirement, which makes macOS forget the Screen
    # Recording permission on every rebuild. Pin the requirement to the bundle ID instead
    # (fine for local development builds).
    codesign --force --sign - --requirements '=designated => identifier "com.ownrecord.OwnRecord"' "$APP"
fi
echo "Built $APP"
