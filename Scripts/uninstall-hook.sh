#!/usr/bin/env bash
# Removes the FlowTrace SessionStart hook, leaving every other hook untouched.
set -euo pipefail
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || { echo "No settings.json — nothing to remove."; exit 0; }

python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    settings = json.load(f)

starts = settings.get("hooks", {}).get("SessionStart", [])
before = len(starts)
starts[:] = [g for g in starts
             if not any("flowtrace" in (h.get("command") or "").lower()
                        for h in g.get("hooks", []))]
if not starts:
    settings.get("hooks", {}).pop("SessionStart", None)

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print(f"▸ Removed {before - len(starts)} FlowTrace hook(s)")
PY
echo "✓ Done."
