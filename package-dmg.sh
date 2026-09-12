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

# A volume with our name already mounted (an opened NoSleep DMG, or a leftover
# temp image from an aborted run) would make hdiutil mount the new image at
# "/Volumes/NoSleep 1" while every later step — the AppleScript, SetFile and the
# detach — targets /Volumes/NoSleep, i.e. the WRONG disk. Refuse up front.
if [ -e "$MOUNT_DIR" ]; then
    echo "Error: a volume named '${VOL_NAME}' is already mounted at ${MOUNT_DIR}." >&2
    echo "       Eject it first:  hdiutil detach \"${MOUNT_DIR}\"   then re-run." >&2
    exit 1
fi

echo "==> Staging DMG contents…"
STAGING="$(mktemp -d)"
DEV_NODE=""   # set once the temp image is attached; cleanup detaches by node
OSA_PID=""    # Finder-layout osascript, while it runs
WATCHER=""    # its 45 s watchdog subshell, while it runs

# Detach with retries. Finder / QuickLook / Spotlight often keep a fresh volume
# open for a few seconds after the layout step and hdiutil then exits 16
# (EBUSY, see hdiutil(1) COMMON ERRORS). Retry only on EBUSY; any other error
# fails fast with hdiutil's own message.
detach_volume() {  # $1 = /dev node or mount point
    local attempt rc err
    for attempt in 1 2 3 4 5; do
        rc=0
        # Capture the status of THIS command. (`if cmd; then …; fi; rc=$?` would
        # always read 0: the status of a completed `if` with no branch taken.)
        err="$(hdiutil detach "$1" 2>&1 >/dev/null)" || rc=$?
        if [ "$rc" -eq 0 ]; then
            return 0
        fi
        if [ "$rc" -ne 16 ]; then     # not EBUSY: fail fast with hdiutil's own message
            echo "$err" >&2
            return "$rc"
        fi
        echo "    Volume busy, retrying detach ($attempt/5)…"
        sleep "$attempt"
    done
    echo "    Warning: $1 still busy after retries; forcing eject." >&2
    hdiutil detach -force "$1" >/dev/null 2>&1
}

cleanup() {
    # Background jobs ignore SIGINT, so on Ctrl-C they would outlive the script:
    # osascript keeping the volume open, the watchdog's sleep holding stdout.
    if [ -n "$WATCHER" ]; then
        pkill -P "$WATCHER" 2>/dev/null || true
        kill "$WATCHER" 2>/dev/null || true
    fi
    if [ -n "$OSA_PID" ]; then
        kill "$OSA_PID" 2>/dev/null || true
    fi
    OSA_PID=""; WATCHER=""
    if [ -n "$DEV_NODE" ]; then
        detach_volume "$DEV_NODE" \
            || echo "Warning: ${DEV_NODE} is still attached; run: hdiutil detach -force '${DEV_NODE}'" >&2
        DEV_NODE=""
    fi
    rm -rf "$STAGING"
}
# Run cleanup exactly once, from the EXIT trap. A plain `trap cleanup INT` would
# run the handler and then let the script CONTINUE after the interrupted
# command; exiting explicitly here routes Ctrl-C / TERM through EXIT instead.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$STAGING/.background"
# Finder accepts exactly one background picture, so a separate @2x PNG is never
# used. Fold both renders into one multi-resolution TIFF; Finder picks the 2x
# page on Retina displays.
BG_FILE=""
if [ -f "$BACKGROUND" ] && [ -f "$BACKGROUND2X" ]; then
    tiffutil -cathidpicheck "$BACKGROUND" "$BACKGROUND2X" \
        -out "$STAGING/.background/background.tiff" >/dev/null
    BG_FILE="background.tiff"
elif [ -f "$BACKGROUND" ]; then
    cp "$BACKGROUND" "$STAGING/.background/background.png"
    BG_FILE="background.png"
fi
# (The volume icon is added AFTER the Finder layout step below: Finder deletes
# a root .VolumeIcon.icns and rewrites the root FinderInfo while it lays out
# the window, so anything placed here would not survive.)
# Keep the build machine's file-system event log out of the shipped image.
mkdir -p "$STAGING/.fseventsd" && touch "$STAGING/.fseventsd/no_log"

