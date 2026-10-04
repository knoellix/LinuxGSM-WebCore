# Auto-Update Check + Warned Restart — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-instance auto-check for game build + workshop updates (PZ v1), with optional player countdown messages and a hard restart that installs updates (stop → optional LGSM update → start).

**Architecture:** State file + game-user cron checker (like schedule/monitor). Modular adapter interface; v1 = PZ (`servermsg`, Steam build + workshop `time_updated`). Manage UI under Upgrades/maintenance. Restart uses existing lifecycle (`lgsm_stop_reliable` / `lgsm_start_reliable`).

**Tech Stack:** Perl (`auto_update.pl`, `manage.cgi`, `pz_workshop.pl`), bash worker + cron, `lgsm_control.sh` broadcast, Steam Web API, `t/` tests, `bash scripts/verify.sh`.

**Spec:** `docs/superpowers/specs/2026-10-03-auto-update-restart-design.md` (approved 2026-10-03).

## Global Constraints

- Modular adapter; **v1 PZ only** (other games later, same shell)
- Separate toggles: `check_game` / `check_workshop` (defaults on when master enabled)
- Players online → fixed warn raster **15,10,5,1,0** then **hard** restart (no wait-until-empty)
- Install path: stop → LGSM update **only if** `need_game` → start; workshop via PZ boot (no bulk `workshop_download_item` in v1)
- State: `$SERVER_DIR/.monitor/auto_update` (game-user owned)
- Cron: game-user lines (like schedule), rebuild on save / postinstall
- No parallel action if start/stop/restart/update job already running for instance
- Steam API failure → skip check (log), do **not** restart
- No API key + workshop on → skip workshop check, show UI hint; game check may continue
- Player count unknown → treat as **players > 0** (warn path)
- UI strings: `src/lang/de` + `src/lang/en`; code/comments English; `ui_*` only
- Verified success / flash on save (no blind success)
- Game-user runtime for `$SERVER_DIR`; root only for cron.d rewrite
- Include already-landed local fixes: Gamedig preflight + clear monitor starting on failed start/restart
- `bash scripts/verify.sh` green before claiming done
- **Version bump** only when user asks (with this feature)
- **No commits** unless user asks

## File map

| File | Role |
|------|------|
| `src/lib/auto_update.pl` | State R/W, validation, message fill, adapter dispatch, cron rebuild |
| `src/lib/auto_update_pz.pl` | PZ adapter: build IDs, workshop stamps, players, broadcast cmd |
| `src/scripts/auto_update_check_user.sh` | Cron entry: detect → pending / messages / launch restart job |
| `src/scripts/auto_update_restart_user.sh` | Job: messages → stop → [update] → start → clear pending |
| `src/manage.cgi` | UI block + `save_auto_update` |
| `src/postinstall.pl` | Rebuild auto-update cron |
| `src/lang/de`, `src/lang/en` | Labels / defaults / errors |
| `src/scripts/lib/lgsm_control.sh` | Already: gamedig ensure (ship with release) |
| `src/scripts/game_action_user.sh` | Already: clear starting on fail |
| `t/test_auto_update.pl` | State, messages, adapter stubs, decisions |
| `t/test_auto_update.sh` | Shell worker smoke with mocks |
| `CHANGELOG.md` | Unreleased → version section on bump |

---

### Task 0: Land Gamedig + monitor-grace fixes

**Files:**
- Modify: `src/scripts/lib/lgsm_control.sh` (ensure gamedig — may already be in tree)
- Modify: `src/scripts/game_action_user.sh`, `src/manage.cgi`
- Modify: `t/test_lgsm_control.sh`, `t/test_monitor_state.pl`, `CHANGELOG.md`

**Interfaces:**
- Produces: `lgsm_ensure_gamedig($server_dir)`; failed start/restart clears monitor starting

- [ ] **Step 1:** Confirm working tree has gamedig preflight + failed-start grace clear; if missing, restore from spec “Bezug zu aktuellen Fixes”
- [ ] **Step 2:** `bash t/test_lgsm_control.sh` and `perl t/test_monitor_state.pl` green
- [ ] **Step 3:** Leave uncommitted until user asks (or fold into final feature commit)

---

### Task 1: State library + validation (TDD)

