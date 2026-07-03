#!/bin/bash
# Micro smoke tests for Claude Sessions.  Run:  bash test.sh
#
# Pure bash + python3 (python3 is already required by hook.sh). No jq, no
# network, no sudo. Everything runs inside a throwaway $HOME sandbox, so your
# real ~/.claude and installed app are never touched.
#
# Covers exactly the surface that breaks installs on other Macs:
#   1. the app compiles with no errors AND no warnings
#   2. the CLI modes run
#   3. hook.sh writes the state-file contract correctly (incl. escaping)
#   4. install-hooks.sh registers all events, is idempotent, keeps other hooks

set -u
cd "$(dirname "$0")"
ROOT="$(pwd)"
HOOK="$ROOT/hook.sh"

PASS=0; FAIL=0
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
no()   { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
sect() { printf "\n\033[1m%s\033[0m\n" "$1"; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# read a field from a JSON file
jget() { /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null; }
# is a file valid JSON?
valid_json() { /usr/bin/python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
sect "1. Build (no errors, no warnings)"
BIN="$SANDBOX/CS"; LOG="$SANDBOX/build.log"
if swiftc -O ClaudeSessions.swift -o "$BIN" -framework Cocoa >"$LOG" 2>&1; then
  ok "swiftc compiles (exit 0)"
else
  no "swiftc FAILED:"; sed 's/^/        /' "$LOG"
fi
if grep -q "warning:" "$LOG"; then
  no "compiler warnings (look like errors during install):"
  grep "warning:" "$LOG" | sed 's/^/        /'
else
  ok "no compiler warnings"
fi

# ---------------------------------------------------------------------------
sect "2. CLI smoke"
if [ -x "$BIN" ]; then
  if "$BIN" --scan >/dev/null 2>&1; then ok "--scan runs (exit 0)"; else no "--scan crashed"; fi
  CROP="$("$BIN" --hero-crop --lang=en 2>/dev/null)"
  if printf '%s' "$CROP" | grep -Eq '^CROP [0-9]+ [0-9]+ [1-9][0-9]* [1-9][0-9]*$'; then
    ok "--hero-crop prints a valid rect ($CROP)"
  else
    no "--hero-crop bad output: '$CROP'  (needs a display; skip over headless SSH)"
  fi
else
  no "no binary to smoke-test (build failed above)"
fi

# ---------------------------------------------------------------------------
sect "3. hook.sh state-file contract (sandboxed \$HOME)"
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
SD="$HOME/.claude/session-state"

printf '{"session_id":"s1","cwd":"/tmp/proj","tool_name":"Edit"}' | bash "$HOOK" working PreToolUse
F="$SD/s1.json"
[ -f "$F" ] && ok "writes one state file per session" || no "no state file written"
[ "$(jget "$F" state)" = "working" ] && ok "PreToolUse -> working" || no "wrong state: $(jget "$F" state)"
[ "$(jget "$F" tool)" = "Edit" ]     && ok "tool_name recorded"    || no "tool not recorded"
[ "$(jget "$F" cwd)" = "/tmp/proj" ] && ok "cwd recorded"          || no "cwd not recorded"
valid_json "$F" && ok "state file is valid JSON" || no "state file is NOT valid JSON"

printf '{"session_id":"s1","notification_type":"permission_request","message":"go?"}' | bash "$HOOK" waiting Notification
[ "$(jget "$F" state)" = "waiting" ] && ok "permission Notification -> waiting" || no "expected waiting, got $(jget "$F" state)"

# a generic/idle Notification must NOT downgrade an active session
printf '{"session_id":"s2","cwd":"/tmp/p2"}' | bash "$HOOK" working PostToolUse
printf '{"session_id":"s2","notification_type":"idle"}' | bash "$HOOK" waiting Notification
[ "$(jget "$SD/s2.json" state)" = "working" ] && ok "idle Notification does NOT downgrade a working session" || no "idle downgraded working -> $(jget "$SD/s2.json" state)"

# special characters in the message must not corrupt the JSON.
# fed via a quoted heredoc so the backslashes reach the hook byte-for-byte.
bash "$HOOK" working PreToolUse <<'EOF'
{"session_id":"s3","message":"say \"hi\" \\ bye","tool_name":"Bash"}
EOF
if /usr/bin/python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["message"]=="say \"hi\" \\ bye" else 1)' "$SD/s3.json" 2>/dev/null; then
  ok "special chars in message are escaped (JSON stays valid)"
else
  no "special chars corrupt the state file"
fi

printf '{"session_id":"s1"}' | bash "$HOOK" done Stop
[ "$(jget "$F" state)" = "done" ] && ok "Stop -> done" || no "expected done"
printf '{"session_id":"s1"}' | bash "$HOOK" end SessionEnd
[ ! -f "$F" ] && ok "SessionEnd removes the state file" || no "state file not removed on SessionEnd"

# ---------------------------------------------------------------------------
sect "4. install-hooks.sh (sandboxed \$HOME)"
mkdir -p "$HOME/.claude"
# seed a pre-existing, unrelated hook we must not clobber
cat > "$HOME/.claude/settings.json" <<'JSON'
{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "~/.claude/hooks/other.sh" } ] } ] } }
JSON

stats() { /usr/bin/python3 - "$HOME/.claude/settings.json" "$HOOK" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); hook = sys.argv[2]
h = d.get("hooks", {})
ev = ["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","Notification","Stop","SessionEnd"]
ours = lambda c: c.startswith(hook + " ")
counts = [sum(1 for g in h.get(e, []) for x in g.get("hooks", []) if ours(x.get("command",""))) for e in ev]
unrel = any("other.sh" in x.get("command","") for g in h.get("PreToolUse", []) for x in g.get("hooks", []))
print(min(counts), max(counts), "1" if unrel else "0")
PY
}

bash "$ROOT/install-hooks.sh" "$HOOK" >/dev/null 2>&1
read -r MN MX UNREL < <(stats)
{ [ "$MN" = "1" ] && [ "$MX" = "1" ]; } && ok "all 7 events registered exactly once" || no "unexpected counts (min=$MN max=$MX)"
[ "$UNREL" = "1" ] && ok "pre-existing unrelated hook preserved" || no "clobbered an unrelated hook"

bash "$ROOT/install-hooks.sh" "$HOOK" >/dev/null 2>&1   # run twice
read -r MN MX UNREL < <(stats)
{ [ "$MN" = "1" ] && [ "$MX" = "1" ]; } && ok "re-running is idempotent (no duplicates)" || no "duplicates after re-run (min=$MN max=$MX)"
valid_json "$HOME/.claude/settings.json" && ok "settings.json stays valid JSON" || no "settings.json invalid after install-hooks"

# ---------------------------------------------------------------------------
sect "Result"
printf "  %d passed, %d failed\n\n" "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then printf "\033[32mAll good ✅\033[0m\n"; exit 0
else printf "\033[31m%d check(s) failed ❌\033[0m\n" "$FAIL"; exit 1; fi
