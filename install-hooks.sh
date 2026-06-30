#!/bin/bash
# Registers the menu-bar state hooks into ~/.claude/settings.json (backup first).
# Usage: install-hooks.sh [/path/to/hook.sh]   (defaults to ./hook.sh)
set -e
cd "$(dirname "$0")"
HOOK="${1:-$(pwd)/hook.sh}"
SETTINGS="$HOME/.claude/settings.json"

/usr/bin/python3 - "$SETTINGS" "$HOOK" <<'PY'
import json, os, sys, shutil, time

settings_path, hook = sys.argv[1], sys.argv[2]

data = {}
if os.path.exists(settings_path):
    backup = settings_path + ".bak." + time.strftime("%Y%m%d-%H%M%S")
    shutil.copy2(settings_path, backup)
    print("Backup:", backup)
    try:
        with open(settings_path) as f:
            data = json.load(f)
    except Exception as e:
        print("WARN: could not parse settings.json, aborting:", e); sys.exit(1)

hooks = data.setdefault("hooks", {})

# event -> (state arg, event arg)
mapping = {
    "SessionStart":     "done",
    "UserPromptSubmit": "working",
    "PreToolUse":       "working",
    "PostToolUse":      "working",
    "Notification":     "waiting",
    "Stop":             "done",
    "SessionEnd":       "end",
}

def make_entry(state, event):
    return {
        "hooks": [{
            "type": "command",
            "command": f'{hook} {state} {event}',
        }]
    }

def is_ours(group):
    # match any prior variant of our hook (dev path, installed app, or this path)
    def m(c):
        return (hook in c or "ClaudeSessions.app" in c
                or "claude-sessions-menubar" in c)
    return any(m(h.get("command", "")) for h in group.get("hooks", []))

for event, state in mapping.items():
    arr = hooks.setdefault(event, [])
    # remove any previous entry we installed, then append fresh
    arr[:] = [g for g in arr if not is_ours(g)]
    arr.append(make_entry(state, event))

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
print("Installed hooks into", settings_path)
print("Events:", ", ".join(mapping.keys()))
PY

echo
echo "Done. Restart your Claude Code sessions (or start new ones) so the hooks load."
