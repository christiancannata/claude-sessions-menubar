#!/bin/bash
# Claude Sessions — updater. Scarica l'ultima versione, ricompila, reinstalla e riavvia.
# Sicuro: solo git dal repo ufficiale, nessun sudo. Tocca solo ~/Applications.
#   - lanciato dal repo clonato  -> git pull
#   - lanciato dall'app (bundle)  -> git clone in una cartella temporanea
set -euo pipefail

# Overridable via env (used by tests); defaults point at the official repo.
REPO="${CS_REPO:-https://github.com/christiancannata/claude-sessions-menubar.git}"
BRANCH="${CS_BRANCH:-main}"
DEST="${CS_DEST:-$HOME/Applications}"
APPNAME="ClaudeSessions.app"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }

bold "Claude Sessions — aggiornamento"
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1) procurati i sorgenti aggiornati -------------------------------------
if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  SRC="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
  bold "1/4  Scarico gli aggiornamenti (git pull)"
  git -C "$SRC" pull --ff-only
  CLEANUP=""
else
  bold "1/4  Scarico l'ultima versione (git clone)"
  TMP="$(mktemp -d)"
  CLEANUP="$TMP"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$TMP/repo"
  SRC="$TMP/repo"
fi
cleanup() { [ -n "${CLEANUP:-}" ] && rm -rf "$CLEANUP"; }
trap cleanup EXIT
NEWV="$(tr -d ' \t\r\n' < "$SRC/VERSION" 2>/dev/null || echo '?')"
ok "sorgenti pronti (v$NEWV)"

# 2) ricompila -----------------------------------------------------------
echo; bold "2/4  Ricompilo l'app"
( cd "$SRC" && bash build.sh >/dev/null )
ok "app compilata"

# 3) chiudi la versione in esecuzione e sostituisci ----------------------
echo; bold "3/4  Installo in ~/Applications"
if [ "${CS_LAUNCH:-1}" = "1" ]; then
  osascript -e 'quit app "Claude Sessions"' >/dev/null 2>&1 || true
  # aspetta che l'app esca davvero prima di rimpiazzare il bundle
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x ClaudeSessions >/dev/null 2>&1 || break
    sleep 0.5
  done
fi
mkdir -p "$DEST"
rm -rf "$DEST/$APPNAME"
cp -R "$SRC/build/$APPNAME" "$DEST/"
ok "installata v$NEWV in $DEST/$APPNAME"

# 4) riavvia -------------------------------------------------------------
echo; bold "4/4  Riavvio l'app"
if [ "${CS_LAUNCH:-1}" = "1" ]; then
  # Launch Services può restituire -600 subito dopo il quit: riprova qualche volta.
  launched=0
  for _ in 1 2 3 4 5; do
    if open "$DEST/$APPNAME" 2>/dev/null; then launched=1; break; fi
    sleep 1
  done
  if [ "$launched" = "1" ]; then
    ok "Claude Sessions aggiornata e riavviata (v$NEWV)"
  else
    ok "aggiornata a v$NEWV — riaprila da ~/Applications se non è ripartita"
  fi
else
  ok "riavvio saltato (CS_LAUNCH=0)"
fi
echo
bold "Fatto!"
