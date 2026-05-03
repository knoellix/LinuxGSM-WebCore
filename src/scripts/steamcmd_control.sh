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
    printf "%s\n" "$pid" > "$PIDFILE"
    chown "$UNIX_USER":"$UNIX_USER" "$PIDFILE" 2>/dev/null || true
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

case "$ACTION" in
    start)
        echo "steamcmd_control action=start"

        DIAG_LOG="$SERVER_DIR/windrose-debug.log"
        : > "$DIAG_LOG" 2>/dev/null || true
        chown "$UNIX_USER":"$UNIX_USER" "$DIAG_LOG" 2>/dev/null || true
        chmod 0644 "$DIAG_LOG" 2>/dev/null || true
        {
            echo "=== worker start $(date -Is) (rev: 2026-05-02-ports-v16) ==="
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
            chown "$UNIX_USER":"$UNIX_USER" "$LOCK_FILE" 2>/dev/null || true
            chmod 0644 "$LOCK_FILE"
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
            su -s /bin/bash -c "screen -wipe >/dev/null 2>&1 || true" "$UNIX_USER" 2>/dev/null || true
            su -s /bin/bash -c "screen -S '$SCREEN_NAME' -X quit 2>/dev/null || true" "$UNIX_USER" 2>/dev/null || true
            su -s /bin/bash -c "tmux kill-session -t '$SCREEN_NAME' 2>/dev/null || true" "$UNIX_USER" 2>/dev/null || true
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
# Wine prints a lot to stderr only via WINEDEBUG channels. Pump them up so the screen PTY
# (which only sees wine stdout/stderr — all our other diag goes to files) is never silent
# during a failing start. err+all is verbose but actionable; users can dial back later.
export WINEDEBUG="\${WINEDEBUG:-err+all,fixme-all}"
unset WINEDLLOVERRIDES
# Wine sync primitives — values baked at launch-script generation time from instance cfg.
[ $WINE_FSYNC_VAL -eq 1 ] && export WINEFSYNC=1 || true
[ $WINE_ESYNC_VAL -eq 1 ] && export WINEESYNC=1 || true
# pam_systemd usually sets XDG_RUNTIME_DIR for an interactive sudo session, but Webmin's
# 'setsid nohup … su' chain can land here without it. Wine/Xvfb then fall back to /tmp and
# behave inconsistently. Set it deterministically.
if [ -z "\${XDG_RUNTIME_DIR:-}" ]; then
  uid="\$(id -u)"
  if [ -n "\$uid" ] && [ -d "/run/user/\$uid" ]; then
    export XDG_RUNTIME_DIR="/run/user/\$uid"
  fi
fi
echo "=== launcher env (relevant) ===" >>"\$DIAG"
env | grep -E '^(HOME|USER|LOGNAME|SHELL|TERM|LANG|LC_|PATH|XDG_RUNTIME_DIR|XDG_SESSION_ID|XDG_SESSION_TYPE|DBUS_SESSION_BUS_ADDRESS|DISPLAY|XAUTHORITY|WINEPREFIX|WINEARCH|WINEDEBUG)=' | sort >>"\$DIAG" 2>&1 || true
{
  echo "binary check:"
  ls -l /usr/bin/wine /usr/bin/xvfb-run
  echo "binary target check:"
  ls -l "$WINDROSE_DIRECT_BIN"
  echo "server.log status:"
  ls -l "\$LOGFILE" 2>&1
  echo "=== run WINEPREFIX=\$WINEPREFIX WINEARCH=\$WINEARCH wine $WINDROSE_DIRECT_BIN -log (manual Xvfb) ==="
} >>"\$DIAG" 2>&1
if [ ! -w "\$LOGFILE" ]; then
  echo "FATAL: logfile not writable: \$LOGFILE" >>"\$DIAG"
  exit 91
fi
# Manual Xvfb dance — bypasses xvfb-run's SIGUSR1 ready notification, which hangs
# under Webmin's setsid/nohup/su context (signal mask oddity). Inside this launcher
# we own Xvfb directly and never block on a signal we may not receive.
XVFB_PIDFILE="$SERVER_DIR/.xvfb.pid"
# Reap our own previous Xvfb (recorded last start) before picking a new display.
if [ -f "\$XVFB_PIDFILE" ]; then
  OLD_XVFB=\$(cat "\$XVFB_PIDFILE" 2>/dev/null || true)
  if [ -n "\$OLD_XVFB" ] && kill -0 "\$OLD_XVFB" 2>/dev/null; then
    OLD_CMD=\$(ps -o args= -p "\$OLD_XVFB" 2>/dev/null || true)
    case "\$OLD_CMD" in
      Xvfb*)
        echo "Reaping previous Xvfb pid \$OLD_XVFB (\$OLD_CMD)" >>"\$DIAG"
        kill "\$OLD_XVFB" 2>/dev/null || true
        sleep 1
        kill -KILL "\$OLD_XVFB" 2>/dev/null || true
        ;;
    esac
  fi
  rm -f "\$XVFB_PIDFILE"
