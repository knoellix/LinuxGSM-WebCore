# PZ Workshop Inventory — Design Spec

**Datum:** 2026-09-29  
**Status:** Implemented

---

## Ziel

Auf `workshop.cgi` eine **MC-Mods-ähnliche** Verwaltung heruntergeladener Steam-Workshop-Items: auflisten was auf Disk liegt, Metadaten zeigen, pro Item aktivieren / deaktivieren / löschen — nicht nur die reine `WorkshopItems=`-INI-Liste.

---

## Entscheidungen

| Thema | Entscheidung |
|-------|--------------|
| Liste | Eine gemeinsame Tabelle: Disk-Scan ∪ INI-`WorkshopItems` |
| Einheit | Pro Workshop-Item (Steam-ID / Content-Ordner), nicht pro einzelne Mod-ID |
| Deaktivieren | Nur INI (`WorkshopItems` + zugehörige Mod-IDs aus `Mods=`); Dateien bleiben |
| Löschen | INI bereinigen **und** Content-Ordner löschen (Game-User); Confirm |
| Aktivieren | Item + aus `mod.info` gelesene Mod-IDs in INI schreiben (sync) |
| Metadaten | Lokal (`mod.info`) **+** Steam Web API Details (Key bereits für Suche nötig) |
| Restart | Nur Hinweis; kein Zwangs-Restart |
| Success | Flash + Verify (INI-Readback / Ordner weg nach Delete) |

---

## Nicht in diesem Scope

- Einzel-Mod-ID-Toggle innerhalb eines Workshop-Items
- Collections, Auto-Update, Load-Order-UI
- Bulk-Aktionen / Filter-Pagination à la volle `mods.cgi`
- Andere Spiele außer PZ (`mod_support: workshop` bleibt Meta-Flag)
- Transitive Workshop-Deps beim Enable (nur Subscribe — siehe `2026-09-29-pz-workshop-deps-design.md`)

---

## Datenmodell (Zeile)

```text
workshop_id
on_disk          bool
in_ini           bool
content_dir      path | undef
mod_infos[]      { id, name, modversion, pz_require, authors }  # aus mod.info
steam            { title, description, preview_url, time_updated } | undef
status           active | inactive | orphan_ini
```

**Status:**

| Status | Bedeutung |
|--------|-----------|
| `active` | `on_disk` ∧ `in_ini` |
| `inactive` | `on_disk` ∧ ¬`in_ini` |
| `orphan_ini` | ¬`on_disk` ∧ `in_ini` (Warnung; Deaktivieren oder INI-Cleanup) |

---

## Pfade

Unverändert zu V1 — Content unter Home / SteamCMD-Prefix:

- `$HOME/Steam/steamapps/workshop/content/<appid>/<id>/`
- `$HOME/.steam/steam/steamapps/workshop/content/<appid>/<id>/`
- `$HOME/steamapps/…`, `$SERVER_DIR/steamapps/…`, `$SERVER_DIR/serverfiles/steamapps/…`

Scan: bekannte Roots für `<appid>` durchgehen, Unterordner = numerische Workshop-IDs. Löschen nur nach Canonical-Pfad-Check unter erlaubtem Content-Root (kein Escape außerhalb Home/Server-Dir).

INI: wie V1 via `pz_workshop_resolve_ini_path` (z. B. `pzserver.ini`).

---

## Bibliothek (`pz_workshop.pl`)

| Funktion (Arbeitstitel) | Rolle |
|-------------------------|--------|
| `pz_workshop_content_roots($unix_user, $server_dir, $appid)` | Erlaubte Scan-Roots |
| `pz_workshop_scan_disk(...)` | Gefundene Item-Dirs + `mod.info`-Parse |
| `pz_workshop_parse_mod_info($path)` | Erweitert: name/id/modversion/require/authors (nicht nur IDs) |
| `pz_workshop_list_inventory(...)` | Merge Disk ∪ INI → Zeilen + Status |
| `pz_workshop_steam_details(\@ids)` | Batch `GetPublishedFileDetails` (API-Key) |
| `pz_workshop_enable_item` / `disable_item` | INI patch + Verify |
| `pz_workshop_delete_item` | disable + sicheres Löschen des Content-Dirs als Game-User |

**Disable / Mods=:** Zugehörige Mod-IDs kommen aus `mod.info` auf Disk. Bei `orphan_ini` (kein Ordner): nur `WorkshopItems`-Eintrag entfernen; `Mods=` unverändert (kann verwaiste Mod-IDs hinterlassen — Hinweis in UI).

**Delete-Ausführung (V1):** synchron als Game-User (`su` Privilege-Drop / bestehende Write-as-user-Helfer), mit Confirm. Kein Background-Job, solange Delete nur ein Ordnerbaum ist. Job + `job_live` nur falls nötig in einem Follow-up.

---

## UI (`workshop.cgi`)

1. Suche / Subscribe-by-ID — unverändert (Collapsible oben).
2. Sektion **Installiert** (ersetzt reine INI-ID-Liste):
   - Spalten: Item (Titel, Workshop-ID, kleines Preview), Mods/Version (`mod.info`), Status-Badge, Aktionen.
   - Aktionen: Aktivieren \| Deaktivieren \| Löschen (Confirm bei Delete).
   - `orphan_ini`: Warnhinweis + Deaktivieren.
3. Pfad zur INI als Small-Print behalten.
4. Ohne API-Key: Liste trotzdem aus Disk/`mod.info`; Steam-Spalten leer + Integrationen-Hinweis.

Success-Banner: Flash (`workshop_enabled` / `workshop_disabled` / `workshop_deleted`) + Query-Flag; kein Blind-OK nur über URL.

---

## Steam API

- Endpoint: `ISteamRemoteStorage/GetPublishedFileDetails/v1/` (POST `itemcount` + `publishedfileids[n]`) für IDs der Inventarliste.
- Fehler/Timeout: Inventar trotzdem rendern; Steam-Felder fehlen.
- Keine Secrets im HTML; Key nur Modul-Config / Worker-Secrets.

---

## Tests

- Disk-Scan Fixture (Temp-Dirs mit `mod.info`) + INI-Merge → Status-Matrix
- Enable/Disable Round-Trip `WorkshopItems`/`Mods`
- Delete: Ordner weg + INI clean; Pfad außerhalb Roots abgelehnt
- `mod.info`-Parser Felder
- Steam-Details Fixture-JSON (kein Live-Steam)
- `bash scripts/verify.sh`

---

## Erfolgskriterien

- Nach Download erscheinen Items in **Installiert**, auch wenn User sie noch nicht aktiviert hat (oder Subscribe aktiviert hat — dann `active`).
- An/Aus und Löschen funktionieren ohne manuelles INI-Editieren.
- Metadaten zeigen mindestens lokalen Namen/Mod-ID und, mit Key, Steam-Titel.