**Files:**
- Create: `src/lib/auto_update.pl`
- Create: `t/test_auto_update.pl`

**Interfaces:**
- Produces:
  - `read_auto_update($server_dir)` → hashref defaults
  - `write_auto_update($server_dir, $href, $unix_user)` → 1/0
  - `validate_auto_update_interval($min)` → 1/0 (e.g. 5–1440)
  - `validate_warn_minutes($csv)` → 1/0 (sorted unique non-neg ints, must include 0 or allow 0 separately)
  - `auto_update_fill_message($template, \%vars)` → string
  - `auto_update_file($server_dir)` → path

- [ ] **Step 1:** Write failing tests for defaults, round-trip write/read, bad interval, bad warn CSV, message placeholders
- [ ] **Step 2:** Implement minimal `auto_update.pl` (kv file like `schedule.pl`)
- [ ] **Step 3:** `perl t/test_auto_update.pl` green
- [ ] **Step 4:** Wire into `verify.sh` when worker/UI tasks land (or add now)

Defaults:

```
enabled=0
check_game=1
check_workshop=1
interval_min=30
warn_minutes=15,10,5,1,0
msg_template=Server-Neustart in {minutes} Min — {reason}
msg_now=Server startet jetzt neu — {reason}
pending=0
countdown_deadline=0
need_game=0
need_workshop=0
```

---

### Task 2: PZ adapter (detect + broadcast + players)

**Files:**
- Create: `src/lib/auto_update_pz.pl`
- Modify: `t/test_auto_update.pl`
- Reuse: `pz_workshop.pl` (`pz_workshop_steam_details`, INI read, content roots), `lgsm_control.sh` tmux send (from shell)

**Interfaces:**
- Consumes: workshop INI helpers, Steam details
- Produces (Perl, for tests + optional CGI hints):
  - `auto_update_adapter_for_script($script)` → `'pz'` / `''`
  - `auto_update_pz_game_build_local($server_dir)` → buildid string or `''`
  - `auto_update_pz_game_build_remote()` → buildid or error
  - `auto_update_pz_workshop_diff($unix_user, $server_dir, $script)` → `{ changed => [...], err => }`
  - `auto_update_pz_player_count($server_dir, $script)` → int or `-1` unknown
  - `auto_update_pz_broadcast_cmd($text)` → shell-safe console line `servermsg "..."`  

Shell worker may call a thin Perl helper script for detect (preferred over embedding Steam in bash):

- Create: `src/scripts/auto_update_detect.pl` — prints KEY=value for bash eval (`NEED_GAME=1`, `MODS=…`, `PLAYERS=0`, `REASON=…`, `ERR=…`)

- [ ] **Step 1:** Failing tests with fixtures for appmanifest buildid + workshop mtime vs stubbed `time_updated`
- [ ] **Step 2:** Implement adapter + detect helper (network mocked in unit tests)
- [ ] **Step 3:** Remote game build: use SteamCMD `+app_info_print 380870` **or** existing Steam Web API pattern if already in repo; document chosen method in code comment; fail soft on error
- [ ] **Step 4:** Tests green

---

### Task 3: Check worker + cron rebuild

**Files:**
- Create: `src/scripts/auto_update_check_user.sh`
- Modify: `src/lib/auto_update.pl` — `rebuild_auto_update_cron($module_root, $config_dir)`
- Modify: `src/postinstall.pl` — call rebuild
- Create: `t/test_auto_update_cron.pl` (or extend `t/test_auto_update.pl`)
- Cron path: `/etc/cron.d/linuxgsm-webcore-auto-update` (game-user field, like schedule)

**Interfaces:**
- Consumes: detect.pl, state R/W, `find_running_job_for_instance` via Perl one-liner or jobs helper
- Produces: check script exit 0 always unless hard misconfig; may `setsid`/job-launch restart worker

Check logic (pseudocode):

```
read state; exit if !enabled
if adapter missing → exit
if job running for instance → log skip; exit
run detect → if ERR and no usable signal → log; update last_check; exit
if no need_game and no need_workshop → clear stale pending only if not in countdown? keep last_check; exit
set pending + need_* + reason/mods
if players<=0 → launch restart job; exit
if countdown_deadline==0 → set deadline = now + max(warn_minutes)
for each due warn minute not yet sent → broadcast; mark sent in state (msg_sent=15,10 or bitmask)
if now >= deadline → launch restart job
```

