#!/usr/bin/env bash
# Unit tests for lgsm_control.sh (no real tmux/Java required for most cases).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../src/scripts/lib/lgsm_control.sh
. "$ROOT/src/scripts/lib/lgsm_control.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- minecraft detection ---
mkdir -p "$TMP/mc-a" "$TMP/mc-b/lgsm/config-lgsm/mcserver"
touch "$TMP/mc-a/.mcprofile.json"
printf 'gamename="Minecraft"\nport="25565"\n' >"$TMP/mc-b/lgsm/config-lgsm/mcserver/mcserver.cfg"
mkdir -p "$TMP/other"

lgsm_is_minecraft_instance "$TMP/mc-a" mcserver || { echo "fail: profile detect"; exit 1; }
lgsm_is_minecraft_instance "$TMP/mc-b" mcserver || { echo "fail: cfg gamename detect"; exit 1; }
if lgsm_is_minecraft_instance "$TMP/other" pwserver; then
    echo "fail: non-mc should be false"
    exit 1
fi

# --- stop when already offline ---
out="$(lgsm_stop_direct "$TMP/other" pwserver stop 2 2>&1)"
echo "$out" | grep -qi 'Already offline' || { echo "fail: already offline message: $out"; exit 1; }

# --- stop_reliable picks direct for MC ---
out="$(lgsm_stop_reliable "$TMP/mc-a" mcserver 2>&1)"
echo "$out" | grep -qi 'direct' || { echo "fail: expected direct stop path: $out"; exit 1; }

# --- Project Zomboid detection + direct stop path ---
mkdir -p "$TMP/pz/lgsm/config-default/config-lgsm/pzserver"
printf 'gamename="Project Zomboid"\nengine="projectzomboid"\n' \
    >"$TMP/pz/lgsm/config-default/config-lgsm/pzserver/_default.cfg"
lgsm_is_project_zomboid_instance "$TMP/pz" pzserver || { echo "fail: pz detect"; exit 1; }

# --- Gamedig present / ensure no-op when marker exists ---
if lgsm_gamedig_present "$TMP/pz"; then
    echo "fail: gamedig should be absent initially"
    exit 1
fi
mkdir -p "$TMP/pz/lgsm/node_modules/gamedig/bin"
touch "$TMP/pz/lgsm/node_modules/gamedig/bin/gamedig.js"
lgsm_gamedig_present "$TMP/pz" || { echo "fail: gamedig present after marker"; exit 1; }
out="$(lgsm_ensure_gamedig "$TMP/pz" 2>&1)"
echo "$out" | grep -qi 'Ensuring Gamedig' && { echo "fail: ensure should no-op when present: $out"; exit 1; }

# --- start_reliable calls ensure before CLI when offline ---
unset -f lgsm_is_started lgsm_run_timeout lgsm_ensure_gamedig \
    lgsm_lifecycle_wait_ready 2>/dev/null || true
_pz_flip=0
lgsm_ensure_gamedig() { echo "ensure-called"; return 0; }
lgsm_lifecycle_wait_ready() { echo "ready-ok"; return 0; }
lgsm_is_started() {
    if [[ "$_pz_flip" -eq 1 ]]; then return 0; fi
    return 1
}
lgsm_run_timeout() { _pz_flip=1; echo "cli-start"; return 0; }
out="$(lgsm_start_reliable "$TMP/pz" pzserver 5 2>&1)"
echo "$out" | grep -q 'ensure-called' || { echo "fail: expected ensure before start: $out"; exit 1; }
echo "$out" | grep -q 'cli-start' || { echo "fail: expected CLI start after ensure: $out"; exit 1; }
unset -f lgsm_is_started lgsm_run_timeout lgsm_ensure_gamedig \
    lgsm_lifecycle_wait_ready 2>/dev/null || true
# Restore real functions after mocks (later tests redefine as needed).
# shellcheck source=../src/scripts/lib/lgsm_control.sh
. "$ROOT/src/scripts/lib/lgsm_control.sh"
if lgsm_is_project_zomboid_instance "$TMP/other" pwserver; then
    echo "fail: non-pz should be false"
    exit 1
fi
out="$(lgsm_stop_reliable "$TMP/pz" pzserver 2>&1)"
echo "$out" | grep -qi 'Project Zomboid' || { echo "fail: expected PZ direct stop: $out"; exit 1; }

