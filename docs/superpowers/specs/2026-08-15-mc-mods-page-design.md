# Minecraft Mods-Seite — Design Spec

**Datum:** 2026-08-15  
**Status:** Implementiert / Akzeptiert (2026-08-15) — Plan: `docs/superpowers/plans/2026-08-15-mc-mods-page.md`  
**Bezieht sich auf:** `docs/superpowers/specs/2026-06-28-minecraft-profile-mods-design.md` (Mod-APIs, Index, Jobs)  
**Ersetzt UI-Platzierung:** Mod-/Modpack-Blöcke wandern von `manage.cgi` nach `mods.cgi`

---

## Ziel

Mod-Management (installierte Liste, Einzel-Install, Modpack) soll **nutzerfreundlich** und **skalierbar** sein — nicht mehr als langer Block auf der Manage-Seite. Eine eigene Seite bietet Übersicht, An/Aus, Löschen, Versionswahl und schnelles Testen (Start/Stop + Log).

---

## Entscheidungen (fest)

| Thema | Entscheidung |
|-------|--------------|
| Seite | **Eigene CGI** `mods.cgi` (Ansatz 1) |
| Inhalt | **Alles** Mods: Liste + Suche/Install + Modpack |
| Serverleiste | Status + **Start** + **Stop** + **Log** oben |
| Manage | Nur Link „Mods verwalten“; Mod-/Modpack-UI entfernen |
| Disable | Rename `*.jar` ↔ `*.jar.disabled` (Minecraft-üblich) |
| Aktionen pro Mod | An/Aus, Löschen, Update mit Versionswahl |
| Neu-Install Versionswahl | **Optional** (Default: auto-passende Version) |
| Update Versionswahl | **Immer** (kompatible Versionen listen) |
| Listen-Komfort | Suche, Filter An/Aus/Alle, Sortierung, Pagination (~50) |
| Mehrfach-Aktionen | **Nicht in v1** |
| Writes | Nur als Game-User unter `serverfiles/{mods\|plugins}/` |
| Success | Verifiziert (Rename/Delete read-back; Jobs über `$JOB_DIR/status`) |

---

## Seitenlayout (`mods.cgi`)

```
┌─────────────────────────────────────────────────────────┐
│ Instanzname · Status · [Start] [Stop] [Log]  [← Manage] │
├─────────────────────────────────────────────────────────┤
│ Installierte Mods                                       │
│ [Suche…] [Filter: Alle|An|Aus] [Sort]   Seite 1/n       │
│ Name | Datei | Quelle | Status | Aktionen               │
│ …                                                       │
├─────────────────────────────────────────────────────────┤
│ Mod suchen & installieren                               │
│ (bestehende Suche; optional „Version wählen“)           │
├─────────────────────────────────────────────────────────┤
│ Modpack                                                 │
│ (Suche/Import/Resume — von manage hierher)              │
└─────────────────────────────────────────────────────────┘
```

### Serverleiste

- Gleiche Rechte/ACL wie Manage (`user_can_manage`, readonly blockiert Mutationen).
- **Start / Stop:** bestehende Job-Dispatch-Pfade (wie `manage.cgi`); nach Dispatch → `job_live.cgi`, danach Rückkehr-Hinweis/`return` zu `mods.cgi`.
- **Log:** Konsolen-/Live-Log wie Manage `action=monitor` (Spiel-Log-Tail). Implementierung: entweder `mods.cgi?action=monitor` (Logik teilen) oder Link auf Manage-Monitor mit `return=mods`. Nutzer bleibt im Mods-Kontext (Zurück-Link Pflicht).
- Kein voller Monitor-/Schedule-Block auf der Mods-Seite (nur die drei Controls + Status).

### Manage-Seite

- Abschnitt Modpack + Mod-Browser entfernen.
- Ersetzen durch einen klaren CTA/Link: „Mods verwalten“ → `mods.cgi?instance_id=…`.
- Deep-Links mit `mod_q` / `pack_q` optional weiterhin an `mods.cgi` weiterreichen.

---

## Installierte Mods — Datenmodell

### Disk-Scan

Quelle der Wahrheit für An/Aus:

| Datei | Status |
|-------|--------|
| `serverfiles/$mod_dir/foo.jar` | enabled |
| `serverfiles/$mod_dir/foo.jar.disabled` | disabled |

`$mod_dir` aus Profil (`mods` oder `plugins`). Nur Basename; keine Unterordner in v1 (außer ggf. bekannte Ignore-Patterns wie `.cache` — ignorieren).

### Index (`.mc_mods_index.json`)

Bestehender Index anreichern/anzeigen wenn Key passt (`$mod_dir/$basename` ohne `.disabled`):

- Titel, source (`modrinth` / `curseforge` / `hangar` / `modpack` / unbekannt)
- project_id / version_id / file_id wo vorhanden
- hashes optional

Ohne Index-Eintrag: Zeile zeigt Dateiname; Update nur wenn Quelle+Projekt auflösbar, sonst UI-Hinweis „Keine Update-Quelle“.

### Listen-API (Library)

Neue Hilfen in `mc_mods.pl` (oder kleines `mc_mods_list.pl` nur wenn `mc_mods.pl` zu groß wird):

