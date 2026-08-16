#!/bin/bash
# monitor_instance_user.sh — game-user-side monitoring (runs AS the game user).
#
# Args: <instance_id> <kind:lgsm|native> <server_dir> <script_name> <module_root>
#   - lgsm:   `./<script> monitor` (LGSM health + restart, lockfile-gated)
#   - native: PID + A2S watchdog; restart via steamcmd_control_user.sh (no root)
set -euo pipefail

INSTANCE_ID="${1:?missing instance_id}"
KIND="${2:?missing kind}"
SERVER_DIR="${3:?missing server_dir}"
SCRIPT_NAME="${4:?missing script_name}"
MODULE_ROOT="${5:?missing module_root}"

STATE_DIR="$SERVER_DIR/.monitor"
STATE_FILE="$STATE_DIR/state"
LOG_DIR="$SERVER_DIR/logs"
LOG_FILE="$LOG_DIR/monitor.log"
MAX_RESTARTS=5
WINDOW_SECS=3600
WAIT_TRIES="${WEBCORE_MONITOR_WAIT_TRIES:-12}"
WAIT_DELAY="${WEBCORE_MONITOR_WAIT_DELAY:-5}"

mkdir -p "$STATE_DIR" 2>/dev/null || true
mkdir -p "$LOG_DIR"   2>/dev/null || true

# shellcheck source=lib/mc_java_env.sh
. "$MODULE_ROOT/scripts/lib/mc_java_env.sh"

# --- helpers ---------------------------------------------------------------

_read_state_key() {
    local key="$1" default="${2:-}"
    if [ -f "$STATE_FILE" ]; then
        local v
        v=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2- | head -1) || true
        [ -n "$v" ] && echo "$v" && return
    fi
    echo "$default"
}

_write_state() {
    local status="$1" count="$2" window="$3"
    mkdir -p "$STATE_DIR"
    declare -A ST=([status]="$status" [restart_count]="$count" [window_start]="$window")
    if [[ -f "$STATE_FILE" ]]; then
        while IFS='=' read -r k v; do
            [[ -n "$k" ]] || continue
            case "$k" in
                last_restart_at|last_restart_job) ST[$k]="$v" ;;
            esac
        done <"$STATE_FILE"
    fi
    local tmp_file
    tmp_file="$(mktemp "$STATE_DIR/.state.XXXXXX")" || return 1
    {
        printf 'status=%s\n' "${ST[status]}"
        printf 'restart_count=%s\n' "${ST[restart_count]}"
        printf 'window_start=%s\n' "${ST[window_start]}"
        if [[ -n "${ST[last_restart_at]:-}" ]]; then
            printf 'last_restart_at=%s\n' "${ST[last_restart_at]}"
        fi
        if [[ -n "${ST[last_restart_job]:-}" ]]; then
            printf 'last_restart_job=%s\n' "${ST[last_restart_job]}"
        fi
    } >"$tmp_file"
    mv "$tmp_file" "$STATE_FILE"
}

