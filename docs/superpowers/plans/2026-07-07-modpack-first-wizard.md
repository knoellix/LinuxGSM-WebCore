# Modpack-first (versionslose Suche im Wizard)

Datum: 2026-07-07
Status: in Umsetzung

## Ziel

Beim Anlegen eines modded Minecraft-Servers soll man **optional** ein Modpack
suchen können, **bevor** MC-Version und Loader festgelegt sind. Nach Auswahl
werden Loader + MC-Version aus dem Modpack **vorausgefüllt** (editierbar) und das
Pack nach der Provisionierung **automatisch importiert**.

Entscheidungen (mit User abgestimmt):
- Platzierung: **inline, optional aufklappbar** im bestehenden Schritt 35
  (Loader/Version-Wahl) — kein extra Wizard-Schritt.
- Nach Auswahl: Felder **editierbar** vorausgefüllt (nicht gesperrt).
- **Auto-Import** nach Anlegen als Job.
- CurseForge Auto-Fortsetzen: Standard **AN** (separat, bereits erledigt).

## Woher kommt die Versionsinfo

Das Modpack ist selbstbeschreibend:
- Modrinth-Suchtreffer: `versions` (MC-Liste) + `categories`/`display_categories`
  (enthält Loader).
- CurseForge `latestFiles[]`: `gameVersions`/`sortableGameVersions` (MC + Loader-Name)
  + `modLoaders`.

Die Open-Suche schreibt MC-Version + Loader (interne ID) direkt in jeden Treffer,
damit „Übernehmen" ohne zweiten Netzwerk-Resolve auskommt.

## Bausteine

### 1. `src/lib/mc_loader.pl`
- `mc_loader_id_from_name($name)` — mappt `forge|fabric|neoforge|quilt` (case-insensitive)
  auf interne Loader-ID. Nur `forge|fabric|neoforge` sind modded-unterstützt.

### 2. `src/lib/mc_modpack.pl`
- `_modpack_open_hit_from_curseforge_mod($mod)` — pur: baut Treffer mit
  `source, project_id, file_id, title, downloads, pack_mc, loader, loader_label`
  aus `latestFiles` (neueste nicht-server Datei).
- `_modpack_open_hit_from_modrinth($hit)` — pur: baut Treffer aus Modrinth-Suchhit
  (`versions`, `categories`).
- `mc_modpack_search_open($query)` — versionslose Suche (Modrinth + CF, ohne
  gameVersion/modLoaderType-Filter), liefert `{ ok, results=>[...], errors=>[] }`.
  Nur Treffer mit erkanntem, unterstütztem Loader + MC-Version.

### 3. `src/wizard.cgi`
- Schritt-35-Handler: bei `mc_pack_search` oder `pack_apply` immer Formular
  rendern (nicht vorrücken).
- `_step35_mc_form`: 
  - Prefill von `mc_loader`/`mc_version` aus `$in` (wenn Pack übernommen).
  - Optionaler aufklappbarer Bereich mit Such-Textfeld + Button (POST step=35,
    Flag `mc_pack_search=1`, ctx erhalten).
  - Bei vorhandener Suche: Ergebnisse mit „Übernehmen"-Buttons (POST step=35,
    setzt `mc_loader`/`mc_version` + Pack-Hiddens + `pack_apply=1`).
  - Hinweis „aus Modpack übernommen: <Titel>" wenn Pack aktiv.
- `_wizard_print_provision_hiddens`: trägt Pack-Hiddens
  (`pack_source, pack_project_id, pack_file_id, pack_version_id, pack_title,
  pack_import`) durch alle Schritte, wenn in `$in` vorhanden.
- Schritt 5: nach `write_mc_profile` + `register_instance`, falls
  `pack_import=1` + IDs vorhanden → Redirect auf
  `manage.cgi?instance_id=...&action=modpack_import_remote&pack_*...&xnavigation=1`
  (bestehender Dispatch, läuft auch per GET). Sonst wie bisher.

### 4. Lang de/en
- `wizard_mc_pack_section`, `wizard_mc_pack_search_btn`, `wizard_mc_pack_apply_btn`,
  `wizard_mc_pack_hint`, `wizard_mc_pack_applied`, `wizard_mc_pack_none`,
  `wizard_mc_pack_col_pack`, `wizard_mc_pack_col_target`.

### 5. Tests
- `mc_loader_id_from_name` Mapping.
- `_modpack_open_hit_from_curseforge_mod` (ATM10 NeoForge 1.21.1) — Loader/MC korrekt.
- `_modpack_open_hit_from_modrinth` (synthetischer Hit) — Loader/MC korrekt.

## Erweiterung: Manifest = Source of Truth + Import orchestriert Java/Loader

Problem: die gepinnte `loader_version` (und autoritativ `mc_version`) steht erst
im Manifest, das erst nach dem Download vorliegt. Der Loader darf daher nicht
vor dem Modpack installiert werden. Der Import-Job orchestriert die Reihenfolge.

Gated über einen **Adopt-Modus** (`adopt_profile` im pack_meta.json), gesetzt nur
im Wizard-Modpack-first-Pfad (`pack_adopt=1` im Redirect). Bestehende Flows
(manueller Import auf fertiger Instanz) bleiben komplett unverändert.

- `expand_remote_modpack_job_meta`:
  - speichert `pack_loader`, `pack_loader_version`, `pack_mc_version` ins Meta.
  - im Adopt-Modus: `loader_mismatch`/`version_mismatch` sind **kein** harter
    Fehler (die Pack-Werte werden übernommen).
- `modpack_adopt_profile_from_meta($job_dir,$server_dir,$user)`: baut Profil aus
  Pack-Werten neu (`build_mc_profile` → lgsm_script/mod_dir/java_major), erhält
  EULA/Java-Felder, schreibt via `write_mc_profile`.
- Install-Skripte `mc_java_install.sh` / `mc_loader_install.sh`: neuer
  `WEBCORE_SUBSTEP=1`-Guard → kein `job_log_init`, kein `set_final_status`
  (Aufruf als Unter-Schritt innerhalb eines anderen Jobs). Default unverändert.
- Modpack-Worker `mc_modpack_install_user.sh` (läuft als Game-User): bei
  `adopt_profile`:
  1. Profil adоptieren (Pack-Werte).
  2. `WEBCORE_SUBSTEP=1 mc_java_install.sh` (falls Java fehlt).
  3. `WEBCORE_SUBSTEP=1 mc_loader_install.sh` (gepinnte Version aus Profil).
  4. Mods entpacken.
  Ein Job, ein Status (vom Worker final geschrieben), ein Live-Log.
- Wizard modpack-first: Provision + provisorisches Profil (Loader aus Treffer),
  Auto-Import mit `pack_adopt=1` als erster Schritt; Java/Loader macht der Import.

## Sicherheit / Erfolgsfeedback
- Pack-IDs werden bei Redirect-Bau in Schritt 5 sanitisiert (source `[a-z]`,
  CF project/file `\d`, modrinth ids `[a-z0-9_-]`).
- Kein blindes Erfolgs-Feedback: Auto-Import läuft über bestehenden Job-Flow
  (`job_live.cgi`, Status aus `$JOB_DIR/status`).
- Rein additiv: ohne Modpack-Auswahl bleibt der Flow unverändert.
