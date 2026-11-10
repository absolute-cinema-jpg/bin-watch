#!/bin/bash
# Builds "Bin Watch.app" into ./build.   Usage: ./build.sh [install]
#   install  → also copies the app into /Applications
# For the updater's end-to-end test only: BUNDLE_ID and VERSION override the Info.plist values.
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
[ -n "${BUNDLE_ID:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
[ -n "${VERSION:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")

echo "→ Compiling the updater helper…"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" Sources/Updater/*.swift Sources/UpdateShared.swift -o "$TMP/Updater-$arch"
done
XPC="$APP/Contents/XPCServices/Updater.xpc"
mkdir -p "$XPC/Contents/MacOS"
lipo -create "$TMP"/Updater-* -output "$XPC/Contents/MacOS/Updater"
PLIST="$XPC/Contents/Info.plist"
plutil -create xml1 "$PLIST"
plutil -insert CFBundleIdentifier -string "$ID.Updater" "$PLIST"
plutil -insert CFBundleName -string "Bin Watch Updater" "$PLIST"
plutil -insert CFBundleExecutable -string Updater "$PLIST"
plutil -insert CFBundlePackageType -string 'XPC!' "$PLIST"
plutil -insert CFBundleShortVersionString -string "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")" "$PLIST"
plutil -insert LSMinimumSystemVersion -string 13.0 "$PLIST"
plutil -insert XPCService -xml '<dict><key>ServiceType</key><string>Application</string></dict>' "$PLIST"

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
# The helper is signed without the App Sandbox: it applies its own, stricter limits when it
# starts (see Sources/Updater/main.swift). The app is signed last, sealing the helper inside it.
codesign --force --sign - --options runtime "$XPC"
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
