#!/bin/bash
# Claude Code hook -> writes per-session state for the menu-bar app.
# Usage (from settings.json): hook.sh <state> <event>
#   state in: working | waiting | done | end
# Reads the hook JSON payload from stdin (session_id, cwd, tool_name, ...).

STATE="$1"
EVENT="$2"
PAYLOAD="$(cat)"

STATE_DIR="$HOME/.claude/session-state"
mkdir -p "$STATE_DIR"

# Find the owning `claude` pid by walking up from this hook's parent.
find_claude_pid() {
  local p="${PPID:-$$}"
  local i
  for i in $(seq 1 15); do
    [ -z "$p" ] && break
    [ "$p" -le 1 ] && break
    local comm
    comm="$(ps -o comm= -p "$p" 2>/dev/null | sed 's#.*/##' | tr -d ' ')"
    if [ "$comm" = "claude" ]; then
      echo "$p"; return
    fi
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  echo ""
}

CPID="$(find_claude_pid)"

# Extract a field from the JSON payload on stdin.
json_get() {
  printf '%s' "$PAYLOAD" | /usr/bin/python3 -c '
import json,sys
key=sys.argv[1]
try:
    d=json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
print(d.get(key,"") or "")
' "$1" 2>/dev/null
}

# Extract a field from a JSON file on disk.
json_get_file() {
  /usr/bin/python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print(""); sys.exit(0)
print(d.get(sys.argv[2],"") or "")
' "$1" "$2" 2>/dev/null
}

# Escape a value for embedding inside a JSON/AppleScript string.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

SID="$(json_get session_id)"
CWD="$(json_get cwd)"
TOOL="$(json_get tool_name)"
NTYPE="$(json_get notification_type)"
MSG="$(json_get message)"

# Fall back to pid-based filename if no session_id.
KEY="${SID:-$CPID}"
[ -z "$KEY" ] && exit 0

STATE_FILE="$STATE_DIR/$KEY.json"
TS="$(date +%s)"

# Refine Notification events: only real "needs you" prompts turn the session yellow.
# Idle / generic notifications must NOT downgrade an active session — keep its state.
if [ "$EVENT" = "Notification" ]; then
  case "$NTYPE" in
    *permission*|*elicit*|*approv*|*confirm*|*denied*)
      STATE="waiting" ;;   # real attention required
    *)
      PREV="$(json_get_file "$STATE_FILE" state)"
      STATE="${PREV:-done}" ;;  # idle/other: leave as-is (don't go yellow)
  esac
fi

# Notifications + sound are handled by the menu-bar app (native, clickable).
# This hook only records state.

if [ "$STATE" = "end" ]; then
  rm -f "$STATE_FILE" 2>/dev/null
  exit 0
fi

cat > "$STATE_FILE" <<EOF
{
  "pid": ${CPID:-0},
  "session_id": "$(esc "$SID")",
  "cwd": "$(esc "$CWD")",
  "state": "$(esc "$STATE")",
  "event": "$(esc "$EVENT")",
  "tool": "$(esc "$TOOL")",
  "notification_type": "$(esc "$NTYPE")",
  "message": "$(esc "$MSG")",
  "ts": $TS
}
EOF

exit 0
