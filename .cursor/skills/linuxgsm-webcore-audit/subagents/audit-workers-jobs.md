# Subagent: Workers & Jobs

Readonly audit. Focus: `src/scripts/**`, `src/lib/jobs.pl`, `src/lib/monitor.pl`, `src/lib/schedule.pl`.

## Read first

- `.cursor/rules/workers-shell.mdc`
- `.cursor/rules/instance-jobs.mdc`
- `.cursor/skills/linuxgsm-webcore-audit/allowed-patterns.md`

## Search patterns

```bash
# Ad-hoc root worker launch (should use user_worker_launch_cmd)
rg -n 'setsid nohup bash' src/

# Missing MODULE_ROOT
rg -l 'bash.*scripts/' src/*.cgi src/lib | xargs rg -L 'MODULE_ROOT' 2>/dev/null

# Internal su inside user workers
rg -n '\bsu\b' src/scripts/*_user.sh src/scripts/monitor_instance_user.sh

# Job status not set
rg -n 'status' src/scripts/*_user.sh | head

# worker_secrets
rg -n 'worker_secrets|write_job_worker_secrets' src/
```

## Check manually

- Cron lines: game user, not root (`monitor.pl`, `schedule.pl`)
- `job_dispatch_verified` after launch
- Game-user Perl: `module_config_bootstrap_standalone` + `WEBCORE_JOB_DIR`
- Long ops not blocking CGI without job

## Output

Bullet list. `critical` = root on game data or missing job status; `important` = dispatch anti-pattern.