# --- start when "online" via mocked lgsm_tmux_is_online ---
lgsm_tmux_is_online() { return 0; }
out="$(lgsm_start_reliable "$TMP/mc-a" mcserver 5 2>&1)"
echo "$out" | grep -qi 'Already online' || { echo "fail: already online start: $out"; exit 1; }

# --- latest.log discovery + Done-after-offset ---
mkdir -p "$TMP/mc-a/serverfiles/logs"
printf 'old Done (1.0s)!\n' >"$TMP/mc-a/serverfiles/logs/latest.log"
log="$(lgsm_mc_latest_log "$TMP/mc-a")"
[[ "$log" == "$TMP/mc-a/serverfiles/logs/latest.log" ]] || { echo "fail: latest.log path: $log"; exit 1; }
off=$(wc -c <"$log" | tr -d ' ')
if lgsm_mc_log_has_done_after "$log" "$off"; then
    echo "fail: Done should not match only-old content"
    exit 1
fi
printf '[Server thread/INFO]: Done (42.0s)! For help, type "help"\n' >>"$log"
lgsm_mc_log_has_done_after "$log" "$off" || { echo "fail: Done after offset"; exit 1; }

# --- MC start waits for Done (mocked spawn + short ready timeout) ---
unset -f lgsm_tmux_is_online 2>/dev/null || true
_mc_started=0
lgsm_is_started() {
    [[ "$_mc_started" -eq 1 ]] && return 0
    return 1
}
lgsm_run_timeout() {
    _mc_started=1
    return 0
}
# Pre-seed log; append Done quickly via background while wait loop runs
: >"$TMP/mc-a/serverfiles/logs/latest.log"
(
    sleep 1
    printf '[Server thread/INFO]: Done (3.0s)!\n' >>"$TMP/mc-a/serverfiles/logs/latest.log"
) &
export WEBCORE_MC_START_CLI_SECS=2 WEBCORE_MC_START_SPAWN_SECS=5 WEBCORE_MC_START_READY_SECS=10
out="$(lgsm_start_minecraft "$TMP/mc-a" mcserver 2>&1)"
echo "$out" | grep -qiE 'Ready: (Done|marker)' || { echo "fail: expected Ready Done: $out"; exit 1; }
unset WEBCORE_MC_START_CLI_SECS WEBCORE_MC_START_SPAWN_SECS WEBCORE_MC_START_READY_SECS

# --- java pid filter: empty when no java ---
pids="$(lgsm_java_pids_for_server "$TMP/mc-a" || true)"
[[ -z "$pids" ]] || { echo "fail: unexpected java pids: $pids"; exit 1; }

# --- generic ready-after-offset + console log path ---
mkdir -p "$TMP/pz/log/console"
printf 'old *** SERVER STARTED ****\n' >"$TMP/pz/log/console/pzserver-console.log"
clog="$(lgsm_console_log "$TMP/pz" pzserver)"
[[ "$clog" == "$TMP/pz/log/console/pzserver-console.log" ]] || { echo "fail: console log path: $clog"; exit 1; }
coff=$(wc -c <"$clog" | tr -d ' ')
if lgsm_log_has_ready_after "$clog" "$coff" '\*\*\* SERVER STARTED \*\*\*\*'; then
    echo "fail: ready should not match only-old content"
    exit 1
fi
printf 'LOG  : General     , *** SERVER STARTED ****\n' >>"$clog"
lgsm_log_has_ready_after "$clog" "$coff" '\*\*\* SERVER STARTED \*\*\*\*' \
    || { echo "fail: ready after offset"; exit 1; }

# --- PZ start waits for SERVER STARTED (mocked spawn + short ready timeout) ---
unset -f lgsm_is_started lgsm_run_timeout 2>/dev/null || true
_pz_started=0
lgsm_is_started() {
    [[ "$_pz_started" -eq 1 ]] && return 0
    return 1
}
lgsm_run_timeout() {
    _pz_started=1
    return 0
}
: >"$TMP/pz/log/console/pzserver-console.log"
(
    sleep 1
    printf 'LOG  : General     , *** SERVER STARTED ****\n' \
        >>"$TMP/pz/log/console/pzserver-console.log"
) &
export WEBCORE_PZ_START_READY_SECS=10
out="$(lgsm_start_reliable "$TMP/pz" pzserver 5 2>&1)"
echo "$out" | grep -qi 'Ready: marker seen' || { echo "fail: expected PZ Ready marker: $out"; exit 1; }
unset WEBCORE_PZ_START_READY_SECS

