# Linux-Game-Server-Dependency-Hell — Design-Spec

**Datum:** 2026-04-23
**Status:** Genehmigt

## Ziel

Automatisiertes Build-System für Shared-Library-Pakete pro LinuxGSM-Game-Server. Statt jede Lib manuell auf dem Ziel-Host zu verwalten, werden Pakete zentral auf GitHub gebaut und vom WebMin-Plugin (`LinuxGSM-WebCore`) bei Bedarf heruntergeladen.

---

## Repository-Struktur

```
Linux-Game-Server-Dependency-Hell/
├── games.yml                        ← Source-of-Truth: alle unterstützten Games
├── index.json                       ← generiert aus games.yml, vom WebMin-Plugin gelesen
├── .github/
│   ├── ISSUE_TEMPLATE/
│   │   └── game-request.yml         ← Issue-Template: Steam App ID + optionale Platform
│   └── workflows/
│       ├── build-game.yml           ← Haupt-Build: Docker debian:bookworm + ldd-Scan
│       ├── build-all.yml            ← Nacht-Rebuild aller Games (cron)
│       ├── issue-handler.yml        ← Issue → Steam API → games.yml PR + Build
│       └── gen-index.yml            ← games.yml → index.json nach jedem Merge
└── scripts/
    ├── build_game.sh                ← ldd-Scan + Paket bauen (läuft in Docker)
    ├── detect_engine.sh             ← Engine-Erkennung via Binary + Steam API
    └── gen_index.py                 ← games.yml → index.json generieren
```

---

## games.yml — Datenformat

```yaml
games:
  - id: csgoserver
    steam_app_id: 740
    lgsm_script: csgoserver
    engine: source          # source | unity | unreal | goldsrc | other
    platform: linux/amd64
    login_required: false
    added: 2026-04-23
```

**Felder:**
- `id` — eindeutiger Bezeichner = LinuxGSM-Script-Name
- `steam_app_id` — Steam App ID (Pflicht für Lookup + Build)
- `engine` — Engine/Plattform (auto-erkannt wenn möglich, sonst manuell)
- `login_required` — `true` = derzeit nicht automatisch baubar

---

## index.json — Datenformat (generiert)

```json
{
  "csgoserver": {
    "engine": "source",
    "steam_app_id": 740,
    "libs_url": "https://github.com/knoellix/Linux-Game-Server-Dependency-Hell/releases/download/csgoserver-20260423/libs.tar.gz",
    "apt_hints_url": "https://github.com/knoellix/Linux-Game-Server-Dependency-Hell/releases/download/csgoserver-20260423/apt-hints.json",
    "built_at": "2026-04-23T12:00:00Z"
  }
}
```

---

## Subsystem 1: Build-Workflow (`build-game.yml`)

**Trigger:** `workflow_dispatch` mit Input `game_id` (= LinuxGSM-Script-Name)

**Läuft in:** Docker `debian:bookworm` auf GitHub-hosted Runner

**Ablauf:**

```
1. i386-Architektur aktivieren + apt-get update
2. SteamCMD installieren (aus contrib/non-free)
3. Scout Runtime herunterladen → /opt/steam-runtime/ (gecacht als Docker-Layer)
4. LGSM + game_id-Script installieren (anonym via SteamCMD)
5. scripts/build_game.sh:
   a. find serverfiles/ -type f \( -executable -o -name "*.so*" \)
   b. ldd auf jede Binary → "not found"-Zeilen sammeln
   c. Scout Runtime lib_index.json durchsuchen → .so-Dateien → libs/
   d. Nicht gefunden in Scout → apt-hints.json (bekannte Paketnamen)
   e. tar.gz bauen: libs/ + apt-hints.json + manifest.json
6. GitHub Release erstellen (Tag: {game_id}-{YYYYMMDD})
7. Release-Assets hochladen: libs.tar.gz + apt-hints.json
8. gen-index.yml triggern → index.json aktualisieren + committen
```

**Paket-Inhalt (libs.tar.gz):**
```
libs/
  libgcc_s.so.1        ← symlink-Ziel aus Scout Runtime
  libstdc++.so.6
  ...
apt-hints.json         ← ["lib32gcc-s1", "libsdl2-2.0-0:i386"]
manifest.json          ← {game, engine, built_at, lib_count}
```

**Nacht-Rebuild (`build-all.yml`):** Cron `0 3 * * 0` (wöchentlich sonntags) — alle Games aus `games.yml` mit `login_required: false` neu bauen.

---

## Subsystem 2: Issue-Handler (`issue-handler.yml`)

**Trigger:** `issues: [opened, labeled]` — Label `game-request`

**Issue-Template Felder:**
- `steam_app_id` — Pflichtfeld (Zahl)
- `engine` — Optional: `source` / `unity` / `unreal` / `goldsrc` / leer

