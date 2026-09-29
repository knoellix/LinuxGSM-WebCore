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