# --- Console truncate after offset capture: must still see ready (not hang) ---
# Pre-start log is large → offset high; LGSM spawn truncates then writes marker.
# With workshop stall-pause + pending, a stuck offset would hang until ready_secs.
unset -f lgsm_is_started lgsm_run_timeout 2>/dev/null || true
_pz_started=0
lgsm_is_started() {
    [[ "$_pz_started" -eq 1 ]] && return 0
    return 1
}
python3 - <<'PY' >"$TMP/pz/log/console/pzserver-console.log"
print("x" * 50000)
print("old noise without marker")
PY
lgsm_run_timeout() {
    _pz_started=1
    : >"$TMP/pz/log/console/pzserver-console.log"
    (
        sleep 1
        printf 'LOG  : General     , *** SERVER STARTED ****\n' \
            >>"$TMP/pz/log/console/pzserver-console.log"
    ) &
    return 0
}
export WEBCORE_PZ_START_READY_SECS=15 \
    WEBCORE_LC_WORKSHOP_STALL_PAUSE=1 WEBCORE_LC_WORKSHOP_PENDING=5
out="$(lgsm_start_reliable "$TMP/pz" pzserver 5 2>&1)"
echo "$out" | grep -qi 'truncated\|rotated' || { echo "fail: expected truncate reset: $out"; exit 1; }
echo "$out" | grep -qi 'Ready: marker seen' || { echo "fail: truncate path should see Ready: $out"; exit 1; }
unset WEBCORE_PZ_START_READY_SECS WEBCORE_LC_WORKSHOP_STALL_PAUSE WEBCORE_LC_WORKSHOP_PENDING

# --- PZ already online still waits for ready marker from current offset ---
unset -f lgsm_is_started lgsm_run_timeout 2>/dev/null || true
lgsm_is_started() { return 0; }
lgsm_run_timeout() { echo "FAIL: should not start when already online"; return 1; }
: >"$TMP/pz/log/console/pzserver-console.log"
printf 'old *** SERVER STARTED ****\n' >"$TMP/pz/log/console/pzserver-console.log"
(
    sleep 1
    printf 'LOG  : General     , *** SERVER STARTED ****\n' \
        >>"$TMP/pz/log/console/pzserver-console.log"
) &
export WEBCORE_PZ_START_READY_SECS=10
# Mid-boot: old marker is "old ***" which still matches recent — clear to only
# have pre-offset content without a fresh boot. Use a log WITHOUT ready marker
# so we must wait for the appended one (allow_existing finds nothing).
: >"$TMP/pz/log/console/pzserver-console.log"
printf 'booting…\n' >"$TMP/pz/log/console/pzserver-console.log"
(
    sleep 1
    printf 'LOG  : Network     , *** SERVER STARTED ****\n' \
        >>"$TMP/pz/log/console/pzserver-console.log"
) &
out="$(lgsm_start_reliable "$TMP/pz" pzserver 5 2>&1)"
echo "$out" | grep -qi 'Already online' || { echo "fail: expected Already online: $out"; exit 1; }
echo "$out" | grep -qi 'Ready: marker seen' || { echo "fail: mid-boot should wait for new marker: $out"; exit 1; }
echo "$out" | grep -qi 'should not start' && { echo "fail: must not invoke LGSM start when online: $out"; exit 1; }
unset WEBCORE_PZ_START_READY_SECS

# --- PZ already online + already ready → immediate Ready (no 900s hang) ---
: >"$TMP/pz/log/console/pzserver-console.log"
printf 'LOG  : Network     , *** SERVER STARTED ****\nlistening\n' \
    >"$TMP/pz/log/console/pzserver-console.log"
