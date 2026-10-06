#!/usr/bin/env bash
# Submit an already Developer ID signed ZIP, staple its app, and verify the final ZIP.
set -euo pipefail

if [ "$#" -ne 2 ] || [ ! -f "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 path/to/FlowTrace-<version>-macOS.zip notarytool-keychain-profile" >&2
    exit 2
fi

ARCHIVE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
PROFILE="$2"
case "$ARCHIVE" in
    *.zip) OUTPUT="${ARCHIVE%.zip}-notarized.zip" ;;
    *) echo "Expected a .zip archive." >&2; exit 2 ;;
esac
if [ -e "$OUTPUT" ]; then
    echo "Output already exists: $OUTPUT" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/flowtrace-notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ditto -x -k "$ARCHIVE" "$WORK/input"
APP="$WORK/input/FlowTrace.app"
if [ ! -d "$APP" ]; then
    echo "Archive must contain FlowTrace.app at its top level." >&2
    exit 1
fi

# All local checks precede the external submission. An ad-hoc build stops here.
plutil -lint "$APP/Contents/Info.plist"
test -s "$APP/Contents/Resources/AppIcon.icns"
codesign --verify --deep --strict --verbose=2 "$APP"
DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
if ! printf '%s\n' "$DETAILS" | grep -q '^Authority=Developer ID Application:'; then
    echo "Notarization blocked: the app needs a Developer ID Application signature." >&2
    exit 1
fi
if ! printf '%s\n' "$DETAILS" | grep -q '^flags=.*runtime'; then
    echo "Notarization blocked: the hardened runtime is missing." >&2
    exit 1
fi
if ! printf '%s\n' "$DETAILS" | grep -q '^Timestamp='; then
    echo "Notarization blocked: a secure signing timestamp is missing." >&2
    exit 1
fi

echo "Submitting $ARCHIVE to Apple's notary service…"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --wait --output-format json > "$WORK/submission.json"
if ! /usr/bin/python3 -c 'import json,sys; result=json.load(open(sys.argv[1])); print("Notary status:",result.get("status"),"submission:",result.get("id")); sys.exit(0 if result.get("status")=="Accepted" else 1)' "$WORK/submission.json"; then
    echo "Notarization was not accepted. Inspect the submission with: xcrun notarytool log <submission-id> --keychain-profile <profile>" >&2
    exit 1
fi

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/verified.zip"
"$ROOT/Scripts/verify-public-release.sh" "$WORK/verified.zip"
mv "$WORK/verified.zip" "$OUTPUT"
echo "Verified notarized archive: $OUTPUT"
