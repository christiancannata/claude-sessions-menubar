# Porting guide (Windows & other platforms)

The current app is **macOS-only** (Swift + Cocoa). A Windows version is a
**from-scratch rewrite of the UI layer**, not a port — but the design splits
cleanly into a platform-agnostic contract and a thin platform-specific shell, so
most of the thinking is already done. This document is the spec you need.

**Contributions welcome.** If you build a Windows (or Linux) client that respects
the contract below, open a PR — ideally under `windows/` so the macOS app stays
untouched.

## Architecture

Two independent parts talk only through **state files on disk**:

```
Claude Code ──(hooks)──▶ hook script ──writes──▶ ~/.claude/session-state/*.json
                                                          │
                                                          ▼
                                          menu-bar / tray app  ──reads──▶ UI + toasts
```

1. **The hook script** runs on Claude Code lifecycle events and writes one JSON
   file per session describing its current state.
2. **The tray app** polls those files (every ~2s) plus the process list, and
   renders the menu + notifications.

Neither side calls the other directly. Reimplement either half in any language as
long as it honors the contract below.

## The state-file contract (platform-agnostic)

- **Location:** `~/.claude/session-state/` (`%USERPROFILE%\.claude\session-state\`
  on Windows). One file per session: `<session_id>.json` (falls back to
  `<pid>.json` if no session id).
- **Format:**

  ```json
  {
    "pid": 12345,
    "session_id": "abc-123",
    "cwd": "/Users/me/projects/app",
    "state": "working",
    "event": "PreToolUse",
    "tool": "Edit",
    "notification_type": "",
    "message": "",
    "ts": 1719840000
  }
  ```

- **`state`** is one of: `working` · `waiting` · `done`. A file is **deleted** when
  the session ends. Missing file ⇒ treat as `unknown`.
- **`ts`** is a Unix timestamp (seconds).

## Hook event → state mapping

Registered in `~/.claude/settings.json`. Each hook invokes the script as
`<script> <state> <event>` and pipes the event JSON on stdin.

| Claude Code event | state written |
|-------------------|---------------|
| `SessionStart`    | `done`        |
| `UserPromptSubmit`| `working`     |
| `PreToolUse`      | `working`     |
| `PostToolUse`     | `working`     |
| `Notification`    | `waiting`\*   |
| `Stop`            | `done`        |
| `SessionEnd`      | *(delete file)* |

\* **Important nuance:** on `Notification`, only turn the session **yellow
(`waiting`)** when `notification_type` matches a real attention request
(`permission` / `elicit` / `approval` / `confirm` / `denied`). For idle or generic
notifications, keep the previous state — do not downgrade an active session. See
`hook.sh` for the reference logic.

The hook payload fields consumed: `session_id`, `cwd`, `tool_name`,
`notification_type`, `message`.

## What a Windows client needs to implement

| Concern | macOS (reference) | Windows equivalent |
|---|---|---|
| Hook script | `hook.sh` (bash) | `hook.ps1` / `hook.cmd` — same contract |
| Find `claude` processes | `ps -axo pid,ppid,command` | `Get-CimInstance Win32_Process` (has `ParentProcessId`, `CommandLine`) |
| Host app (walk parents to a GUI app) | parent chain to first `.app` bundle | walk `ParentProcessId` to the owning `.exe` / window |
| Session working dir | `lsof -d cwd -p <pid>` | harder — prefer the `cwd` already stored in the state file; `Get-Process` doesn't expose cwd |
| Tray icon + menu | `NSStatusItem` + `NSMenu` | `NotifyIcon` (WinForms) / a tray lib |
| Notifications | custom `NSPanel` toasts | WinRT toast (`Windows.UI.Notifications`) or an always-on-top borderless window |
| Sounds | `afplay` on `/System/Library/Sounds/*.aiff` | `System.Media.SystemSounds` / `SoundPlayer` |
| Launch at login | LaunchAgent plist | Startup registry key / Startup folder shortcut |

**Tip:** the `cwd` is already captured by the hook into each state file, so the
Windows client can skip process-cwd inspection entirely and just read it from JSON
— that removes the hardest platform-specific piece.

### Suggested stacks

- **C# / .NET** — most native tray + toast story on Windows (WinForms `NotifyIcon`
  + WinRT toasts). Recommended.
- **Python** — `pystray` + `win10toast`/`winrt`, quickest to prototype.
- **Rust (Tauri / tray-icon)** — single binary, cross-platform.

Reading the state files and the event mapping is identical across all of them; only
the tray/toast shell differs.

## macOS reference files

- `ClaudeSessions.swift` — scanner (process tree, state files) + UI (menu, toasts).
- `hook.sh` — the state writer; the clearest spec of the contract.
- `install-hooks.sh` — how the hooks are registered into `settings.json`.
