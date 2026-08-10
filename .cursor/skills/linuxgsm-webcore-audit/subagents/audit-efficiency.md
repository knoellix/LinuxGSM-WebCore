# Subagent: Efficiency

Readonly audit. No premature micro-optimization — focus on clear waste.

## Look for

1. **Duplicate logic** — same parsing/validation in CGI and lib (extract to lib)
2. **Double file reads** — read same state file twice in one request (`manage.cgi`)
3. **Redundant su** — caller already game-user worker but still su-writes
4. **Sync heavy work in CGI** — sleep, long loops, steamcmd in request thread
5. **Repeated `require`** inside hot subs instead of top-level
6. **Copy-paste cron/build helpers** — merge candidates in monitor.pl vs schedule.pl (only if truly identical)
7. **N+1 registry walks** — `_load_registered()` in tight loops

## Search hints

```bash
rg -n '_load_registered\(\)' src/
rg -n 'read_monitor_state|read_restart_schedule' src/manage.cgi
rg -n 'sleep ' src/*.cgi
```

## Output

Bullet list severity `suggestion` or `important` if measurable request/worker cost.
Include **concrete refactor** (one sentence), not vague "could be faster".
