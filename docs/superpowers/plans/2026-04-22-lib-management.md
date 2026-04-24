# Apt-Only Dependency Management + Nicht-LGSM-Game-Support

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Abhängigkeiten für Game-Server ausschließlich über apt lösen. Wenn ein Paket fehlt, erscheint ein klarer Hinweis im UI statt einer Fehlermeldung ohne Kontext. Zusätzlich: Nicht-LGSM-Spiele (z.B. Windrose, Unreal-Engine-Server) über direkten SteamCMD-Download + Wrapper-Script verwalten.

**Architecture:** Kein Scout Runtime, kein LD_LIBRARY_PATH, kein `libs_pending`-Status. Der bestehende Installationsflow (`fresh → lgsm_ready → installed`) bleibt. `setup_lgsm.sh` stellt i386 + contrib/non-free sicher. `game_action.sh` läuft LGSM-install (LGSM handhabt seine Deps selbst via apt) und parst Fehlerausgaben → `error_hints.pl` liefert Lösungshinweise. Für Nicht-LGSM-Spiele: eigene Worker-Scripts (`steamcmd_install.sh`, `steamcmd_control.sh`) + `source`-Feld in Registry-Eintrag steuert welche Scripts manage.cgi aufruft.

**Tech Stack:** Perl 5, Bash, apt-get, SteamCMD, Webmin `ui_*`, TAP-Tests, JSON::PP, `games_meta.json`.

---

## Was entfällt (Scout-Runtime-Ansatz — nie implementiert)

Der alte Plan `2026-04-22-lib-management.md` war auf Scout Runtime ausgelegt. Folgende Teile werden **nicht** gebaut:
- `host_setup.cgi` (4 Scout-Checks)
- `src/scripts/download_scout.sh`
- `src/scripts/resolve_libs.sh`
- `src/lib/lib_resolver.pl`
- `src/lib/lib_package_map.json` (nur im dependency-hell-repo)
- Status `libs_pending` — wird nicht eingeführt

---

## Datei-Übersicht

| Datei | Aktion | Zweck |
|---|---|---|
| `src/scripts/setup_lgsm.sh` | Modify | i386 + contrib/non-free vor LGSM-Install sicherstellen |
| `src/scripts/game_action.sh` | Modify | Fehlerausgabe von LGSM-install parsen → hint-Datei |
| `src/lib/error_hints.pl` | Modify | Neue Fehlermuster für apt-Fehler + fehlende Libs |
| `src/lib/games_meta.json` | Modify | `apt_deps` + `source`-Feld + Windrose-Eintrag |
| `src/scripts/steamcmd_install.sh` | Create | Nicht-LGSM: SteamCMD-Download + apt-Deps |
| `src/scripts/steamcmd_control.sh` | Create | Nicht-LGSM: start/stop/status/update Wrapper |
| `src/manage.cgi` | Modify | `source`-basiertes Dispatching für install/control |
| `src/lang/de` | Modify | Hinweis-Strings für apt-Fehler, non-LGSM |
| `src/lang/en` | Modify | Englische Entsprechungen |
| `t/test_error_hints.pl` | Modify | Tests für neue Fehlermuster |

---

### Task 1: setup_lgsm.sh — i386 + Repos sicherstellen

**Files:**
- Modify: `src/scripts/setup_lgsm.sh`

Lies die aktuelle Datei. Vor dem `apt-get install`-Aufruf folgendes einfügen, falls noch nicht vorhanden:

- [ ] **Step 1: i386 + contrib/non-free Block einfügen**

Füge direkt nach `set -euo pipefail` und den Argument-Variablen ein:

```bash
echo "=== Ensuring i386 architecture ==="
dpkg --add-architecture i386 2>/dev/null || true
apt-get update -qq

echo "=== Enabling contrib and non-free repos ==="
if ! grep -qE "contrib|non-free" /etc/apt/sources.list 2>/dev/null; then
    sed -i 's/^\(deb .*debian\.org\/debian [a-z]* main\)$/\1 contrib non-free/' \
        /etc/apt/sources.list 2>/dev/null || true
    apt-get update -qq
fi
```