export WEBCORE_PZ_START_READY_SECS=10
out="$(lgsm_start_reliable "$TMP/pz" pzserver 5 2>&1)"
echo "$out" | grep -qi 'Already online' || { echo "fail: already-ready Already online: $out"; exit 1; }
echo "$out" | grep -qi 'marker already present' || { echo "fail: expected immediate already-present Ready: $out"; exit 1; }
echo "$out" | grep -qi 'Still starting' && { echo "fail: must not wait when already ready: $out"; exit 1; }
unset WEBCORE_PZ_START_READY_SECS

# --- Stall: session up, no console growth → fail (not 900s warn-ok) ---
: >"$TMP/pz/log/console/pzserver-console.log"
printf 'stale line without marker\n' >"$TMP/pz/log/console/pzserver-console.log"
export WEBCORE_PZ_START_READY_SECS=30 \
    WEBCORE_START_LOG_STALL_SECS=2 WEBCORE_START_LOG_STALL_FAIL_SECS=4
# START_LOG_* wins over any LC stall left in the environment.
unset WEBCORE_LC_STALL_SECS WEBCORE_LC_STALL_FAIL_SECS 2>/dev/null || true
set +e
out="$(lgsm_start_reliable "$TMP/pz" pzserver 5 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "fail: stall should fail rc!=0: $out"; exit 1; }
echo "$out" | grep -qiE 'start log stalled|console log not growing' \
    || { echo "fail: expected stall error: $out"; exit 1; }
unset WEBCORE_PZ_START_READY_SECS WEBCORE_START_LOG_STALL_SECS WEBCORE_START_LOG_STALL_FAIL_SECS
unset -f lgsm_is_started lgsm_run_timeout 2>/dev/null || true

# --- Sliding stall: grows then freezes → WARNING then ERROR ---
unset -f lgsm_is_started 2>/dev/null || true
lgsm_is_started() { return 0; }
: >"$TMP/pz/log/console/pzserver-console.log"
printf 'boot begin\n' >"$TMP/pz/log/console/pzserver-console.log"
(
    sleep 1
    printf 'more output\n' >>"$TMP/pz/log/console/pzserver-console.log"
) &
export WEBCORE_LC_READY_REGEX='\*\*\* SERVER STARTED \*\*\*\*'
export WEBCORE_LC_READY_SECS=30
export WEBCORE_LC_STALL_SECS=2
export WEBCORE_LC_STALL_FAIL_SECS=4
set +e
out="$(lgsm_lifecycle_wait_ready "$TMP/pz" pzserver \
    "$TMP/pz/log/console/pzserver-console.log" 0 \
    "$WEBCORE_LC_READY_REGEX" 30 0 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "fail: sliding stall should fail rc!=0: $out"; exit 1; }
echo "$out" | grep -q 'WARNING: start log stalled' \
    || { echo "fail: expected stall WARNING: $out"; exit 1; }
echo "$out" | grep -q 'ERROR: start log stalled' \
    || { echo "fail: expected stall ERROR: $out"; exit 1; }
unset WEBCORE_LC_READY_REGEX WEBCORE_LC_READY_SECS WEBCORE_LC_STALL_SECS WEBCORE_LC_STALL_FAIL_SECS

# --- START_LOG_STALL_* overrides LC (even after eval_meta-style LC fill) ---
: >"$TMP/pz/log/console/pzserver-console.log"
printf 'boot begin\n' >"$TMP/pz/log/console/pzserver-console.log"
(
    sleep 1
    printf 'more output\n' >>"$TMP/pz/log/console/pzserver-console.log"
) &
export WEBCORE_LC_READY_REGEX='\*\*\* SERVER STARTED \*\*\*\*'
export WEBCORE_LC_READY_SECS=30
# High LC values would never stall within READY_SECS if they won
export WEBCORE_LC_STALL_SECS=600
export WEBCORE_LC_STALL_FAIL_SECS=900
export WEBCORE_START_LOG_STALL_SECS=2
export WEBCORE_START_LOG_STALL_FAIL_SECS=4
set +e
out="$(lgsm_lifecycle_wait_ready "$TMP/pz" pzserver \
    "$TMP/pz/log/console/pzserver-console.log" 0 \
    "$WEBCORE_LC_READY_REGEX" 30 0 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "fail: START_LOG override should stall-fail: $out"; exit 1; }
echo "$out" | grep -q 'WARNING: start log stalled' \
    || { echo "fail: START override expected stall WARNING: $out"; exit 1; }
