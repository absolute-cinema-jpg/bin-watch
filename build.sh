#!/bin/bash
# Builds "Bin Watch.app" into ./build.   Usage: ./build.sh [install]
#   install  → also copies the app into /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Bin Watch.app"
TMP="build/tmp"
rm -rf "$APP" "$TMP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP"

echo "→ Compiling (Apple Silicon + Intel)…"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos13.0" Sources/*.swift -o "$TMP/BinWatch-$arch"
done
lipo -create "$TMP"/BinWatch-* -output "$APP/Contents/MacOS/BinWatch"

cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "→ Drawing app icon…"
  swift scripts/make-icon.swift "$TMP/icon.png"
  ICONSET="$TMP/AppIcon.iconset"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "→ Signing with read-only sandbox entitlements…"
codesign --force --sign - --options runtime --entitlements Resources/BinWatch.entitlements "$APP"
rm -rf "$TMP"

if [ "${1:-}" = "install" ]; then
  pkill -x BinWatch 2>/dev/null && sleep 1 || true
  rm -rf "/Applications/Bin Watch.app"
  cp -R "$APP" /Applications/
  echo "✓ Installed to /Applications/Bin Watch.app"
else
  echo "✓ Built $APP"
fi
