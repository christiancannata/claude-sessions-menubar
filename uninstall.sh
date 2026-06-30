#!/bin/bash
# Claude Sessions — uninstaller. Removes the app, the login item and our hooks.
set -uo pipefail

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }

LABEL="com.christiancannata.claudesessions"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SETTINGS="$HOME/.claude/settings.json"

bold "Claude Sessions — disinstallazione"
echo

# 1) login agent
if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  ok "rimosso avvio al login"
fi

# 2) running app
pkill -f "ClaudeSessions.app/Contents/MacOS" 2>/dev/null && ok "app chiusa" || true

# 3) app bundle
for d in "$HOME/Applications/ClaudeSessions.app" "/Applications/ClaudeSessions.app"; do
  [ -d "$d" ] && rm -rf "$d" && ok "rimossa $d"
done

# 4) hooks from settings.json (backup first)
if [ -f "$SETTINGS" ]; then
  /usr/bin/python3 - "$SETTINGS" "$LABEL" <<'PY'
import json, sys, shutil, time
path, label = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception:
    sys.exit(0)
shutil.copy2(path, path + ".bak." + time.strftime("%Y%m%d-%H%M%S"))
hooks = data.get("hooks", {})
changed = False
for event in list(hooks.keys()):
    arr = hooks[event]
    new = [g for g in arr if not any("ClaudeSessions.app" in h.get("command","")
                                     or "claude-sessions-menubar" in h.get("command","")
                                     for h in g.get("hooks", []))]
    if len(new) != len(arr):
        changed = True
        if new: hooks[event] = new
        else: del hooks[event]
if changed:
    json.dump(data, open(path, "w"), indent=2)
    print("  hooks rimossi (backup creato)")
else:
    print("  nessun hook nostro trovato")
PY
  ok "settings.json ripulito"
fi

# 5) state files
read -r -p "Rimuovo anche gli stati salvati (~/.claude/session-state)? [y/N] " a
if [ "${a:-n}" = "y" ]; then
  rm -rf "$HOME/.claude/session-state"
  ok "stati rimossi"
fi

echo; bold "Disinstallazione completata."
