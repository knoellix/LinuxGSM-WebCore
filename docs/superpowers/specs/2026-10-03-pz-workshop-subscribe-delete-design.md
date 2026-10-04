# Design: PZ Workshop — Abonnieren/Löschen statt An/Aus

**Datum:** 2026-10-03  
**Status:** freigegeben  
**Bezug:** `2026-09-29-pz-workshop-inventory-design.md`, Manage Auto-Update (separat)

---

## Ziel

UI-Logik an Steam-Denken anpassen: **abonniert oder nicht**. Kein separates Workshop-Item-An/Aus. Löschen = Dateien weg + aus INI (deabonniert).

---

## Entscheidungen

| Thema | Wahl |
|---|---|
| Item-Aktionen | Nur **Abonnieren** + **Löschen** |
| Item Enable/Disable | Entfernen (POST `enable`/`disable` am Item nicht mehr in UI; Backend-Helfer dürfen intern bleiben für Subscribe/Delete) |
| Mod-Aktionen | Pro Mod-ID weiter **an/aus** |
| Auto beim Abonnieren | **Höchstens eine** Mod-ID: beste passende Version, sonst **keine**. Nie mehrere automatisch |
| Versions-Badge | Parsebare PZ-Version + Mismatch → **unpassend**; kein Versionsstring (Deps/Namen) → **unbekannt** |
| Fallback Version | Wenn `mod.info` `require`/`pzversion` leer: schwacher Fallback aus Mod-Name / ID / Ordner (`[B42.20]`, `42.12`, …). Oft nutzlos — ok |
| Status-Labels | Abonniert / nur Dateien / INI ohne Dateien (statt aktiv / workshop-only / inaktiv mit Enable) |
| Umlaut | `manage.cgi` (und fehlende CGIs) `charset=utf-8` wie `workshop.cgi` |

---

## Verhalten

### Abonnieren
Unverändert im Kern: SteamCMD-Download + `WorkshopItems` + Auto-Mod-Pick (neu: max. 1 ID).

### Löschen
Unverändert: Content-Roots löschen + ID aus `WorkshopItems` und zugehörige Mod-IDs aus `Mods`.

### Auto-Pick (`pz_workshop_select_mod_ids_for_version`)
1. Exact major.minor → höchstens 1 (beste/einzige)  
2. Sonst kompatibel (require ≤ server, gleiches Major) → 1 (höchste passende)  
3. Sonst nur unconstrained und **genau eine** → die eine  
4. Mehrere unconstrained / keine passende → **keine** Auto-Aktivierung  

### Versionszelle
- Rohstring ohne extrahierbare Version → Label Roh/„unbekannt“, match `unknown` (nicht `bad`)  
- Extrahierte Version ≠ Server → `bad` / unpassend  
- Extrahierte Version passt → `ok`  
- Fallback-Quelle nur für Anzeige + Auto-Pick, nicht in INI schreiben  

### Encoding
`$main::gconfig{'charset'} = 'utf-8';` in `manage.cgi` (Ursache typischer `geprÃ¼ft`-Mojibake bei UTF-8-Langkeys).

---

## Nicht in diesem Slice
- Auto-Update-Message-Bash-Bug (separater Fix, ggf. schon im Tree)
- Collections / Steam-Live-Sync
- Andere Spiele außer PZ

---

## Tests
- Select: nie >1 ID; multi unconstrained → 0  
- Version cell: Deps-String → unknown; `42.12` vs Server mismatch → bad  
- Fallback: Name `[B42.20]` ohne require → Version 42.20 für Match  
- Layout/UI: keine Item-Enable/Disable-Buttons; Delete + Mod-Toggle bleiben  
- manage charset / Badge-String mit ü unverfälscht in Smoke wenn machbar  
