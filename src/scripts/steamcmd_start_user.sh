#!/bin/bash
# steamcmd_start_user.sh — game-user-side start preparation
# Runs as the game-user via 'su' from steamcmd_control.sh.
# Creates server.log and generates .windrose_launch.sh with all vars baked in.
# Args: <server_dir> <launch_script> <diag_log> <logfile> <serverfiles>
#       <windrose_direct_bin> <wine_fsync_val> <wine_esync_val>
#       <game_port> <query_port> <beacon_port>
set -euo pipefail

SERVER_DIR="$1"
LAUNCH_SCRIPT="$2"
DIAG_LOG="$3"
LOGFILE="$4"
SERVERFILES="$5"
WINDROSE_DIRECT_BIN="$6"
WINE_FSYNC_VAL="$7"
WINE_ESYNC_VAL="$8"
INSTANCE_GAME_PORT="$9"
INSTANCE_QUERY_PORT="${10}"
INSTANCE_BEACON_PORT="${11}"

THIS_USER="$(id -un)"

# Create server.log owned by game user
touch "$LOGFILE" 2>/dev/null || true
chmod 0644 "$LOGFILE" 2>/dev/null || true

# Write .windrose_launch.sh — all path/port vars baked in at generation time.
# Runtime vars inside the generated script are escaped with \$ so they expand
# when the launcher itself runs, not when this heredoc is written.
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
  ls -l "$SERVERFILES/$WINDROSE_DIRECT_BIN"
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
# Do NOT wrap wine in \`stdbuf\`: coreutils injects LD_PRELOAD=libstdbuf.so, which Wine's loader
# rejects with "wrong ELF class: ELFCLASS64" noise on every start (harmless but confusing).
# UE5 dedicated server CLI args: -Port (game), -QueryPort (Steam A2S), -BeaconPort (UE beacon).
# Without these, every instance binds the same UE5 defaults (7777/27015/15000) and the second one
# fails silently — see CLAUDE.md §8.12 multi-instance isolation notes.
/usr/bin/wine "$SERVERFILES/$WINDROSE_DIRECT_BIN" -log -Port=$INSTANCE_GAME_PORT -QueryPort=$INSTANCE_QUERY_PORT -BeaconPort=$INSTANCE_BEACON_PORT 2>&1 | tee -a "\$LOGFILE"
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
pgrep -af -u "$THIS_USER" "WindroseServer-Win64-Shipping.exe|WindroseServer.exe|xvfb-run|Xvfb|wineserver|wine" >>"\$DIAG" 2>&1 || true
exit \$RC
EOF
chmod 0750 "$LAUNCH_SCRIPT"