Track sent messages via `msg_sent` CSV of minutes already announced (avoid spam).

- [ ] **Step 1:** Test cron line generation (enabled instance → line; disabled → absent)
- [ ] **Step 2:** Implement rebuild + check script with mocked detect
- [ ] **Step 3:** Shell test: pending + players 0 → would call restart launcher (mock)
- [ ] **Step 4:** Shell test: players >0 → sets deadline, no second deadline
- [ ] **Step 5:** `bash -n` on scripts; tests green

---

### Task 4: Restart worker

**Files:**
- Create: `src/scripts/auto_update_restart_user.sh`
- Modify: `t/test_auto_update.sh`
- Reuse: `lgsm_control.sh`, `job_log.sh`, `monitor_mark_ready.pl`, game_action patterns

**Interfaces:**
- Job meta action: `auto_update_restart`
- Env/state: `need_game`, templates, server_dir, script
- Flow: optional final `msg_now` → `lgsm_stop_reliable` → if need_game: `./script update` with timeout → `lgsm_start_reliable` → clear pending/countdown → mark_ready → status ok/failed

- [ ] **Step 1:** Failing shell test with mocked stop/update/start
- [ ] **Step 2:** Implement worker (user-native, MODULE_ROOT, job_dir)
- [ ] **Step 3:** On failure: clear monitor starting (call mark_ready.pl); leave pending=1 so next check can retry **or** clear pending per spec “nächster Check darf neu planen” — **choose: clear need flags but keep last reason in log; set pending=0 after failed attempt to avoid tight loop; next interval re-detects**
- [ ] **Step 4:** Tests green

---

### Task 5: Manage UI + save

**Files:**
- Modify: `src/manage.cgi` (upgrades section)
- Modify: `src/lang/de`, `src/lang/en`
- Modify: `t/test_page_layout.pl` (keys / form action present for PZ)

**Interfaces:**
- POST `action=save_auto_update`
- Flash `auto_update_save_$instance_id`
- Show block only when `auto_update_adapter_for_script($script) ne ''`

Fields: enabled, check_game, check_workshop, interval_min, warn_minutes, msg_template, msg_now  
Status rows: last_check, pending/countdown, last_restart_job link  
Hint if workshop on and no Steam API key  
**Howto blurb** above the form (DE+EN): unusual client/server workshop sync — restart checks/pulls workshop; Auto-Update polls and restarts when needed so versions match. Keys: `auto_update_howto_title`, `auto_update_howto_body`.

- [ ] **Step 1:** Lang keys both files including howto title/body
- [ ] **Step 2:** Render howto + form; save with validate + write + cron rebuild + flash
- [ ] **Step 3:** Layout/smoke test asserts howto keys / section present for PZ
- [ ] **Step 4:** Manual checklist note in plan completion

---

### Task 6: Wire jobs labels + verify + CHANGELOG

**Files:**
- Modify: `src/lib/jobs.pl` — action label `auto_update_restart`
- Modify: `scripts/verify.sh` — include new tests
- Modify: `CHANGELOG.md`
- Modify: spec status → implemented when done

- [x] **Step 1:** Lang + `job_action_label` for new action
- [x] **Step 2:** `bash scripts/verify.sh`
- [x] **Step 3:** CHANGELOG under Unreleased (or version section when user bumps)
- [ ] **Step 4:** Stop — ask user for version bump + commit/push

---

## Manual test checklist (root server PZ)

1. Enable auto-update, game+workshop, interval 30, defaults messages  
2. With 0 players and forced pending (or real workshop bump) → restart job runs, server returns  
3. With players → see `servermsg` at 15/10/5/1/0 then restart  
4. Disable master → no cron line / no checks  
5. Workshop only / game only toggles  
6. No API key → workshop skipped, UI hint, game still works  
7. Gamedig missing → start still succeeds via preflight  

---

## Execution note

After this plan is written, implement via **subagent-driven-development** (one task per subagent + review) or **executing-plans** in this session. Do not bump `module.info` until the user explicitly asks.
