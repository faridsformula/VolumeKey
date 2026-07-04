#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="VolumeKey.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
# Generate the app icon (idempotent — only re-renders if .icns is missing)
if [ ! -f AppIcon.icns ]; then
    rm -rf AppIcon.iconset
    swift make-icon.swift AppIcon.iconset > /dev/null
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "Compiling…"
swiftc -O \
    -framework Cocoa -framework Carbon -framework CoreAudio \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/VolumeKey"

# Apple Development cert SHA1 — stable identity so TCC permissions (Local Network, Accessibility)
# persist across rebuilds. Falls back to ad-hoc if the cert isn't available.
SIGN_ID="CF603165B17B0380F8BD424BCC1CF7E25473E1E6"
codesign --force --deep --sign "$SIGN_ID" "$APP" \
    || codesign --force --deep --sign - "$APP"

echo "Built $APP"

# Automatically refresh Local Network permission for the new binary cdhash.
# (macOS silently invalidates Local Network on every binary change even when the
# UI shows it allowed; this drives System Settings to toggle off+on which rebinds.)
if [ "$1" != "--no-refresh" ]; then
    "$(dirname "$0")/refresh-permission.sh"
fi
