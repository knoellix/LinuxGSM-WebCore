# Übersicht Instanz- und Mods-Seite: Collapsibles + Upgrade-Check-Kette

> **Status:** Entwurf (noch nicht implementiert)
> **Anlass:** 2026-09-02 — `manage.cgi` und `mods.cgi` sind lange Einzelspalten aus `<h4>`-Blöcken. Nur der Config-Editor ist einklappbar, alles andere (Loader-/MC-Upgrade, Modpack-Import, Upload, FTP-Pfad, Mod-Kompatibilität) steht permanent offen. Die Mod-Kompatibilität prüft außerdem nur die MC-Version, nicht den Loader.
> **Betroffen:** `src/manage.cgi`, `src/mods.cgi`, `src/lib/mc_upgrade.pl`, `src/lib/core.pl` (neuer UI-Helper), `src/lang/de` + `src/lang/en`, `t/test_mc_upgrade.pl` (+ neue Tests)

## Ziele

1. **Einklappbare Abschnitte** auf beiden Seiten, mit sinnvollem Default (offen/zu) und stabilen Anker-IDs.
2. **Upgrade-Check als logische Kette**: Ziel wählen → Gegendimension prüfen → erst dann Mods prüfen.
   - MC-Ziel prüfen ⇒ zuerst „gibt es einen Loader-Build für dieses MC?“, danach Mods.
   - Loader-Ziel prüfen ⇒ zuerst „passt der Build zur MC-Linie des Profils?“, danach Mods.
3. **Mod-Kompatibilität nach oben** (über „Modpack importieren“), weil sie zur Upgrade-Planung gehört, nicht zum Import.
4. **Keine Netzwerk-Calls beim Seitenaufbau** für zugeklappte Blöcke (heute holt `manage.cgi` bei jedem Aufruf Loader-Versionslisten übers Netz).
5. Reihenfolge und Bedienlogik zwischen `manage.cgi` und `mods.cgi` vereinheitlichen.

## Nicht-Ziele

- Kein automatisches Mod-Update beim MC-/Loader-Bump (bleibt manuell).
- Kein Loader-Family-Wechsel (Forge ↔ NeoForge ↔ Fabric).
- Kein neues CSS/Theming, keine harten Farben — nur `ui_*` und Webmin-Klassen.
- Keine Tabs/SPA-Umbauten; `<details>`/`<summary>` bleibt das Mittel (funktioniert ohne JS).

## Ist-Zustand

### `manage.cgi` (Hauptseite, L2505–L3364)

| Reihenfolge | Block | Zustand |
|---|---|---|
| 1 | Flash-/Job-Banner | immer offen (korrekt) |
| 2 | Instanz-Infotabelle (Spiel, MC-Profil, Ports, Connect, Status, RAM/Spieler, Script-Pfad) | immer offen, wird lang |
| 3 | Setup-Checkliste (MC) | bedingt |
| 4 | Firewall-Status | immer offen |
| 5 | Monitor + geplanter Neustart | immer offen |
| 6 | Steuerung (Start/Stop/Restart) | immer offen (soll so bleiben) |
| 7 | Wartung (Update/Validate/Log/Reinstall) | immer offen |
| 8 | Mods-Seiten-Link | bedingt `mc_mod_ui_ready` |
| 9 | Instanz löschen | Admin |
| 10 | FTP | immer offen |
| 11 | Steam-Account | immer offen |
| 12 | Health-Warnungen / Migrate / Quick-Fix | bedingt |
| 13 | **Config-Editor** | `<details>` (einziges Collapsible) |
| 14 | **Loader-Upgrade** | immer offen, **Netzwerk beim Rendern** |
| 15 | **MC-Version-Upgrade** | immer offen, **Netzwerk beim Rendern** |
| 16 | Jobs-Tabelle | nicht readonly |

**Befund A (Performance):** `_manage_render_mc_loader_upgrade_block` ruft `mc_fetch_loader_versions()`, `_manage_render_mc_version_upgrade_block` ruft `mc_list_mc_versions()` — beide **vor** der Entscheidung, ob überhaupt etwas angezeigt wird. Jeder Seitenaufruf einer Modded-MC-Instanz macht damit HTTP-Requests zu Maven/Mojang.

**Befund B (Logik):** `mc_upgrade_mc_loader_supports()` prüft nur, ob die Ziel-MC-Version in der Wizard-Liste steht — **nicht**, ob der Loader dafür Builds hat. Ein MC-Upgrade kann daher als „gültig“ angeboten werden, obwohl der Loader-Installer später im Worker scheitert (`ERROR: loader install sub-step failed`).