- [ ] **Step 2: Syntax prüfen**

```bash
bash -n src/scripts/setup_lgsm.sh && echo "Syntax OK"
```

- [ ] **Step 3: Commit**

```bash
git add src/scripts/setup_lgsm.sh
git commit -m "feat: setup_lgsm.sh enables i386 and contrib/non-free before install"
```

---

### Task 2: game_action.sh — Fehlerausgabe parsen → hint-Datei

**Files:**
- Modify: `src/scripts/game_action.sh`

LGSM install handhabt seine eigenen apt-Deps intern. Was wir brauchen: Wenn LGSM install fehlschlägt, den Output nach bekannten Fehlermustern durchsuchen und einen verständlichen Hinweis in `$JOB_DIR/error_hint` schreiben.

- [ ] **Step 1: Fehler-Parsing nach LGSM-Aufruf einfügen**

Ersetze den bestehenden `if ! su ...` Block mit:

```bash
OUTPUT_FILE="$JOB_DIR/lgsm_output.txt"

if ! su -s /bin/bash -c "
    cd '$SERVER_DIR' &&
    ./'$GAME_SCRIPT' '$ACTION'
" "$UNIX_USER" 2>&1 | tee "$OUTPUT_FILE"; then

    # Parse output for known error patterns
    if grep -qiE "unable to locate package|E: Package" "$OUTPUT_FILE" 2>/dev/null; then
        MISSING=$(grep -oiE "E: Package '[^']+' has no installation candidate|Unable to locate package [^ ]+" \
            "$OUTPUT_FILE" | head -5 | tr '\n' ' ')
        echo "hint_package_not_found: $MISSING" > "$JOB_DIR/error_hint"
    elif grep -qiE "error.*libssl|cannot open shared object|no such file.*\.so" "$OUTPUT_FILE" 2>/dev/null; then
        MISSING_LIB=$(grep -oiE "lib[a-z0-9._-]+\.so[.0-9]*" "$OUTPUT_FILE" | head -3 | tr '\n' ' ')
        echo "hint_lib_missing: $MISSING_LIB" > "$JOB_DIR/error_hint"
    elif grep -qiE "command not found|No such file or directory" "$OUTPUT_FILE" 2>/dev/null; then
        echo "hint_command_not_found" > "$JOB_DIR/error_hint"
    else
        echo "hint_generic_install_error" > "$JOB_DIR/error_hint"
    fi

    echo "failed" > "$JOB_DIR/status"
    exit 1
fi
```

- [ ] **Step 2: Syntax prüfen**

```bash
bash -n src/scripts/game_action.sh && echo "Syntax OK"
```

- [ ] **Step 3: Commit**

```bash
git add src/scripts/game_action.sh
git commit -m "feat: game_action.sh parses LGSM output into error hints"
```

---

### Task 3: error_hints.pl — neue Fehlermuster

**Files:**
- Modify: `src/lib/error_hints.pl`

Lies die aktuelle Datei. Ergänze folgende Muster in der `%HINTS`-Map (oder wie die bestehende Struktur heißt):

- [ ] **Step 1: Datei lesen und Muster ergänzen**

Die Funktion `get_hint($hint_key)` (oder äquivalent) muss folgende Keys kennen:

```perl
'hint_package_not_found' =>
    'Ein benötigtes Debian-Paket wurde nicht gefunden. '
    . 'Mögliche Ursachen: apt-Quellen veraltet (apt-get update), '
    . 'Paket nur in contrib/non-free verfügbar, oder Paketname hat sich geändert.',

'hint_lib_missing' =>
    'Eine Shared Library fehlt. '
    . 'Prüfe ob das zugehörige Paket (z.B. lib32gcc-s1, libsdl2-2.0-0:i386) installiert ist. '
    . 'Für sehr alte Libs (libssl1.0.x): Debian-Backports oder manuelle Installation nötig.',

'hint_command_not_found' =>
    'Ein Befehl wurde nicht gefunden. Eine Abhängigkeit ist nicht installiert. '
    . 'LGSM-Abhängigkeitsliste unter https://docs.linuxgsm.com prüfen.',

'hint_generic_install_error' =>
    'Die Installation ist fehlgeschlagen. '
    . 'Bitte die Ausgabe oben prüfen. Häufige Ursachen: Festplatte voll, '
    . 'Netzwerkproblem, oder inkompatible Debian-Version.',
```

Füge außerdem hinzu (falls noch nicht vorhanden):

```perl
'hint_steamcmd_login' =>
    'SteamCMD-Login fehlgeschlagen. '
    . 'Prüfe Steam-Guard (2FA) oder versuche es erneut — '
    . 'manchmal hilft ein zweiter Versuch bei anonymem Login.',
```

- [ ] **Step 2: Tests laufen lassen**

```bash
perl t/test_error_hints.pl
```

- [ ] **Step 3: Neue Tests für die neuen Keys ergänzen**

In `t/test_error_hints.pl` folgendes hinzufügen:

```perl
my $h1 = get_hint('hint_package_not_found');
like($h1, qr/Paket/, 'hint_package_not_found contains Paket');

my $h2 = get_hint('hint_lib_missing');
like($h2, qr/Shared Library|lib32/, 'hint_lib_missing contains lib info');

my $h3 = get_hint('hint_generic_install_error');
like($h3, qr/fehlgeschlagen/, 'hint_generic_install_error contains fehlgeschlagen');

my $h4 = get_hint('hint_steamcmd_login');
like($h4, qr/SteamCMD/, 'hint_steamcmd_login contains SteamCMD');
```

- [ ] **Step 4: Tests grün**

```bash
perl t/test_error_hints.pl
```

Alle Tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/error_hints.pl t/test_error_hints.pl
git commit -m "feat: add apt/lib/steamcmd error hints to error_hints.pl"
```

---

### Task 4: games_meta.json — apt_deps + source + Windrose

**Files:**
- Modify: `src/lib/games_meta.json`

Zwei Änderungen:
1. Jedem LGSM-Spiel ein optionales `"apt_deps"`-Array hinzufügen (ergänzende Pakete die LGSM manchmal nicht selbst installiert)
2. Windrose Dedicated Server eintragen (`source: steamcmd`)

- [ ] **Step 1: Datei lesen**

```bash
head -60 src/lib/games_meta.json
```

- [ ] **Step 2: `csgoserver`-Eintrag um apt_deps ergänzen**

Im csgoserver-Objekt (oder ähnlichem Game das bereits drin ist) ergänzen:

```json
"apt_deps": ["lib32gcc-s1", "lib32stdc++6", "libsdl2-2.0-0:i386"],
"source": "lgsm"
```

- [ ] **Step 3: Windrose-Eintrag hinzufügen**

Neuen Eintrag für Windrose Dedicated Server (Unreal Engine, App ID 4129620):

```json
"windrose": {
  "display_name": "Windrose Dedicated Server",
  "source": "steamcmd",
  "steam_app_id": 4129620,
  "engine": "unreal",
  "default_port": 7777,
  "login_required": false,
  "apt_deps": ["lib32gcc-s1", "libsdl2-2.0-0:i386"],
  "fields": [
    {"key": "port", "label": "Game Port", "type": "port", "default": 7777},
    {"key": "queryport", "label": "Query Port", "type": "port", "default": 27015},
    {"key": "maxplayers", "label": "Max Spieler", "type": "integer", "default": 16}
  ]
}
```

- [ ] **Step 4: JSON validieren**

```bash
perl -e 'use JSON::PP; open(my $f,"<","src/lib/games_meta.json"); local $/; decode_json(<$f>); print "JSON OK\n"'
```

- [ ] **Step 5: Commit**

```bash
git add src/lib/games_meta.json
git commit -m "feat: add apt_deps and source fields; add Windrose (steamcmd) to games_meta"
```

---

### Task 5: steamcmd_install.sh — Nicht-LGSM Game installieren

**Files:**
- Create: `src/scripts/steamcmd_install.sh`

Wird von `game_action.sh` aufgerufen wenn `source == steamcmd`.

- [ ] **Step 1: Script erstellen**

```bash
#!/bin/bash
# steamcmd_install.sh — install a non-LGSM game via SteamCMD
# Usage: steamcmd_install.sh <job_dir> <unix_user> <server_dir> <steam_app_id> [validate]
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
STEAM_APP_ID="$4"
VALIDATE="${5:-}"

