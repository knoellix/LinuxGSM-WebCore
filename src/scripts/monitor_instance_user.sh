#!/bin/bash
# monitor_instance_user.sh — game-user-side monitoring
# Runs as the game-user via 'su' from monitor_all.sh.
# Responsibilities: PID check, A2S query, state write, wineserver cleanup.
# Restart is signaled via restart-requested file; root wrapper handles dispatch.
# Args: <instance_id> <source> <server_dir> <script_name> <config_dir> <module_root>
set -euo pipefail

INSTANCE_ID="${1:?missing instance_id}"
INST_SOURCE="${2:?missing source}"
SERVER_DIR="${3:?missing server_dir}"
SCRIPT_NAME="${4:?missing script_name}"
CONFIG_DIR="${5:?missing config_dir}"
MODULE_ROOT="${6:?missing module_root}"

STATE_DIR="$SERVER_DIR/.monitor"
STATE_FILE="$STATE_DIR/state"
LEGACY_STATE_FILE="$CONFIG_DIR/monitor/$INSTANCE_ID/state"
LOG_DIR="$SERVER_DIR/logs"
LOG_FILE="$LOG_DIR/monitor.log"
MAX_RESTARTS=5
WINDOW_SECS=3600

mkdir -p "$STATE_DIR" 2>/dev/null || true
mkdir -p "$LOG_DIR"   2>/dev/null || true

# --- helpers ---------------------------------------------------------------

_read_state_key() {
    local key="$1" default="${2:-}"
    if [ -f "$STATE_FILE" ]; then
        local v
        v=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2- | head -1) || true
        [ -n "$v" ] && echo "$v" && return
    fi
    if [ -f "$LEGACY_STATE_FILE" ]; then
        local v
        v=$(grep "^${key}=" "$LEGACY_STATE_FILE" 2>/dev/null | cut -d= -f2- | head -1) || true
        [ -n "$v" ] && echo "$v" && return
    fi
    echo "$default"
}

_write_state() {
    local status="$1" count="$2" window="$3"
    mkdir -p "$STATE_DIR"
    local tmp_file
    tmp_file="$(mktemp "$STATE_DIR/.state.XXXXXX")" || return 1
    printf 'status=%s\nrestart_count=%s\nwindow_start=%s\n' \
        "$status" "$count" "$window" > "$tmp_file"
    mv "$tmp_file" "$STATE_FILE"
}

_log() {
    local msg="[$(date '+%Y-%m-%d %T')] [$INSTANCE_ID] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# --- state gate ------------------------------------------------------------

STATUS=$(_read_state_key status running)
if [[ "$STATUS" == "paused" || "$STATUS" == "disabled" ]]; then
    _log "Skipping — status=$STATUS"
    exit 0
fi

# --- LGSM path -------------------------------------------------------------

if [[ "$INST_SOURCE" == "lgsm" ]]; then
    _log "LGSM: running ./$SCRIPT_NAME monitor"
    cd "$SERVER_DIR" && "./$SCRIPT_NAME" monitor 2>&1 || true
    lgsm_status=$(cd "$SERVER_DIR" && "./$SCRIPT_NAME" status 2>/dev/null | grep -ci 'ONLINE' || echo "0")
    if [[ "$lgsm_status" -gt 0 ]]; then
        _write_state "running" "0" "$(date +%s)"
        _log "LGSM: server running"
    else
        _log "LGSM: server offline after monitor"
        # 99 = sentinel meaning "LGSM-managed failure, not tracked by our counter"
        _write_state "failed" "99" "$(date +%s)"
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

# 2. A2S query — only if PID alive and query port known
freeze=0
if [[ "$pid_alive" -eq 1 && "${INSTANCE_QUERY_PORT:-0}" -gt 0 ]]; then
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
    logger -t linuxgsm-webcore "Monitor: $INSTANCE_ID failed — restart limit reached"
    exit 0
fi

RESTART_COUNT=$((RESTART_COUNT + 1))
_log "Restart attempt $RESTART_COUNT/$MAX_RESTARTS — signaling root wrapper"
_write_state "restarting" "$RESTART_COUNT" "$WINDOW_START"

# Kill stale process (game-user can kill own processes)
if [[ "${server_pid:-0}" -gt 0 ]]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    sleep 2
    kill -KILL "$server_pid" 2>/dev/null || true
fi

# Wineserver cleanup (own WINEPREFIX, no root needed)
# Windrose uses .wine-windrose; older layouts may use .wine.
for _pfx in "$SERVER_DIR/.wine-windrose" "$SERVER_DIR/.wine"; do
    [ -d "$_pfx" ] || continue
    WINEPREFIX="$_pfx" /usr/bin/wineserver -k 2>/dev/null || true
done

# Signal root wrapper to dispatch steamcmd_control.sh start (needs nice -n -5)
touch "$STATE_DIR/restart-requested" 2>/dev/null || true
_log "restart-requested signal written — root wrapper will dispatch"
exit 0