echo "$out" | grep -q 'ERROR: start log stalled' \
    || { echo "fail: START override expected stall ERROR: $out"; exit 1; }
unset WEBCORE_LC_READY_REGEX WEBCORE_LC_READY_SECS WEBCORE_LC_STALL_SECS \
    WEBCORE_LC_STALL_FAIL_SECS WEBCORE_START_LOG_STALL_SECS \
    WEBCORE_START_LOG_STALL_FAIL_SECS

# --- Workshop phase: freeze must NOT stall-fail ---
: >"$TMP/pz/log/console/pzserver-console.log"
printf 'Waiting for response from Steam servers\nDownloadPending\n' \
    >"$TMP/pz/log/console/pzserver-console.log"
(
    sleep 1
    printf 'Workshop: download 1/5\n' >>"$TMP/pz/log/console/pzserver-console.log"
) &
export WEBCORE_LC_READY_REGEX='\*\*\* SERVER STARTED \*\*\*\*'
export WEBCORE_LC_READY_SECS=12
export WEBCORE_LC_STALL_SECS=2
export WEBCORE_LC_STALL_FAIL_SECS=4
export WEBCORE_LC_WORKSHOP_STALL_PAUSE=1
export WEBCORE_LC_WORKSHOP_PENDING=3
export WEBCORE_LC_START_PHASE_0='workshop_download|DownloadPending|Waiting for response from Steam servers|Workshop: download '
export WEBCORE_LC_START_PHASE_1='loading_mods|Initialising Server Systems'
set +e
out="$(lgsm_lifecycle_wait_ready "$TMP/pz" pzserver \
    "$TMP/pz/log/console/pzserver-console.log" 0 \
    "$WEBCORE_LC_READY_REGEX" 12 0 2>&1)"
rc=$?
set -e
echo "$out" | grep -qi 'ERROR: start log stalled' \
    && { echo "fail: workshop_download must not stall-fail: $out"; exit 1; }
# With prior growth + workshop pause, ready timeout → warn+0 (not stall ERROR)
[[ "$rc" -eq 0 ]] || { echo "fail: workshop quiet should warn-ok on ready timeout: rc=$rc $out"; exit 1; }
echo "$out" | grep -qi 'WARNING: no ready marker' \
    || { echo "fail: expected ready-timeout warning: $out"; exit 1; }
unset WEBCORE_LC_READY_REGEX WEBCORE_LC_READY_SECS WEBCORE_LC_STALL_SECS \
    WEBCORE_LC_STALL_FAIL_SECS WEBCORE_LC_WORKSHOP_STALL_PAUSE \
    WEBCORE_LC_WORKSHOP_PENDING WEBCORE_LC_START_PHASE_0 WEBCORE_LC_START_PHASE_1
unset -f lgsm_is_started 2>/dev/null || true

# --- MC enabled mod count (*.jar, skip *.jar.disabled) ---
mkdir -p "$TMP/mc-mods/serverfiles/mods"
touch "$TMP/mc-mods/serverfiles/mods/a.jar" \
    "$TMP/mc-mods/serverfiles/mods/b.jar" \
    "$TMP/mc-mods/serverfiles/mods/c.jar" \
    "$TMP/mc-mods/serverfiles/mods/d.jar.disabled" \
    "$TMP/mc-mods/serverfiles/mods/e.jar.disabled"
mc_n="$(lgsm_mc_count_enabled_mods "$TMP/mc-mods")"
[[ "$mc_n" == "3" ]] || { echo "fail: expected 3 enabled mods, got $mc_n"; exit 1; }

# --- lifecycle log path: Windrose R5.log via live_log fallbacks ---
mkdir -p "$TMP/windrose/serverfiles/R5/Saved/Logs"
printf 'boot\n' >"$TMP/windrose/serverfiles/R5/Saved/Logs/R5.log"
wlog="$(lgsm_lifecycle_log_path "$TMP/windrose" windrose live_log)"
[[ "$wlog" == "$TMP/windrose/serverfiles/R5/Saved/Logs/R5.log" ]] \
    || { echo "fail: windrose live_log R5 path: $wlog"; exit 1; }