echo $$ > "$JOB_DIR/pid"
exec >> "$JOB_DIR/output" 2>&1

INSTALL_DIR="$SERVER_DIR/serverfiles"

echo "=== Installing apt dependencies ==="
# Read apt_deps from games_meta.json if available
APT_DEPS=$(perl -e '
use JSON::PP;
my $meta_file = "$ENV{MODULE_ROOT}/lib/games_meta.json";
open(my $f, "<", $meta_file) or exit 0;
local $/;
my $data = decode_json(<$f>);
# Find entry with matching steam_app_id
for my $k (keys %$data) {
    if (($data->{$k}{steam_app_id} // 0) == $ENV{STEAM_APP_ID}) {
        my $deps = $data->{$k}{apt_deps} // [];
        print join(" ", @$deps);
        last;
    }
}
' 2>/dev/null || true)
MODULE_ROOT="$MODULE_ROOT" STEAM_APP_ID="$STEAM_APP_ID"

if [ -n "$APT_DEPS" ]; then
    dpkg --add-architecture i386 2>/dev/null || true
    apt-get update -qq
    apt-get install -y $APT_DEPS || {
        echo "hint_package_not_found" > "$JOB_DIR/error_hint"
        echo "failed" > "$JOB_DIR/status"
        exit 1
    }
fi

echo "=== Downloading via SteamCMD (App ID: $STEAM_APP_ID) ==="
mkdir -p "$INSTALL_DIR"

VALIDATE_FLAG=""
[ "$VALIDATE" = "validate" ] && VALIDATE_FLAG="validate"

if ! su -s /bin/bash -c "
    steamcmd +force_install_dir '$INSTALL_DIR' \
             +login anonymous \
             +app_update '$STEAM_APP_ID' $VALIDATE_FLAG \
             +quit
" "$UNIX_USER"; then
    echo "hint_steamcmd_login" > "$JOB_DIR/error_hint"
    echo "failed" > "$JOB_DIR/status"
    exit 1
fi

echo "=== Installation complete ==="
echo "ok" > "$JOB_DIR/status"
```

Schreibe nach `src/scripts/steamcmd_install.sh`.

- [ ] **Step 2: Ausführbar + Syntax**

```bash
chmod +x src/scripts/steamcmd_install.sh
bash -n src/scripts/steamcmd_install.sh && echo "Syntax OK"
```

- [ ] **Step 3: Commit**

```bash
git add src/scripts/steamcmd_install.sh
git commit -m "feat: add steamcmd_install.sh for non-LGSM game install"
```

---

### Task 6: steamcmd_control.sh — start/stop/status/update

**Files:**
- Create: `src/scripts/steamcmd_control.sh`

Wrapper der die gleiche Schnittstelle wie LGSM-Scripts imitiert.

- [ ] **Step 1: Script erstellen**

```bash
#!/bin/bash
# steamcmd_control.sh — start/stop/status/update for non-LGSM games
# Usage: steamcmd_control.sh <action> <server_dir> <unix_user> <steam_app_id> [extra_args...]
set -euo pipefail

ACTION="$1"
SERVER_DIR="$2"
UNIX_USER="$3"
STEAM_APP_ID="$4"
shift 4
EXTRA_ARGS="$*"

SERVERFILES="$SERVER_DIR/serverfiles"
PIDFILE="$SERVER_DIR/run.pid"
LOGFILE="$SERVER_DIR/server.log"

_find_binary() {
    find "$SERVERFILES" -maxdepth 3 -type f \( -name "*.x86_64" -o -name "*Server.sh" \) \
        -perm /0111 2>/dev/null | head -1
}

case "$ACTION" in
    start)
        BINARY=$(_find_binary)
        if [ -z "$BINARY" ]; then
            echo "ERROR: No server binary found in $SERVERFILES" >&2
            exit 1
        fi
        su -s /bin/bash -c "
            cd '$SERVER_DIR' &&
            nohup '$BINARY' $EXTRA_ARGS >> '$LOGFILE' 2>&1 &
            echo \$! > '$PIDFILE'
        " "$UNIX_USER"
        echo "Server started (PID $(cat "$PIDFILE" 2>/dev/null || echo unknown))"
        ;;

    stop)
        if [ -f "$PIDFILE" ]; then
            PID=$(cat "$PIDFILE")
            kill "$PID" 2>/dev/null && echo "Server stopped (PID $PID)" || echo "Process not running"
            rm -f "$PIDFILE"
        else
            echo "No PID file — server may not be running"
        fi
        ;;

    status)
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "running"
        else
            echo "stopped"
        fi
        ;;

    update)
        su -s /bin/bash -c "
            steamcmd +force_install_dir '$SERVERFILES' \
                     +login anonymous \
                     +app_update '$STEAM_APP_ID' validate \
                     +quit
        " "$UNIX_USER"
        ;;

    *)
        echo "Unknown action: $ACTION" >&2
        exit 1
        ;;
