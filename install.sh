#!/bin/bash
# Claude Sessions — installer (builds locally, no Gatekeeper warnings).
# Safe by design: builds from source on this Mac, only touches your own
# ~/.claude config (with a backup) and ~/Applications. No network, no sudo.
set -euo pipefail
cd "$(dirname "$0")"
SRC="$(pwd)"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }

bold "Claude Sessions — installazione"
echo

# 1) prerequisiti --------------------------------------------------------
if ! command -v swiftc >/dev/null 2>&1; then
  warn "Swift non trovato. Servono gli Xcode Command Line Tools."
  echo "  Lancia:  xcode-select --install   poi riprova."
  exit 1
fi
ok "Swift presente ($(swiftc --version 2>/dev/null | head -1 | cut -d'(' -f1))"

if [ ! -d "$HOME/.claude" ]; then
  warn "~/.claude non esiste: Claude Code non risulta installato/usato."
  echo "  L'app rileva le sessioni di Claude Code: installalo prima."
  read -r -p "  Continuo comunque? [y/N] " a; [ "$a" = "y" ] || exit 1
fi
ok "Claude Code rilevato (~/.claude)"

# 2) build ---------------------------------------------------------------
echo; bold "1/4  Compilo l'app"
bash build.sh >/dev/null
ok "app compilata: build/ClaudeSessions.app"

# 3) install in ~/Applications ------------------------------------------
echo; bold "2/4  Installo in ~/Applications"
DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/ClaudeSessions.app"
cp -R "build/ClaudeSessions.app" "$DEST/"
APP="$DEST/ClaudeSessions.app"
ok "installata in $APP"

# 4) hooks di stato ------------------------------------------------------
echo; bold "3/4  Registro gli hook di stato in ~/.claude/settings.json"
echo "  (verrà fatto un backup; gli hook esistenti NON vengono toccati)"
read -r -p "  Procedo? [Y/n] " a; a="${a:-y}"
if [ "$a" = "y" ] || [ "$a" = "Y" ]; then
  # punta l'hook alla copia installata, così resta valido anche spostando i sorgenti
  HOOK_TARGET="$APP/Contents/Resources/hook.sh"
  bash install-hooks.sh "$HOOK_TARGET"
  ok "hook registrati"
else
  warn "saltato: senza hook l'app mostra le sessioni ma non gli stati live"
fi

# 5) avvio ---------------------------------------------------------------
echo; bold "4/4  Avvio l'app"
open "$APP"
ok "Claude Sessions è in esecuzione (icona campanella in alto a destra)"

echo
bold "Fatto!"
echo "  • Avvio al login:  menu della campanella → 'Avvia al login'"
echo "  • Disattivare suoni: menu → 'Suoni di notifica'"
echo "  • Disinstallare:   bash \"$SRC/uninstall.sh\""
