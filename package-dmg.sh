#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="NoSleep"
APP_BUNDLE="${APP_NAME}.app"
VOL_NAME="NoSleep"

BACKGROUND="assets/dmg-background.png"
BACKGROUND2X="assets/dmg-background@2x.png"
ICON="assets/AppIcon.icns"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: ${APP_BUNDLE} not found. Run ./build.sh first."
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_BUNDLE}/Contents/Info.plist")"
DMG_FINAL="${APP_NAME}-${VERSION}.dmg"
DMG_TMP="${APP_NAME}-tmp.dmg"
MOUNT_DIR="/Volumes/${VOL_NAME}"

echo "==> Staging DMG contents…"
STAGING="$(mktemp -d)"
cleanup() {
    [ -d "$MOUNT_DIR" ] && hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    rm -rf "$STAGING"
}
trap cleanup EXIT INT TERM

cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$STAGING/.background"
[ -f "$BACKGROUND" ]   && cp "$BACKGROUND"   "$STAGING/.background/background.png"
[ -f "$BACKGROUND2X" ] && cp "$BACKGROUND2X" "$STAGING/.background/background@2x.png"
[ -f "$ICON" ]         && cp "$ICON"         "$STAGING/.VolumeIcon.icns"

echo "==> Creating writable image…"
rm -f "$DMG_TMP" "$DMG_FINAL"
SIZE_MB=$(( $(du -sm "$STAGING" | awk '{print $1}') + 20 )) # content + slack for .DS_Store/background
hdiutil create -srcfolder "$STAGING" -volname "$VOL_NAME" \
    -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$DMG_TMP" >/dev/null

echo "==> Mounting…"
hdiutil attach "$DMG_TMP" -readwrite -noverify -noautoopen >/dev/null
sleep 2

echo "==> Applying Finder layout (best effort — needs Automation → Finder permission)…"
apply_layout() {
    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${VOL_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "${APP_NAME}.app" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
}

# Run in the background with a timeout so packaging never hangs on a TCC prompt.
apply_layout & OSA_PID=$!
( sleep 45; kill "$OSA_PID" 2>/dev/null ) & WATCHER=$!
if wait "$OSA_PID" 2>/dev/null; then
    kill "$WATCHER" 2>/dev/null || true
    echo "    Layout applied."
else
    echo "    Warning: Finder layout not applied (Automation denied or timed out)."
    echo "    The DMG is still valid. Grant your terminal 'Automation → Finder' in"
    echo "    System Settings → Privacy & Security, then re-run for the styled window."
fi

# Volume icon (best effort — layout/background still work without it)
if [ -f "$STAGING/.VolumeIcon.icns" ] && command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$MOUNT_DIR" || true
fi

sync
echo "==> Detaching…"
hdiutil detach "$MOUNT_DIR" >/dev/null

echo "==> Converting to compressed image ${DMG_FINAL}…"
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" >/dev/null
rm -f "$DMG_TMP"

echo "==> Done! Created ${DMG_FINAL}"