esac
```

- [ ] **Step 2: Ausführbar + Syntax**

```bash
chmod +x src/scripts/steamcmd_control.sh
bash -n src/scripts/steamcmd_control.sh && echo "Syntax OK"
```

- [ ] **Step 3: Commit**

```bash
git add src/scripts/steamcmd_control.sh
git commit -m "feat: add steamcmd_control.sh for non-LGSM server management"
```

---

### Task 7: manage.cgi — source-basiertes Dispatching

**Files:**
- Modify: `src/manage.cgi`

Zwei Änderungen:
1. `install_game`-Handler: prüft `source` aus Registry → startet `game_action.sh` (LGSM) oder `steamcmd_install.sh` (SteamCMD)
2. Lifecycle-Buttons (Start/Stop/Update): rufen `steamcmd_control.sh` statt LGSM-Script auf wenn `source == steamcmd`

- [ ] **Step 1: `install_game`-Handler anpassen**

Lies `src/manage.cgi` ab dem `install_game`-Block (Zeile ~363). Der Block startet `game_action.sh`. Davor `source` aus Registry lesen und verzweigen:

```perl
elsif ($action eq 'install_game') {
    my $reg   = &get_registered_instance($instance_id) or &error($text{'err_not_found'});
    my $source = $reg->{'source'} // 'lgsm';
    my ($script_path, $script_name, $server_dir) = _parse_script_info($reg);

    our ($config_directory, $module_root);
    my $job_id = &create_job();

    if ($source eq 'steamcmd') {
        my $app_id = $reg->{'steam_app_id'} // '';
        $app_id =~ s/[^0-9]//g;
        &system_logged(
            "MODULE_ROOT=\Q$module_root\E "
            . "nohup bash \Q$module_root/scripts/steamcmd_install.sh\E "
            . "\Q$config_directory/jobs/$job_id\E "
            . "\Q$unix_user\E \Q$server_dir\E \Q$app_id\E "
            . ">/dev/null 2>&1 &"
        );
    } else {
        &system_logged(
            "nohup bash \Q$module_root/scripts/game_action.sh\E "
            . "\Q$config_directory/jobs/$job_id\E "
            . "\Q$unix_user\E \Q$server_dir\E \Q$script_name\E install "
            . ">/dev/null 2>&1 &"
        );
    }
    &redirect("manage.cgi?instance_id=" . &html_escape($instance_id)
        . "&action=poll_job&job=" . &html_escape($job_id)
        . "&next_status=installed");
}
```

Hilfsfunktion `_parse_script_info` am Anfang von manage.cgi ergänzen (oder inline auflösen wenn bereits ähnlich vorhanden):

```perl
sub _parse_script_info {
    my ($reg) = @_;
    my $script_path = $reg->{'script'} // '';
    my $script_name = (split '/', $script_path)[-1] // '';
    (my $server_dir = $script_path) =~ s|/[^/]+$||;
    $script_name =~ s/[^a-zA-Z0-9_-]//g;
    return ($script_path, $script_name, $server_dir);
}
```

- [ ] **Step 2: Update/Validate-Handler — steamcmd-Zweig**

Im `update`-Handler (Zeile ~374 ff.) analog: wenn `source == steamcmd` → `steamcmd_control.sh update` statt LGSM-Script.

Finde den Block:
```perl
elsif ($action eq 'update') {
    my $script_name = (split('/', $inst->{'script'}))[-1];
```

Ersetze den Worker-Aufruf mit:
```perl
elsif ($action eq 'update') {
    my $reg    = &get_registered_instance($instance_id) or &error($text{'err_not_found'});
    my $source = $reg->{'source'} // 'lgsm';
    my ($script_path, $script_name, $server_dir) = _parse_script_info($reg);

    our ($config_directory, $module_root);
    my $job_id = &create_job();

    if ($source eq 'steamcmd') {
        my $app_id = $reg->{'steam_app_id'} // '';
        $app_id =~ s/[^0-9]//g;
        &system_logged(
            "nohup bash \Q$module_root/scripts/steamcmd_control.sh\E update "
            . "\Q$server_dir\E \Q$unix_user\E \Q$app_id\E "
            . ">/dev/null 2>&1 &"
        );
    } else {
        &system_logged(
            "nohup bash \Q$module_root/scripts/game_action.sh\E "
            . "\Q$config_directory/jobs/$job_id\E "
            . "\Q$unix_user\E \Q$server_dir\E \Q$script_name\E update "
            . ">/dev/null 2>&1 &"
        );
    }
    &redirect("manage.cgi?instance_id=" . &html_escape($instance_id)
        . "&action=poll_job&job=" . &html_escape($job_id)
        . "&next_status=installed");
}
```

- [ ] **Step 3: Start/Stop — steamcmd_control aufrufen**

Finde die Start/Stop-Handler in manage.cgi. Wenn `source == steamcmd` → `steamcmd_control.sh start/stop` direkt ausführen (kein Background-Job nötig, da schnell):

```perl
elsif ($action eq 'start' || $action eq 'stop') {
    my $reg    = &get_registered_instance($instance_id) or &error($text{'err_not_found'});
    my $source = $reg->{'source'} // 'lgsm';
    my ($script_path, $script_name, $server_dir) = _parse_script_info($reg);

    if ($source eq 'steamcmd') {
        my $app_id = $reg->{'steam_app_id'} // '';
        $app_id =~ s/[^0-9]//g;
        &system_logged(
            "su -s /bin/bash -c "
            . "'bash \Q$module_root/scripts/steamcmd_control.sh\E $action "
            . "\Q$server_dir\E \Q$unix_user\E \Q$app_id\E' root"
        );
    } else {
        &system_logged(
            "su -s /bin/bash -c './$script_name $action' $unix_user"
        );
    }
    &redirect("manage.cgi?instance_id=" . &html_escape($instance_id));
}
```

- [ ] **Step 4: Perl syntax check**

```bash
perl -c src/manage.cgi
```

Erwartet: `src/manage.cgi syntax OK`

- [ ] **Step 5: verify.sh**

```bash
bash scripts/verify.sh
```

- [ ] **Step 6: Commit**

```bash
git add src/manage.cgi
git commit -m "feat: manage.cgi dispatches install/update/start/stop by source (lgsm|steamcmd)"
```

---

### Task 8: Lang-Strings + Wizard-Erweiterung

**Files:**
- Modify: `src/lang/de`
- Modify: `src/lang/en`

Scout-Runtime-Strings entfernen/anpassen, neue Hints ergänzen.

- [ ] **Step 1: Veraltete Scout-Strings aus lang/de entfernen (falls bereits vorhanden)**

Prüfe ob folgende Strings schon in `src/lang/de` existieren und entferne sie:
```
host_setup_scout_*
setup_libs_scout_hint
hint_scout_missing
```

- [ ] **Step 2: Neue Strings in `src/lang/de` anhängen**

```
hint_apt_deps_title=Fehlende Pakete
hint_apt_deps_desc=Diese Pakete fehlen und müssen manuell installiert werden:
hint_lib_old_version=Sehr alte Library-Version benötigt — nicht in aktuellen Debian-Repos verfügbar. Manuell installieren oder Backports prüfen.
manage_steamcmd_source=Dieser Server wird direkt über SteamCMD verwaltet (kein LinuxGSM).
wizard_source_lgsm=LinuxGSM (empfohlen)
wizard_source_steamcmd=Direkter SteamCMD-Download (für Spiele ohne LGSM-Support)
```

- [ ] **Step 3: Englische Entsprechungen in `src/lang/en`**

```
hint_apt_deps_title=Missing Packages
hint_apt_deps_desc=These packages are missing and need to be installed manually:
hint_lib_old_version=Very old library version required — not available in current Debian repos. Install manually or check backports.
manage_steamcmd_source=This server is managed directly via SteamCMD (no LinuxGSM).
wizard_source_lgsm=LinuxGSM (recommended)
wizard_source_steamcmd=Direct SteamCMD download (for games without LGSM support)
```

- [ ] **Step 4: Prüfen**

```bash
grep -c "hint_apt_deps_title" src/lang/de src/lang/en
```

Erwartet: je 1.

- [ ] **Step 5: Commit**

```bash
git add src/lang/de src/lang/en
git commit -m "feat: add apt-error hint strings; remove Scout-Runtime strings"
```

---

### Task 9: Verifikation + Build

- [ ] **Step 1: Alle Tests**

```bash
perl t/test_error_hints.pl
perl t/test_security_guards.pl
perl t/test_provisioning_flow.pl
```

Alle grün.

- [ ] **Step 2: verify-full**

```bash
bash scripts/verify-full.sh
```

- [ ] **Step 3: Build**

```bash
bash scripts/build.sh
```

Erwartet: `dist/linuxgsm-webcore-*.wbm` ohne Fehler.

---

## Self-Review

**Spec-Abdeckung:**
- ✅ Scout Runtime entfernt (nie implementiert — kein Cleanup nötig)
- ✅ i386 + contrib/non-free in setup_lgsm.sh (Task 1)
- ✅ Fehler-Parsing in game_action.sh → error_hint-Datei (Task 2)
- ✅ Neue Fehlermuster in error_hints.pl (Task 3)
- ✅ Windrose in games_meta.json mit source=steamcmd (Task 4)
- ✅ steamcmd_install.sh für Nicht-LGSM-Games (Task 5)
- ✅ steamcmd_control.sh für start/stop/update (Task 6)
- ✅ manage.cgi dispatcht nach source (Task 7)
- ✅ Lang-Strings angepasst (Task 8)

**Kein `libs_pending`-Status** — Flow bleibt: `fresh → lgsm_ready → installed`

**LGSM handhabt seine eigenen apt-Deps** — wir installieren nur ergänzende Pakete (i386, contrib/non-free) und parsen Fehler wenn LGSM selbst scheitert.
