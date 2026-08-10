# Palworld server mods (Workshop-style)

## Goal

MC-like mod install UI for Palworld LGSM instances: search/browse, install via background job, enable in `PalModSettings.ini`, outcome verified in live log.

## Context

- Palworld dedicated server mods use `Mods/Workshop/<folder>/Info.json` under the server binary tree (LGSM: typically `serverfiles/` or script dir — resolve from instance).
- Enable via `Mods/PalModSettings.ini`: `bGlobalEnableMod=true`, `ActiveModList=<PackageName>` (from `Info.json`, not folder name).
- Server restart deploys mods per `InstallRules`; only mods with `"IsServer": true` are valid.
- Official docs note Linux server mod support is limited/experimental vs Windows; validate on target before promising parity.

## Not in scope (v1)

- RE-UE4SS / Lua loader chain
- Client-only `.pak` mods without server `Info.json`
- Nexus/CurseForge search (unless we add a generic download URL whitelist like MC custom hosts)

## Proposed architecture

| Layer | Responsibility |
|-------|----------------|
| `games_meta.json` (`pwserver`) | `mod_support: workshop`, paths for `Mods/Workshop`, `PalModSettings.ini` |
| `src/lib/pw_mods.pl` | Parse `Info.json`, read/write `PalModSettings.ini`, list installed mods |
| `manage.cgi` | UI section (like `mc_mods`): workshop ID or manual path, install/remove, enable toggle |
| `src/scripts/pw_mod_install_user.sh` | User-native worker: download workshop folder (SteamCMD `workshop_download_item` app 2394010 or copy from supplied path), verify `Info.json`, update `ActiveModList` |
| Job | `pw_mod_install` → `job_live.cgi`, success only on `status=ok` |

## Open questions

1. **Workshop download on Linux**: confirm SteamCMD workshop item download path for Palworld dedicated (app 2394010) and whether LGSM already documents a helper.
2. **Mod source**: Steam Workshop ID only, or also ZIP upload / SFTP path (like modpack path import)?
3. **Restart policy**: auto-restart after install (job chain) or prompt user?

## Phases

1. Read-only: list installed mods from `Mods/Workshop` + `PalModSettings.ini`.
2. Enable/disable toggles (ini edit, restart job).
3. Install worker (workshop ID + optional URL/ZIP).
4. Tests: ini parser, job meta, security guards (path under `$SERVER_DIR` only).
