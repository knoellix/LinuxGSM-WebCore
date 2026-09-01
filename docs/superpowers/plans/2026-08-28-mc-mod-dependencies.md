# MC Mod-Abhängigkeiten prüfen / nachziehen

> **Status:** Geplant — Umsetzungsplan: [`2026-09-01-mc-mod-dependencies-implementation.md`](2026-09-01-mc-mod-dependencies-implementation.md)  
> **Anlass:** 2026-08-28 — Farming for Blockheads ohne passende Balm-Nutzung / Version-Mismatch → Server-Crash (`IllegalClassLoadError` / Shipping Bin). Frage: werden Dependencies beim Einzelmod-Install überhaupt beachtet?

## Ist-Zustand (kurz geprüft)

| Pfad | Dependencies? |
|------|----------------|
| **Modpack-Import** (`mc_modpack.pl` / mrpack+CF-Manifest) | Ja — Dateiliste enthält die Pack-Deps; Worker lädt die Manifest-Dateien. |
| **Einzelmod-Install** (`mods.cgi` → `mc_mod_install_*`) | **Nein** — lädt nur die gewählte Version/Datei. Modrinth/CurseForge `dependencies` (required/optional) werden nicht ausgewertet, nicht angezeigt, nicht nachinstalliert. |
| **Loader/MC-Version-Filter** | Ja — kompatible Versionen nach Profile (`mc_version` + Loader). Das ist **kein** Ersatz für Mod-zu-Mod-Deps (z. B. Balm für Farming for Blockheads). |

`mc_mods.pl` kennt Env-Side (`required` client/server) und Loader-Keys, aber **keine** Project-Dependency-Auflösung beim Install.

## Ziel (später)

1. Bei Einzelmod-Install **required** Dependencies von Modrinth/CurseForge lesen.
2. UI: fehlende Deps klar anzeigen (Name + bereits installiert / fehlt).
3. Optional: required Deps mitinstallieren (gleiche MC/Loader-Filter), optional Deps nur vorschlagen.
4. Version-Pin: Dep-Version muss zum Profile passen; Konflikt → Fehler, kein Blind-Download.
5. Tests mit Fixtures (Mod mit required Dep, bereits vorhanden, fehlend, Version-Konflikt).

## Nicht-Ziele (erstmal)

- Transitive Deps endlos auflösen ohne Limit (Cap + klare Meldung).
- Client-only Deps auf den Server zwingen.
- Hangar-Deps (Paper) — separat, wenn Hangar-API das hergibt.

## Referenz / Symptom

- Server Pepega: `farmingforblockheads` Shipping Bin tick → `balm.mixin.RecipeManagerAccessor` IllegalClassLoadError.
- Lehre: „Mod installiert“ ≠ „Laufzeit-Deps erfüllt / Versionen passen“.

## Einstiegspunkte im Code

- `src/mods.cgi` — Install-Dispatch Einzelmod
- `src/lib/mc_mods.pl` — API-Clients (hier Dep-Felder parsen)
- `src/scripts/mc_mod_install_user.sh` — Download nur der einen Datei
- Vergleich: `src/lib/mc_modpack.pl` — Manifest-Deps bereits vorhanden
