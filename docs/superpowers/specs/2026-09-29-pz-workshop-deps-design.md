# PZ Workshop Transitive Dependencies — Design Spec

**Datum:** 2026-09-29  
**Status:** Implemented
**Baut auf:** `2026-09-29-pz-workshop-design.md`, Inventory `2026-09-29-pz-workshop-inventory-design.md`  
**Plan:** `docs/superpowers/plans/2026-09-29-pz-workshop-inventory.md` (Tasks D1–D3)

---

## Ziel

Beim **Abonnieren** eines Workshop-Items automatisch alle Steam-**Required items** (transitiv) mit herunterladen und in der Server-INI aktivieren — mit sinnvoller `Mods=`-Reihenfolge (Deps vor Consumer).

---

## Entscheidungen

| Thema | Entscheidung |
|-------|--------------|
| Wann | **Nur Subscribe-Job** (nicht Enable/Disable/Delete im Inventory) |
| Quelle | Steam Published-File **children / required items** — **nicht** `mod.info require=` (oft Spielversion) |
| Graph | Transitiv, BFS; Zyklus-Schutz (bereits besuchte IDs überspringen) |
| Cap | Max. **20** Workshop-IDs inkl. Root; darüber Job `failed` + klare Meldung |
| Download | SteamCMD pro fehlendem Item; vorhandene Content-Dirs überspringen |
| INI | Alle IDs in `WorkshopItems=`; `Mods=` topologisch (Deps zuerst), bestehende Einträge möglichst erhalten |
| UI | Job-Log listet Reihenfolge; optional Success-Hinweis „inkl. N Abhängigkeiten“ |

---

## Nicht im Scope

- Auto-Deps beim Inventory-Enable
- Optionale Dependencies / Collections
- Manuelle Load-Order-UI
- `mod.info require=` als Mod-Dependency interpretieren

---

## Ablauf (Subscribe-Worker)

```text
root_id
  → steam_details(root) → children[]
  → BFS expand (cap 20, cycle skip)
  → ordered_ids = topological (deps before dependents; root last among its closure)
  → for id in ordered_ids:
        download if missing content dir
        parse mod.info → mod_ids
  → patch INI: add all workshop ids + all mod ids (order Mods=)
  → verify root (and preferably all) in WorkshopItems
  → status=ok
```

**Topologie:** Kanten `child → parent` (child must load before parent). Sort so children appear earlier in `Mods=` than parents. Unrelated existing Mods entries stay; newly added dep mod-ids are inserted before the root’s mod-ids when possible.

---

## Bibliothek

| Funktion | Rolle |
|----------|--------|
| `pz_workshop_steam_children($id)` / details field | Required workshop IDs from API |
| `pz_workshop_resolve_dependency_closure($root_id, %opts)` | Returns `{ ok, ids => [...], err, skipped_cycles }` |
| Worker uses closure then existing download + `pz_workshop_patch_ini` | |

Steam: `IPublishedFileService/GetDetails` mit `includechildren=true` (RemoteStorage `GetPublishedFileDetails` liefert keine Required items). Fallback: HTML-Scrape der Workshop-Seite (`RequiredItems`), auch ohne API-Key.

---

## Fehler

| Fall | Verhalten |
|------|-----------|
| API-Key fehlt | Closure über HTML-Scrape der Required items; Warnung im Job-Log |
| Cap überschritten | `failed`, keine INI-Änderung für diesen Lauf (oder Rollback wenn schon gepatcht — Prefer: resolve **before** any download/patch) |
| Einzel-Download fail | `failed` nach Log; bereits geladene Dateien dürfen bleiben; INI nicht halb patchen wenn Root fehlte — Prefer: download all first, patch once at end |
| Zyklus | Kante ignorieren, weiter |

---

## Tests

- Fixture children graph → closure order + cycle skip + cap fail
- Worker-facing: mock details → ordered list
- `verify.sh`

---

## Erfolgskriterien

- Subscribe auf Mod mit Required items lädt Deps mit und trägt sie in INI ein.
- `Mods=` listet Dependency-Mod-IDs vor den Root-Mod-IDs.
- Inventory-Enable bleibt ohne Auto-Deps (wie Inventory-Spec).
