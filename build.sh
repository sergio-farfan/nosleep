#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="NoSleep"
APP_BUNDLE="${APP_NAME}.app"
BUNDLE_ID="com.nosleep.app"

echo "==> Building ${APP_NAME} (release)…"
swift build -c release

echo "==> Creating ${APP_BUNDLE}…"
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp ".build/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"

# Write Info.plist — LSUIElement hides Dock icon
cat > "${APP_BUNDLE}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>NoSleep</string>
    <key>CFBundleIdentifier</key>
    <string>com.nosleep.app</string>
    <key>CFBundleName</key>
    <string>NoSleep</string>
    <key>CFBundleDisplayName</key>
    <string>NoSleep</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing…"
codesign --force --sign - "$APP_BUNDLE"

echo "==> Done! Run with:  open ${APP_BUNDLE}"
