#!/bin/bash
# Refreshes the Local Network TCC binding for VolumeKey by toggling its switch
# off then on in System Settings. macOS doesn't expose a programmatic way to
# do this, so we drive the UI via AppleScript GUI scripting.
#
# Requires: Terminal (or whatever runs this) to have Accessibility permission
# in System Settings → Privacy & Security → Accessibility.

set -e

echo "Quitting VolumeKey…"
pkill -f "VolumeKey.app/Contents/MacOS/VolumeKey" 2>/dev/null || true
sleep 0.5

echo "Opening Local Network settings…"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
sleep 2

echo "Toggling VolumeKey off then on…"
osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "System Settings"
        -- Find VolumeKey's switch and click it twice (off → on)
        set foundIt to false
        try
            -- The Local Network list is a scroll area with rows of checkboxes
            -- We hunt through descendants for the "VolumeKey" label.
            set allUI to entire contents of window 1
            repeat with element in allUI
                try
                    if (description of element) contains "VolumeKey" then
                        click element
                        delay 0.7
                        click element
                        set foundIt to true
                        exit repeat
                    end if
                end try
            end repeat
        end try
        if not foundIt then
            display dialog "Couldn't find VolumeKey toggle automatically. Please toggle it off then on manually, then close this dialog." buttons {"Done"} default button "Done"
        end if
    end tell
end tell
APPLESCRIPT

sleep 1
echo "Relaunching VolumeKey…"
open /Users/fmcomp/VolumeKey/VolumeKey.app
sleep 2

echo ""
echo "Verifying discovery worked:"
sleep 3
tail -20 /tmp/volumekey.log 2>/dev/null | grep -E "found|zone found" || echo "(no recent log entries)"
echo ""
echo "Done. Click the VolumeKey menu bar icon to see your zones."
