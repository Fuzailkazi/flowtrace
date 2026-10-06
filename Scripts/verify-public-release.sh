#!/usr/bin/env bash
# Check the exact ZIP that will be shared with macOS users.
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    echo "Usage: $0 path/to/FlowTrace-<version>-macOS.zip" >&2
    exit 2
fi

ARCHIVE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/flowtrace-release-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

ditto -x -k "$ARCHIVE" "$CHECK_DIR"
APP="$CHECK_DIR/FlowTrace.app"
if [ ! -d "$APP" ]; then
    echo "Release ZIP must contain FlowTrace.app at its top level." >&2
    exit 1
fi

plutil -lint "$APP/Contents/Info.plist"
test -s "$APP/Contents/Resources/AppIcon.icns"
codesign --verify --deep --strict --verbose=2 "$APP"

SIGNING_DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
if ! printf '%s\n' "$SIGNING_DETAILS" | grep -q '^Authority=Developer ID Application:'; then
    echo "Public release blocked: the app needs a Developer ID Application signature." >&2
    exit 1
fi
if ! printf '%s\n' "$SIGNING_DETAILS" | grep -q '^flags=.*runtime'; then
    echo "Public release blocked: the hardened runtime is missing." >&2
    exit 1
fi
if ! printf '%s\n' "$SIGNING_DETAILS" | grep -q '^Timestamp='; then
    echo "Public release blocked: a secure signing timestamp is missing." >&2
    exit 1
fi

xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

echo "Public release checks passed: $ARCHIVE"
