# Steam-Integration — Design-Spec

**Datum:** 2026-04-18
**Status:** Genehmigt

## Ziel

Steam-Verwaltung in das LinuxGSM-WebCore Webmin-Modul integrieren:
- SteamCMD installieren und System vorbereiten (Debian 13: Repos patchen)
- Steam-Accounts verwalten (Vault mit Usernames; Passwörter werden nie gespeichert)
- Interaktiver Steam Guard Web-Flow (2FA ohne SSH-Zugang)
- Spiele mit Steam-Pflicht-Login in Wizard und Manage-Seite integrieren

---

## Architektur

### Neue Dateien

| Datei | Zweck |
|---|---|
| `src/steam_settings.cgi` | Haupt-Steam-Seite: System, Accounts, laufende Sessions |
| `src/lib/steam.pl` | Alle Steam-Logik: Erkennung, Repo-Patch, Vault, Login-Flow |
| `src/scripts/steam_login_worker.sh` | Hintergrundprozess: steamcmd via FIFO steuern, Guard-Prompt erkennen |

### Geänderte Dateien

| Datei | Änderung |
|---|---|
| `src/index.cgi` | Button "Steam-Einstellungen" (sichtbar für `can_scan()`) |
| `src/wizard.cgi` | Optionaler Steam-Account-Schritt wenn `steam_required` |
| `src/manage.cgi` | Steam-Abschnitt: Account + Status + Re-Login |
| `src/lib/games_meta.json` | `"steam_required": true/false` pro Spiel |
| `src/lib/games_meta.pl` | Neue Funktion `game_requires_steam($script)` |
| `src/lib/instance.pl` | 7. TSV-Spalte `steam_account` in Registry |
| `src/lang/de` + `src/lang/en` | Neue Lang-Strings |

---

## Abschnitt 1: Steam-System-Setup

### UI (`steam_settings.cgi` — erster Abschnitt)

Drei Statuszeilen mit Aktions-Buttons:

| Prüfung | OK | Problem | Aktion |
|---|---|---|---|
| SteamCMD installiert | ✅ Pfad | ❌ fehlt | "SteamCMD installieren" |
| `non-free contrib` in sources.list | ✅ | ❌ | "Repos aktivieren" |
| CD-ROM-Zeile auskommentiert | ✅ | ⚠️ aktiv | "CD-ROM deaktivieren" |

### Funktionen in `steam.pl`

```perl
sub detect_steamcmd()
# Gibt Pfad zurück (z.B. /usr/games/steamcmd) oder undef.
# Prüft: which steamcmd, /usr/games/steamcmd, /usr/bin/steamcmd

sub check_apt_repos()
# Liest /etc/apt/sources.list
# Gibt zurück: { non_free => 0/1, contrib => 0/1, cdrom_active => 0/1 }

sub patch_apt_sources()
# 1. Kommentiert cdrom:-Zeilen aus
# 2. Ergänzt "non-free contrib" in bestehenden deb-Zeilen wenn fehlend
# Sicherheit: Nur /etc/apt/sources.list erlaubt (exakter Pfad-Match)

sub install_steamcmd()
# apt-get install -y steamcmd via system_logged()
# Läuft im Webmin-CGI-Kontext als root
```

### POST-Aktionen

- `action=patch_repos` → `patch_apt_sources()` → Redirect
- `action=install_steamcmd` → `install_steamcmd()` → Redirect

---

## Abschnitt 2: Account-Vault

### Speicherformat

`$config_directory/steam_accounts.tsv`:
```
steam_username<TAB>display_name<TAB>status
```

`status` ∈ `ok` | `guard_pending` | `token_expired`

**Passwörter werden niemals gespeichert.**

### UI (`steam_settings.cgi` — zweiter Abschnitt)

- Tabelle: Username, Display-Name, Status-Badge, Aktionen
- "Account hinzufügen"-Formular: Display-Name + Steam-Username + Passwort (type=password, einmalig)
- "Entfernen"-Button pro Account
- "Re-Login"-Button bei Status `token_expired`

### Funktionen in `steam.pl`

```perl
sub load_steam_accounts()
# Gibt Liste von Hashrefs zurück: { username, display_name, status }

sub save_steam_accounts(\@accounts)
# Schreibt TSV; chmod 600

sub add_steam_account($username, $display_name)
# Fügt Eintrag mit status=guard_pending hinzu; kein Passwort

sub remove_steam_account($username)
# Entfernt aus TSV; löscht Steam-Token-Files im Home des zugehörigen Game-Users nicht
# (Token verbleibt in ~/.steam — Entfernung nur auf Wunsch)

sub get_steam_account_status($username)
# Gibt status-String zurück
```

