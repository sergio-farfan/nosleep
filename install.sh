#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="NoSleep"
APP_BUNDLE="${SCRIPT_DIR}/${APP_NAME}.app"
DEST="$HOME/Applications/${APP_NAME}.app"
PLIST_PATH="$HOME/Library/LaunchAgents/com.nosleep.app.plist"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: ${APP_BUNDLE} not found. Run build.sh first."
    exit 1
fi

mkdir -p "$HOME/Applications"

echo "==> Installing ${APP_NAME}.app to ~/Applications…"
rm -rf "$DEST"
cp -R "$APP_BUNDLE" "$DEST"

# Update LaunchAgent plist if it exists (points to old path)
if [ -f "$PLIST_PATH" ]; then
    echo "==> Updating LaunchAgent plist to point to ~/Applications…"
    /usr/libexec/PlistBuddy -c \
        "Set :ProgramArguments:0 $HOME/Applications/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" \
        "$PLIST_PATH"
fi

echo "==> Done! Launch with:  open ~/Applications/${APP_NAME}.app"
