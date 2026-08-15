# LinuxGSM-WebCore

Webmin module (`.wbm`) for provisioning and managing LinuxGSM, SteamCMD, and Wine game servers.

## Priority

User instruction > project rules (`.cursor/rules/`) > agent defaults. **Security and runtime stability over convenience.**

## Agent workflow

1. **Plan** before non-trivial code changes (`docs/superpowers/plans/` for larger features).
2. **Check** ports, Unix users, and dependencies before provisioning or service changes.
3. **Validate** Perl with `perl -c` before saving; shell scripts via `bash -n` or `verify.sh`.
4. **Verify** with `bash scripts/verify.sh` before claiming work is done.
5. **Build** for deploy: `bash scripts/build.sh` — no symlink/auto-sync to live Webmin.

## Commands

| Task | Command |
|------|---------|
| Standard verify | `bash scripts/verify.sh` |
| Full verify (releases) | `bash scripts/verify-full.sh` |
| Build `.wbm` | `bash scripts/build.sh` |
| Single test | `perl t/test_<name>.pl` |

**Deploy:** copy `dist/*.wbm` to `/tmp/`, then run `install-module.pl` (resolve via `command -v` or `/usr/share|/usr/libexec|/usr/lib/webmin` paths). WBM root inside tar: `linuxgsm-webcore/`.

## Project layout

| Path | Role |
|------|------|
| `src/*.cgi` | Webmin CGIs (`integrations.cgi` = Steam + download APIs + module debug) |
| `src/lib/*.pl` | Core libraries |
| `src/scripts/` | Background workers (LGSM, SteamCMD, monitor) |
| `src/lang/de`, `src/lang/en` | UI strings (`key=value`; both required for new keys) |
| `src/lib/games_meta.json` | Static game metadata |
| `$config_directory/games_meta_local.json` | Local game overrides |
| `src/defaultacl` | Default ACL fallback |
| `t/stubs.pl` | Standalone test stubs |
| `docs/superpowers/` | Specs and implementation plans |

**Legacy redirects:** `steam_settings.cgi`, `config.cgi` → `integrations.cgi`.

## Function map

| Need | File |
|------|------|
| `list_webmin_users()` | `src/lib/acl.pl` |
| `get_game_list()` | `src/lib/games.pl` |
| `get_game_fields()`, `get_game_live_log_path()` | `src/lib/games_meta.pl` |
| Instance registry, status, `instance_is_lgsm()` | `src/lib/instance.pl` |
| Jobs, action labels | `src/lib/jobs.pl` |
| Config editor | `src/lib/config_editor.pl` |
| Steam accounts | `src/lib/steam.pl` |
| Module config load/save/flash, worker bootstrap | `src/lib/module_config.pl` |
| MC profile / loader / compat | `src/lib/mc_profile.pl`, `src/lib/mc_loader.pl`, `src/lib/mc_compat.json` (+ optional `mc_compat_local.json`) |
| Mods API, download whitelist | `src/lib/mc_mods.pl` |
| Modpack search/import/resolve/errors | `src/lib/mc_modpack.pl` |
| Monitor cron rebuild | `src/lib/monitor.pl` |
| Live log / job server | `src/lib/live_log.pl`, `src/job_live.cgi` |

## Workers (short)

- **Game-user side:** monitoring (`monitor_instance_user.sh`), SteamCMD control (`steamcmd_control_user.sh`), file writes in `$SERVER_DIR`.
- **Root dispatch:** starts user workers, apt, provisioning, cron install.
- **Perl helpers** (`mc_modpack_expand_meta.pl`, …): `module_config_bootstrap_standalone($MODULE_ROOT)` before reading API keys.
- **Live log:** all background jobs → `job_live.cgi`; output in `$JOB_DIR/output`, status in `$JOB_DIR/status`.

## Standards (short)

- UI text: **German**; code and comments: **English**.
- Webmin UI: only `ui_*` helpers; escape dynamic HTML with `html_escape()`.
- Webmin-native-first: use core Webmin patterns before custom workarounds.
- Game ops in `$SERVER_DIR`: always as game user via `su -s /bin/bash -c` or `_write_file_as_user()` — never bare `chown` on game files.
- `&redirect(...)` must always be followed by `exit;`.
- **Success feedback:** verified outcome only — see `.cursor/rules/no-blind-success-feedback.mdc`. Config saves: `src/lib/module_config.pl` (write + read-back + one-time flash). Async jobs: outcome from `$JOB_DIR/status`, errors in Live-Log with specific messages (not generic “failed”).

## Detailed rules

Cursor loads topic rules from `.cursor/rules/` (by glob). Key topic files:

| Rule | Topic |
|------|--------|
| `instance-jobs.mdc` | Jobs, live log, per-user monitor cron |
| `workers-shell.mdc` | Shell workers, game-user dispatch, job_log, config bootstrap |
| `minecraft-mods.mdc` | MC profile, mods, modpack import, CurseForge/Modrinth |
| `no-blind-success-feedback.mdc` | Verified success, flash pattern |
| `security-isolation.mdc` | Unix users, su boundary |
| `webmin-cgi.mdc` | CGI bootstrap, redirects |

Custom agents in `.cursor/agents/`. Periodic quality: skill `.cursor/skills/linuxgsm-webcore-audit/` + agent `linuxgsm-auditor`; reports in `docs/audits/`.
