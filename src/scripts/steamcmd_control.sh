#!/bin/bash
# steamcmd_control.sh — start/stop/status/update for non-LGSM games
# Usage: steamcmd_control.sh <action> <server_dir> <unix_user> <steam_app_id> [extra_args...]
set -euo pipefail

ACTION="$1"
SERVER_DIR="$2"
UNIX_USER="$3"
STEAM_APP_ID="$4"
shift 4
EXTRA_ARGS="$*"

SERVERFILES="$SERVER_DIR/serverfiles"
PIDFILE="$SERVER_DIR/run.pid"
LOGFILE="$SERVER_DIR/server.log"

_find_binary() {
    find "$SERVERFILES" -maxdepth 3 -type f \( -name "*.x86_64" -o -name "*Server.sh" \) \
        -perm /0111 2>/dev/null | head -1
}

case "$ACTION" in
    start)
        BINARY=$(_find_binary)
        if [ -z "$BINARY" ]; then
            echo "ERROR: No server binary found in $SERVERFILES" >&2
            exit 1
        fi
        # shellcheck disable=SC2086
        su -s /bin/bash -c "
            cd '$SERVER_DIR' &&
            nohup '$BINARY' $EXTRA_ARGS >> '$LOGFILE' 2>&1 &
            echo \$! > '$PIDFILE'
        " "$UNIX_USER"
        echo "Server started (PID $(cat "$PIDFILE" 2>/dev/null || echo unknown))"
        ;;

    stop)
        if [ -f "$PIDFILE" ]; then
            PID=$(cat "$PIDFILE")
            kill "$PID" 2>/dev/null && echo "Server stopped (PID $PID)" || echo "Process not running"
            rm -f "$PIDFILE"
        else
            echo "No PID file — server may not be running"
        fi
        ;;

    status)
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "running"
        else
            echo "stopped"
        fi
        ;;

    update)
        su -s /bin/bash -c "
            steamcmd +force_install_dir '$SERVERFILES' \
                     +login anonymous \
                     +app_update '$STEAM_APP_ID' validate \
                     +quit
        " "$UNIX_USER"
        ;;

    *)
        echo "Unknown action: $ACTION" >&2
        exit 1
        ;;
esac
