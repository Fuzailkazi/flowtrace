#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product FlowTraceApp
BIN_DIR="$(swift build --show-bin-path)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -I "$BIN_DIR/Modules" \
    -I .build/checkouts/GRDB.swift/Sources/GRDBSQLite \
    Sources/FlowTraceApp/HotKeyShortcut.swift \
    Sources/FlowTraceApp/CaptureTrigger.swift \
    Tests/Shortcuts/main.swift \
    "$BIN_DIR"/FlowTraceCore.build/*.o "$BIN_DIR"/GRDB.build/*.o \
    -lsqlite3 -o "$TEST_DIR/FlowTraceShortcutTests"
"$TEST_DIR/FlowTraceShortcutTests"
