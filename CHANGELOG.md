# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.4] - 2026-09-29

### Added

- **Project Zomboid Workshop** (`workshop.cgi`): Steam Web API search, SteamCMD subscribe worker, `servertest`/`pzserver.ini` WorkshopItems/Mods patching
- PZ LGSM field **Admin-Passwort** (`adminpassword`) with auto-wired `startparameters` so first start does not hang on the interactive password prompt
- PZ **Server-INI** game-config tab rooted at `$HOME/Zomboid/Server/pzserver.ini` (LGSM default layout)
- PZ **SandboxVars** world-settings tab (`*_SandboxVars.lua`): all flattened keys as form fields + raw mode
- Root **LGSM deps install** worker (`./script install` as root after `setup_lgsm`) instead of maintaining full per-game `apt_deps` for LGSM titles
- Module config **Steam Web API key** on Integrations

### Changed

- **Workshop inventory** (`workshop.cgi`): installed list merges disk scan with INI — shows mod.info metadata, Steam titles (with API key), and per-item enable / disable / delete actions
- **Workshop subscribe dependencies:** Subscribe pulls transitive Steam Required items automatically (cap 20 workshop IDs including the selected mod); `Mods=` order places dependencies before dependents
- PZ stop uses a short direct/force path (like Minecraft) so a hung admin-password prompt no longer waits ~90s on LGSM `quit`
- Config editor GET render uses soft path checks (`check_game_config_path`) so paths outside `$script_dir` no longer abort the manage page via Webmin `&error`
- Collapsible section chevrons/borders made theme-visible

### Fixed

- After Workshop subscribe, job live view returns to `workshop.cgi` (not manage)
- Workshop dependency resolve used `ISteamRemoteStorage/GetPublishedFileDetails`, which omits Required items — switched to `IPublishedFileService/GetDetails` (`includechildren`) with HTML scrape fallback (e.g. Skill Recovery Journal deps)
- Firewall open/close is **protocol-aware**: opening UDP no longer skips when TCP is already allowed (broke PZ — only `16261/tcp` was opened). Manage firewall badge requires both tcp and udp
- PZ monitor: force LGSM `querymode=1` (session-only) so GameDig query FAIL no longer stop→start loops; longer monitor wait after PZ start
- Quick Fix create config when `lgsm/config-lgsm/<script>/` does not exist yet (realpath parent walk)
- Manage success banners no longer call nonexistent `ui_success` (HTTP 500 after Quick Fix)
- PZ `adminpassword` now wired into LGSM `startparameters` with correct escaped quotes; synced automatically before start (`pz_sync_lgsm_cfg.pl`)
- PZ Server-INI tab parses as key=value properties (was misread as Palworld OptionSettings) and lists **all** keys from the file

## [0.2.3] - 2026-09-02

### Added

- **Collapsible sections** on `manage.cgi` and `mods.cgi`: every block is a `<details>` section with a badge summary; open/closed state is remembered per section in `localStorage`, deep links (`#section`) open their section automatically
- Collapsible section styling: border, chevron (▶/▼), and a dedicated danger-zone frame for **Remove instance**
- **Inline job log card** on `manage.cgi` and `mods.cgi`: finished jobs open their output in-page (JSON fetch, no full reload); close with **Schließen** / **Close**
- **Upgrade check (MC / loader / mods)** on `mods.cgi`: ordered preflight that validates the target version first, then the opposite side, and only spends mod API calls when both hold. An MC upgrade is blocked when no loader build exists for the target MC version; a loader build bump is blocked when it does not belong to the profile's MC line
- Instance status line shared by `manage.cgi` and `mods.cgi` (runtime, monitor, loader/MC/Java, firewall)
- Update hint at the top of `manage.cgi` linking into the upgrades section

### Changed

- `manage.cgi` grouped into Controls, Monitoring and schedule, Upgrades and maintenance, Access, Configuration and diagnostics, and Remove instance
- **Live-Log** (server log tail) button moved to **Controls → Server controls** next to Start/Stop/Restart
- Configuration block on `manage.cgi` flattened — no nested collapsible inside *Configuration and diagnostics*
- **Remove instance** stays always visible (not collapsible)
- `mods.cgi` reordered: jobs, upgrade check, modpack import, mod search, installed mods. Modpack search, browser upload, and own file (FTP/SFTP) are nested collapsibles
- Loader and MC version lists are fetched on demand and cached instead of on every page load; the upgrade blocks render from cache
- Mod compatibility is scanned from the mods page on request, no longer during `manage.cgi` rendering

