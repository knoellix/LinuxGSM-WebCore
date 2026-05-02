#!/bin/bash
# steamcmd_control.sh — start/stop/update for non-LGSM games
# Usage: steamcmd_control.sh <action> <job_dir> <unix_user> <server_dir>
set -euo pipefail

ACTION="$1"
JOB_DIR="$2"
UNIX_USER="$3"
SERVER_DIR="$4"

echo $$ > "$JOB_DIR/pgid"
exec >> "$JOB_DIR/output" 2>&1

SERVERFILES="$SERVER_DIR/serverfiles"
PIDFILE="$SERVER_DIR/run.pid"
LOGFILE="$SERVER_DIR/server.log"
LAUNCH_WRAPPER="$SERVER_DIR/steamcmd-start.sh"
LAUNCH_CMD_FILE="$SERVER_DIR/.steam_launch_cmd"

FINAL_STATUS_WRITTEN=0
set_final_status() {
    local s="$1"
    echo "$s" > "$JOB_DIR/status"
    FINAL_STATUS_WRITTEN=1
}
on_exit() {
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

_running_windrose_pid() {
    local pid cmd
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        cmd="$(ps -o args= -p "$pid" 2>/dev/null || true)"
        [ -n "$cmd" ] || continue
        case "$cmd" in
            *"WindroseServer-Win64-Shipping.exe"*|*"WindroseServer.exe"*)
                if ! _is_transient_shell_pid "$pid"; then
                    printf "%s\n" "$pid"
                    return 0
                fi
                ;;
        esac
    done < <(pgrep -u "$UNIX_USER" -f "WindroseServer-Win64-Shipping.exe|WindroseServer.exe|xvfb-run -a /usr/bin/wine" 2>/dev/null || true)
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
            *"WindroseServer-Win64-Shipping.exe"*|*"WindroseServer.exe"*)
                if ! _is_transient_shell_pid "$pid"; then
                    printf "%s\n" "$pid"
                fi
                ;;
        esac
    done < <(pgrep -u "$UNIX_USER" -f "WindroseServer-Win64-Shipping.exe|WindroseServer.exe|xvfb-run -a /usr/bin/wine" 2>/dev/null || true)
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
    printf "%s\n" "$pid" > "$PIDFILE"
    chown "$UNIX_USER":"$UNIX_USER" "$PIDFILE" 2>/dev/null || true
    chmod 0644 "$PIDFILE" 2>/dev/null || true
    return 0
}

