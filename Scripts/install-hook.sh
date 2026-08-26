#!/usr/bin/env bash
# Installs the FlowTrace SessionStart hook into ~/.claude/settings.json.
#
# The hook runs `flowtrace brief` when you start Claude Code in a directory, and
# injects where that repository was left. A hotkey has to be remembered; typing
# `claude` is something you already do, so the trigger cannot decay.
#
# Merges into any existing hooks rather than replacing them, and is safe to run
# twice.
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
BINARY="${FLOWTRACE_BIN:-$(command -v flowtrace || true)}"

if [ -z "$BINARY" ]; then
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    for candidate in "$ROOT/dist/flowtrace" "$ROOT/.build/release/flowtrace"; do
        [ -x "$candidate" ] && BINARY="$candidate" && break
    done
fi

if [ -z "$BINARY" ]; then
    echo "Couldn't find the flowtrace binary." >&2
    echo "Build it with ./Scripts/bundle.sh, or set FLOWTRACE_BIN=/path/to/flowtrace." >&2
    exit 1
fi

echo "▸ Using $BINARY"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Back up before touching a file the user's whole CLI reads.
cp "$SETTINGS" "$SETTINGS.flowtrace-backup"

python3 - "$SETTINGS" "$BINARY" <<'PY'
import json, sys

path, binary = sys.argv[1], sys.argv[2]
with open(path) as f:
    try:
        settings = json.load(f)
    except json.JSONDecodeError:
        sys.exit("settings.json isn't valid JSON — fix it before installing the hook.")

command = f'"{binary}" brief --format hook --quiet'
hooks = settings.setdefault("hooks", {})
starts = hooks.setdefault("SessionStart", [])

# Drop any previous FlowTrace entry so re-running updates rather than duplicates.
def is_ours(group):
    return any("flowtrace" in (h.get("command") or "").lower()
               for h in group.get("hooks", []))

starts[:] = [g for g in starts if not is_ours(g)]
starts.append({
    "matcher": "startup|clear|compact",
    "hooks": [{"type": "command", "command": command, "shell": "bash", "async": False}],
})

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print(f"▸ Hook installed into {path}")
PY

echo "✓ Done. Start Claude Code in a repository with uncommitted work to see it."
echo "  Backup of your previous settings: $SETTINGS.flowtrace-backup"
echo "  Remove with ./Scripts/uninstall-hook.sh"
