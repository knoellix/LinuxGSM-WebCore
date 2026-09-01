# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
