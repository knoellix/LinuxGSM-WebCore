# Library Management — Design-Spec

**Datum:** 2026-04-22
**Status:** Genehmigt

## Ziel

Game-Server scheitern häufig beim Start wegen fehlender Shared Libraries (vor allem 32-Bit Source-Engine-Libs). Dieses Feature löst das Problem durch:

1. **Host-Vorbereitung** — einmalige Admin-Aktion: i386-Architektur, Paketquellen, Valve Scout Runtime (~300 MB) nach `/opt/steam-runtime/`
2. **Automatische Lib-Auflösung** — nach jedem Game-Install: `ldd`-Scan der Binaries, Symlinks aus Scout Runtime, rekursive Abhängigkeitsprüfung, apt-Fallback, `LD_LIBRARY_PATH` in LGSM-Config

---

## Architektur-Übersicht

```
/opt/steam-runtime/          ← systemweit, root-owned
  lib_index.json             ← { "libname.so.1": "/opt/steam-runtime/.../libname.so.1" }
  steamcmd -> /usr/games/steamcmd   ← Symlink für spätere Integration
  ...kompilierte .so-Dateien...

/home/{unix_user}/.shared_libs/    ← pro Unix-User, Symlinks auf Scout Runtime
  libgcc_s.so.1 -> /opt/steam-runtime/.../libgcc_s.so.1
  ...

LGSM-Config ($script.cfg):
  LD_LIBRARY_PATH="/home/{user}/.shared_libs:${LD_LIBRARY_PATH}"
```

**Installationsfluss (manage.cgi Setup-Phase):**

```
fresh
  → [LGSM + Deps installieren]
lgsm_ready
  → [Game-Server installieren]
libs_pending                  ← NEU
  → [Libs auflösen]
installed
  → normale manage.cgi-Ansicht
```

Solange der Status nicht `installed` ist, zeigt manage.cgi ausschließlich die Setup-Phase. Kein Zugriff auf Start/Stop/Config-Editor.

---

## Subsystem 1: Host-Setup-Seite (`host_setup.cgi`)

Analog zu `steam_settings.cgi` — vier Status-Checks mit Fix-Buttons, kein Wizard. Erreichbar über einen Button auf `index.cgi` (neben dem Steam-Button).

### Checks

| Check | Gut-Kriterium | Fix-Aktion |
|---|---|---|
| i386-Architektur | `dpkg --print-foreign-architectures` enthält `i386` | `dpkg --add-architecture i386 && apt-get update` |
| contrib/non-free Repos | `/etc/apt/sources.list` enthält `contrib` und `non-free` (nicht nur `non-free-firmware`) | Zeile patchen + `apt-get update` |
| Scout Runtime | `/opt/steam-runtime/lib_index.json` vorhanden | Background-Job: `download_scout.sh` |
| steamcmd Symlink | `/opt/steam-runtime/steamcmd` ist Symlink auf `/usr/games/steamcmd` | `ln -sf /usr/games/steamcmd /opt/steam-runtime/steamcmd` |

### Scout-Runtime-Download (`src/scripts/download_scout.sh`)

Läuft als Background-Job (Job-System aus `jobs.pl`), Output live in manage-ähnlichem Polling:

```bash
mkdir -p /opt/steam-runtime
cd /opt/steam-runtime
TARBALL="com.valvesoftware.SteamRuntime.Sdk-amd64,i386-scout-sysroot.tar.gz"
wget "https://repo.steampowered.com/steamrt-images-scout/snapshots/latest-steam-client-general-availability/${TARBALL}"
tar -xf "${TARBALL}"
# Index bauen
find /opt/steam-runtime -name "*.so*" -not -type d | perl -e '
  use JSON::PP;
  my %idx;
  while(<STDIN>){ chomp; my $f=(split "/",$_)[-1]; $idx{$f}=$_; }
  print encode_json(\%idx);
' > /opt/steam-runtime/lib_index.json
```

---

## Subsystem 2: Lib-Resolver

### Neuer Instance-Status `libs_pending`

`src/lib/instance.pl`: erlaubte Status-Werte werden um `libs_pending` erweitert.

TSV-Spalte 8 (`instance_status`) Werte: `fresh | lgsm_ready | libs_pending | installed`

Backward-Kompatibilität: kein Wert in Spalte 8 → `installed` (unverändert).

### Integration in `game_action.sh`

Nach erfolgreichem `./script install` schreibt `game_action.sh` `libs_pending` in `$JOB_DIR/next_status`, damit `poll_job` den Instanz-Status korrekt setzt. Dann startet ein zweiter Job für den Lib-Resolver:

```bash
# game_action.sh (ACTION=install) nach Erfolg:
echo "libs_pending" > "$JOB_DIR/next_status"
echo "ok" > "$JOB_DIR/status"
# manage.cgi poll_job setzt instance_status=libs_pending, zeigt Setup-Phase mit Lib-Button
```

`resolve_libs.sh` läuft als eigener Background-Job (eigene Job-ID), gestartet aus manage.cgi wenn `action=resolve_libs`. Dieser Job setzt `next_status=installed`.

### `src/scripts/resolve_libs.sh`

Läuft als **root** (nötig für Symlinks in Home-Verzeichnis des Unix-Users):