# Prefer WEBCORE_LC_LIVE_LOG_REL when set and file exists
mkdir -p "$TMP/windrose/serverfiles/alt"
printf 'alt\n' >"$TMP/windrose/serverfiles/alt/custom.log"
export WEBCORE_LC_LIVE_LOG_REL='serverfiles/alt/custom.log'
wlog="$(lgsm_lifecycle_log_path "$TMP/windrose" windrose live_log)"
[[ "$wlog" == "$TMP/windrose/serverfiles/alt/custom.log" ]] \
    || { echo "fail: live_log rel override: $wlog"; exit 1; }
# Preferred LIVE_LOG_REL missing → return 1 (no server.log sticky)
rm -f "$TMP/windrose/serverfiles/alt/custom.log"
printf 'sticky\n' >"$TMP/windrose/server.log"
set +e
lgsm_lifecycle_log_path "$TMP/windrose" windrose live_log >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "fail: missing LIVE_LOG_REL must return 1 (not server.log)"; exit 1; }
unset WEBCORE_LC_LIVE_LOG_REL
rm -f "$TMP/windrose/server.log"

# console / latest_log keys
clog2="$(lgsm_lifecycle_log_path "$TMP/pz" pzserver console)"
[[ "$clog2" == "$TMP/pz/log/console/pzserver-console.log" ]] \
    || { echo "fail: lifecycle console path: $clog2"; exit 1; }
mclog="$(lgsm_lifecycle_log_path "$TMP/mc-a" mcserver latest_log)"
[[ "$mclog" == "$TMP/mc-a/serverfiles/logs/latest.log" ]] \
    || { echo "fail: lifecycle latest_log path: $mclog"; exit 1; }

# Reject path traversal / absolute relative keys
printf 'outside\n' >"$TMP/outside.log"
set +e
lgsm_lifecycle_log_path "$TMP/windrose" windrose '../outside.log' >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "fail: ../outside.log key must be rejected"; exit 1; }
export WEBCORE_LC_LIVE_LOG_REL='../outside.log'
wlog="$(lgsm_lifecycle_log_path "$TMP/windrose" windrose live_log)" \
    || { echo "fail: bad LIVE_LOG_REL should fall back to R5"; exit 1; }
[[ "$wlog" == "$TMP/windrose/serverfiles/R5/Saved/Logs/R5.log" ]] \
    || { echo "fail: after bad LIVE_LOG_REL expected R5: $wlog"; exit 1; }
[[ "$wlog" != *outside* ]] || { echo "fail: escaped via LIVE_LOG_REL: $wlog"; exit 1; }
unset WEBCORE_LC_LIVE_LOG_REL

# --- lifecycle_env.pl + eval_meta for pzserver ---
export MODULE_ROOT="$ROOT/src"
set +e
lgsm_lifecycle_eval_meta "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "fail: empty script_name must return non-zero"; exit 1; }
lgsm_lifecycle_eval_meta pzserver || { echo "fail: eval_meta pzserver"; exit 1; }
[[ -n "${WEBCORE_LC_READY_REGEX:-}" ]] || { echo "fail: READY_REGEX not exported"; exit 1; }
echo "${WEBCORE_LC_READY_REGEX}" | grep -q 'SERVER STARTED' \
    || { echo "fail: READY_REGEX content: ${WEBCORE_LC_READY_REGEX}"; exit 1; }
[[ "${WEBCORE_LC_READY_LOG:-}" == "console" ]] || { echo "fail: READY_LOG=${WEBCORE_LC_READY_LOG:-}"; exit 1; }
[[ "${WEBCORE_LC_READY_SECS:-}" == "900" ]] || { echo "fail: READY_SECS=${WEBCORE_LC_READY_SECS:-}"; exit 1; }
[[ "${WEBCORE_LC_STALL_SECS:-}" == "120" ]] || { echo "fail: STALL_SECS=${WEBCORE_LC_STALL_SECS:-}"; exit 1; }
[[ "${WEBCORE_LC_STALL_FAIL_SECS:-}" == "300" ]] || { echo "fail: STALL_FAIL=${WEBCORE_LC_STALL_FAIL_SECS:-}"; exit 1; }
[[ -n "${WEBCORE_LC_START_PHASE_0:-}" ]] || { echo "fail: START_PHASE_0 missing"; exit 1; }
echo "${WEBCORE_LC_START_PHASE_0}" | grep -q 'workshop_download|' \
    || { echo "fail: START_PHASE_0=${WEBCORE_LC_START_PHASE_0}"; exit 1; }