### `mods.cgi` (aktuelle Reihenfolge)

1. Kopf (Instanz, Status, Monitor) + Start/Stop/Log/Zurück
2. Jobs-Tabelle
3. `<h4>` **Modpack importieren** (nur Beschreibung + Auto-Resume-Hinweis)
4. `<h4>` **Modpack-Suche** (+ Trefferliste)
5. `<h4>` **Browser-Upload**
6. `<h4>` **Eigene Datei (FTP/SFTP)**
7. Resume-UI (bedingt)
8. `<h4>` **Mods / Plugins** (Suche + Trefferliste)
9. `<h4>` **Mod-Kompatibilität (MC-Upgrade)** ← zu weit unten
10. `<h4>` **Installierte Mods** (Filter, Liste, Paginierung)

**Befund C (Struktur):** Punkt 3 ist eine reine Überschrift ohne eigenen Inhalt; 4–7 sind faktisch Unterabschnitte davon, stehen aber auf gleicher Ebene.

**Befund D (Root-Writes):** `_mc_upgrade_compat_cache_path()` schreibt `$SERVER_DIR/.webcore/mc_compat_<mc>.json` aus dem Root-CGI heraus → root-eigene Dateien/Verzeichnis im Spieldaten-Ordner. Verstößt gegen die Invariante aus `security-isolation.mdc` („keine Root-Writes auf Spieldaten zur Laufzeit“).

## Kernentscheidungen

| # | Entscheidung | Begründung |
|---|---|---|
| D1 | Ein gemeinsamer Helper `ui_collapsible_start(...)` / `ui_collapsible_end()` in `src/lib/core.pl` | Regel „nur `ui_*` für UI“; Config-Editor-Rohcode wird darauf migriert |
| D2 | Default-Zustand pro Abschnitt fest im Code, plus Auto-Open über URL-Parameter/Anker | wie heute beim Config-Editor (`config_file` ⇒ `open`); deep-linkbar, kein Serverstate |
| D3 | Zugeklappte Blöcke rendern nur die Hülle, **keine** API-Abfragen | behebt Befund A; teure Listen erst nach Klick bzw. aus Cache |
| D4 | Versionslisten-Cache (Loader-Builds, MC-Liste) unter `$module_config_directory/version_cache/`, TTL 1 h | Root-Verzeichnis, keine Spieldaten (behebt Befund D für den neuen Cache) |
| D5 | Compat-Cache-Key wird `<loader>_<mc>`, Ablage nach `$module_config_directory/compat_cache/<instance>_...` | Loader-Familie ist Teil des Ergebnisses; behebt Befund D für den bestehenden Cache |
| D6 | Mods-Schritt läuft **nur**, wenn MC- und Loader-Schritt grün sind; sonst Status „nicht geprüft“ (neutral, nicht grün) | `no-blind-success-feedback.mdc`: Unknown = not OK; spart außerdem API-Quota |
| D7 | Loader-**Build**-Nummer filtert Mods nicht | Modrinth/CurseForge kennen nur Loader-*Familie* + MC-Version. Ein reiner Build-Bump (26.1.2.95 → 26.1.2.99) kann das Mod-Ergebnis nicht ändern — der Loader-Schritt ist Verfügbarkeits-/Linien-Prüfung, kein Mod-Filter. Muss im UI-Text ehrlich stehen, sonst suggeriert die Kette eine Prüftiefe, die die APIs nicht liefern |

## Phase 1 — UI-Helper für Collapsibles

`src/lib/core.pl`:

```perl
# ui_collapsible_start($title, %opts)
#   open  => 1|0        default-Zustand
#   id    => 'anchor'   stabile Anker-ID (Deep-Links, Tests)
#   badge => 'Text'     kurzer Zusatz im <summary> (z. B. Anzahl/Ziel)
#   hint  => 'Text'     Absatz direkt unter dem <summary>
sub ui_collapsible_start { ... }
sub ui_collapsible_end   { return "</details>\n"; }
```

- Titel/Badge/Hint werden mit `html_escape()` ausgegeben, `id` auf `[a-z0-9_-]` reduziert.
- Kein `style=`, keine Farben; `<summary><b>…</b></summary>` wie beim Config-Editor.
- Config-Editor (`manage.cgi` L3109/L3349) auf den Helper umstellen — Verhalten identisch (`open`, wenn `config_file` gesetzt).

Optionales Add-on (getrennt entscheiden): kleiner JS-Snippet, das den Auf-/Zuklapp-Zustand pro `id` in `localStorage` merkt. Kein Serverstate, kein Cookie; ohne JS bleibt der Code-Default.