fi
DISPLAY_NUM=99
while [ -e "/tmp/.X\${DISPLAY_NUM}-lock" ]; do
  DISPLAY_NUM=\$((DISPLAY_NUM + 1))
  if [ "\$DISPLAY_NUM" -gt 250 ]; then
    echo "FATAL: no free Xvfb display below :250" >>"\$DIAG"
    exit 92
  fi
done
XVFB_LOG="$SERVER_DIR/xvfb.log"
: > "\$XVFB_LOG" 2>/dev/null || true
echo "Starting Xvfb :\$DISPLAY_NUM (manual, no xvfb-run)" >>"\$DIAG"
Xvfb ":\$DISPLAY_NUM" -screen 0 1280x1024x24 -nolisten tcp >>"\$XVFB_LOG" 2>&1 &
XVFB_PID=\$!
echo "\$XVFB_PID" > "\$XVFB_PIDFILE" 2>/dev/null || true
echo "Xvfb pid=\$XVFB_PID (recorded in \$XVFB_PIDFILE)" >>"\$DIAG"
# Wait until Xvfb is actually listening, max 10s.
for _i in 1 2 3 4 5 6 7 8 9 10; do
  if [ -S "/tmp/.X11-unix/X\${DISPLAY_NUM}" ] || [ -e "/tmp/.X\${DISPLAY_NUM}-lock" ]; then
    sleep 1
    if kill -0 "\$XVFB_PID" 2>/dev/null; then
      break
    fi
  fi
  sleep 1
done
if ! kill -0 "\$XVFB_PID" 2>/dev/null; then
  echo "FATAL: Xvfb did not stay alive (see \$XVFB_LOG)" >>"\$DIAG"
  tail -n 40 "\$XVFB_LOG" >>"\$DIAG" 2>&1 || true
  exit 93
fi
export DISPLAY=":\$DISPLAY_NUM"
echo "DISPLAY=\$DISPLAY ready, launching wine" >>"\$DIAG"
printf '%s\\n' "\$(date -Is) Windrose: starting wine on DISPLAY=\$DISPLAY (manual Xvfb pid=\$XVFB_PID), ports game=$INSTANCE_GAME_PORT query=$INSTANCE_QUERY_PORT beacon=$INSTANCE_BEACON_PORT." >>"\$LOGFILE"
# Run wine directly. stdout+stderr → tee → server.log AND screen PTY.
# UE5 dedicated server CLI args: -Port (game), -QueryPort (Steam A2S), -BeaconPort (UE beacon).
# Without these, every instance binds the same UE5 defaults (7777/27015/15000) and the second one
# fails silently — see CLAUDE.md §8.12 multi-instance isolation notes.
if command -v stdbuf >/dev/null 2>&1; then
  stdbuf -oL -eL /usr/bin/wine "$WINDROSE_DIRECT_BIN" -log -Port=$INSTANCE_GAME_PORT -QueryPort=$INSTANCE_QUERY_PORT -BeaconPort=$INSTANCE_BEACON_PORT 2>&1 | tee -a "\$LOGFILE"
else
  /usr/bin/wine "$WINDROSE_DIRECT_BIN" -log -Port=$INSTANCE_GAME_PORT -QueryPort=$INSTANCE_QUERY_PORT -BeaconPort=$INSTANCE_BEACON_PORT 2>&1 | tee -a "\$LOGFILE"