_log() {
    local msg="[$(date '+%Y-%m-%d %T')] [$INSTANCE_ID] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# --- state gate ------------------------------------------------------------

STATUS=$(_read_state_key status disabled)
if [[ "$STATUS" == "paused" || "$STATUS" == "disabled" ]]; then
    _log "Skipping — status=$STATUS"
    exit 0
fi

# --- LGSM path (runs as the game user, no root) ----------------------------

_lgsm_is_online() {
    local LGSM_ONLINE_SH="$MODULE_ROOT/scripts/lib/lgsm_online.sh"
    if [[ -f "$LGSM_ONLINE_SH" ]]; then
        # shellcheck source=lib/lgsm_online.sh
        . "$LGSM_ONLINE_SH"
        lgsm_tmux_is_online "$SERVER_DIR" "$SCRIPT_NAME" && return 0
    fi
    _lgsm_details_online
}

_lgsm_details_online() {
    ( cd "$SERVER_DIR" && "./$SCRIPT_NAME" details ) 2>/dev/null \
        | grep -Eqi 'Status:[[:space:]]*STARTED'
}

# LGSM monitor may restart internally even when tmux looked alive:
# - session FAIL → start
# - query FAIL (gamedig) → graceful stop → start  (Minecraft false positives)
_lgsm_monitor_showed_restart() {
    local run_log="$1"
    [[ -f "$run_log" ]] || return 1
    local started=0
    grep -qiE '\[  OK  \].*Starting|Starting '"$SCRIPT_NAME" "$run_log" 2>/dev/null && started=1
    [[ "$started" -eq 1 ]] || return 1

    if grep -qiE 'Checking session \.+ FAIL|\[ ERROR \].*FAIL|Session check.*FAIL' "$run_log" 2>/dev/null; then
        return 0
    fi
    if grep -qiE 'Querying port:.*FAIL' "$run_log" 2>/dev/null \
        && grep -qiE 'Stopping .*|Graceful:.*stop' "$run_log" 2>/dev/null; then
        return 0
    fi
    return 1
}

# After monitor/start, poll until LGSM reports STARTED (Palworld can take >30s).
_lgsm_wait_online() {
    local tries="${1:-12}" delay="${2:-5}" require_details="${3:-0}"
    local i
    for ((i = 1; i <= tries; i++)); do
        if [[ "$require_details" -eq 1 ]]; then
            _lgsm_details_online && return 0
        elif _lgsm_is_online; then
            return 0
        fi
        sleep "$delay"
    done
    return 1
}

_lgsm_record_restart_job() {
    local run_log="${1:-}"
    MONITOR_JOB_SH="$MODULE_ROOT/scripts/lib/monitor_job.sh"
    if [[ -x "$MONITOR_JOB_SH" || -f "$MONITOR_JOB_SH" ]]; then
        if jid=$(bash "$MONITOR_JOB_SH" "$INSTANCE_ID" "$(id -un)" "$SERVER_DIR" "$run_log" \
            2>>"$LOG_FILE"); then
            _log "LGSM: monitor_restart job recorded ($jid)"
        else
            _log "LGSM: monitor job record failed (exit $?)"
        fi
    else
        _log "LGSM: monitor_job.sh not found at $MONITOR_JOB_SH"
    fi
}

_lgsm_restart_backoff_ready() {
    local now count window_start
    now=$(date +%s)
    count=$(_read_state_key restart_count 0)
    window_start=$(_read_state_key window_start "$now")
    # Legacy sentinel from the old LGSM-only path — treat as zero for backoff.
    if [[ "$count" -eq 99 ]]; then
        count=0
    fi
    if [[ $((now - window_start)) -gt $WINDOW_SECS ]]; then
        _log "Window expired — resetting restart counter"
        count=0
        window_start=$now
    fi
    if [[ "$count" -ge "$MAX_RESTARTS" ]]; then
        _log "LGSM: FAILED — $MAX_RESTARTS restart attempts in ${WINDOW_SECS}s"
        _write_state "failed" "$count" "$window_start"
        return 1
    fi
    count=$((count + 1))
    _LGSM_RESTART_COUNT=$count
    _LGSM_WINDOW_START=$window_start
    return 0
}

if [[ "$KIND" == "lgsm" ]]; then
    if [ ! -x "$SERVER_DIR/$SCRIPT_NAME" ]; then
        _log "LGSM: script not found/executable: $SERVER_DIR/$SCRIPT_NAME"
        _write_state "failed" "99" "$(date +%s)"
        exit 0
    fi
    monitor_recovery=0
    MONITOR_RUN_LOG="$STATE_DIR/.last_monitor_run.log"
    if _lgsm_is_online; then
        :
    else
        monitor_recovery=1
    fi
    _log "LGSM: running ./$SCRIPT_NAME monitor"
    # LGSM monitor handles query-based health checks when the process is up.
    # It will not start a crashed server when its lockfile is missing (e.g. after
    # an external tmux kill). WebCore already gates deliberate stops via paused.
    : >"$MONITOR_RUN_LOG"
    ( cd "$SERVER_DIR" && "./$SCRIPT_NAME" monitor ) >>"$MONITOR_RUN_LOG" 2>&1 || true
    cat "$MONITOR_RUN_LOG" >>"$LOG_FILE"

    if _lgsm_monitor_showed_restart "$MONITOR_RUN_LOG"; then
        monitor_recovery=1
        _log "LGSM: monitor triggered restart (session/query fail → start)"
    fi

    if ! _lgsm_wait_online "$WAIT_TRIES" "$WAIT_DELAY" "$monitor_recovery"; then
        monitor_recovery=1
        _LGSM_RESTART_COUNT=0
        _LGSM_WINDOW_START=$(date +%s)
        if _lgsm_restart_backoff_ready; then
            _log "LGSM: still offline after monitor — start attempt $_LGSM_RESTART_COUNT/$MAX_RESTARTS"
            _write_state "restarting" "$_LGSM_RESTART_COUNT" "$_LGSM_WINDOW_START"
            mc_java_env_apply "$SERVER_DIR"
            ( cd "$SERVER_DIR" && "./$SCRIPT_NAME" start ) >>"$LOG_FILE" 2>&1 || true
            ( cd "$SERVER_DIR" && "./$SCRIPT_NAME" start ) >>"$MONITOR_RUN_LOG" 2>&1 || true
            _lgsm_wait_online "$WAIT_TRIES" "$WAIT_DELAY" 1 || true
        else
            exit 0
        fi
    fi

    if _lgsm_is_online; then
        _write_state "running" "0" "$(date +%s)"
        if [[ "$monitor_recovery" -eq 1 ]]; then
            _log "LGSM: server recovered — recording monitor_restart job"
            _lgsm_record_restart_job "$MONITOR_RUN_LOG"
        else
            _log "LGSM: server online"
        fi
    else
        _write_state "failed" "${_LGSM_RESTART_COUNT:-1}" "${_LGSM_WINDOW_START:-$(date +%s)}"
        _log "LGSM: server offline after monitor+start (will retry next cron run)"
    fi
    exit 0
fi

# --- Non-LGSM (steamcmd/Wine) path -----------------------------------------

# Source ports helper to get query port from instance LGSM config
INSTANCE_QUERY_PORT=0
if [ -f "$MODULE_ROOT/scripts/lib/ports.sh" ]; then
    export SERVER_DIR
    # shellcheck source=lib/ports.sh
    . "$MODULE_ROOT/scripts/lib/ports.sh"
    _resolve_instance_ports "$SCRIPT_NAME" 2>/dev/null || true
fi

# 1. PID check
PIDFILE="$SERVER_DIR/run.pid"
server_pid=0
if [ -f "$PIDFILE" ]; then
    server_pid=$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]') || server_pid=0