### Fixed

- Upgrade caches moved from `$SERVER_DIR/.webcore/` to the module config directory — no more root writes into game data
- MC upgrade preflight verifies loader build availability, so an upgrade can no longer fail late inside the worker
- `action=job_log_card` no longer falls through to LGSM server dispatch on `manage.cgi`
- Job log card fetch uses JSON (like `poll_job`) without `xnavigation=1`, so Webmin no longer returns a framed noscript page

## [0.2.2] - 2026-09-01

### Added

- **Mod dependencies:** Modrinth/CurseForge required deps parsed; preview on `mods.cgi`; worker installs up to five missing deps before the primary mod
- **Loader upgrade** on `manage.cgi`: pick a newer NeoForge/Fabric/Forge build (server stopped); job re-runs loader installer without wiping mods/world
- **Minecraft version upgrade:** bump MC version on `manage.cgi` with optional Java install step, then loader rebuild
- **Mod compat warning** before MC upgrade: read-only scan of indexed mods against target MC version
- **Reliable MC start:** `lgsm_control.sh` waits for session + optional `Done` in `latest.log` (large modpacks)
- Mods page: monitor restarts, jobs table, live-log polling aligned with manage

### Fixed

- Mods page success banners use alert styling (no `ui_success` guard regression)

### Changed

- Live-log / monitor auto-refresh interval 2s → 3s on manage and mods pages

## [0.2.1] - 2026-08-16

### Added

- Mods page: monitor status, last auto-restart (with job log link), jobs table, enable/disable monitoring — same visibility as manage for other games

### Fixed

- Mods page Start/Stop 500: `mods.cgi` now loads `logging.pl` (`log_action`)
- Single-mod install SHA1 check: Perl `print (EXPR), "\n"` gotcha no longer glues `prefer_disabled` onto the hash
- Live log: pick Minecraft `latest.log` / `debug.log` / rotated `*.log.gz` (gzip decompressed in-panel)
- Live log: “Back to instance” button; replace broken middle-dot separators with ASCII `-`
- Panel Start no longer re-enables an explicitly **disabled** monitor (`set_monitor_resume_after_start`)
- Forge/NeoForge start: LGSM uses `preexecutable=bash` + `executable=./run.sh` (not `java -jar ./run.sh`)
- Minecraft LGSM monitor: `querymode=1` (session only) so failed gamedig no longer stop/start-loops players
- Monitor UI: LGSM query-fail → graceful stop → start now records `monitor_restart` + `last_restart_*`
- Monitor restart job is recorded before state write so `last_restart_*` is reliable on the mods page

### Changed

- Friendlier installed-mod display names and server/client/unknown side column on the mods list
- Install/Java patch aligns `enable-query=true` and `query.port` with `server-port` in `server.properties`

## [0.2.0] - 2026-08-15

### Added

- Dedicated Minecraft **Mods page** (`mods.cgi`) with Start / Stop / Log toolbar for quick testing
- Installed mod/plugin list: search, filter (on/off), sort, pagination (~50)
- Per-mod **enable / disable** (`.jar` ↔ `.jar.disabled`) and **delete** with verified success feedback
- **Version picker** for updates and optional version choice on new installs (Modrinth / CurseForge / Hangar)
- Update installs replace the previous jar (including same-filename overwrite) and can preserve disabled state
- Mod search/install and **modpack** import UI moved onto the mods page (manage keeps a gated link only)
- Job live-log return URLs can keep mods-page list/search state safely
- Modded **reinstall** chain (`mc_reinstall_user.sh`): wipe `serverfiles/` then Java + loader from profile
- Start-time **JAVA_HOME** helper (`mc_java_env.sh`) and Forge/NeoForge wrapper preexecutable so `run.sh` does not use system JDK
- Profile **Java heal** when `java_major` lags behind MC version requirements

### Changed

- Manage page no longer embeds the large mod/modpack blocks; opens `mods.cgi` when the instance is mod-UI ready
- Modpack import prints pack-vs-instance comparison and soft version/Java warnings in the live log
- CurseForge/server import keeps mods with unknown side metadata (no longer skipped as client-only)

## [0.1.0] - 2026-08-10

### Added

- Initial public Webmin `.wbm` release
- Provisioning, jobs / live log, Minecraft loaders & modpack import, monitoring, integrations