**Workflow-Ablauf:**

```
1. Steam API: store.steampowered.com/api/appdetails?appids={steam_app_id}
   → Spiel-Name + Linux-Plattform-Support prüfen
   → Kein Linux: Issue-Kommentar "Linux nicht unterstützt" + close

2. Engine auto-erkennen (wenn nicht im Issue angegeben):
   → Steam Store Categories/Tags ("Source Engine", "Unity" etc.)
   → Nicht erkannt + nicht angegeben → Kommentar "bitte Engine angeben" + Label "needs-info" + stop

3. LGSM-Script-Name ermitteln:
   → GameServerManagers/LinuxGSM Repo: lgsm/config-lgsm/common/common.cfg oder Games-Liste
   → Nicht gefunden → Kommentar "kein LGSM-Script bekannt" + Label "needs-info" + stop

4. Login prüfen:
   → Wenn login_required erkannt → Kommentar "Steam-Login nötig — derzeit nicht automatisch baubar" + Label "login-required" + stop

5. PR erstellen: games.yml + neuer Eintrag
   → PR-Titel: "Add game: {name} ({steam_app_id})"
   → Issue-Kommentar: "PR erstellt: #XY — Build startet nach Merge"

6. Bei PR-Merge: build-game.yml automatisch getriggert
   → Build-Ergebnis als Kommentar im Original-Issue posten
   → Issue schließen bei Erfolg
```

---

## Subsystem 3: WebMin-Plugin-Integration (`LinuxGSM-WebCore`)

**Neue Datei:** `src/lib/lib_registry.pl`

**Ablauf im Plugin (nach Game-Install, Status `libs_pending`):**

```
1. index.json laden:
   GET https://raw.githubusercontent.com/knoellix/
       Linux-Game-Server-Dependency-Hell/main/index.json
   → Cachen in $config_directory/lib_index_cache.json (TTL: 24h)

2. Eintrag für LGSM-Script-Name suchen:
   → Nicht gefunden → Warnung + Link zum Issue-Template
   → Gefunden → weiter

3. libs.tar.gz herunterladen → /tmp/lgsm-libs-{game_id}.tar.gz
   → Entpacken: libs/*.so* → /home/{unix_user}/.shared_libs/
   → chown -h {unix_user}:{unix_user} .shared_libs/*

4. apt-hints.json lesen:
   → Pro Paket: apt-get install -y {paket} (als root im Background-Job)

5. LD_LIBRARY_PATH in LGSM-Config schreiben ($script.cfg)

6. Status → installed
```

**Was entfällt gegenüber dem alten Plan (`2026-04-22-lib-management.md`):**
- `host_setup.cgi` (Scout Runtime Download) — nicht mehr nötig
- `src/scripts/download_scout.sh` — nicht mehr nötig
- `src/scripts/resolve_libs.sh` — ersetzt durch Download-Ansatz
- `src/lib/lib_resolver.pl` — großteils ersetzt durch `lib_registry.pl`
- `src/lib/lib_package_map.json` — in der GitHub-Repo, nicht im Plugin

**Was bleibt:**
- `libs_pending` Status-Flow in `manage.cgi`
- `install_game` → `next_status=libs_pending`
- Setup-Phase-Block für `libs_pending`
- Lang-Strings (angepasst)

---

## Sicherheits-Checkliste

- [ ] `libs.tar.gz` enthält nur `.so`-Dateien — kein ausführbarer Code, keine Skripte
- [ ] Download via HTTPS, SHA256-Prüfung gegen `manifest.json`
- [ ] Symlinks im Tarball werden nicht entpackt (tar `--no-same-owner`, kein `-h`)
- [ ] Path-Traversal: Entpacken nur nach `.shared_libs/` — kein `../`-Escape möglich
- [ ] apt-Pakete nur aus `apt-hints.json` — keine freie Paketnamen-Eingabe vom User
- [ ] Issue-Handler: Steam App ID wird als Integer validiert — kein Injection-Risiko

---

## Nicht im Scope (jetzt)

- Login-pflichtige Games (Steam Guard)
- Mehrere Distro-Targets (nur Debian Bookworm)
- Windows Game Server
- Automatisches Scout-Runtime-Update im CI
- LinuxGSM umbiegen für Steam-App-ID-basierte Steuerung
- Unity/Unreal Server (Struktur ähnlich, aber separate Spezifikation)

---

## Zwei Repos / Zwei Pläne

| Repo | Plan |
|------|------|
| `Linux-Game-Server-Dependency-Hell` | Neuer Plan: CI, Issue-Handler, Build-Scripts, games.yml |
| `LinuxGSM-WebCore` | Bestehender Plan `2026-04-22-lib-management.md` → stark vereinfacht: nur `lib_registry.pl` + manage.cgi-Änderungen |
