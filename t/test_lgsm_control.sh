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
echo "$out" | grep -qi 'Ready: Done' || { echo "fail: expected Ready Done: $out"; exit 1; }
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
out="$(lgsm_start_reliable "$TMP/pz" pzserver 5 2>&1)"
echo "$out" | grep -qi 'Already online' || { echo "fail: expected Already online: $out"; exit 1; }
echo "$out" | grep -qi 'Ready: marker seen' || { echo "fail: already-online should wait for marker: $out"; exit 1; }
echo "$out" | grep -qi 'should not start' && { echo "fail: must not invoke LGSM start when online: $out"; exit 1; }
unset WEBCORE_PZ_START_READY_SECS
unset -f lgsm_is_started lgsm_run_timeout 2>/dev/null || true

echo "ok test_lgsm_control.sh"