fi

pid_alive=0
if [[ "${server_pid:-0}" -gt 0 ]] && kill -0 "$server_pid" 2>/dev/null; then
    pid_alive=1
fi

# Detect Wine/UE5 game (Epic networking — A2S not supported, pgrep fallback needed)
IS_WINE_GAME=0
if [ -d "$SERVER_DIR/.wine-windrose" ] || [ -d "$SERVER_DIR/.wine" ]; then
    IS_WINE_GAME=1
fi

# Fallback for Wine games: run.pid may be stale (Wine preloader exits, game moves to new PID)
if [[ "$pid_alive" -eq 0 && "$IS_WINE_GAME" -eq 1 ]]; then
    _fb_pid=$(pgrep -u "$(id -un)" -f "WindroseServer-Win64-Shipping.exe|WindroseServer.exe" 2>/dev/null | head -1 || true)
    if [ -n "${_fb_pid:-}" ] && kill -0 "$_fb_pid" 2>/dev/null; then
        _log "run.pid stale (was $server_pid) — adopting active Wine process $_fb_pid"
        printf "%s\n" "$_fb_pid" > "$PIDFILE" 2>/dev/null || true
        server_pid="$_fb_pid"
        pid_alive=1
    fi
fi

# 2. A2S query — skipped for Wine/UE5 games (Epic networking, not Valve A2S protocol)
freeze=0
if [[ "$pid_alive" -eq 1 && "${INSTANCE_QUERY_PORT:-0}" -gt 0 && "$IS_WINE_GAME" -eq 0 ]]; then
    if ! perl "$MODULE_ROOT/scripts/query_a2s.pl" "127.0.0.1" "$INSTANCE_QUERY_PORT" > /dev/null 2>&1; then
        _log "A2S timeout on port $INSTANCE_QUERY_PORT — freeze detected"
        freeze=1
    fi