---

## Abschnitt 3: Steam Guard Web-Flow

### Sicherheit der Session

- `$TOKEN` = 32 Zeichen Hex aus `/dev/urandom`
- Session-Dir: `$config_directory/steam_sessions/$TOKEN/`
- `chmod 700` auf Session-Dir
- Session-Timeout: 5 Minuten (Status → `timeout`); Cleanup beim nächsten Poll

### Dateien pro Session

```
$SESSION_DIR/
  steam_out        # steamcmd stdout/stderr (append)
  steam_in         # FIFO für stdin-Input
  status           # ok | guard_required | failed | timeout
  guard_code       # Wird vom CGI geschrieben wenn Guard-Code eingegeben
  pid              # PID des Worker-Prozesses
```

### `steam_login_worker.sh`

```bash
#!/bin/bash
SESSION_DIR="$1"
USERNAME="$2"
PASS_FILE="$3"    # Temp-Datei mit Passwort (chmod 600, wird sofort gelesen+gelöscht)

PASSWORD=$(cat "$PASS_FILE")
rm -f "$PASS_FILE"

mkfifo "$SESSION_DIR/steam_in"
steamcmd < "$SESSION_DIR/steam_in" > "$SESSION_DIR/steam_out" 2>&1 &
STEAM_PID=$!
echo $STEAM_PID > "$SESSION_DIR/pid"

# Login-Befehl senden (im Hintergrund, da FIFO blockiert bis steamcmd liest)
(echo "+login $USERNAME $PASSWORD"; echo "+quit") > "$SESSION_DIR/steam_in" &

# Monitor-Loop
START=$(date +%s)
while kill -0 $STEAM_PID 2>/dev/null; do
    NOW=$(date +%s)
    if [ $((NOW - START)) -gt 300 ]; then
        echo "timeout" > "$SESSION_DIR/status"
        kill $STEAM_PID 2>/dev/null
        exit 1
    fi

    if grep -q "Steam Guard" "$SESSION_DIR/steam_out" 2>/dev/null; then
        echo "guard_required" > "$SESSION_DIR/status"
        # Warten auf Guard-Code vom CGI
        while [ ! -f "$SESSION_DIR/guard_code" ]; do
            sleep 1
            NOW=$(date +%s)
            [ $((NOW - START)) -gt 300 ] && echo "timeout" > "$SESSION_DIR/status" && kill $STEAM_PID 2>/dev/null && exit 1
        done
        # Code senden
        cat "$SESSION_DIR/guard_code" > "$SESSION_DIR/steam_in"
        rm -f "$SESSION_DIR/guard_code"
    fi
    sleep 1
done

# Ergebnis auswerten
if grep -qE "Login.*OK|Logged in OK|Connecting anonymously" "$SESSION_DIR/steam_out" 2>/dev/null; then
    echo "ok" > "$SESSION_DIR/status"
else
    echo "failed" > "$SESSION_DIR/status"
fi
```

### CGI POST-Aktionen

| Aktion | Beschreibung |
|---|---|
| `start_login` | Session anlegen, Passwort in Temp-Datei (chmod 600), Worker starten, Redirect zu `poll` |
| `poll` | Status lesen; auto-refresh alle 3s; bei `guard_required` → Code-Formular; bei `ok`/`failed` → Vault aktualisieren + Session löschen |
| `submit_guard` | Guard-Code in `$SESSION_DIR/guard_code` schreiben; Redirect zu `poll` |

### Passwort-Übergabe (sicher)

```perl
# Temp-Datei statt Shell-Argument:
my $pass_file = "$session_dir/pass_tmp";
open(my $fh, '>', $pass_file); print $fh $password; close($fh);
chmod(0600, $pass_file);
system_logged("nohup $worker_script $session_dir $username $pass_file &");
# Worker löscht Datei als erste Aktion
```

---

## Abschnitt 4: games_meta.json + Wizard/Manage

### games_meta.json

```json
"csgoserver": { "steam_required": true,  ... },
"rustserver":  { "steam_required": true,  ... },
"armaserver":  { "steam_required": true,  ... },
"vhserver":    { "steam_required": false, ... },
"mcserver":    { "steam_required": false, ... },
"pwserver":    { "steam_required": false, ... }
```

### games_meta.pl

```perl
sub game_requires_steam {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key  = _resolve_meta_key($script_name);
    return $meta{$key}{'steam_required'} ? 1 : 0;
}
```

### Wizard-Integration

Nach Port-Schritt: wenn `game_requires_steam($game)` → zusätzlicher Schritt:

