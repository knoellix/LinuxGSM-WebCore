# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.1] - 2026-08-16

### Fixed

- Mods page Start/Stop 500: `mods.cgi` now loads `logging.pl` (`log_action`)
- Single-mod install SHA1 check: Perl `print (EXPR), "\n"` gotcha no longer glues `prefer_disabled` onto the hash
- Live log: pick Minecraft `latest.log` / `debug.log` / rotated `*.log.gz` (gzip decompressed in-panel)
- Live log: “Back to instance” button; replace broken middle-dot separators with ASCII `-`

### Changed

- Friendlier installed-mod display names and server/client/unknown side column on the mods list

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
