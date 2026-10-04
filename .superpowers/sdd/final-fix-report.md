# Final review fix report — feature/start-ready-monitor

**Date:** 2026-09-29  
**Branch:** `feature/start-ready-monitor`  
**Scope:** Important findings from final branch review (one pass)

## Status

All four Important findings fixed. `bash scripts/verify.sh` green. No push. No version bump.

## Fixes

### 1. Already-online skips ready-wait (PZ)

**File:** `src/scripts/lib/lgsm_control.sh`

When Project Zomboid session is already up, `lgsm_start_reliable` no longer returns success immediately. It captures the current console byte offset and runs `lgsm_start_wait_ready_marker` (same `*** SERVER STARTED ****` path as a fresh start). Minecraft already-online behaviour unchanged.

**Test:** `t/test_lgsm_control.sh` — already-online PZ waits for marker after current offset.

### 2. SteamCMD `mark_ready`

**File:** `src/scripts/steamcmd_control_user.sh`

`_finalize_detach_ok` now calls `monitor_mark_ready.pl` after successful start/restart (parity with `game_action_user.sh`), so monitor `starting`/`paused` clears to `running` for native/SteamCMD instances.

### 3. Start-log ready banner

**Files:** `src/lib/server_log.pl`, `src/lib/live_log.pl`

- Poll payload adds `started` / `status=online` when the log tail matches PZ `SERVER STARTED` or MC `Done (`.
- Embed passes `ready_banner_id=start_log_ready_banner` into poll JS.
- Poll JS unhides `#start_log_ready_banner` when `started` or `status` is online/started/running.

**Test:** `t/test_server_log.pl` — banner id, `readyBannerId`, poll `started` 0/1.

### 4. Flash-fail wording

**Files:** `src/mods.cgi`, `src/workshop.cgi`, `src/manage.cgi`, `src/lang/de`, `src/lang/en`

If job launch is verified OK but `server_log_start_log_flash_mark` fails, pages no longer call job-launch-failed / hard error. Soft-warn flash `start_log_embed_warn` + lang key `start_log_embed_unavailable` (de+en); redirect continues without embed (`start_log_warn=1`).

## Verify

```text
bash -n src/scripts/lib/lgsm_control.sh
bash -n src/scripts/steamcmd_control_user.sh
bash t/test_lgsm_control.sh
perl t/test_server_log.pl
perl t/test_start_ready.pl
bash scripts/verify.sh   # completed OK
```

## Concerns

- **PZ already-online + fully ready:** wait starts at current EOF, so an already-joinable server will not see a new marker and will sit until `start_ready_secs` then succeed with the existing timeout warning (session still up). Acceptable per design; operators rarely re-Start a fully ready PZ from the UI.
- **Ready banner heuristic:** `started` is derived from log-tail regex, not live tmux/PID status — intentional “simple” wiring for the embed; false negatives possible if the ready line scrolled out of the 8 KiB tail.
- **SteamCMD restart:** nested `start` path sets `ACTION=start`, so `mark_ready` still runs via `_finalize_detach_ok`.

---

# Final review fix report — player-query status

**Date:** 2026-10-04
**Scope:** Important findings from the final player-query code review

## Status

Both Important findings fixed. `bash scripts/verify.sh` green (full suite, exit 0). No commit, no push, no version bump.

## Fixes

### Important #1 — root writes to `$SERVER_DIR/.monitor` (Option A, as recommended)

**File:** `src/lib/player_query.pl`

`_pq_cache_write()` now takes a `$unix_user` third arg. When `$> == 0` (root Webmin CGI) and `$unix_user` matches the strict unix-user format, it:

1. Repairs `.monitor` dir ownership via a new `_pq_repair_cache_dir_owner()` (self-contained duplicate of `monitor.pl`'s owner-repair helper — not calling into `monitor.pl` to keep `player_query.pl`'s dependency list unchanged).
2. Writes the cache JSON via `su -s /bin/bash -c "mkdir -p ... && umask 077 && cat > ..." $unix_user` — same su-drop pattern as `write_monitor_state()` in `monitor.pl`.

Falls back to the original direct `open`/`chmod 0600` write when `$unix_user` is absent/invalid or euid is already non-root (user-native callers, tests).

`player_query_count()` now passes `$opts{'unix_user'}` into `_pq_cache_write()`. No caller changes needed in `manage.cgi` — both `player_query_status_html()` call sites (status line + `poll_players` action) already pass `unix_user => $unix_user` into `%opts`, which flows through `player_query_count()` unchanged.

Option A was straightforward (mirrors an existing, already-reviewed pattern) — Option B was not needed.

### Important #2 — RCON single-packet read can undercount large PZ `players` responses

**File:** `src/lib/player_query.pl`, `_pq_rcon_real_fetch()`

Added a clear English comment above the drain loop explaining the Source RCON ~4096-byte single-packet cap and that a response trickling in slower than the grace window could still be undercounted (not a full multi-packet protocol implementation).

Also implemented the "optional, if easy" drain: after the first `SERVERDATA_RESPONSE_VALUE` packet, the code now makes a best-effort attempt to read further packets within a short `PLAYER_QUERY_RCON_DRAIN_TIMEOUT` (0.2s) grace window and concatenates their bodies before parsing, so most multi-packet PZ `players` lists are no longer undercounted.

## Tests

- `t/test_player_query.pl`: added a case asserting `player_query_count(..., unix_user => '...')` still succeeds and writes a 0600 cache file via the direct-write fallback (uses a syntactically-invalid unix_user so the assertion is deterministic whether the test host is root or not — this sandbox runs tests as root, where `su` itself is blocked by sandboxing, so the real su branch is exercised only via code-review parity with `write_monitor_state`, same as that function's own test suite never exercises its su branch either).
- Result: **147/147 passed** (was 143; +4 new assertions), including existing cache TTL/mode-0600 coverage untouched.
- `bash scripts/verify.sh`: full suite green, exit code 0 (`t/test_player_query.pl` listed `ok` in both the general and critical-regression passes).