fi
RC=\${PIPESTATUS[0]}
echo "wine exited with rc=\$RC at \$(date -Is)" >>"\$DIAG"
kill "\$XVFB_PID" 2>/dev/null || true
wait "\$XVFB_PID" 2>/dev/null || true
rm -f "\$XVFB_PIDFILE" 2>/dev/null || true
echo "--- server.log tail (last 120 lines) ---" >>"\$DIAG"
tail -n 120 "\$LOGFILE" >>"\$DIAG" 2>&1 || true
echo "--- end server.log tail ---" >>"\$DIAG"
echo "Saved tree after exit:" >>"\$DIAG"
ls -la "$SERVERFILES/R5/Saved" 2>>"\$DIAG" || echo "(no R5/Saved yet)" >>"\$DIAG"
ls -la "$SERVERFILES/R5/Saved/Logs" 2>>"\$DIAG" || echo "(no R5/Saved/Logs yet)" >>"\$DIAG"
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
            # PRIO_HIGH wraps the detach command so screen + bash + wine + EXE
            # all inherit nice=-5 / ionice best-effort 0. Negative nice is set
            # by root BEFORE su drops to the game user — inheriting low values
            # across su(1) is unrestricted (only setpriority() is gated).
            echo "Process priority: launching via [$PRIO_HIGH]" >>"$DIAG_LOG"
            if command -v screen >/dev/null 2>&1; then
                DETACH_METHOD="screen"
                echo "Detached via $PRIO_HIGH screen -dmS $SCREEN_NAME bash $LAUNCH_SCRIPT"
                echo "(attach: sudo -u $UNIX_USER screen -r $SCREEN_NAME)"
                {
                    echo "=== launching via screen -dmS $(date -Is) ==="
                    echo "screen cmd: $PRIO_HIGH screen -dmS $SCREEN_NAME bash $LAUNCH_SCRIPT"
                } >>"$DIAG_LOG" 2>&1
                # Match manual: sudo -u <user> bash -c 'screen ...' — use su boundary (no runuser session quirks).
                $PRIO_HIGH su -s /bin/bash -c "screen -dmS '$SCREEN_NAME' bash '$LAUNCH_SCRIPT'" "$UNIX_USER" >>"$DIAG_LOG" 2>&1 || true
            elif command -v tmux >/dev/null 2>&1; then
                DETACH_METHOD="tmux"
                echo "Detached via $PRIO_HIGH tmux new-session -d -s $SCREEN_NAME"
                {
                    echo "=== launching via tmux $(date -Is) ==="
                } >>"$DIAG_LOG" 2>&1
                $PRIO_HIGH su -s /bin/bash -c "tmux new-session -d -s '$SCREEN_NAME' 'bash $LAUNCH_SCRIPT'" "$UNIX_USER" >>"$DIAG_LOG" 2>&1 || true
            elif command -v systemd-run >/dev/null 2>&1; then
                DETACH_METHOD="systemd-run"
                echo "Detached via systemd-run --scope (escapes webmin cgroup, prio inherited)"
                {
                    echo "=== launching via systemd-run --scope $(date -Is) ==="
                } >>"$DIAG_LOG" 2>&1
                # systemd-run inherits nice from this shell — wrap in $PRIO_HIGH so
                # the transient scope unit starts elevated.
                $PRIO_HIGH systemd-run --quiet --scope --slice=user.slice \
                    --unit="windrose-${UNIX_USER}-$$" \
                    --uid="$UNIX_USER" --gid="$UNIX_USER" \
                    /bin/bash -c "$LAUNCH_SCRIPT" \
                    </dev/null >>"$LOGFILE" 2>&1 &
                disown 2>/dev/null || true
            else
                DETACH_METHOD="nohup-setsid"
                echo "Detached via $PRIO_HIGH nohup setsid (no screen/tmux/systemd-run available)"
                $PRIO_HIGH nohup setsid su -s /bin/bash -c "$LAUNCH_SCRIPT" "$UNIX_USER" \
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
        _finalize_detach_ok
        ;;

    stop)
        echo "steamcmd_control action=stop"
        STOP_DONE=0
        SCREEN_NAME="windrose_server"
        # Kill detached screen/tmux sessions for this user (best-effort)
        if command -v screen >/dev/null 2>&1; then
            su -s /bin/bash -c "screen -S '$SCREEN_NAME' -X quit 2>/dev/null || true" "$UNIX_USER" 2>/dev/null || true
        fi
        if command -v tmux >/dev/null 2>&1; then
            su -s /bin/bash -c "tmux kill-session -t '$SCREEN_NAME' 2>/dev/null || true" "$UNIX_USER" || true
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
            set_final_status "failed"
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
