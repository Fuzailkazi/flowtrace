#!/usr/bin/env bash
# Builds FlowTrace.app from the Swift package.
#
# Requires the Command Line Tools only — no Xcode. Produces a normal .app bundle
# in ./dist plus the `flowtrace` CLI alongside it.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/FlowTrace.app"
BUNDLE_ID="ai.flowtrace.FlowTrace"
VERSION="0.1.0"

# Set FLOWTRACE_SIGN_IDENTITY to a Developer ID to produce a distributable
# build; without it the app is ad-hoc signed, which is fine on this machine but
# will be quarantined on anyone else's.
SIGN_IDENTITY="${FLOWTRACE_SIGN_IDENTITY:--}"

echo "▸ Building ($CONFIG)…"
cd "$ROOT"
swift build -c "$CONFIG" --product FlowTraceApp
swift build -c "$CONFIG" --product flowtrace

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/FlowTraceApp" "$APP/Contents/MacOS/FlowTrace"
cp "$BIN_DIR/flowtrace" "$DIST/flowtrace"

# Bundled resources produced by SwiftPM (if any target declares them).
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FlowTrace</string>
    <key>CFBundleDisplayName</key><string>FlowTrace</string>
    <key>CFBundleExecutable</key><string>FlowTrace</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSAppleEventsUsageDescription</key>
    <string>FlowTrace reads the titles and URLs of the tabs in your browser's front window, only when you ask it to capture them. It never reads page contents, cookies or form data.</string>
    <key>NSAppleScriptEnabled</key><false/>
</dict>
</plist>
PLIST

cat > "$APP/Contents/PkgInfo" <<< "APPL????"

echo "▸ Signing (identity: $SIGN_IDENTITY)…"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP" 2>/dev/null

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "  ad-hoc signed — macOS may re-ask for Automation permission after each rebuild"
fi

echo "✓ $APP"
echo "✓ $DIST/flowtrace"