echo "==> Creating writable image…"
rm -f "$DMG_TMP" "$DMG_FINAL"
SIZE_MB=$(( $(du -sm "$STAGING" | awk '{print $1}') + 20 )) # content + slack for .DS_Store/background
hdiutil create -srcfolder "$STAGING" -volname "$VOL_NAME" \
    -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$DMG_TMP" >/dev/null

echo "==> Mounting…"
# Capture where the image REALLY landed instead of assuming /Volumes/<name>.
# Only stdout is parsed, so hdiutil's deprecation warnings on stderr are inert.
ATTACH_OUT="$(hdiutil attach "$DMG_TMP" -readwrite -noverify -noautoopen)"
DEV_NODE="$(printf '%s\n' "$ATTACH_OUT" | awk '/^\/dev\//{print $1; exit}')"   # whole-disk node, e.g. /dev/disk4
ACTUAL_MOUNT="$(printf '%s\n' "$ATTACH_OUT" | grep -o '/Volumes/.*' | head -n1 || true)"
if [ -z "$DEV_NODE" ] || [ "$ACTUAL_MOUNT" != "$MOUNT_DIR" ]; then
    echo "Error: image attached as '${DEV_NODE:-?}' at '${ACTUAL_MOUNT:-<none>}', expected ${MOUNT_DIR}." >&2
    exit 1   # EXIT trap detaches DEV_NODE
fi
sleep 2   # give Finder a moment to register the new disk before scripting it

echo "==> Applying Finder layout (best effort — needs Automation → Finder permission)…"
BG_LINE=""
if [ -n "$BG_FILE" ]; then
    BG_LINE="set background picture of theViewOptions to file \".background:${BG_FILE}\""
fi
LAYOUT_SCRIPT="$STAGING/layout.applescript"
cat > "$LAYOUT_SCRIPT" <<APPLESCRIPT
tell application "Finder"
    tell disk "${VOL_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- 600x428 window so the CONTENT area (below the ~28 px title bar) is
        -- 600x400, the size of the background image.
        set the bounds of container window to {200, 120, 800, 548}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        ${BG_LINE}
        set position of item "${APP_NAME}.app" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Run osascript itself in the background (not a wrapper function/subshell) so
# $! is the pid the watchdog needs to kill; packaging must never hang on a TCC
# prompt.
osascript "$LAYOUT_SCRIPT" & OSA_PID=$!
# The subshell's stderr is discarded so bash does not print a "Terminated: 15
# sleep 45" job notice when the watchdog is stopped below.
( sleep 45; kill "$OSA_PID" 2>/dev/null ) 2>/dev/null & WATCHER=$!
if wait "$OSA_PID" 2>/dev/null; then
    echo "    Layout applied."
else
    echo "    Warning: Finder layout not applied (Automation denied or timed out)."
    echo "    The DMG is still valid. Grant your terminal 'Automation → Finder' in"
    echo "    System Settings → Privacy & Security, then re-run for the styled window."
fi
# Stop the watchdog AND its sleep, so no orphan keeps stdout open for 45 s.
pkill -P "$WATCHER" 2>/dev/null || true
kill "$WATCHER" 2>/dev/null || true
OSA_PID=""; WATCHER=""

# Volume icon (best effort — layout/background still work without it). Must
# come after the Finder step, which removes a pre-existing .VolumeIcon.icns and
# resets the root FinderInfo (verified on macOS 27). Set the kHasCustomIcon flag
# by writing FinderInfo directly; SetFile is deprecated and missing without full
# Xcode, and this is exactly what it wrote.
if [ -f "$ICON" ]; then
    if cp "$ICON" "$MOUNT_DIR/.VolumeIcon.icns" \
        && xattr -wx com.apple.FinderInfo \
            0000000000000000040000000000000000000000000000000000000000000000 "$MOUNT_DIR"; then
        echo "    Volume icon set."
    else
        echo "    Warning: could not set the volume icon." >&2
    fi
fi

sync
echo "==> Detaching…"
detach_volume "$DEV_NODE"
DEV_NODE=""   # disarm cleanup so it cannot detach a reused disk number later

echo "==> Converting to compressed image ${DMG_FINAL}…"
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" >/dev/null
rm -f "$DMG_TMP"

echo "==> Done! Created ${DMG_FINAL}"