## Phase 2 — `manage.cgi`: Upgrade-Blöcke einklappbar + ohne Netzwerk

1. Beide Upgrade-Renderer bekommen eine **billige Vorprüfung** (Profil, `mc_loader_is_modded`, `mc_mod_ui_ready`, ACL) und rendern danach *immer* die Collapsible-Hülle.
2. Kandidatenlisten kommen aus dem Versions-Cache (D4):
   - Cache frisch ⇒ Select + Badge („2 neuere Builds“, „Ziel 26.2 verfügbar“) direkt rendern.
   - Cache leer/alt ⇒ zugeklappt mit Button **„Versionen laden“** (`GET action=upgrade_versions&dim=loader|mc`), der Cache füllt und mit `#anchor` + `open` zurückspringt.
3. Beide Blöcke in einen gemeinsamen Abschnitt **„Upgrades“** gruppieren (`id=upgrades`), darin je ein Unter-Collapsible `Loader-Build` und `Minecraft-Version`, Default zu.
4. Position: direkt **nach** Wartung/Steuerung, **vor** FTP/Steam/Config-Editor — Upgrades sind Betriebsthema, nicht Anhang. (Heute stehen sie hinter dem Config-Editor, weil sie dort mal versehentlich *innerhalb* lagen.)
5. Der bestehende Link „Mod-Kompatibilität auf der Mods-Seite prüfen“ wird zu einem Deep-Link mit `check_mode` + Ziel + `#upgrade-check`.

## Phase 3 — `mods.cgi`: Reihenfolge und Collapsibles

Neue Reihenfolge:

| # | Abschnitt | Default | Anker |
|---|---|---|---|
| 1 | Kopf: Instanz, Status, Monitor, Start/Stop/Log/Zurück | offen (kein Collapsible) | — |
| 2 | Jobs | offen, wenn laufender Job, sonst zu | `jobs` |
| 3 | **Upgrade-Check (MC / Loader / Mods)** | zu; offen nach Scan oder per Deep-Link | `upgrade-check` |
| 4 | **Modpack importieren** (Klammer-Collapsible) | zu; offen bei laufendem/resumebarem Import | `modpack` |
| 4a | ↳ Modpack-Suche | offen wenn `pack_q` gesetzt | `modpack-search` |
| 4b | ↳ Browser-Upload | zu | `modpack-upload` |
| 4c | ↳ Eigene Datei (FTP/SFTP) | zu | `modpack-path` |
| 4d | ↳ Resume-UI | offen wenn resumebarer Job | `modpack-resume` |
| 5 | **Mods / Plugins suchen** | offen wenn `mod_q` gesetzt, sonst zu | `mod-search` |
| 6 | **Installierte Mods** | immer offen | `installed-mods` |

- Der bisher inhaltslose „Modpack importieren“-Header (Befund C) wird die Klammer für 4a–4d; Auto-Resume-Hinweis wandert in dessen `hint`.
- `<summary>`-Badges: „Installierte Mods (37)“, „Upgrade-Check (3 Mods ohne Version)“, „Modpack importieren (Job läuft)“ — Relevanz sichtbar ohne Aufklappen.
- Formular-State (`q`, `status`, `sort`, `dir`, `page`, `mod_q`, `pack_q`) bleibt unverändert erhalten; Collapsibles ändern nichts an den Hidden-Feldern.

## Phase 4 — Upgrade-Check-Kette (Kernstück)

### Neue Funktion in `src/lib/mc_upgrade.pl`

```perl
# mc_upgrade_check_chain($server_dir, $profile, $target, $opts)
#   $target = { mode => 'mc'|'loader',
#               target_mc_version => '26.2',        # mode=mc
#               target_loader_version => '26.1.2.99' } # mode=loader
# Rückgabe:
#   { mode, order => [ 'mc','loader','mods' ] | [ 'loader','mc','mods' ],
#     blocked_at => 'loader'|'mc'|undef, ok => 0|1,
#     steps => {
#       mc     => { status => 'ok'|'fail'|'unchanged', err => '...', value => '26.2' },
#       loader => { status => 'ok'|'fail'|'unchanged', err => '...',
#                   value => '26.2.0.12', candidates => [...], java_major => 25 },
#       mods   => { status => 'ok'|'warn'|'skipped', report => { ... } },
#     } }
```

Ablauf `mode = 'mc'` (Reihenfolge im UI: MC-Ziel → Loader → Mods):

