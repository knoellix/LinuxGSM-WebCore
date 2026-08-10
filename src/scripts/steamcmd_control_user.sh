#!/bin/bash
# steamcmd_control_user.sh — start/stop/update for non-LGSM games (runs AS game user).
# Invoked directly from monitor cron, or via steamcmd_control.sh (root su dispatch).
# Usage: steamcmd_control_user.sh <action> <job_dir> <unix_user> <server_dir>
set -euo pipefail

ACTION="$1"
JOB_DIR="$2"
UNIX_USER="$3"
SERVER_DIR="$4"

# Job dir is owned by the game user (create_job). Root must never write pgid/output
# here — root-owned files cause "Permission denied" when this script runs via su.
if [[ ! -d "$JOB_DIR" ]]; then
    echo "ERROR: job dir missing: $JOB_DIR" >&2
    exit 1
fi
if [[ ! -w "$JOB_DIR" ]]; then
    echo "ERROR: job dir not writable by $(id -un): $JOB_DIR" >&2
    exit 1
fi

THIS_USER="$(id -un)"
if [[ "$THIS_USER" != "$UNIX_USER" ]]; then
    echo "ERROR: steamcmd_control_user.sh must run as $UNIX_USER (got $THIS_USER)" >&2
    exit 1
fi

_SCRIPT_LIB="$(cd "$(dirname "$0")"/lib && pwd)"
# shellcheck source=lib/job_log.sh
. "$_SCRIPT_LIB/job_log.sh"
job_log_init_as_user "$JOB_DIR"

# Process priority helpers — game-server tree gets PRIO_HIGH on launch,
# any in-worker maintenance gets PRIO_LOW. See lib/prio.sh for details.
_PRIO_LIB_DIR="${MODULE_ROOT:-}/scripts/lib"
if [ ! -f "$_PRIO_LIB_DIR/prio.sh" ]; then
    _PRIO_LIB_DIR="$(cd "$(dirname "$0")"/lib && pwd)" 2>/dev/null || _PRIO_LIB_DIR=""
fi
if [ -n "$_PRIO_LIB_DIR" ] && [ -f "$_PRIO_LIB_DIR/prio.sh" ]; then
    # shellcheck source=lib/prio.sh
    . "$_PRIO_LIB_DIR/prio.sh"
else
    PRIO_HIGH=""
    PRIO_LOW=""
fi
# Negative nice (PRIO_HIGH) requires root to set — game-user worker uses default scheduling.
PRIO_HIGH=""

SERVERFILES="$SERVER_DIR/serverfiles"
PIDFILE="$SERVER_DIR/run.pid"
LOGFILE="$SERVER_DIR/server.log"
LAUNCH_WRAPPER="$SERVER_DIR/steamcmd-start.sh"
LAUNCH_CMD_FILE="$SERVER_DIR/.steam_launch_cmd"

# Port resolver — see scripts/lib/ports.sh for layered cfg parsing logic.
# Same loader pattern as prio.sh: prefer MODULE_ROOT, fall back to script-relative.
if [ -n "$_PRIO_LIB_DIR" ] && [ -f "$_PRIO_LIB_DIR/ports.sh" ]; then
    # shellcheck source=lib/ports.sh
    . "$_PRIO_LIB_DIR/ports.sh"
fi

FINAL_STATUS_WRITTEN=0
# jobs.pl calls _kill_job_processes($job_id) whenever status != running (including "ok"/"failed").
# pgid must never point at this worker after we detach (screen/wine), or cleanup can kill the game.
# Always unlink pgid before writing final status; on_exit covers abrupt exits.
set_final_status() {
    local s="$1"
    rm -f "$JOB_DIR/pgid" 2>/dev/null || true
    echo "$s" > "$JOB_DIR/status"
    FINAL_STATUS_WRITTEN=1
}

_finalize_detach_ok() {
    set_final_status "ok"
}
on_exit() {
    rm -f "$JOB_DIR/pgid" 2>/dev/null || true
    if [ "${WEBCORE_SKIP_FINAL:-0}" = "1" ]; then
        return 0
    fi
    if [ "${FINAL_STATUS_WRITTEN:-0}" -eq 0 ]; then
        echo "failed" > "$JOB_DIR/status"
    fi
}
trap on_exit EXIT

