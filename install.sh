#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="NoSleep"
APP_BUNDLE="${SCRIPT_DIR}/${APP_NAME}.app"
DEST="$HOME/Applications/${APP_NAME}.app"
PLIST_PATH="$HOME/Library/LaunchAgents/com.nosleep.app.plist"
BUNDLE_ID="com.nosleep.app"
UID_="$(id -u)"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: ${APP_BUNDLE} not found. Run build.sh first."
    exit 1
fi

mkdir -p "$HOME/Applications"

# Quit any running instance first. Otherwise the old binary keeps running from
# the deleted bundle — with its own caffeinate child — next to the new copy.
# Capture each instance's caffeinate child BEFORE killing the app: builds ≤ 1.1.0
# did not tie the child to the app, so it would be reparented to launchd and
# keep the Mac awake. Never pkill caffeinate globally (other tools use it).
# `pgrep -x NoSleep` matches on process name only, which would also hit the
# unrelated third-party NoSleep.app or a developer's bare .build/debug/NoSleep;
# keep only processes whose bundle identifier is ours.
our_pids() {
    local pid comm bundle bid
    for pid in $(pgrep -u "$UID_" -x "$APP_NAME" || true); do
        comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
        bundle="${comm%/Contents/MacOS/*}"
        [ "$bundle" != "$comm" ] || continue        # bare binary, not an .app
        bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null || true)"
        [ "$bid" = "$BUNDLE_ID" ] || continue
        echo "$pid"
    done
}

WAS_RUNNING=0
for pid in $(our_pids); do
    WAS_RUNNING=1
    kids="$(pgrep -P "$pid" -x caffeinate || true)"
    echo "==> Quitting running ${APP_NAME} (pid ${pid})…"
    kill "$pid" 2>/dev/null || true
    for kid in $kids; do kill "$kid" 2>/dev/null || true; done
done
if [ "$WAS_RUNNING" = 1 ]; then
    for _ in $(seq 1 20); do
        [ -n "$(our_pids)" ] || break
        sleep 0.25
    done
    for pid in $(our_pids); do kill -9 "$pid" 2>/dev/null || true; done
fi

echo "==> Installing ${APP_NAME}.app to ~/Applications…"
rm -rf "$DEST"
cp -R "$APP_BUNDLE" "$DEST"

# Legacy (≤ 1.1.0) LaunchAgent: point it at the installed copy so the next login
# starts the right binary. Newer builds delete this plist on first launch and
# manage Start at Login through SMAppService instead.
if [ -f "$PLIST_PATH" ]; then
    echo "==> Updating legacy LaunchAgent plist to point to ~/Applications…"
    /usr/libexec/PlistBuddy -c \
        "Set :ProgramArguments:0 $HOME/Applications/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" \
        "$PLIST_PATH"
fi

if [ "$WAS_RUNNING" = 1 ]; then
    echo "==> Relaunching ${APP_NAME} from ~/Applications…"
    open "$DEST"
else
    echo "==> Done! Launch with:  open ~/Applications/${APP_NAME}.app"
fi
