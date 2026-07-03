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

# 0) prerequisiti --------------------------------------------------------
bold "Controllo prerequisiti"
MISSING=0

# macOS 12+ (l'app usa API/simboli non disponibili prima)
OSV="$(sw_vers -productVersion 2>/dev/null || echo 0)"; OSMAJ="${OSV%%.*}"
if [ "${OSMAJ:-0}" -ge 12 ] 2>/dev/null; then
  ok "macOS $OSV (richiesto 12+)"
else
  warn "macOS ${OSV:-sconosciuto}: servono macOS 12 (Monterey) o superiore."
  echo "    Aggiorna da:  Impostazioni di Sistema → Generali → Aggiornamento software"
  MISSING=1
fi

# Xcode Command Line Tools -> swiftc (per compilare) + python3 (usato dagli hook)
if command -v swiftc >/dev/null 2>&1; then
  ok "Xcode Command Line Tools ($(swiftc --version 2>/dev/null | head -1 | cut -d'(' -f1 | xargs))"
else
  warn "Swift non trovato: mancano gli Xcode Command Line Tools."
  echo "    Lancia:  xcode-select --install    (poi riapri il terminale e rilancia questo installer)"
  MISSING=1
fi

if /usr/bin/python3 --version >/dev/null 2>&1; then
  ok "python3 disponibile"
else
  warn "python3 non eseguibile (di norma arriva con i Command Line Tools)."
  echo "    Lancia:  xcode-select --install"
  MISSING=1
fi

if [ "$MISSING" != "0" ]; then
  echo
  warn "Prerequisiti mancanti. Sistema i punti qui sopra e rilancia:  bash install.sh"
  exit 1
fi

# Claude Code (non è un blocco: puoi installare l'app anche prima)
if [ -d "$HOME/.claude" ]; then
  ok "Claude Code rilevato (~/.claude)"
else
  warn "~/.claude non esiste: Claude Code non risulta ancora installato."
  echo "    L'app mostra le sessioni di Claude Code, quindi installalo prima:"
  echo "    https://docs.claude.com/claude-code"
  read -r -p "  Continuo comunque? [y/N] " a; [ "$a" = "y" ] || exit 1
fi

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
