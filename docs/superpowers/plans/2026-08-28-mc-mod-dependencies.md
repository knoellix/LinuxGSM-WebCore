# MC Mod-Abhängigkeiten prüfen / nachziehen

> **Status:** Implementiert (0.2.2) — Umsetzungsplan: [`2026-09-01-mc-mod-dependencies-implementation.md`](2026-09-01-mc-mod-dependencies-implementation.md)  
> **Tests:** `t/test_mc_mod_deps.pl`  
> **Anlass:** 2026-08-28 — Farming for Blockheads ohne passende Balm-Nutzung / Version-Mismatch → Server-Crash (`IllegalClassLoadError` / Shipping Bin).

## Ist-Zustand (0.2.2)

| Pfad | Dependencies? |
|------|----------------|
| **Modpack-Import** (`mc_modpack.pl` / mrpack+CF-Manifest) | Ja — Dateiliste enthält Pack-Deps; Worker lädt Manifest-Dateien. |
| **Einzelmod-Install** (`mods.cgi` → `mc_mod_install_user.sh`) | **Ja** — `build_mod_install_plan`, Dep-Preview, optional `install_deps`, Worker installiert Primary + Deps (Cap 5). |
| **Loader/MC-Version-Filter** | Ja — kompatible Versionen nach Profile. Ergänzt Mod-zu-Mod-Deps (z. B. Balm für Farming for Blockheads). |

CurseForge-Deps: API liefert nur `modId` (kein `fileId`); Auflösung wählt neueste loader/MC-kompatible Datei.

## Referenz / Symptom

- Modrinth-Version mit required Dep → `t/fixtures/mc_mods/modrinth_version_with_dep.json`
- CurseForge-Datei mit Dep → `t/fixtures/mc_mods/curseforge_file_with_dep.json`
