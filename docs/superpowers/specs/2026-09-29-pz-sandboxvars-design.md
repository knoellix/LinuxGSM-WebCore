# Project Zomboid SandboxVars Editor — Design Spec

**Datum:** 2026-09-29  
**Status:** Implemented (0.2.4)  
**Version:** module 0.2.4+

---

## Ziel

Welteinstellungen (`pzserver_SandboxVars.lua`) im Manage-Config-Editor bearbeiten — gleiches UX-Muster wie Server-INI / Instance-Config: alle Keys als Formularfelder + Rohmodus.

## Datei

| | |
|--|--|
| Pfad | `$HOME/Zomboid/Server/<selfname>_SandboxVars.lua` |
| Beispiel | `/home/gs_pz_…/Zomboid/Server/pzserver_SandboxVars.lua` |
| Format | Lua-Tabelle `SandboxVars = { … }` (auch nested: `ZombieLore`, `ZombieConfig`, …) |

Ableitung aus Meta: `game_config_path` `.ini` → `_SandboxVars.lua` (oder explizites `game_sandbox_path`).

## UI

- Vierter Config-View-Button **Welteinstellungen** (nur wenn Sandbox-Pfad resolvable / Datei existiert oder Meta gesetzt)
- Formular: alle Keys aus der Datei (flatten: `ZombieLore.Speed`)
- Labels optional aus Meta; sonst Key-Name
- Bool / Zahl / Text analog Server-INI
- Rohmodus: volle Datei
- Hinweis: Server stoppen vor Edit (PZ schreibt beim Quit zurück)

## Sicherheit

- Canonical path unter Unix-Home + `Zomboid/Server/` + `*_SandboxVars.lua`
- Write als Game-User (`_write_file_as_user`)
- Flash + read-back wie andere Config-Saves
- Kein Blind-Success

## Nicht in V1

- SandboxVars erstellen wenn missing (kommt vom Erststart)
- Strukturierte Sektionen / Presets
- Live-Edit bei laufendem Server erzwingen (nur Hinweis)

## Tests

- Flatten / unflatten Round-Trip
- Update einzelner nested Keys
- Path außerhalb Home abgelehnt
- `bash scripts/verify.sh`