_find_binary() {
    find "$SERVERFILES" -maxdepth 3 -type f \( -name "*.x86_64" -o -name "*Server.sh" \) \
        -perm /0111 2>/dev/null | head -1
}

_is_transient_shell_pid() {
    local pid="$1"
    local cmd
    cmd="$(ps -o args= -p "$pid" 2>/dev/null || true)"
    [ -n "$cmd" ] || return 1
    case "$cmd" in
        *"bash -c"*"$SERVER_DIR"*)
            return 0
            ;;
    esac
    return 1
}

_running_pid_from_launch_cmd() {
    local binary base stem pid
    binary="$(cat "$LAUNCH_CMD_FILE" 2>/dev/null || true)"
    [ -n "$binary" ] || return 1
    base="$(basename "$binary")"
    stem="${base%.exe}"

    # Fallback to binary-specific process matches.
    pid="$(pgrep -u "$UNIX_USER" -f "$base" 2>/dev/null | head -1 || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        printf "%s\n" "$pid"
        return 0
    fi

    if [ "$stem" != "$base" ]; then
        pid="$(pgrep -u "$UNIX_USER" -f "$stem" 2>/dev/null | head -1 || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            printf "%s\n" "$pid"
            return 0
        fi
    fi

    return 1
}

# True Windrose/Wine PID — never the xvfb-run shell (its argv contains the EXE path too and fooled adoption).
_running_windrose_pid() {
    local pid cmd
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        cmd="$(ps -o args= -p "$pid" 2>/dev/null || true)"
        [ -n "$cmd" ] || continue
        case "$cmd" in
            *xvfb-run*|*Xvfb*)
                continue
                ;;
            *"WindroseServer-Win64-Shipping.exe"*|*"WindroseServer.exe"*)
                if ! _is_transient_shell_pid "$pid"; then
                    printf "%s\n" "$pid"
                    return 0
                fi
                ;;
        esac
    done < <(pgrep -u "$UNIX_USER" -f "WindroseServer-Win64-Shipping.exe|WindroseServer.exe" 2>/dev/null || true)
    return 1
}

_list_windrose_pids() {
    local pid cmd stat
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        stat="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
        # Ignore zombies; they cannot be killed and should not block startup.
        case "$stat" in
            *Z*) continue ;;
        esac
        cmd="$(ps -o args= -p "$pid" 2>/dev/null || true)"
        [ -n "$cmd" ] || continue
        case "$cmd" in
            *xvfb-run*|*Xvfb*)
                continue
                ;;
            *"WindroseServer-Win64-Shipping.exe"*|*"WindroseServer.exe"*)
                if ! _is_transient_shell_pid "$pid"; then
                    printf "%s\n" "$pid"
                fi
                ;;
        esac
    done < <(pgrep -u "$UNIX_USER" -f "WindroseServer-Win64-Shipping.exe|WindroseServer.exe" 2>/dev/null || true)
    return 0
}

_terminate_pid() {
    local pid="$1"
    local pgid=""
    [ -n "$pid" ] || return 0
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    # Kill whole process group first to avoid leaving wrappers/children.
    if [ -n "$pgid" ]; then
        kill -TERM -- "-$pgid" 2>/dev/null || true
    fi
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    if [ -n "$pgid" ]; then
        kill -KILL -- "-$pgid" 2>/dev/null || true
    fi
    kill -KILL "$pid" 2>/dev/null || true
}

_write_pidfile() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    printf '%s\n' "$pid" > "$PIDFILE"
    chmod 0644 "$PIDFILE" 2>/dev/null || true
    return 0
}

# Identify whether a pid belongs to THIS instance — only used for "is server already running?" checks.
# We do NOT use this to mass-kill orphans anymore: orphan xvfb-run/Xvfb don't block a new start
# (xvfb-run -a picks a fresh display number) and the user wants the cleanup noise gone.
_pid_belongs_to_instance() {
    local pid="$1" prefix="$2" env
    [ -n "$pid" ] || return 1
    [ -r "/proc/$pid/environ" ] || return 1
    env="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | awk -F= '$1=="WINEPREFIX"{print $2; exit}')"
    [ "$env" = "$prefix" ]
}

