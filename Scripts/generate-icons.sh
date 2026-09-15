#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Resources/AppIcon-1024.png"
ICONSET="$ROOT/Resources/AppIcon.iconset"
DIST="$ROOT/dist"

if [ ! -f "$SRC" ]; then
    echo "Error: $SRC not found"
    exit 1
fi

echo "▸ Preparing iconset directory…"
rm -rf "$ICONSET"
mkdir -p "$ICONSET" "$ROOT/Extension/icons"

# Convert and resize to standard Apple Icon sizes
sips -s format png "$SRC" --out "$ICONSET/icon_base.png" >/dev/null

sips -z 16 16     "$ICONSET/icon_base.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$ICONSET/icon_base.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$ICONSET/icon_base.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$ICONSET/icon_base.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$ICONSET/icon_base.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$ICONSET/icon_base.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ICONSET/icon_base.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$ICONSET/icon_base.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$ICONSET/icon_base.png" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICONSET/icon_base.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

rm -f "$ICONSET/icon_base.png"

echo "▸ Compiling AppIcon.icns via iconutil…"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "▸ Generating Chrome/Brave Extension icons…"
sips -z 16 16   "$SRC" --out "$ROOT/Extension/icons/icon16.png" >/dev/null
sips -z 32 32   "$SRC" --out "$ROOT/Extension/icons/icon32.png" >/dev/null
sips -z 48 48   "$SRC" --out "$ROOT/Extension/icons/icon48.png" >/dev/null
sips -z 128 128 "$SRC" --out "$ROOT/Extension/icons/icon128.png" >/dev/null

echo "✓ Successfully generated Resources/AppIcon.icns and Extension/icons/"