1. `mc_upgrade_validate_mc_target($profile, $target_mc)` → bei Fehler `blocked_at='mc'`.
2. **Loader-Schritt:** `mc_fetch_loader_versions($loader, $target_mc)` (über Cache).
   - leer ⇒ `status='fail'`, `err='loader_no_build_for_mc'`, `blocked_at='loader'`, Mods `skipped`.
   - sonst `value` = neuester Build, `java_major` = `resolve_java_major($target_mc)`.
   - **Behebt Befund B** und wird zusätzlich in `mc_upgrade_validate_mc_target()` als Vorbedingung genutzt, damit der Job nicht erst im Worker scheitert.
3. **Mods-Schritt:** `mc_upgrade_mod_compat_report($server_dir, $profile, $target_mc)` gegen Zielprofil `{loader, target_mc}`.

Ablauf `mode = 'loader'` (Reihenfolge im UI: Loader-Ziel → MC → Mods):

1. `mc_upgrade_validate_loader_target($profile, $target_pin)` → bei Fehler `blocked_at='loader'`.
2. **MC-Schritt:** `mc_loader_version_matches_mc($loader, $profile_mc, $target_pin)` — MC-Version bleibt unverändert; Status `unchanged` mit Anzeige der aktuellen MC-Version. Passt der Build nicht zur MC-Linie ⇒ `fail`, Mods `skipped`.
3. **Mods-Schritt:** Report gegen `{loader, aktuelle MC}` + Hinweistext gemäß D7 („Loader-Builds sind für die Mod-APIs transparent; geprüft wird die MC-Linie“).

### Renderer

`mc_upgrade_render_check_chain_html($chain)` in `mc_upgrade.pl` (neben dem bestehenden `mc_upgrade_render_mod_compat_report_html`, das weiterverwendet wird):

- Drei Zeilen (Schritt / Status / Detail) über `ui_columns_table`, Status als Textlabel (keine harten Farben; `ui_*`-Klassen bzw. `alert-*` wie bisher).
- Bei `blocked_at` ein `alert-warning` mit konkreter Ursache und Handlungshinweis („Loader hat noch keine Builds für MC 26.2 — später erneut prüfen“).
- Darunter der Mod-Report (bestehende Tabelle, max. 25 Zeilen + „… und N weitere“).

### CGI-Anbindung (`mods.cgi`)

- Aktion `mod_compat_scan` → **`upgrade_check`** (POST, `user_can_operate`, `mc_mod_ui_ready`), Parameter `check_mode` (`mc|loader`), `compat_mc`, `compat_loader`.
  Alter Aktionsname bleibt als Alias erhalten, damit Deep-Links/Bookmarks aus 0.2.2 nicht brechen.
- Zwei kleine Formulare in Abschnitt 3: „MC-Version prüfen“ (Select MC) und „Loader-Build prüfen“ (Select Loader).
- Ergebnis wird direkt gerendert (kein Job) — der Scan bleibt synchron, aber ausschließlich auf Klick.
- `manage.cgi` verlinkt mit `check_mode`+Ziel; kein Scan auf der Manage-Seite.

## Phase 5 — Weitere Übersichts-Verbesserungen (Vorschläge, einzeln zu- oder abwählbar)

| # | Vorschlag | Nutzen | Aufwand |
|---|---|---|---|
| V1 | **Statuszeile mit Badges** im Instanz-Kopf (Status · Monitor · Loader/MC/Java · Ports offen) statt Werte quer über die große Tabelle | schneller Überblick oben | mittel |
| V2 | Selten gebrauchte Zeilen (Script-Pfad, Config-Pfade, Server-Root, Filemanager-Link) in Collapsible **„Pfade & Details“** | kürzere Seite | klein |
| V3 | **Update-Hinweiszeile** im Kopf: „Loader: 2 neuere Builds · MC 26.2 verfügbar“ (nur aus Cache, kein Netzwerk) mit Sprunglink zu `#upgrades` | Upgrades werden gefunden, ohne zu suchen | klein (nach D4) |
| V4 | `manage.cgi` in vier Gruppen bündeln: **Steuerung** (offen) · **Upgrades & Wartung** · **Zugriff** (FTP/Steam) · **Konfiguration & Diagnose** (Config-Editor, Health, Migrate, Jobs) | eine Ebene statt 12 gleichrangiger `<h4>` | mittel |
| V5 | Gleiche Kopf-/Aktionsleiste auf `manage.cgi` und `mods.cgi` (gemeinsamer Renderer) | Wiedererkennung, weniger Duplikat-Code | mittel |
| V6 | Anker-Sprünge nach jedem POST (`#abschnitt`), damit man nach dem Speichern nicht wieder oben landet | spürbar bei langen Seiten | klein |
| V7 | Jobs-Tabelle auf beiden Seiten zuklappen, wenn kein Job läuft (Badge „letzter Job: ok“) | Platz | klein |
| V8 | **Compat-Cache aus `$SERVER_DIR` heraus** (Befund D) — auch unabhängig vom Rest umsetzen | Sicherheits-Invariante | klein |
| V9 | „Alles prüfen“-Knopf: Kette für den empfohlenen Ziel-Bump (neuester Loader auf aktueller MC) mit einem Klick | häufigster Fall in einem Schritt | klein (nach Phase 4) |
| V10 | Readonly-Konten sehen leere Collapsibles nicht (Hülle nur rendern, wenn Inhalt existiert) | keine Blindtüren | klein |