[[ -n "${WEBCORE_LC_STOP_PHASE_0:-}" ]] || { echo "fail: STOP_PHASE_0 missing"; exit 1; }
unset MODULE_ROOT
# Clear LC exports so later suites are clean
unset WEBCORE_LC_READY_LOG WEBCORE_LC_READY_REGEX WEBCORE_LC_READY_SECS \
    WEBCORE_LC_STALL_SECS WEBCORE_LC_STALL_FAIL_SECS \
    WEBCORE_LC_STOP_GRACE WEBCORE_LC_STOP_FORCE WEBCORE_LC_LIVE_LOG_REL
unset WEBCORE_LC_START_PHASE_0 WEBCORE_LC_START_PHASE_1 WEBCORE_LC_START_PHASE_2 \
    WEBCORE_LC_START_PHASE_3 WEBCORE_LC_START_PHASE_4 \
    WEBCORE_LC_STOP_PHASE_0 WEBCORE_LC_STOP_PHASE_1

# --- Restart hard-gate: stop failure aborts; start must not run ---
unset -f lgsm_tmux_is_online lgsm_is_started lgsm_run_timeout \
    lgsm_start_reliable lgsm_stop_reliable 2>/dev/null || true
_start_called=0
lgsm_start_reliable() {
    _start_called=1
    echo "START_CALLED"
    return 0
}
lgsm_stop_reliable() {
    echo "mock stop: still online / failed"
    return 1
}
set +e
out="$(lgsm_restart_reliable "$TMP/mc-a" mcserver 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "fail: restart must be non-zero when stop fails: $out"; exit 1; }
[[ "$_start_called" -eq 0 ]] || { echo "fail: start must not run after stop fail: $out"; exit 1; }
echo "$out" | grep -qi 'restart aborted' \
    || { echo "fail: expected restart aborted message: $out"; exit 1; }

# Still online after stop returns 0 → abort before start
_start_called=0
lgsm_stop_reliable() { echo "mock stop: claimed ok"; return 0; }
lgsm_is_started() { return 0; }
set +e
out="$(lgsm_restart_reliable "$TMP/mc-a" mcserver 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "fail: restart must abort when still online: $out"; exit 1; }
[[ "$_start_called" -eq 0 ]] || { echo "fail: start must not run while still online: $out"; exit 1; }
echo "$out" | grep -qi 'still online' \
    || { echo "fail: expected still-online abort: $out"; exit 1; }
unset -f lgsm_start_reliable lgsm_stop_reliable lgsm_is_started 2>/dev/null || true

# --- Stop grace: while saving, do not force before stop_force; log still saving ---
mkdir -p "$TMP/pz/log/console"
printf 'Saving world chunks...\n' >"$TMP/pz/log/console/pzserver-console.log"
_stop_online=1
lgsm_tmux_is_online() { [[ "$_stop_online" -eq 1 ]]; }
lgsm_tmux_resolve_live() { return 1; }
lgsm_tmux_kill_live() { _stop_online=0; return 0; }
lgsm_kill_java_for_server() { return 0; }
lgsm_java_pids_for_server() { return 0; }
export WEBCORE_LC_STOP_GRACE=2
export WEBCORE_LC_STOP_FORCE=5
export WEBCORE_LC_READY_LOG=console
export WEBCORE_LC_STOP_PHASE_0='saving|[Ss]aving'
export WEBCORE_LC_STOP_PHASE_1='stopped|Server stopped'
set +e
out="$(lgsm_stop_direct "$TMP/pz" pzserver quit 2 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "fail: stop after force should reach offline: $out"; exit 1; }
echo "$out" | grep -q 'Stop: still saving' \
    || { echo "fail: expected still saving log: $out"; exit 1; }
echo "$out" | grep -qiE 'forcing|forced' \
    || { echo "fail: expected force after stop_force: $out"; exit 1; }
# Without saving match, force may happen at grace (not only at force cap)
_stop_online=1
printf 'Shutting down cleanly\n' >"$TMP/pz/log/console/pzserver-console.log"
set +e
out="$(lgsm_stop_direct "$TMP/pz" pzserver quit 2 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "fail: non-saving stop should offline: $out"; exit 1; }
echo "$out" | grep -qi 'grace expired\|forcing\|forced' \
    || { echo "fail: expected early force when not saving: $out"; exit 1; }
