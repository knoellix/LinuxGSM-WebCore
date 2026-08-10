# Subagent: Security & Isolation

Readonly audit. Scope paths from coordinator.

## Read first

- `.cursor/rules/security-isolation.mdc`
- `.cursor/skills/linuxgsm-webcore-audit/allowed-patterns.md`

## Search patterns

```bash
# Runtime apt outside provision_deps
rg -n 'apt-get|apt install|dpkg' src/scripts --glob '!provision_deps.sh'

# Root writes to server dirs (suspicious)
rg -n 'chown|chmod|write_file|open\(.*>' src/lib src/*.cgi | rg -v 'chown_job|_write_file_as_user|write_monitor|write_restart|provision'

# su usage — classify each hit
rg -n '\bsu\b' src/

# Missing escape in CGI output
rg -n 'print.*\$in\{|print.*\$_[^}]+[^html_escape]' src/*.cgi

# sanitize_input on optional fields
rg -n 'sanitize_input\(\$in\{' src/
```

## Check manually

- SteamCMD/Wine: kein `./script status` im LGSM-Sinn
- SFTP: `resolve_instance_sftp_user`
- Firewall: nur `firewall_*` API
- Config editor: `validate_config_target` vor Save
- Secrets in Logs/Commits

## Output

Bullet list only. Tag each: `critical` if privilege/data-loss; `important` if hardening gap.
