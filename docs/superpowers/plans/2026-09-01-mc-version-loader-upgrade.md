# MC-Version & Modloader upgraden (Server)

> **Status:** Implementiert (0.2.2) — Umsetzungsplan: [`2026-09-01-mc-version-loader-upgrade-implementation.md`](2026-09-01-mc-version-loader-upgrade-implementation.md)  
> **Tests:** `t/test_mc_upgrade.pl`  
> **Anlass:** 2026-09-01 — Pepega/NeoForge 26.1.2 läuft; MC-Patch und Loader-Version gezielt hochziehbar ohne blindes Reinstall.

## Shipped (0.2.2)

| Aktion | UI / Job | Worker |
|--------|----------|--------|
| **Loader-Upgrade** | `manage.cgi` → `mc_upgrade_loader` | `mc_upgrade_user.sh` (mode `loader`) |
| **MC-Version-Upgrade** | `manage.cgi` → `mc_upgrade_mc` | `mc_upgrade_user.sh` (mode `mc`, optional Java) |
| **Mod-Compat-Warnung** | vor MC-Upgrade auf manage | `mc_upgrade_mod_compat_report` |

Lang-Keys: `mc_upgrade_*`, Job-Labels `jobs_action_mc_upgrade_*`.

## Nicht-Ziele (weiterhin)

- Kein automatisches Mod-Update beim MC-Bump
- Kein Forge↔NeoForge-Wechsel
- Kein Loader-Family-Wechsel

## Verwandt

- `2026-08-28-mc-mod-dependencies.md`
- `2026-08-15-mc-versions-modular.md`