unset WEBCORE_LC_STOP_GRACE WEBCORE_LC_STOP_FORCE WEBCORE_LC_READY_LOG \
    WEBCORE_LC_STOP_PHASE_0 WEBCORE_LC_STOP_PHASE_1
unset -f lgsm_tmux_is_online lgsm_tmux_resolve_live lgsm_tmux_kill_live \
    lgsm_kill_java_for_server lgsm_java_pids_for_server 2>/dev/null || true

# --- WEBCORE_LC_ALIVE_PID: kill -0 instead of tmux (SteamCMD/Windrose twin) ---
mkdir -p "$TMP/wr-alive/serverfiles/R5/Saved/Logs"
: >"$TMP/wr-alive/serverfiles/R5/Saved/Logs/R5.log"
# Fake "game" PID: sleep in background
sleep 60 &
_fake_pid=$!
# Append GenlandiaMulty after a short delay (simulates boot)
(
    sleep 1
    printf 'Engine is initialized. Leaving FEngineLoop::Init()\n' \
        >>"$TMP/wr-alive/serverfiles/R5/Saved/Logs/R5.log"
    sleep 1
    printf 'Start preloading GenlandiaMulty\n' \
        >>"$TMP/wr-alive/serverfiles/R5/Saved/Logs/R5.log"
) &
export WEBCORE_LC_ALIVE_PID="$_fake_pid"
export WEBCORE_LC_READY_REGEX='Start preloading GenlandiaMulty'
export WEBCORE_LC_READY_SECS=20
export WEBCORE_LC_STALL_SECS=60
export WEBCORE_LC_STALL_FAIL_SECS=90
export WEBCORE_LC_READY_LOG=live_log
export WEBCORE_LC_START_PHASE_0='engine_ready|Engine is initialized'
export WEBCORE_LC_START_PHASE_1='ready|Start preloading GenlandiaMulty'
# Must NOT call lgsm_is_started (would fail without tmux) — ALIVE_PID wins
unset -f lgsm_is_started 2>/dev/null || true
lgsm_is_started() { echo "fail: lgsm_is_started must not run with ALIVE_PID"; return 1; }
set +e
out="$(lgsm_lifecycle_wait_ready "$TMP/wr-alive" windrose \
    "$TMP/wr-alive/serverfiles/R5/Saved/Logs/R5.log" 0 \
    "$WEBCORE_LC_READY_REGEX" 20 0 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "fail: Windrose ALIVE_PID ready wait: $out"; kill "$_fake_pid" 2>/dev/null || true; exit 1; }
echo "$out" | grep -q 'Ready: marker seen' \
    || { echo "fail: expected GenlandiaMulty ready: $out"; kill "$_fake_pid" 2>/dev/null || true; exit 1; }
kill "$_fake_pid" 2>/dev/null || true
wait "$_fake_pid" 2>/dev/null || true

# Dead PID → fail before ready
export WEBCORE_LC_ALIVE_PID=999999999
: >"$TMP/wr-alive/serverfiles/R5/Saved/Logs/R5.log"
printf 'boot\n' >"$TMP/wr-alive/serverfiles/R5/Saved/Logs/R5.log"
set +e
out="$(lgsm_lifecycle_wait_ready "$TMP/wr-alive" windrose \
    "$TMP/wr-alive/serverfiles/R5/Saved/Logs/R5.log" 0 \
    'Start preloading GenlandiaMulty' 12 0 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "fail: dead ALIVE_PID must fail: $out"; exit 1; }
echo "$out" | grep -qi 'process died' \
    || { echo "fail: expected process died message: $out"; exit 1; }
unset WEBCORE_LC_ALIVE_PID WEBCORE_LC_READY_REGEX WEBCORE_LC_READY_SECS \
    WEBCORE_LC_STALL_SECS WEBCORE_LC_STALL_FAIL_SECS WEBCORE_LC_READY_LOG \
    WEBCORE_LC_START_PHASE_0 WEBCORE_LC_START_PHASE_1
unset -f lgsm_is_started 2>/dev/null || true

echo "ok test_lgsm_control.sh"
