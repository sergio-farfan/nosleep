#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

ASSETS="assets"
MASTER="${ASSETS}/AppIcon.png"
ICONSET="${ASSETS}/AppIcon.iconset"

echo "==> Rendering artwork (app icon + DMG background)…"
swift scripts/generate-art.swift

echo "==> Building iconset from ${MASTER}…"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# gen <pixel-size> <iconset-filename>
gen() {
    sips -z "$1" "$1" "$MASTER" --out "${ICONSET}/$2" >/dev/null
}
# Intentionally NO 16x16 / 16x16@2x / 32x32 representations. On macOS 26+
# IconServices draws any legacy .icns that carries <=32 px reps shrunk on a grey
# "legacy" plate at 16/32 pt (Finder list/column view, Open panels, sidebar,
# Login Items). Without them it derives those sizes from the 64 px rep with no
# plate; macOS 14/15 simply downsample the 64 px rep as before.
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

echo "==> Converting to ${ASSETS}/AppIcon.icns…"
iconutil -c icns "$ICONSET" -o "${ASSETS}/AppIcon.icns"

rm -rf "$ICONSET"
echo "==> Done! Generated ${ASSETS}/AppIcon.icns and DMG background art."
