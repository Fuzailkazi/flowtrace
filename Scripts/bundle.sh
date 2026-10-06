#!/usr/bin/env bash
# Builds FlowTrace.app from the Swift package.
#
# Requires the Command Line Tools only — no Xcode. Produces a normal .app bundle
# in ./dist plus the `flowtrace` CLI alongside it.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${FLOWTRACE_DIST_DIR:-$ROOT/dist}"
APP="$DIST/FlowTrace.app"
BUNDLE_ID="ai.flowtrace.FlowTrace"
VERSION="${FLOWTRACE_VERSION:-0.1.0}"
BUILD_NUMBER="${FLOWTRACE_BUILD_NUMBER:-1}"

# These values are embedded in XML and used in an archive filename. Reject
# unsafe or invalid input before building or replacing an existing bundle.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "FLOWTRACE_VERSION must be a numeric version such as 0.1.1." >&2
    exit 2
fi
if ! [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "FLOWTRACE_BUILD_NUMBER must be a positive integer." >&2
    exit 2
fi
if [ "$CONFIG" = "debug" ]; then
    BUNDLE_ID="${FLOWTRACE_DEV_BUNDLE_ID:-$BUNDLE_ID}"
    if ! [[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
        echo "FLOWTRACE_DEV_BUNDLE_ID must be a dotted bundle identifier." >&2
        exit 2
    fi
    if [ -n "${FLOWTRACE_DEV_SUPPORT_DIR:-}" ] &&
       { [ "${FLOWTRACE_DEV_SUPPORT_DIR:0:1}" != "/" ] || [ "$FLOWTRACE_DEV_SUPPORT_DIR" = "/" ]; }; then
        echo "FLOWTRACE_DEV_SUPPORT_DIR must be an absolute directory other than /." >&2
        exit 2
    fi
fi

# Set FLOWTRACE_SIGN_IDENTITY to a Developer ID for a build eligible for
# notarization. Signing alone is not the finished public distribution step.
SIGN_IDENTITY="${FLOWTRACE_SIGN_IDENTITY:--}"

echo "▸ Building ($CONFIG)…"
cd "$ROOT"
swift build -c "$CONFIG" --product FlowTraceApp
swift build -c "$CONFIG" --product flowtrace

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Assembling bundle…"
mkdir -p "$DIST"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/FlowTraceApp" "$APP/Contents/MacOS/FlowTrace"
cp "$BIN_DIR/flowtrace" "$DIST/flowtrace"

# Bundled resources produced by SwiftPM (if any target declares them).
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FlowTrace</string>
    <key>CFBundleDisplayName</key><string>FlowTrace</string>
    <key>CFBundleExecutable</key><string>FlowTrace</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSAppleEventsUsageDescription</key>
    <string>After you connect a browser, FlowTrace reads tab titles and URLs in its front window to show what you were reading. It never reads page contents, cookies or form data.</string>
    <key>NSAppleScriptEnabled</key><false/>
</dict>
</plist>
PLIST

if [ "$CONFIG" = "debug" ] && [ -n "${FLOWTRACE_DEV_SUPPORT_DIR:-}" ]; then
    plutil -insert FlowTraceDevSupportDirectory -string "$FLOWTRACE_DEV_SUPPORT_DIR" \
        "$APP/Contents/Info.plist"
fi

cat > "$APP/Contents/PkgInfo" <<< "APPL????"

echo "▸ Signing (identity: $SIGN_IDENTITY)…"
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - --timestamp=none "$APP" 2>/dev/null
    echo "  ad-hoc signed — macOS may re-ask for Automation permission after each rebuild"
else
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
    echo "  Developer ID signed — notarize the release archive before public distribution"
fi

echo "▸ Verifying bundle…"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
test -s "$APP/Contents/Resources/AppIcon.icns"

echo "✓ $APP"
echo "✓ $DIST/flowtrace"

if [ "$CONFIG" = "release" ]; then
    ARCHIVE_NAME="FlowTrace-$VERSION-macOS.zip"
    if [ "$BUILD_NUMBER" != "1" ]; then
        ARCHIVE_NAME="FlowTrace-$VERSION-build$BUILD_NUMBER-macOS.zip"
    fi
    ARCHIVE="$DIST/$ARCHIVE_NAME"
    rm -f "$ARCHIVE"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
    echo "✓ $ARCHIVE"
fi
