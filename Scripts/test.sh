#!/usr/bin/env bash
# The test suite. An executable rather than `swift test`, because XCTest ships
# with Xcode and this project builds with the Command Line Tools.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec swift run flowtrace-tests "$@"