fi

# 3. Server healthy?
if [[ "$pid_alive" -eq 1 && "$freeze" -eq 0 ]]; then
    _write_state "running" "0" "$(date +%s)"
    _log "OK"
    exit 0
fi

# 4. Restart flow
NOW=$(date +%s)
RESTART_COUNT=$(_read_state_key restart_count 0)
WINDOW_START=$(_read_state_key window_start "$NOW")

if [[ $((NOW - WINDOW_START)) -gt $WINDOW_SECS ]]; then
    _log "Window expired — resetting restart counter"
    RESTART_COUNT=0
    WINDOW_START=$NOW
fi

if [[ "$RESTART_COUNT" -ge "$MAX_RESTARTS" ]]; then
    _log "FAILED — $MAX_RESTARTS restarts in ${WINDOW_SECS}s"
    _write_state "failed" "$RESTART_COUNT" "$WINDOW_START"
    logger -t linuxgsm-webcore "Monitor: $INSTANCE_ID failed — restart limit reached" 2>/dev/null || true
    exit 0
fi

RESTART_COUNT=$((RESTART_COUNT + 1))
_log "Restart attempt $RESTART_COUNT/$MAX_RESTARTS — dispatching steamcmd_control_user.sh start"
_write_state "restarting" "$RESTART_COUNT" "$WINDOW_START"

# Kill stale process (game-user can kill own processes)
if [[ "${server_pid:-0}" -gt 0 ]]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    sleep 2
    kill -KILL "$server_pid" 2>/dev/null || true
fi

# Wineserver cleanup (own WINEPREFIX, no root needed)
for _pfx in "$SERVER_DIR/.wine-windrose" "$SERVER_DIR/.wine"; do
    [ -d "$_pfx" ] || continue
    WINEPREFIX="$_pfx" /usr/bin/wineserver -k 2>/dev/null || true
done

THIS_USER="$(id -un)"
RESTART_JOB_DIR=""
if RESTART_JOB_DIR="$(mktemp -d "$STATE_DIR/restart.XXXXXX" 2>/dev/null)"; then
    chmod 700 "$RESTART_JOB_DIR" 2>/dev/null || true
    if bash "$MODULE_ROOT/scripts/steamcmd_control_user.sh" start \
        "$RESTART_JOB_DIR" "$THIS_USER" "$SERVER_DIR" >>"$LOG_FILE" 2>&1; then
        _log "Monitor restart completed (user-native)"
        _write_state "running" "$RESTART_COUNT" "$WINDOW_START"
        MONITOR_JOB_SH="$MODULE_ROOT/scripts/lib/monitor_job.sh"
        if [[ -f "$MONITOR_JOB_SH" ]]; then
            bash "$MONITOR_JOB_SH" "$INSTANCE_ID" "$THIS_USER" "$SERVER_DIR" "$LOG_FILE" \
                >>"$LOG_FILE" 2>&1 || true
        fi
    else
        _log "Monitor restart failed — see $LOG_FILE and $RESTART_JOB_DIR/output"
    fi
else
    _log "Monitor restart failed — could not create temp job dir under $STATE_DIR"
fi
exit 0