- `list_installed_mods($server_dir, $profile)` → Array von Hashes  
  `{ basename, filename_on_disk, enabled, title, source, project_id, … }`
- `mod_set_enabled($server_dir, $unix_user, $mod_dir, $basename, $enabled)` → `1/0` + verify
- `mod_delete_file($server_dir, $unix_user, $mod_dir, $basename)` → Datei + Index-Eintrag entfernen, verify
- Filter/Sort/Pagination in CGI oder Helper: `filter_installed_mods(\@list, \%opts)`

Disable/Enable/Delete: sync in CGI als Game-User (`_write`/`rename`/`unlink` via bestehende User-Write-Helfer), **kein** Background-Job. Flash-Pattern für Success-Banner.

---

## Aktionen

### An / Aus

1. Sanitize basename (nur `[\w.\-]+`, endet auf `.jar` oder `.jar.disabled`).
2. Rename innerhalb von `$SERVER_DIR/serverfiles/$mod_dir/` (realpath-Check: Ziel bleibt unter diesem Dir).
3. Read-back: erwartete Datei existiert, Gegenstück nicht.
4. Flash + Redirect `mods.cgi?…&enabled=1` / `disabled=1` (Banner nur nach Flash-Consume).
5. Hinweis in UI: Server-Neustart nötig, damit Loader die Änderung lädt (nicht auto-restart in v1).

### Löschen

1. Bestätigungsformular (destruktiv, `btn-danger`).
2. Entfernt enabled- oder disabled-Datei; Index-Key löschen falls vorhanden.
3. Verify + Flash.

### Update / Version wählen (installiert)

1. Nur wenn `source` + Projekt-IDs bekannt.
2. API: kompatible Versionen zu Profil (Loader + MC), neueste zuerst; aktuelle markieren.
3. User wählt Version → Job `mc_mod_install` (oder `mc_mod_update`) mit fester `version_id`/`file_id`.
4. Nach Erfolg: alte Datei ersetzen; wenn vorher disabled, neue Datei wieder als `.disabled` belassen (Status erhalten).
5. Live-Log wie bei Install.

### Neu-Install (Suche)

1. Default: unverändert — auto-resolve passende Version.
2. Optionaler Link/Button „Version wählen…“ → Versionsliste → Install mit gewählter ID.
3. UI etwas aufgeräumter als heute (klare Trennung Ergebnisse vs. Aktion), aber gleiche APIs.

---

## Modpack

- Vollständiger Block von `manage.cgi` nach `mods.cgi` (Suche, Remote-Import, Path-Import falls vorhanden, Resume-UI).
- Validierungs-Vergleich/Warnungen bleiben im Job-Live-Log (bestehende `modpack_print_validation_report*`).
- Job-Redirects zielen auf `job_live.cgi` mit Return zu `mods.cgi` wo sinnvoll.

---

## Jobs & Feedback

| Aktion | Sync/Async | Success |
|--------|------------|---------|
| An/Aus | sync | rename verify + flash |
| Löschen | sync | unlink verify + flash |
| Install / Update / Modpack | job | `$JOB_DIR/status=ok` |
| Start / Stop | job | wie Manage |

Keine Success-Banner nur aus URL-Parametern ohne Flash/Verify (`no-blind-success-feedback`).

---

## Sicherheit

- ACL: gleiche Instanz-Rechte wie Manage; readonly → keine Mutationen.
- Path: nur unter `serverfiles/$mod_dir/`; `basename` sanitize; Reject bei `..`, Symlink-Escape (wie Modpack-Path-Validate).
- Downloads: bestehende URL-Whitelist (`mc_download_url_allowed`).
- HTML: `html_escape` für alle dynamischen Strings; nur `ui_*`.

---

## Nicht in v1

- Bulk enable/disable/delete
- Auto-Restart nach An/Aus
- Mod-Export / mrpack bauen
- Client-only Mods installieren
- Abhängigkeitsgraph / „fehlende Mods“-Resolver jenseits bestehender Pack-Logik

---

## Tests

- Unit: list/scan erkennt `.jar` / `.jar.disabled`; enable/disable rename roundtrip; delete entfernt Index; filter/pagination.
- Versionslisten-Helper (Mock/Fixture) filtert nach Profil.
- CGI-nahe Tests wo möglich (Pfad-Sanitize, flash consume).
- `bash scripts/verify.sh` grün; neue Keys in `lang/de` + `lang/en`.

---

## Migration / Kompatibilität

- Bestehende `.mc_mods_index.json` bleibt gültig.
- Manuell per FTP abgelegte JARs erscheinen in der Liste ohne Metadaten.
- Bookmarks auf Manage-Mod-Suche: optional Redirect `manage.cgi` → `mods.cgi` wenn `mod_q`/`pack_q` gesetzt (nice-to-have, nicht blockierend).

---

## Erfolgskriterien

1. Manage ohne Mod-/Modpack-Ballast; ein Link zur Mods-Seite.
2. Mods-Seite: Serverleiste (Start/Stop/Log) + lesbare paginierte Liste + Install + Modpack.
3. Einzelne Mods an/aus und löschbar; Update mit Versionswahl; Neu-Install mit optionaler Versionswahl.
4. Verified success; Game-User-Grenze eingehalten; verify.sh grün.