```
Steam-Account für diesen Server:
  [Dropdown: existierende Accounts mit Status "ok"]
  [Link: → Neuen Account anlegen (öffnet steam_settings.cgi)]
```

Submitted als Hidden-Field `steam_account=$username`.
`provision_server()` erhält neuen Parameter `steam_account`; schreibt ihn als 7. TSV-Spalte.

### instance.pl — 7. TSV-Spalte

Format:
```
id<TAB>user<TAB>script<TAB>source<TAB>sftp_user<TAB>owners<TAB>steam_account
```

Geänderte Funktionen:
- `_load_registered()` — liest Spalte 7 (`$cols[6] // ''`)
- `_save_registered()` — schreibt Spalte 7
- `register_instance()` — akzeptiert `steam_account` in opts-Hash
- `get_instance()` — gibt `steam_account` zurück
- `list_instances()` — propagiert `steam_account` für alle Instanzen

### Manage.cgi — Steam-Abschnitt

Nur sichtbar wenn `game_requires_steam($script_name)`:

```
╔══════════════════════════════════╗
║ Steam                            ║
║ Account: meinaccount ✅ aktiv    ║
║ [Account ändern] [Re-Login]      ║
╚══════════════════════════════════╝
```

"Re-Login" → Redirect zu `steam_settings.cgi?action=relogin&instance=$ID`
Dort: Username aus Registry vorausgefüllt, nur Passwort-Eingabe nötig → normaler Login-Flow.

---

## Lang-Strings (Auswahl)

| Key | Deutsch | Englisch |
|---|---|---|
| `steam_title` | Steam-Einstellungen | Steam Settings |
| `steam_btn` | Steam-Einstellungen | Steam Settings |
| `steam_cmd_ok` | SteamCMD gefunden | SteamCMD found |
| `steam_cmd_missing` | SteamCMD nicht installiert | SteamCMD not installed |
| `steam_install_btn` | SteamCMD installieren | Install SteamCMD |
| `steam_repos_ok` | Repositories korrekt | Repositories correct |
| `steam_repos_fix_btn` | Repos aktivieren | Enable repositories |
| `steam_accounts_title` | Steam-Accounts | Steam Accounts |
| `steam_add_account` | Account hinzufügen | Add account |
| `steam_username` | Steam-Benutzername | Steam username |
| `steam_display_name` | Anzeigename | Display name |
| `steam_password_hint` | Passwort (wird nicht gespeichert) | Password (not stored) |
| `steam_status_ok` | Token aktiv | Token active |
| `steam_status_expired` | Token abgelaufen | Token expired |
| `steam_status_pending` | Einrichtung ausstehend | Setup pending |
| `steam_guard_prompt` | Steam Guard Code eingeben | Enter Steam Guard code |
| `steam_guard_submit` | Code bestätigen | Confirm code |
| `steam_login_ok` | Login erfolgreich | Login successful |
| `steam_login_failed` | Login fehlgeschlagen | Login failed |
| `steam_login_timeout` | Zeitüberschreitung | Login timed out |
| `steam_required_wizard` | Steam-Account erforderlich | Steam account required |
| `steam_account_label` | Steam-Account | Steam account |
| `steam_relogin_btn` | Re-Login auslösen | Trigger re-login |
| `steam_no_accounts` | Keine Accounts konfiguriert | No accounts configured |

---

## Sicherheits-Checkliste

- [ ] Passwort wird nie in Datei/DB geschrieben (nur Temp-Datei chmod 600, sofort gelöscht)
- [ ] Session-Token = 32 Hex-Zeichen (`/dev/urandom`)
- [ ] Session-Dir chmod 700
- [ ] Session-Timeout 5 Minuten
- [ ] `patch_apt_sources()` akzeptiert nur exakten Pfad `/etc/apt/sources.list`
- [ ] Input-Sanitization: Steam-Username `[a-zA-Z0-9_\-]{1,64}`
- [ ] Guard-Code: nur `[A-Z0-9]{5}` akzeptiert (Steam Guard ist 5 Zeichen)
- [ ] HTML-Output: alle dynamischen Werte via `html_escape()`
- [ ] Worker-Script: nicht via Shell-String-Expansion aufgerufen (Quote-Liste)

---

## Nicht im Scope (bewusst ausgelassen)

- Automatisches Token-Refresh (Token hält Monate; Re-Login ist manueller Schritt)
- Steam-Workshop-Integration
- Mehrspieler-Accounts pro Instanz (ein Account pro Server reicht)
- E-Mail-Benachrichtigung bei Token-Ablauf