```
Argumente: JOB_DIR UNIX_USER SERVER_DIR GAME_SCRIPT

1. Prüfe /opt/steam-runtime/lib_index.json — wenn nicht vorhanden:
   → Fehler + Hinweis auf host_setup.cgi → exit 1

2. mkdir -p /home/$UNIX_USER/.shared_libs/

3. Finde alle ausführbaren Binaries + .so-Dateien in $SERVER_DIR/serverfiles/
   (find ... -type f \( -executable -o -name "*.so*" \))

4. Für jede Binary: ldd → parse "libname => not found" Zeilen

5. Für jede fehlende Lib:
   a. In lib_index.json suchen (jq oder Perl JSON::PP)
   b. Wenn gefunden → ln -sf {runtime_path} /home/$UNIX_USER/.shared_libs/
   c. Dann: ldd auf die neu verlinkte Lib → rekursiv (max. Tiefe 5)
   d. Fallback: Lookup in lib_package_map.json → apt-get install -y {paket}
   e. Wenn beides schlägt fehl → in $JOB_DIR/lib_errors anhängen

6. chown -h $UNIX_USER:$UNIX_USER /home/$UNIX_USER/.shared_libs/*

7. Wenn .shared_libs nicht leer:
   → LD_LIBRARY_PATH in LGSM-Config schreiben (via Perl lib_resolver.pl)

8. Wenn $JOB_DIR/lib_errors nicht leer:
   → In $JOB_DIR/error_hint: "hint_lib_not_found"
   → Status: failed

9. Sonst: Status: ok
```

### `src/lib/lib_resolver.pl`

Perl-Library für manage.cgi und resolve_libs.sh:

```perl
# Schreibt LD_LIBRARY_PATH in LGSM-Instanz-Config
sub write_ld_library_path($instance_id)

# Prüft ob .shared_libs vorhanden und nicht leer
sub get_lib_status($instance_id)   # 'ok' | 'empty' | 'missing'

# Baut/aktualisiert /opt/steam-runtime/lib_index.json
sub build_runtime_index()

# Liest lib_package_map.json
sub get_apt_package_for_lib($libname)  # returns apt-Paketname oder undef
```

### `src/lib/lib_package_map.json`

Übersetzungstabelle: `.so`-Dateiname → apt-Paketname. Initiale Einträge für bekannte Source-Engine-Abhängigkeiten:

```json
{
  "libgcc_s.so.1":     "lib32gcc-s1",
  "libstdc++.so.6":    "lib32stdc++6",
  "libsdl2-2.0.so.0":  "libsdl2-2.0-0:i386",
  "libcurl.so.4":      "libcurl4:i386",
  "libssl.so.1.0.0":   "libssl1.0.0",
  "libtcmalloc_minimal.so.4": "libgoogle-perftools4:i386"
}
```

---

## manage.cgi — Setup-Phase Erweiterung

Dritter Button wenn `instance_status = libs_pending`:

```
[✅ LGSM installiert]
[✅ Game-Server installiert]
[Libs auflösen] ← btn-primary → action=resolve_libs → Background-Job → poll_job
```

Nach Erfolg → `set_instance_status($id, 'installed')` → normale Ansicht.

Nach Fehler → `job_failed` + `lib_errors`-Inhalt anzeigen + "Erneut versuchen"-Button.

Hinweis wenn Scout Runtime fehlt: direkt Link auf `host_setup.cgi`.

---

## Neue/geänderte Dateien

| Datei | Status | Zweck |
|---|---|---|
| `src/host_setup.cgi` | NEU | Host-Setup-Seite |
| `src/scripts/download_scout.sh` | NEU | Scout Runtime laden + Index bauen |
| `src/scripts/resolve_libs.sh` | NEU | ldd-Scan + Symlinks + LD_LIBRARY_PATH |
| `src/lib/lib_resolver.pl` | NEU | Perl-Hilfsfunktionen |
| `src/lib/lib_package_map.json` | NEU | .so → apt-Paket Übersetzungstabelle |
| `src/lib/instance.pl` | Modify | `libs_pending` Status-Wert |
| `src/scripts/game_action.sh` | Modify | resolve_libs.sh nach install aufrufen |
| `src/manage.cgi` | Modify | Dritter Setup-Phase-Button |
| `src/index.cgi` | Modify | Link auf host_setup.cgi |
| `src/lang/de` + `src/lang/en` | Modify | Neue Strings |

---

## Sicherheits-Checkliste

- [ ] `resolve_libs.sh` läuft als root — kein User-Input darf in Shell-Befehle fließen; alle Pfade aus Registry gelesen
- [ ] Symlinks zeigen nur auf `/opt/steam-runtime/` — Path-Traversal-Check vor `ln -sf`
- [ ] Rekursionstiefe auf 5 begrenzt — kein infinite loop bei zirkulären Abhängigkeiten
- [ ] Scout-Runtime-Download läuft als Background-Job — kein CGI-Timeout
- [ ] `lib_index.json` wird nur von root geschrieben, von Usern nur gelesen
- [ ] `LD_LIBRARY_PATH` in LGSM-Config via `validate_config_target()` abgesichert
- [ ] apt-Fallback nur für Pakete die in `lib_package_map.json` whitelisted sind

---

## Nicht im Scope

- Automatisches Scout-Runtime-Update
- Lib-Status nachträglich in manage.cgi anzeigen (einmalig beim Install ausreichend)
- Windows-Game-Server
- Container-Mode der Steam Runtime (nur LD_LIBRARY_PATH-Modus)
- Mehrere Scout-Runtime-Versionen parallel
