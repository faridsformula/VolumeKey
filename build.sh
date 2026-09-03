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
cp knob.png "$APP/Contents/Resources/knob.png"

echo "Compiling…"
swiftc -O \
    -framework Cocoa -framework Carbon -framework CoreAudio \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/VolumeKey"

# Prefer a named Apple Development identity so TCC (Accessibility, Local Network)
# can persist across rebuilds. SHA1 hash is a fallback; ad-hoc is last resort.
SIGN_ID="CF603165B17B0380F8BD424BCC1CF7E25473E1E6"
codesign --force --deep --sign "Apple Development" "$APP" 2>/dev/null \
    || codesign --force --deep --sign "$SIGN_ID" "$APP" 2>/dev/null \
    || codesign --force --deep --sign - "$APP"

echo "Built $APP"

# Permission repair is intentionally manual. Automated privacy-pane deep links,
# TCC resets, and GUI scripting can wedge System Settings, especially when an
# ad-hoc rebuild changes the app's code identity. Building never opens or drives
# System Settings.