case "$ACTION" in
    start)
        echo "steamcmd_control action=start"

        DIAG_LOG="$SERVER_DIR/windrose-debug.log"
        : > "$DIAG_LOG" 2>/dev/null || true
        chown "$UNIX_USER":"$UNIX_USER" "$DIAG_LOG" 2>/dev/null || true
        chmod 0644 "$DIAG_LOG" 2>/dev/null || true
        {
            echo "=== worker start $(date -Is) (rev: 2026-05-01-screen-v1) ==="
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
        if [ -f "$LAUNCH_CMD_FILE" ]; then
            BINARY=$(cat "$LAUNCH_CMD_FILE" 2>/dev/null || true)
            BIN_BASE=$(basename "${BINARY:-}")
            if [ "$BIN_BASE" = "WindroseServer-Win64-Shipping.exe" ] || [ "$BIN_BASE" = "WindroseServer.exe" ]; then
                if [ -f "$SERVERFILES/R5/Binaries/Win64/WindroseServer-Win64-Shipping.exe" ]; then
                    WINDROSE_DIRECT_BIN="R5/Binaries/Win64/WindroseServer-Win64-Shipping.exe"
                elif [ -f "$SERVERFILES/WindroseServer.exe" ]; then
                    WINDROSE_DIRECT_BIN="WindroseServer.exe"
                fi
            fi
        fi
        {
            echo "WINDROSE_DIRECT_BIN resolved to: '${WINDROSE_DIRECT_BIN:-<none>}'"
        } >>"$DIAG_LOG" 2>&1
        if [ -n "$WINDROSE_DIRECT_BIN" ]; then
            LOCK_FILE="$SERVER_DIR/.windrose_start.lock"
            exec 8>"$LOCK_FILE"
            if ! flock -w 5 8; then
                echo "ERROR: Could not acquire Windrose start lock ($LOCK_FILE)" >&2
                echo "hint_server_process_exited" > "$JOB_DIR/error_hint"
                set_final_status "failed"
                exit 1
            fi

            SCREEN_NAME="windrose-${UNIX_USER}"
            # Kill leftover screen/tmux sessions from previous start attempts first.
            su -s /bin/bash -c "screen -S '$SCREEN_NAME' -X quit 2>/dev/null || true" "$UNIX_USER" >>"$DIAG_LOG" 2>&1 || true
            su -s /bin/bash -c "tmux kill-session -t '$SCREEN_NAME' 2>/dev/null || true" "$UNIX_USER" >>"$DIAG_LOG" 2>&1 || true
            # Kill all xvfb-run+wine instances for this user unconditionally.
            pkill -9 -u "$UNIX_USER" -f "xvfb-run -a /usr/bin/wine" 2>/dev/null || true
            pkill -9 -u "$UNIX_USER" -f "WindroseServer-Win64-Shipping.exe|WindroseServer.exe" 2>/dev/null || true
            su -s /bin/bash -c "WINEPREFIX='$SERVER_DIR/.wine-windrose' /usr/bin/wineserver -k 2>/dev/null || true" "$UNIX_USER" 2>/dev/null || true
            sleep 2

            echo "Collecting existing Windrose PIDs..." >>"$DIAG_LOG" 2>&1
            mapfile -t WINDROSE_PIDS < <(_list_windrose_pids) || true
            echo "Found ${#WINDROSE_PIDS[@]} Windrose PID candidates" >>"$DIAG_LOG" 2>&1
            if [ "${#WINDROSE_PIDS[@]}" -gt 0 ]; then
                echo "Recycling existing Windrose processes before fresh start" >>"$DIAG_LOG" 2>&1
                for old_pid in "${WINDROSE_PIDS[@]}"; do
                    echo "Terminating existing PID: $old_pid" >>"$DIAG_LOG" 2>&1
                    _terminate_pid "$old_pid"
                done
                # Hard fallback cleanup for stubborn wrappers/children under the same user.
                pkill -9 -u "$UNIX_USER" -f "WindroseServer-Win64-Shipping.exe|WindroseServer.exe" 2>/dev/null || true
                pkill -9 -u "$UNIX_USER" -f "xvfb-run -a /usr/bin/wine" 2>/dev/null || true
                su -s /bin/bash -c "WINEPREFIX='$SERVER_DIR/.wine-windrose' /usr/bin/wineserver -k 2>/dev/null || true" "$UNIX_USER" 2>/dev/null || true
                sleep 3
                mapfile -t WINDROSE_LEFT < <(_list_windrose_pids) || true
                echo "Remaining Windrose PIDs after cleanup: ${#WINDROSE_LEFT[@]}" >>"$DIAG_LOG" 2>&1
                if [ "${#WINDROSE_LEFT[@]}" -gt 0 ]; then
                    echo "WARNING: ${#WINDROSE_LEFT[@]} process(es) still alive after cleanup (D-state?), proceeding anyway" >>"$DIAG_LOG" 2>&1
                    echo "WARNING: Could not fully clean old Windrose processes, starting anyway" >&2
                    for leftpid in "${WINDROSE_LEFT[@]}"; do
                        echo "  leftover PID $leftpid: $(ps -o args= -p "$leftpid" 2>/dev/null || echo 'gone')" >>"$DIAG_LOG" 2>&1
                    done
                fi
            fi
            echo "Using direct Windrose start path: $WINDROSE_DIRECT_BIN"

            {
                echo "=== pre-launch diagnostics $(date -Is) ==="
                echo "worker pid: $$"
                echo "worker cgroup:"
                cat /proc/$$/cgroup 2>/dev/null || echo "(unreadable)"
                echo "systemd cgroup of webmin (if any):"
                systemctl show miniserv 2>/dev/null | grep -E '^(MemoryMax|CPUQuota|TasksMax|MemoryHigh)=' || true
                systemctl show webmin 2>/dev/null | grep -E '^(MemoryMax|CPUQuota|TasksMax|MemoryHigh)=' || true
                echo "stale wineserver/Xvfb for $UNIX_USER (before kill):"
                pgrep -af -u "$UNIX_USER" '(wineserver|Xvfb|xvfb-run|wine)' || echo "none"
            } >>"$DIAG_LOG" 2>&1

            su -s /bin/bash -c "WINEPREFIX='$SERVER_DIR/.wine-windrose' /usr/bin/wineserver -k 2>/dev/null || true; pkill -u $UNIX_USER -9 -f Xvfb 2>/dev/null || true; pkill -u $UNIX_USER -9 -f xvfb-run 2>/dev/null || true" "$UNIX_USER" >>"$DIAG_LOG" 2>&1 || true
            sleep 1

            SCREEN_NAME="windrose-${UNIX_USER}"
            touch "$LOGFILE" 2>/dev/null || true
            chown "$UNIX_USER":"$UNIX_USER" "$LOGFILE" 2>/dev/null || true
            chmod 0644 "$LOGFILE" 2>/dev/null || true
            {
                echo "server.log preflight:"
                ls -l "$LOGFILE" 2>/dev/null || echo "missing"
            } >>"$DIAG_LOG" 2>&1
            LAUNCH_SCRIPT="$SERVER_DIR/.windrose_launch.sh"
            cat > "$LAUNCH_SCRIPT" <<EOF
#!/bin/bash
DIAG="$DIAG_LOG"
LOGFILE="$LOGFILE"
echo "=== launcher start \$(date -Is) ===" >>"\$DIAG"
echo "whoami: \$(whoami)" >>"\$DIAG"
echo "id: \$(id)" >>"\$DIAG"
echo "cgroup: \$(cat /proc/\$\$/cgroup 2>/dev/null)" >>"\$DIAG"
echo "TTY: \$(tty 2>/dev/null || echo 'no tty')" >>"\$DIAG"
{
  echo "ulimit -a:"
  ulimit -a
} >>"\$DIAG" 2>&1
cd "$SERVERFILES" || { echo "FATAL: cd failed" >>"\$DIAG"; exit 90; }
echo "pwd: \$(pwd)" >>"\$DIAG"
export WINEPREFIX="$SERVER_DIR/.wine-windrose"
export WINEARCH=win64
unset WINEDEBUG
unset WINEDLLOVERRIDES
echo "WINEPREFIX=\$WINEPREFIX" >>"\$DIAG"
echo "PATH=\$PATH" >>"\$DIAG"
{
  echo "binary check:"
  ls -l /usr/bin/wine /usr/bin/xvfb-run
  echo "binary target check:"
  ls -l "$WINDROSE_DIRECT_BIN"
  echo "HOME=\$HOME"
  echo "USER=\$USER"
  echo "server.log status:"
  ls -l "\$LOGFILE" 2>&1
  echo "=== run xvfb-run wine $WINDROSE_DIRECT_BIN -log ==="
} >>"\$DIAG" 2>&1
if [ ! -w "\$LOGFILE" ]; then
  echo "FATAL: logfile not writable: \$LOGFILE" >>"\$DIAG"
  exit 91
fi
if command -v stdbuf >/dev/null 2>&1; then
  stdbuf -oL -eL xvfb-run -a /usr/bin/wine "$WINDROSE_DIRECT_BIN" -log 2>&1 | tee -a "\$LOGFILE" >>"\$DIAG"
  RC=\${PIPESTATUS[0]}
else
  xvfb-run -a /usr/bin/wine "$WINDROSE_DIRECT_BIN" -log 2>&1 | tee -a "\$LOGFILE" >>"\$DIAG"
  RC=\${PIPESTATUS[0]}
fi
echo "wine launcher exited with rc=\$RC at \$(date -Is)" >>"\$DIAG"
echo "Post-exit process snapshot:" >>"\$DIAG"
pgrep -af -u "$UNIX_USER" "WindroseServer-Win64-Shipping.exe|WindroseServer.exe|xvfb-run|Xvfb|wineserver|wine" >>"\$DIAG" 2>&1 || true
exit \$RC
EOF
            chmod 0750 "$LAUNCH_SCRIPT"
            chown "$UNIX_USER":"$UNIX_USER" "$LAUNCH_SCRIPT" 2>/dev/null || true
            echo "Wrote launcher script: $LAUNCH_SCRIPT"
            echo "Wrote diagnostic log: $DIAG_LOG"

            # Detach order:
            # 1. screen   (LGSM-style, real PTY, attach via `screen -r windrose-<user>`)
            # 2. tmux     (alternative, same model)
            # 3. systemd-run --scope (escapes webmin cgroup)
            # 4. nohup setsid (last-resort fallback)
            DETACH_METHOD=""
            if command -v screen >/dev/null 2>&1; then
                DETACH_METHOD="screen"
                echo "Detached via screen -DmS $SCREEN_NAME"
                echo "(attach later: sudo -u $UNIX_USER screen -r $SCREEN_NAME)"
                {
                    echo "=== launching via screen -DmS $(date -Is) ==="
                } >>"$DIAG_LOG" 2>&1
                # Run screen as the unix user; launcher itself writes runtime logs to $LOGFILE.
                su -s /bin/bash -c "screen -dmS '$SCREEN_NAME' bash '$LAUNCH_SCRIPT'" "$UNIX_USER" >>"$DIAG_LOG" 2>&1 || true
            elif command -v tmux >/dev/null 2>&1; then
                DETACH_METHOD="tmux"
                echo "Detached via tmux new-session -d -s $SCREEN_NAME"
                {
                    echo "=== launching via tmux $(date -Is) ==="
                } >>"$DIAG_LOG" 2>&1
                su -s /bin/bash -c "tmux new-session -d -s '$SCREEN_NAME' 'bash $LAUNCH_SCRIPT'" "$UNIX_USER" >>"$DIAG_LOG" 2>&1 || true
            elif command -v systemd-run >/dev/null 2>&1; then
                DETACH_METHOD="systemd-run"
                echo "Detached via systemd-run --scope (escapes webmin cgroup)"
                {
                    echo "=== launching via systemd-run --scope $(date -Is) ==="
                } >>"$DIAG_LOG" 2>&1
                systemd-run --quiet --scope --slice=user.slice \
                    --unit="windrose-${UNIX_USER}-$$" \
                    --uid="$UNIX_USER" --gid="$UNIX_USER" \
                    /bin/bash -c "$LAUNCH_SCRIPT" \
                    </dev/null >>"$LOGFILE" 2>&1 &
                disown 2>/dev/null || true
            else
                DETACH_METHOD="nohup-setsid"
                echo "Detached via nohup setsid (no screen/tmux/systemd-run available)"
                nohup setsid su -s /bin/bash -c "$LAUNCH_SCRIPT" "$UNIX_USER" \
                    </dev/null >>"$LOGFILE" 2>&1 &
                disown 2>/dev/null || true
            fi
            echo "DETACH_METHOD=$DETACH_METHOD" >>"$DIAG_LOG" 2>&1
            sleep 4
            PID=""
            for try in 1 2 3 4 5; do
                CAND="$(_running_windrose_pid || true)"
                if [ -n "${CAND:-}" ] && ! _is_transient_shell_pid "$CAND"; then
                    PID="$CAND"
                    break
                fi
                sleep 1
            done
            if [ -z "${PID:-}" ] || ! kill -0 "$PID" 2>/dev/null; then
                echo "ERROR: Direct Windrose start did not yield a live server process. Check $LOGFILE" >&2
                echo "hint_server_process_exited" > "$JOB_DIR/error_hint"
                set_final_status "failed"
                exit 1
            fi
            _write_pidfile "$PID"
            sleep 8
            if ! kill -0 "$PID" 2>/dev/null; then
                echo "ERROR: Windrose process PID $PID exited shortly after start. Check $LOGFILE" >&2
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
                    pgrep -af -u "$UNIX_USER" "WindroseServer-Win64-Shipping.exe|WindroseServer.exe|xvfb-run|Xvfb|wineserver|wine" >>"$DIAG_LOG" 2>&1 || true
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
                    set_final_status "ok"
                    exit 0
                fi
                echo "ERROR: Windrose readiness check failed and process is no longer alive." >&2
                echo "Windrose readiness failed after 120s (process died)" >>"$DIAG_LOG" 2>&1
                echo "Readiness snapshot:" >>"$DIAG_LOG" 2>&1
                ls -la "$SERVERFILES/R5" >>"$DIAG_LOG" 2>&1 || true
                ls -la "$SERVERFILES/R5/Saved" >>"$DIAG_LOG" 2>&1 || true
                echo "hint_server_process_exited" > "$JOB_DIR/error_hint"
                set_final_status "failed"
                exit 1
            fi
            echo "Server started (PID $PID)"
            set_final_status "ok"
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
            echo "failed" > "$JOB_DIR/status"
            exit 1
        fi
        echo "Using start command: $START_CMD"
        # shellcheck disable=SC2086
        su -s /bin/bash -c "cd '$SERVER_DIR' && setsid '$START_CMD' >> '$LOGFILE' 2>&1 & echo \$! > '$PIDFILE'" "$UNIX_USER"
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
        set_final_status "ok"
        ;;

    stop)
        echo "steamcmd_control action=stop"
        STOP_DONE=0
        SCREEN_NAME="windrose-${UNIX_USER}"
        # Kill detached screen/tmux sessions for this user (best-effort)
        if command -v screen >/dev/null 2>&1; then
            su -s /bin/bash -c "screen -S '$SCREEN_NAME' -X quit 2>/dev/null || true" "$UNIX_USER" || true
        fi
        if command -v tmux >/dev/null 2>&1; then
            su -s /bin/bash -c "tmux kill-session -t '$SCREEN_NAME' 2>/dev/null || true" "$UNIX_USER" || true
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
        su -s /bin/bash -c "WINEPREFIX='$SERVER_DIR/.wine-windrose' /usr/bin/wineserver -k 2>/dev/null || true" "$UNIX_USER" 2>/dev/null || true
        set_final_status "ok"
        ;;

    update)
        APP_ID_FILE="$SERVER_DIR/.steam_app_id"
        if [ ! -f "$APP_ID_FILE" ]; then
            echo "ERROR: .steam_app_id not found in $SERVER_DIR" >&2
            echo "failed" > "$JOB_DIR/status"
            exit 1
        fi
        STEAM_APP_ID=$(cat "$APP_ID_FILE")
        STEAMCMD="${STEAMCMD_PATH:-steamcmd}"
        echo "=== Updating App ID $STEAM_APP_ID via SteamCMD ($STEAMCMD) ==="
        if ! su -s /bin/bash -c "
            '$STEAMCMD' +force_install_dir '$SERVERFILES' \
                        +login anonymous \
                        +app_update '$STEAM_APP_ID' validate \
                        +quit
        " "$UNIX_USER"; then
            echo "hint_steamcmd_login" > "$JOB_DIR/error_hint"
            set_final_status "failed"
            exit 1
        fi
        echo "=== Update complete ==="
        set_final_status "ok"
        ;;

    *)
        echo "Unknown action: $ACTION" >&2
        set_final_status "failed"
        exit 1
        ;;
esac
