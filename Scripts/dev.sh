#!/usr/bin/env bash
# Rebuild, replace the running app, relaunch. The inner loop while developing.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/Scripts/bundle.sh" "${1:-debug}"
pkill -x FlowTrace 2>/dev/null || true
open "$ROOT/dist/FlowTrace.app"