# True when a game server process for this instance is still alive.
_server_process_running() {
    local pid cand
    if cand="$(_running_windrose_pid 2>/dev/null || true)"; then
        [ -n "$cand" ] && kill -0 "$cand" 2>/dev/null && return 0
    fi
    if [ -f "$PIDFILE" ]; then
        pid="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    if [ -f "$LAUNCH_CMD_FILE" ]; then
        if cand="$(_running_pid_from_launch_cmd 2>/dev/null || true)"; then
            [ -n "$cand" ] && kill -0 "$cand" 2>/dev/null && return 0
        fi
    fi
    return 1
}

# Wait until server processes exit or timeout. Returns 0 when stopped.
_wait_server_stopped() {
    local max="${1:-20}" i
    for i in $(seq 1 "$max"); do
        _server_process_running || return 0
        sleep 1
    done
    return 1
}

case "$ACTION" in
    start)
        echo "steamcmd_control action=start"

        DIAG_LOG="$SERVER_DIR/windrose-debug.log"
        : > "$DIAG_LOG" 2>/dev/null || true
        chmod 0644 "$DIAG_LOG" 2>/dev/null || true
        {
            echo "=== worker start $(date -Is) (rev: 2026-07-04-user-native-v1) ==="
            echo "ACTION=$ACTION"
            echo "JOB_DIR=$JOB_DIR"
            echo "UNIX_USER=$UNIX_USER"
            echo "SERVER_DIR=$SERVER_DIR"
            echo "SERVERFILES=$SERVERFILES"
            echo "LAUNCH_CMD_FILE=$LAUNCH_CMD_FILE"
            if [ -f "$LAUNCH_CMD_FILE" ]; then
                echo "LAUNCH_CMD content: $(cat "$LAUNCH_CMD_FILE" 2>/dev/null)"
            else
                echo "LAUNCH_CMD_FILE missing"
            fi
            echo "files in serverfiles/R5/Binaries/Win64:"
            ls -la "$SERVERFILES/R5/Binaries/Win64/" 2>&1 | head -20
            echo "screen available: $(command -v screen || echo no)"
            echo "tmux available: $(command -v tmux || echo no)"
            echo "systemd-run available: $(command -v systemd-run || echo no)"
            echo "xvfb-run available: $(command -v xvfb-run || echo no)"
            echo "wine available: $(command -v wine || echo no)"
        } >>"$DIAG_LOG" 2>&1

        START_CMD=""
        WINDROSE_DIRECT_BIN=""
        SCRIPT_NAME=""
        if [ -f "$LAUNCH_CMD_FILE" ]; then
            BINARY=$(cat "$LAUNCH_CMD_FILE" 2>/dev/null || true)
            BIN_BASE=$(basename "${BINARY:-}")
            if [ "$BIN_BASE" = "WindroseServer-Win64-Shipping.exe" ] || [ "$BIN_BASE" = "WindroseServer.exe" ]; then
                if [ -f "$SERVERFILES/R5/Binaries/Win64/WindroseServer-Win64-Shipping.exe" ]; then
                    WINDROSE_DIRECT_BIN="R5/Binaries/Win64/WindroseServer-Win64-Shipping.exe"
                elif [ -f "$SERVERFILES/WindroseServer.exe" ]; then
                    WINDROSE_DIRECT_BIN="WindroseServer.exe"
                fi
                SCRIPT_NAME="windrose"
            fi
        fi
        # Fallback: derive script name from lgsm/config-lgsm/<name>/ if present.
        if [ -z "$SCRIPT_NAME" ] && [ -d "$SERVER_DIR/lgsm/config-lgsm" ]; then
            for _d in "$SERVER_DIR"/lgsm/config-lgsm/*/; do
                [ -d "$_d" ] || continue
                SCRIPT_NAME="$(basename "$_d")"
                break
            done
        fi
        {
            echo "WINDROSE_DIRECT_BIN resolved to: '${WINDROSE_DIRECT_BIN:-<none>}'"
            echo "SCRIPT_NAME resolved to: '${SCRIPT_NAME:-<none>}'"
        } >>"$DIAG_LOG" 2>&1

        # Resolve effective game/query/beacon ports BEFORE generating the launcher
        # so they can be baked into the wine command line. Multiple Windrose instances
        # on the same host depend on these being distinct per-instance.
        INSTANCE_GAME_PORT=""
        INSTANCE_QUERY_PORT=""
        INSTANCE_BEACON_PORT=""
        if [ -n "$SCRIPT_NAME" ]; then
            _resolve_instance_ports "$SCRIPT_NAME"
            {
                echo "Resolved ports: game=$INSTANCE_GAME_PORT query=$INSTANCE_QUERY_PORT beacon=$INSTANCE_BEACON_PORT"
                if [ "$INSTANCE_GAME_PORT" = "$DEFAULT_GAME_PORT" ] \
                    || [ "$INSTANCE_QUERY_PORT" = "$DEFAULT_QUERY_PORT" ] \
                    || [ "$INSTANCE_BEACON_PORT" = "$DEFAULT_BEACON_PORT" ]; then
                    echo "WARN: at least one port is at UE5 default — multi-instance setups will collide."
                fi
            } >>"$DIAG_LOG" 2>&1
        fi

        # Read Wine sync flags from instance LGSM config (set via WebUI config editor).
        # Values are baked into the launcher heredoc at generation time (not at runtime).
        WINE_FSYNC_VAL=0
        WINE_ESYNC_VAL=0
        if [ -n "$SCRIPT_NAME" ] && declare -f _read_lgsm_cfg_value >/dev/null 2>&1; then
            _inst_cfg="$SERVER_DIR/lgsm/config-lgsm/$SCRIPT_NAME/$SCRIPT_NAME.cfg"
            _v="$(_read_lgsm_cfg_value "$_inst_cfg" "winefsync" 2>/dev/null || true)"
            [ "$_v" = "1" ] && WINE_FSYNC_VAL=1 || true
            _v="$(_read_lgsm_cfg_value "$_inst_cfg" "wineesync" 2>/dev/null || true)"
            [ "$_v" = "1" ] && WINE_ESYNC_VAL=1 || true
        fi
        echo "Wine sync flags: WINEFSYNC=$WINE_FSYNC_VAL WINEESYNC=$WINE_ESYNC_VAL" >>"$DIAG_LOG" 2>&1
        if [ -n "$WINDROSE_DIRECT_BIN" ]; then
            LOCK_FILE="$SERVER_DIR/.windrose_start.lock"
            touch "$LOCK_FILE" 2>/dev/null || true
            chmod 0644 "$LOCK_FILE" 2>/dev/null || true
            exec 8>"$LOCK_FILE"
            if ! flock -w 5 8; then
                echo "ERROR: Could not acquire Windrose start lock ($LOCK_FILE)" >&2
                echo "hint_server_process_exited" > "$JOB_DIR/error_hint"
                set_final_status "failed"
                exit 1
            fi

            SCREEN_NAME="windrose_server"

            # No-op start: a healthy Windrose for this instance is already running.
            EXISTING_PID="$(_running_windrose_pid 2>/dev/null || true)"
            if [ -n "${EXISTING_PID:-}" ] && kill -0 "$EXISTING_PID" 2>/dev/null && _pid_belongs_to_instance "$EXISTING_PID" "$SERVER_DIR/.wine-windrose"; then
                echo "Windrose already running (PID $EXISTING_PID); start is a no-op."
                echo "start no-op: existing PID $EXISTING_PID matches WINEPREFIX" >>"$DIAG_LOG" 2>&1
                _write_pidfile "$EXISTING_PID"
                _finalize_detach_ok
                exit 0
            fi

            # Minimal session teardown: just our own screen/tmux session by name. No pkill, no wineserver -k.
            # Orphan xvfb-run/Xvfb from previous attempts don't block anything (xvfb-run -a picks a free display).
            screen -wipe >/dev/null 2>&1 || true
            screen -S "$SCREEN_NAME" -X quit 2>/dev/null || true
            tmux kill-session -t "$SCREEN_NAME" 2>/dev/null || true
            sleep 1

            echo "Using direct Windrose start path: $WINDROSE_DIRECT_BIN"

            {
                echo "=== pre-launch diagnostics $(date -Is) ==="
                echo "worker pid: $$"
                echo "worker cgroup:"
                cat /proc/$$/cgroup 2>/dev/null || echo "(unreadable)"
                echo "systemd cgroup of webmin (if any):"
                systemctl show miniserv 2>/dev/null | grep -E '^(MemoryMax|CPUQuota|TasksMax|MemoryHigh)=' || true
                systemctl show webmin 2>/dev/null | grep -E '^(MemoryMax|CPUQuota|TasksMax|MemoryHigh)=' || true
                echo "wine/Xvfb snapshot for $UNIX_USER (informational):"
                pgrep -af -u "$UNIX_USER" '(wineserver|Xvfb|xvfb-run|wine)' || echo "none"
            } >>"$DIAG_LOG" 2>&1

            LAUNCH_SCRIPT="$SERVER_DIR/.windrose_launch.sh"
            SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

            if ! bash "$SCRIPT_DIR/steamcmd_start_user.sh" \
                   "$SERVER_DIR" "$LAUNCH_SCRIPT" "$DIAG_LOG" "$LOGFILE" "$SERVERFILES" \
                   "$WINDROSE_DIRECT_BIN" \
                   "$WINE_FSYNC_VAL" "$WINE_ESYNC_VAL" \
                   "$INSTANCE_GAME_PORT" "$INSTANCE_QUERY_PORT" "$INSTANCE_BEACON_PORT" 2>&1; then
                echo "ERROR: steamcmd_start_user.sh failed" >&2
                set_final_status "failed"
                exit 1
            fi
            echo "Wrote launcher script: $LAUNCH_SCRIPT"
            echo "Wrote diagnostic log: $DIAG_LOG"

            # Detach order: screen → tmux → systemd-run --user → nohup setsid
            DETACH_METHOD=""
            echo "Process priority: game-user worker (default scheduling, no PRIO_HIGH)" >>"$DIAG_LOG"
            if command -v screen >/dev/null 2>&1; then
                DETACH_METHOD="screen"
                echo "Detached via screen -dmS $SCREEN_NAME bash $LAUNCH_SCRIPT"
                echo "(attach: screen -r $SCREEN_NAME)"
                {
                    echo "=== launching via screen -dmS $(date -Is) ==="
                    echo "screen cmd: screen -dmS $SCREEN_NAME bash $LAUNCH_SCRIPT"
                } >>"$DIAG_LOG" 2>&1
                screen -dmS "$SCREEN_NAME" bash "$LAUNCH_SCRIPT" >>"$DIAG_LOG" 2>&1 || true
            elif command -v tmux >/dev/null 2>&1; then
                DETACH_METHOD="tmux"
                echo "Detached via tmux new-session -d -s $SCREEN_NAME"
                {
                    echo "=== launching via tmux $(date -Is) ==="
                } >>"$DIAG_LOG" 2>&1
                tmux new-session -d -s "$SCREEN_NAME" "bash $LAUNCH_SCRIPT" >>"$DIAG_LOG" 2>&1 || true
            elif command -v systemd-run >/dev/null 2>&1; then
                DETACH_METHOD="systemd-run-user"
                echo "Detached via systemd-run --user --scope"
                {
                    echo "=== launching via systemd-run --user --scope $(date -Is) ==="
                } >>"$DIAG_LOG" 2>&1
                systemd-run --user --quiet --scope --unit="windrose-${UNIX_USER}-$$" \
                    /bin/bash -c "$LAUNCH_SCRIPT" \
                    </dev/null >>"$LOGFILE" 2>&1 &
                disown 2>/dev/null || true
            else
                DETACH_METHOD="nohup-setsid"
                echo "Detached via nohup setsid (no screen/tmux/systemd-run available)"
                nohup setsid bash "$LAUNCH_SCRIPT" \
                    </dev/null >>"$LOGFILE" 2>&1 &
                disown 2>/dev/null || true
            fi
            echo "DETACH_METHOD=$DETACH_METHOD" >>"$DIAG_LOG" 2>&1
            sleep 4
            PID=""
            for try in $(seq 1 20); do
                CAND="$(_running_windrose_pid || true)"
                if [ -n "${CAND:-}" ] && ! _is_transient_shell_pid "$CAND"; then
                    PID="$CAND"
                    break
                fi
                sleep 2
            done
            if [ -z "${PID:-}" ] || ! kill -0 "$PID" 2>/dev/null; then
                echo "ERROR: Direct Windrose start did not yield a live Wine/game PID (xvfb-run wrapper does not count)." >&2
                echo "--- windrose-debug.log tail (last 80 lines) ---"
                tail -n 80 "$DIAG_LOG" 2>/dev/null || true
                echo "--- end windrose-debug.log tail ---"
                echo "--- server.log tail (last 80 lines) ---"
                tail -n 80 "$LOGFILE" 2>/dev/null || true
                echo "--- end server.log tail ---"
                echo "hint_server_process_exited" > "$JOB_DIR/error_hint"
                set_final_status "failed"
                exit 1
            fi
            _write_pidfile "$PID"
            sleep 8
            if ! kill -0 "$PID" 2>/dev/null; then
                echo "ERROR: Windrose process PID $PID exited shortly after start." >&2
                echo "--- windrose-debug.log tail (last 80 lines) ---"
                tail -n 80 "$DIAG_LOG" 2>/dev/null || true
                echo "--- end windrose-debug.log tail ---"
                echo "--- server.log tail (last 80 lines) ---"
                tail -n 80 "$LOGFILE" 2>/dev/null || true
                echo "--- end server.log tail ---"
                echo "hint_server_process_exited" > "$JOB_DIR/error_hint"
                set_final_status "failed"
                exit 1
            fi
            # Windrose-specific readiness gate: PID alive is not enough.
            READY=0
            CONFIG_FILE="$SERVERFILES/R5/ServerDescription.json"
            LOGS_DIR="$SERVERFILES/R5/Saved/Logs"
            for _try in $(seq 1 40); do
                if [ -f "$CONFIG_FILE" ]; then
                    READY=1
                    break
                fi
                if [ -d "$LOGS_DIR" ]; then
                    LOG_COUNT=$(find "$LOGS_DIR" -maxdepth 1 -type f -name "*.log" 2>/dev/null | wc -l | tr -d ' ')
                    if [ "${LOG_COUNT:-0}" -gt 0 ]; then
                        READY=1
                        break
                    fi
                fi
                if [ "$((_try % 5))" -eq 0 ]; then
                    echo "Readiness wait: try=$_try, pid=$PID alive=$(kill -0 "$PID" 2>/dev/null && echo yes || echo no)" >>"$DIAG_LOG" 2>&1
                    echo "process tree (wine/xvfb/game):" >>"$DIAG_LOG" 2>&1
                    pgrep -af -u "$UNIX_USER" "WindroseServer-Win64-Shipping.exe|WindroseServer.exe|xvfb-run|Xvfb|wineserver|wine-preloader|wine64|\\.exe" >>"$DIAG_LOG" 2>&1 || true
                fi
                sleep 3
            done
            if [ "$READY" -ne 1 ]; then
                # Process still alive after timeout — Wine/UE5 init is just slow.
                # Don't treat slow startup as failure; report ok and let the user verify.
                if kill -0 "$PID" 2>/dev/null; then
                    echo "WARNING: Readiness files not found after 120s, but process $PID is still alive." >>"$DIAG_LOG" 2>&1
                    echo "Wine/UE5 initialization may still be in progress. Check server.log." >>"$DIAG_LOG" 2>&1
                    ls -la "$SERVERFILES/R5/Saved" >>"$DIAG_LOG" 2>&1 || true
                    pgrep -af -u "$UNIX_USER" "WindroseServer-Win64-Shipping.exe|WindroseServer.exe|xvfb-run|Xvfb|wineserver|wine" >>"$DIAG_LOG" 2>&1 || true
                    echo "Server started (PID $PID, readiness files pending)"
                    _finalize_detach_ok
                    exit 0
                fi
                echo "ERROR: Windrose readiness check failed and process is no longer alive." >&2
                echo "Windrose readiness failed after 120s (process died)" >>"$DIAG_LOG" 2>&1
                echo "Readiness snapshot:" >>"$DIAG_LOG" 2>&1
                ls -la "$SERVERFILES/R5" >>"$DIAG_LOG" 2>&1 || true
                ls -la "$SERVERFILES/R5/Saved" >>"$DIAG_LOG" 2>&1 || true
                echo "--- windrose-debug.log tail (last 120 lines) ---"
                tail -n 120 "$DIAG_LOG" 2>/dev/null || true
                echo "--- end windrose-debug.log tail ---"
                echo "--- server.log tail (last 80 lines) ---"
                tail -n 80 "$LOGFILE" 2>/dev/null || true
                echo "--- end server.log tail ---"
                echo "hint_server_process_exited" > "$JOB_DIR/error_hint"
                set_final_status "failed"
                exit 1
            fi
            echo "Server started (PID $PID)"
            _finalize_detach_ok
            exit 0
        fi
        if [ -x "$LAUNCH_WRAPPER" ]; then
            START_CMD="$LAUNCH_WRAPPER"
        elif [ -f "$LAUNCH_CMD_FILE" ]; then
            BINARY=$(cat "$LAUNCH_CMD_FILE" 2>/dev/null || true)
            if [ -n "${BINARY:-}" ] && [ -x "$BINARY" ]; then
                START_CMD="$BINARY"
            fi
        fi
        if [ -z "$START_CMD" ]; then
            BINARY=$(_find_binary)
            if [ -n "${BINARY:-}" ]; then
                START_CMD="$BINARY"
            fi
        fi
        if [ -z "$START_CMD" ]; then
            echo "ERROR: No server binary found in $SERVERFILES (missing .steam_launch_cmd / steamcmd-start.sh)" >&2
            set_final_status "failed"
            exit 1
        fi
        echo "Using start command: $START_CMD"
        cd "$SERVER_DIR" && setsid "$START_CMD" >> "$LOGFILE" 2>&1 & echo $! > "$PIDFILE"
        sleep 2
        PID="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [ -n "${PID:-}" ] && _is_transient_shell_pid "$PID"; then
            echo "PID $PID points to transient shell wrapper, searching real server process"
            PID=""
        fi
        if [ -z "${PID:-}" ] || ! kill -0 "$PID" 2>/dev/null; then
            if ADOPT_PID="$(_running_pid_from_launch_cmd)"; then
                _write_pidfile "$ADOPT_PID"
                PID="$ADOPT_PID"
                echo "Wrapper exited, adopted server process PID $PID"
            else
                echo "ERROR: Start command exited too early and no server process was detected. Check $LOGFILE" >&2
                echo "hint_no_server_binary" > "$JOB_DIR/error_hint"
                set_final_status "failed"
                exit 1
            fi
        fi
        sleep 5
        if ! kill -0 "$PID" 2>/dev/null; then
            echo "ERROR: Server process PID $PID exited shortly after start. Check $LOGFILE" >&2
            echo "hint_server_process_exited" > "$JOB_DIR/error_hint"
            set_final_status "failed"
            exit 1
        fi
        echo "Server started (PID $PID)"
        _finalize_detach_ok
        ;;

    stop)
        echo "steamcmd_control action=stop"
        STOP_DONE=0
        SCREEN_NAME="windrose_server"
        # Kill detached screen/tmux sessions for this user (best-effort)
        if command -v screen >/dev/null 2>&1; then
            screen -S "$SCREEN_NAME" -X quit 2>/dev/null || true
        fi
        if command -v tmux >/dev/null 2>&1; then
            tmux kill-session -t "$SCREEN_NAME" 2>/dev/null || true
        fi
        # Reap our manual Xvfb (recorded by the launcher), so it doesn't outlive the server.
        XVFB_PIDFILE="$SERVER_DIR/.xvfb.pid"
        if [ -f "$XVFB_PIDFILE" ]; then
            XVFB_PID=$(cat "$XVFB_PIDFILE" 2>/dev/null || true)
            if [ -n "$XVFB_PID" ] && kill -0 "$XVFB_PID" 2>/dev/null; then
                XVFB_CMD=$(ps -o args= -p "$XVFB_PID" 2>/dev/null || true)
                case "$XVFB_CMD" in
                    Xvfb*)
                        kill "$XVFB_PID" 2>/dev/null || true
                        sleep 1
                        kill -KILL "$XVFB_PID" 2>/dev/null || true
                        echo "Reaped Xvfb pid $XVFB_PID"
                        ;;
                esac
            fi
            rm -f "$XVFB_PIDFILE"
        fi
        if [ -f "$PIDFILE" ]; then
            PID=$(cat "$PIDFILE")
            if kill "$PID" 2>/dev/null; then
                echo "Server stopped (PID $PID)"
                STOP_DONE=1
            else
                echo "Process from PID file not running"
            fi
            rm -f "$PIDFILE"
        fi
        # Explicit Windrose/Wine termination (PID file may be stale).
        while IFS= read -r wp; do
            [ -n "$wp" ] || continue
            _terminate_pid "$wp"
            STOP_DONE=1
        done < <(_list_windrose_pids)
        if [ "$STOP_DONE" -eq 0 ] && [ -f "$LAUNCH_CMD_FILE" ]; then
            BINARY=$(cat "$LAUNCH_CMD_FILE" 2>/dev/null || true)
            if [ -n "${BINARY:-}" ]; then
                BIN_BASE=$(basename "$BINARY")
                BIN_STEM="${BIN_BASE%.exe}"
                pkill -u "$UNIX_USER" -f "$BIN_BASE" 2>/dev/null || true
                if [ "$BIN_STEM" != "$BIN_BASE" ]; then
                    pkill -u "$UNIX_USER" -f "$BIN_STEM" 2>/dev/null || true
                fi
                echo "Issued fallback stop signals for server processes"
            else
                echo "No PID file — server may not be running"
            fi
        elif [ "$STOP_DONE" -eq 0 ]; then
            echo "No PID file — server may not be running"
        fi
        # Final cleanup: ensure no Wine prefix remains locked
        WINEPREFIX="$SERVER_DIR/.wine-windrose" /usr/bin/wineserver -k 2>/dev/null || true
        if ! _wait_server_stopped 20; then
            echo "ERROR: Server process still running after stop" >&2
            echo "hint_server_stop_incomplete" > "$JOB_DIR/error_hint"
            set_final_status "failed"
            exit 1
        fi
        echo "Stop verified — no server process running"
        if [ "${WEBCORE_SKIP_FINAL:-0}" = "1" ]; then
            FINAL_STATUS_WRITTEN=1
            exit 0
        fi
        set_final_status "ok"
        ;;

    update)
        APP_ID_FILE="$SERVER_DIR/.steam_app_id"
        if [ ! -f "$APP_ID_FILE" ]; then
            echo "ERROR: .steam_app_id not found in $SERVER_DIR" >&2
            set_final_status "failed"
            exit 1
        fi
        STEAM_APP_ID=$(cat "$APP_ID_FILE")
        STEAMCMD="${STEAMCMD_PATH:-steamcmd}"
        echo "=== Updating App ID $STEAM_APP_ID via SteamCMD ($STEAMCMD) ==="
        if ! "$STEAMCMD" +force_install_dir "$SERVERFILES" \
                    +login anonymous \
                    +app_update "$STEAM_APP_ID" validate \
                    +quit; then
            echo "hint_steamcmd_login" > "$JOB_DIR/error_hint"
            set_final_status "failed"
            exit 1
        fi
        echo "=== Update complete ==="
        set_final_status "ok"
        ;;

    restart)
        echo "steamcmd_control action=restart"
        WEBCORE_SKIP_FINAL=1 bash "$0" stop "$JOB_DIR" "$UNIX_USER" "$SERVER_DIR" || true
        sleep 3
        WEBCORE_APPEND_LOG=1 WEBCORE_SKIP_FINAL=0 bash "$0" start "$JOB_DIR" "$UNIX_USER" "$SERVER_DIR"
        ;;

    *)
        echo "Unknown action: $ACTION" >&2
        set_final_status "failed"
        exit 1
        ;;
esac
