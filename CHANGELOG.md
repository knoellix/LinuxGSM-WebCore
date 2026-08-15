# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-08-15

### Added

- Dedicated Minecraft **Mods page** (`mods.cgi`) with Start / Stop / Log toolbar for quick testing
- Installed mod/plugin list: search, filter (on/off), sort, pagination (~50)
- Per-mod **enable / disable** (`.jar` ↔ `.jar.disabled`) and **delete** with verified success feedback
- **Version picker** for updates and optional version choice on new installs (Modrinth / CurseForge / Hangar)
- Update installs replace the previous jar (including same-filename overwrite) and can preserve disabled state
- Mod search/install and **modpack** import UI moved onto the mods page (manage keeps a gated link only)
- Job live-log return URLs can keep mods-page list/search state safely

### Changed

- Manage page no longer embeds the large mod/modpack blocks; opens `mods.cgi` when the instance is mod-UI ready

## [0.1.0] - 2026-08-10

### Added

- Initial public Webmin `.wbm` release
- Provisioning, jobs / live log, Minecraft loaders & modpack import, monitoring, integrations
