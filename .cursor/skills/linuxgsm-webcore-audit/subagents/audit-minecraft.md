# Subagent: Minecraft & Modpack

Readonly audit. Focus: `src/lib/mc_*.pl`, `src/scripts/mc_*`, MC paths in `manage.cgi`.

## Read first

- `.cursor/rules/minecraft-mods.mdc`
- `.cursor/skills/linuxgsm-webcore-audit/allowed-patterns.md`

## Search patterns

```bash
# Resolve/download in CGI (should be worker)
rg -n 'curseforge|modrinth|expand_remote|download.url' src/*.cgi

# Generic modpack failure text
rg -n "modpack.*failed|import failed" src/ -i

# worker_secrets / bootstrap
rg -n 'module_config_bootstrap_standalone|write_job_worker_secrets|worker_secrets' src/

# Internal su in user MC workers
rg -n '\bsu\b' src/scripts/mc_*_user.sh

# mc_modpack_error_message usage in workers
rg -n 'mc_modpack_error_message|ERROR:' src/scripts/mc_*
```

## Check manually

- Remote modpack import: CGI only validates source+project_id, job → `job_live.cgi`
- Workers: `module_config_bootstrap_standalone($MODULE_ROOT)` + `WEBCORE_JOB_DIR`
- CurseForge: `curseforge_extract_download_url()` for string `data` field
- Errors: concrete `mc_modpack_resolve_*` keys in de+en; `ERROR:` in job output
- Mod writes under `$SERVER_DIR/serverfiles/` as game user
- Adopt flow: single job with substeps, `user_worker_launch_cmd()` dispatch
- Tests: `test_mc_modpack.pl`, `test_mc_mods.pl`, `test_mc_profile.pl`, `test_mc_loader.pl`

## Output

Bullet list. `critical` = resolve in CGI or missing API key bootstrap; `important` = generic error or missing lang keys.
