#!/bin/bash
# monitor_instance.sh — check and optionally restart one game server instance
# Args: <instance_id> <user> <source> <server_dir> <script_name> <config_dir> <module_root>
#
# DEPRECATED: No longer called by monitor_all.sh (as of the Task-2 refactor).
# Responsibilities have been split: game-user-side work moved to
# monitor_instance_user.sh (PID check, A2S query, state write, wineserver cleanup)
# and root-side restart dispatch moved to monitor_all.sh.
# This script is retained for manual execution and testing only.
set -euo pipefail

INSTANCE_ID="${1:?missing instance_id}"
UNIX_USER="${2:?missing user}"
INST_SOURCE="${3:?missing source}"     # lgsm or steamcmd
SERVER_DIR="${4:?missing server_dir}"
SCRIPT_NAME="${5:?missing script_name}"
CONFIG_DIR="${6:?missing config_dir}"
MODULE_ROOT="${7:?missing module_root}"

STATE_DIR="$SERVER_DIR/.monitor"
STATE_FILE="$STATE_DIR/state"
LEGACY_STATE_FILE="$CONFIG_DIR/monitor/$INSTANCE_ID/state"
MAX_RESTARTS=5
WINDOW_SECS=3600

# --- helpers ---------------------------------------------------------------

_read_state_key() {
    local key="$1" default="${2:-}"
    # Try new state file first
    if [ -f "$STATE_FILE" ]; then
        local v
        v=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2- | head -1) || true
        [ -n "$v" ] && echo "$v" && return
    fi
    # Fallback to legacy path
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

_log() { echo "[$(date '+%Y-%m-%d %T')] [$INSTANCE_ID] $*"; }

# --- state gate ------------------------------------------------------------

STATUS=$(_read_state_key status running)
if [[ "$STATUS" == "paused" || "$STATUS" == "disabled" ]]; then
    _log "Skipping — status=$STATUS"
    exit 0
fi

# --- LGSM path -------------------------------------------------------------

if [[ "$INST_SOURCE" == "lgsm" ]]; then
    _log "LGSM: running ./$SCRIPT_NAME monitor"
    # Single-quote-escape SERVER_DIR per CLAUDE.md section 5.1
    safe_dir="${SERVER_DIR//\'/\'\\\'\'}"
    su -s /bin/bash -c "cd '$safe_dir' && ./$SCRIPT_NAME monitor" "$UNIX_USER" 2>&1 || true
    lgsm_status=$(su -s /bin/bash -c "cd '$safe_dir' && ./$SCRIPT_NAME status 2>/dev/null" "$UNIX_USER" 2>/dev/null | grep -ci 'ONLINE' || echo "0")
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

# --- Non-LGSM path ---------------------------------------------------------

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
    _fb_pid=$(pgrep -u "$UNIX_USER" -f "WindroseServer-Win64-Shipping.exe|WindroseServer.exe" 2>/dev/null | head -1 || true)
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
    logger -t linuxgsm-webcore "Monitor: $INSTANCE_ID failed — restart limit reached"
    exit 1
fi

RESTART_COUNT=$((RESTART_COUNT + 1))
_log "Restart attempt $RESTART_COUNT/$MAX_RESTARTS"
_write_state "restarting" "$RESTART_COUNT" "$WINDOW_START"

# Kill stale process and wineserver
if [[ "${server_pid:-0}" -gt 0 ]]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    sleep 2
    kill -KILL "$server_pid" 2>/dev/null || true
fi
# Wine prefixes: Windrose uses .wine-windrose (see steamcmd_install.sh / steamcmd_control.sh).
# Older SteamCMD layouts may use .wine — reap locks from both so RocksDB does not stall on restart.
for _pfx in "$SERVER_DIR/.wine-windrose" "$SERVER_DIR/.wine"; do
    [ -d "$_pfx" ] || continue
    su -s /bin/bash -c "WINEPREFIX='$_pfx' /usr/bin/wineserver -k 2>/dev/null || true" "$UNIX_USER" 2>/dev/null || true
done

# Restart via steamcmd_control.sh — use real job dir so output appears in Job-Übersicht
JOB_DIR=""
MONITOR_JOB_RECORDED=0
if command -v perl >/dev/null 2>&1; then
    _jid_out="$(MODULE_ROOT="$MODULE_ROOT" perl "$MODULE_ROOT/scripts/monitor_create_job.pl" \
        "$CONFIG_DIR" "$INSTANCE_ID" "$UNIX_USER" 2>/dev/null || true)"
    _jid="$(echo -n "$_jid_out" | tr -cd '0-9a-f')"
    if [[ "${#_jid}" -eq 16 ]]; then
        JOB_DIR="$CONFIG_DIR/jobs/$_jid"
        MONITOR_JOB_RECORDED=1
    fi
fi
if [[ -z "$JOB_DIR" ]]; then
    JOB_DIR="$(mktemp -d)"
    chmod 755 "$JOB_DIR"
    _log "WARN: could not create jobs/ record (perl/helper failed) — using temp job dir"
fi

MODULE_ROOT="$MODULE_ROOT" setsid nohup bash "$MODULE_ROOT/scripts/steamcmd_control.sh" \
    start "$JOB_DIR" "$UNIX_USER" "$SERVER_DIR" >/dev/null 2>&1 &
sleep 30

# Verify restart
new_pid=0
if [ -f "$PIDFILE" ]; then
    new_pid=$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]') || true
fi
if [[ "${new_pid:-0}" -gt 0 ]] && kill -0 "$new_pid" 2>/dev/null; then
    _log "Restart successful"
    _write_state "running" "$RESTART_COUNT" "$WINDOW_START"
else
    _log "Restart failed — will retry at next cron tick"
    _write_state "restarting" "$RESTART_COUNT" "$WINDOW_START"
fi

if [[ "$MONITOR_JOB_RECORDED" -eq 1 ]] && [[ -d "$JOB_DIR" ]]; then
    {
        echo ""
        echo "=== monitor_instance.sh post-check ($(date -Is)) ==="
        echo "instance=$INSTANCE_ID server_dir=$SERVER_DIR"
        echo "run.pid new_pid=${new_pid:-0} (live game log: $SERVER_DIR/server.log)"
    } >>"$JOB_DIR/output" 2>/dev/null || true
fi

if [[ "$MONITOR_JOB_RECORDED" -eq 0 ]] && [[ -n "$JOB_DIR" ]]; then
    rm -rf "$JOB_DIR"
fi
exit 0