## Lang-Keys (jeweils `de` **und** `en`)

Neu, Präfix `mc_upgrade_check_*` bzw. `mods_section_*`:

- `mc_upgrade_check_title`, `mc_upgrade_check_hint`, `mc_upgrade_check_btn_mc`, `mc_upgrade_check_btn_loader`
- `mc_upgrade_check_step_mc`, `mc_upgrade_check_step_loader`, `mc_upgrade_check_step_mods`
- `mc_upgrade_check_status_ok`, `_fail`, `_unchanged`, `_skipped`
- `mc_upgrade_check_blocked_loader_no_build`, `mc_upgrade_check_blocked_mc_mismatch`, `mc_upgrade_check_mods_skipped`
- `mc_upgrade_check_loader_build_note` (D7-Hinweis), `mc_upgrade_check_java_note`
- `mods_section_modpack`, `mods_section_upgrades`, `manage_section_upgrades`, `manage_section_paths`, `manage_versions_load_btn`
- Badge-Vorlagen: `mods_badge_installed_count` (`$1`), `mods_badge_compat_issues` (`$1`), `manage_badge_loader_updates` (`$1`)

Bestehende Keys `mc_mods_compat_*` bleiben als Fallback stehen, solange die Alias-Aktion existiert.

## Tests

| Datei | Inhalt |
|---|---|
| `t/test_mc_upgrade.pl` (erweitern) | Kette: `mode=mc` grün; `mode=mc` mit leerer Loader-Liste ⇒ `blocked_at='loader'` + `mods.status='skipped'`; `mode=loader` mit passendem/unpassendem Pin; Cache-Key enthält Loader; Renderer escaped `<` in Mod-Titeln |
| `t/test_ui_collapsible.pl` (neu) | Helper: `open`-Attribut nur bei `open=>1`, `id` sanitisiert, Titel/Badge escaped, `ui_collapsible_end` schließt |
| `t/test_page_layout.pl` (neu) | Quelltext-Reihenfolge in `mods.cgi` (Upgrade-Check vor Modpack-Import vor Mods-Suche vor Installierte Mods), Anker-IDs vorhanden, jeder neue Lang-Key in `de` **und** `en` |
| `t/test_security_guards.pl` | unverändert grün halten (kein Root-Write auf `$SERVER_DIR` durch neuen Cache-Pfad) |

Abschluss: `bash scripts/verify.sh`.

## Risiken

- **Zugeklappt = übersehen.** Gegenmaßnahme: Badges im `<summary>`, Auto-Open bei relevantem State (laufender Job, Suchtreffer, Scan-Ergebnis, Deep-Link).
- **Alias-Aktion `mod_compat_scan`** muss weiter funktionieren, sonst brechen Links aus 0.2.2-Installationen und aus dem Wiki.
- **Versions-Cache verdeckt neue Builds** bis zum TTL-Ablauf. Gegenmaßnahme: „Jetzt neu laden“-Button im Upgrades-Abschnitt, der den Cache verwirft.
- **Reihenfolgewechsel auf `manage.cgi`** (Upgrades vor Config-Editor) ändert vertraute Positionen; Wiki-Screenshots/Texte müssen mitgezogen werden.

## Entscheidungen aus Rücksprache (2026-09-02)

1. **Umfang:** Phase 1–4 plus **alle** Punkte V1–V10.
2. **Zustand:** Auf-/Zuklapp-Zustand wird per `localStorage` pro Anker-ID gemerkt; Code-Default greift ohne JS und beim ersten Besuch. Auto-Open bei laufendem Job / Suchtreffern / Deep-Link überschreibt den gemerkten Zustand.
3. **Release:** **0.2.3** — `src/module.info` bumpen, `CHANGELOG.md` ergänzen, Tag `v0.2.3` erstellen und pushen.

## Verwandt

- `2026-09-01-mc-version-loader-upgrade.md`
- `2026-08-28-mc-mod-dependencies.md`
- `2026-08-15-mc-mods-page.md`
