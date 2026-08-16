# LinuxGSM-WebCore

Webmin module (`.wbm`) for provisioning and managing LinuxGSM, SteamCMD, and Wine game servers.

## Priority

User instruction > project rules (`.cursor/rules/`) > agent defaults. **Security and runtime stability over convenience.**

## Agent workflow

1. **Plan** before non-trivial code changes (`docs/superpowers/plans/` for larger features).
2. **Check** ports, Unix users, and dependencies before provisioning or service changes.
3. **Validate** Perl with `perl -c` before saving; shell via `bash -n` / `verify.sh`.
4. **Verify** with `bash scripts/verify.sh` before claiming work is done.
5. **Build** for deploy: `bash scripts/build.sh` — no symlink/auto-sync to live Webmin.

## Commands

| Task | Command |
|------|---------|
| Standard verify | `bash scripts/verify.sh` |
| Full verify (releases) | `bash scripts/verify-full.sh` |
| Build `.wbm` | `bash scripts/build.sh` |
| Single test | `perl t/test_<name>.pl` |

**Deploy:** copy `dist/*.wbm` to `/tmp/`, then `install-module.pl` (via `command -v` or `/usr/share|/usr/libexec|/usr/lib/webmin`). WBM root inside tar: `linuxgsm-webcore/`.

## Project layout

| Path | Role |
|------|------|
| `src/*.cgi` | Webmin CGIs — `mods.cgi` = MC mods/modpacks; `integrations.cgi` = Steam + download APIs |
| `src/lib/*.pl` | Core libraries |
| `src/scripts/` | Background workers (+ `lib/mc_java_env.sh`, `mc_reinstall_user.sh`, …) |
| `src/lang/de`, `src/lang/en` | UI strings (both required for new keys) |
| `src/lib/games_meta.json` | Static game metadata |
| `$config_directory/games_meta_local.json` | Local game overrides |
| `CHANGELOG.md` | Release notes (bump `src/module.info` with packaging) |
| `docs/superpowers/` | Specs and plans |

**Legacy redirects:** `steam_settings.cgi`, `config.cgi` → `integrations.cgi`.

## Function map

| Need | File |
|------|------|
| ACL / games / registry / jobs | `acl.pl`, `games.pl`, `instance.pl`, `jobs.pl` |
| Config editor / Steam / module config | `config_editor.pl`, `steam.pl`, `module_config.pl` |
| MC profile, Java sync, loader chain | `mc_profile.pl`, `mc_loader.pl`, `mc_compat.json` |
| Mods API + list/enable/disable | `mc_mods.pl`; UI: `mods.cgi` (manage links only) |
| Modpack parse/validate/import | `mc_modpack.pl` |
| Monitor / live log | `monitor.pl`, `live_log.pl`, `job_live.cgi` |

## Minecraft (must-know)

- **UI:** mods/modpacks live on `mods.cgi`; manage only shows a gated link when `mc_mod_ui_ready`.
- **Java:** profile `java_major` must match `resolve_java_major(mc_version)` — heal via `mc_profile_java_needs_sync` / `mc_profile_sync_java_fields`; install verifies real JVM major.
- **Start:** Forge/NeoForge: `executable=./run.sh` + `lgsm_preexecutable=bash` (never `java -jar ./run.sh`). Pin absolute Temurin in `run.sh` via `mc_java_env_apply` / loader install. Sed pin: `#` delimiter when the regex contains `|`.
- **Monitor:** MC LGSM `querymode=1` (session only) — gamedig false-fails kill players; still sync `enable-query`/`query.port=server-port`. Query-fail restarts must appear as `monitor_restart` jobs + `last_restart_*`.
- **Reinstall (modded):** `mc_reinstall_user.sh` (wipe `serverfiles/` → Java + loader). Vanilla/Paper stay on `game_action_user.sh`.
- **Disable mods:** rename `.jar` ↔ `.jar.disabled` as game user; restart needed for loader pickup.
- Details: `.cursor/rules/minecraft-mods.mdc`.

## Workers (short)

- **Game-user:** monitor, SteamCMD control, `$SERVER_DIR` writes, MC install/update/modpack (user-native).
- **Root dispatch:** start user workers, apt/provision, system cron — no root writes to game data at runtime.
- Standalone Perl helpers: `module_config_bootstrap_standalone($MODULE_ROOT)` (+ `WEBCORE_JOB_DIR` for secrets).
- Jobs → `job_live.cgi`; success only `$JOB_DIR/status=ok`.

## Standards (short)

- UI text: **German**; code/comments: **English**.
- Only `ui_*`; `html_escape()` on dynamic HTML; no hardcoded colors.
- `&redirect(...)` always followed by `exit;`.
- Verified success only — `.cursor/rules/no-blind-success-feedback.mdc`.

## Topic rules

| Rule | Topic |
|------|--------|
| `instance-jobs.mdc` | Jobs, live log, monitor cron |
| `workers-shell.mdc` | Shell workers, game-user dispatch, job_log |
| `minecraft-mods.mdc` | Profile, Java, mods page, modpacks, APIs |
| `no-blind-success-feedback.mdc` | Flash / verify success |
| `security-isolation.mdc` | Unix users, su boundary |
| `webmin-cgi.mdc` | CGI bootstrap, redirects |
| `project-core.mdc` | Workflow, integrations config |

Custom agents: `.cursor/agents/`. Audits: skill `linuxgsm-webcore-audit` → `docs/audits/`.
