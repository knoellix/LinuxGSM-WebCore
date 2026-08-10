# Erlaubte Patterns — keine Findings

Diese Patterns sind **absichtlich** — nicht als Verstoss melden.

## su / Privilege

| Pattern | Erlaubt weil |
|---------|----------------|
| `user_worker_launch_cmd()` → `su -s /bin/bash -c '…' gameuser` | Einziger erlaubter Runtime-Privilege-Drop bei Dispatch |
| `write_restart_schedule()` / `write_monitor_state()` mit `su` als Game-User | Root-CGI schreibt `.monitor/*` im Namen des Users |
| `_write_file_as_user()` / `write_mc_profile()` mit `su` wenn `$> == 0` | Root-Kontext; bevorzugt direkter Write wenn Caller schon User ist |
| Root `chown` einmal nach `mkdir` auf `$SERVER_DIR` | Bootstrap only |
| `provision_deps.sh` mit `apt-get` | Einziger apt-Owner |
| `postinstall.pl` schreibt `/etc/cron.d/*` | Modul-Upgrade als root |

## Legacy / Kompatibilität

| Pattern | Erlaubt weil |
|---------|----------------|
| `steam_settings.cgi`, `config.cgi` → Redirect zu `integrations.cgi` | Legacy-URLs |
| `steamcmd_control.sh` (root) → `steamcmd_control_user.sh` | Dispatch-Wrapper |
| Root-only `mc_modpack_install.sh` → `*_user.sh` | Dispatch-Wrapper |

## Webmin / Perl

| Pattern | Erlaubt weil |
|---------|----------------|
| `return 1 if defined &foo;` am Anfang von `.pl` libs | Idempotent require guard |
| `eval { require … }` in `postinstall.pl` | Webmin-Kontext ohne harte Abhängigkeit |
| Hardcoded Fallback-Strings neben `$text{…}` | Defensive UI wenn Key fehlt |
| Deutsche Fallback-Strings in Code | Nur wenn `$text{}` fehlt — **trotzdem** Lang-Key nachziehen als 🟡 |

## Jobs

| Pattern | Erlaubt weil |
|---------|----------------|
| `$HOME/jobs/<id>` unter Game-User + Pointer unter `$config_directory/jobs/` | Design |
| `monitor_restart` / `scheduled_restart` ohne klassischen Dispatch | Cron/User-Worker legt Job selbst an |
| `sync_monitor_job_pointers()` liest `.monitor/state` + `schedule` | Pointer-Sync |

## Nicht erlauben (häufige False-„Erlaubnis“-Fehler)

- Runtime `apt` ausserhalb `provision_deps.sh`
- Root schreibt regelmässig in `$SERVER_DIR` (Logs, Config, Mods)
- Internes `su` **innerhalb** von `*_user.sh` auf Spieldaten
- Erfolgs-UI ohne Flash/Read-back/Job-status=ok
- `%s` in Lang-Dateien für `text()`
