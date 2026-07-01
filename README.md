# Claude Sessions — menu bar

App nativa macOS (menu bar, niente icona nel Dock) che mostra tutte le sessioni
di **Claude Code** attive, in quale app/IDE girano, su quale progetto, e **cosa
stanno facendo in questo momento**.

![Notifiche di Claude Sessions](press/notifications.gif)

Quando una sessione **finisce** o **ti chiede qualcosa**, arriva un **toast**
cliccabile in alto a destra (icona dell'app + progetto + cosa chiede) con suono.
Click sul toast → porta in primo piano la sessione giusta.

- 🟢 **sta lavorando** (genera o esegue tool)
- 🟡 **ti sta chiedendo qualcosa** (permesso / conferma / input)
- ⚪️ **ha finito** (pronto per il prossimo prompt)
- ⚫️ stato sconosciuto (sessione partita prima dell'installazione hook)

## Anteprima

Una singola notifica, quando una sessione ti chiede un permesso:

![Una sessione chiede un permesso](press/notification-waiting.png)

Il menu della campanella elenca tutte le sessioni attive, con stato e progetto:

![Menu con le sessioni attive](press/menu.png)

> L'app segue la lingua di sistema del Mac (**italiano** o **inglese**).
> Puoi forzarla con `--lang=it` / `--lang=en`.

## Installazione

Requisiti: macOS 12+, **Xcode Command Line Tools** (`xcode-select --install`),
e ovviamente **Claude Code**.

```bash
bash install.sh
```

Lo script: compila l'app in locale, la installa in `~/Applications`, registra gli
hook in `~/.claude/settings.json` (con backup, senza toccare hook esistenti) e la
avvia. L'avvio al login e il mute dei suoni si attivano dal menu della campanella.

> Le sessioni Claude **già aperte** prima dell'installazione mostrano ⚫️ finché
> non le riavvii. Le nuove partono già tracciate.

### Disinstallazione

```bash
bash uninstall.sh
```

Rimuove app, avvio al login e i nostri hook (backup di settings.json incluso).

## Sicurezza — cosa fa e cosa NON fa

Tutto è ispezionabile nel sorgente (`ClaudeSessions.swift`, `hook.sh`). In sintesi:

- **Nessuna rete, nessuna telemetria, nessun `sudo`.** Gira come utente normale.
- **Cosa legge**: l'elenco dei processi (`ps`) e la cartella di lavoro delle
  sessioni (`lsof`), per capire app host e progetto.
- **Cosa scrive**: file di stato in `~/.claude/session-state/` (uno per sessione)
  e gli hook in `~/.claude/settings.json` (con backup automatico).
- **Compilata localmente**: nessun binario di terze parti, nessun avviso
  Gatekeeper "sviluppatore non identificato" (l'app nasce dal tuo Mac).
- **Strumenti di sistema** invocati con percorso assoluto (`/bin/ps`, `/usr/sbin/lsof`,
  `/usr/bin/afplay`, `/bin/launchctl`).

## Come funziona (tecnico)

1. **Sessioni + app host** (`ClaudeSessions.swift`): trova i processi `claude` e
   risale i parent fino al primo bundle `.app` (gestisce gli helper Electron
   annidati di VS Code/Cursor). Funziona con iTerm, Terminal, JetBrains, VS Code,
   Cursor, Windsurf, Zed, Warp, Ghostty, ecc.
2. **Stato** (`hook.sh`): ogni sessione scrive il proprio stato sugli eventi
   UserPromptSubmit/Pre/PostToolUse (working), Notification (waiting), Stop (done),
   SessionEnd (rimosso). Per `Notification` diventa giallo **solo** per richieste
   reali (`notification_type` permission/elicit/approval), non per l'inattività.
3. **Notifiche**: gestite dall'app come **toast interni** (NSPanel), non dal
   Notification Center di macOS — così funzionano anche se quello è disabilitato o
   corrotto. Click sul toast → porta in primo piano la sessione.

### Debug

```bash
~/Applications/ClaudeSessions.app/Contents/MacOS/ClaudeSessions --scan
```

Stampa le sessioni rilevate e il loro stato senza toccare la menu bar.

## Immagini promozionali

Gli asset del README stanno nella cartella [`press/`](press/) e sono liberi da
riusare (post, README, Product Hunt, ecc.):

| File | Cosa mostra |
|------|-------------|
| `press/notifications.gif` | I toast che arrivano in sequenza |
| `press/notification-waiting.png` | Una singola notifica "richiede attenzione" |
| `press/menu.png` | Il menu con le sessioni attive |

Rigenerabili in locale con le modalità demo dell'app (sessioni finte, sfondo
brandizzato, nessun dato reale):

```bash
ClaudeSessions --demo-menu   --lang=en   # apre il menu con sessioni di esempio
ClaudeSessions --demo-toasts --lang=en   # riproduce la sequenza di notifiche
```

## Limiti noti

- **tmux**: una sessione lanciata dentro tmux appare come "Terminale" (il server
  tmux è staccato da launchd). Stati e toast funzionano comunque.

## Licenza

MIT — vedi `LICENSE`.
