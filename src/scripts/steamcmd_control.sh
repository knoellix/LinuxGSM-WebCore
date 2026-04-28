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

_find_binary() {
    find "$SERVERFILES" -maxdepth 3 -type f \( -name "*.x86_64" -o -name "*Server.sh" \) \
        -perm /0111 2>/dev/null | head -1
}

case "$ACTION" in
    start)
        BINARY=$(_find_binary)
        if [ -z "$BINARY" ]; then
            echo "ERROR: No server binary found in $SERVERFILES" >&2
            echo "failed" > "$JOB_DIR/status"
            exit 1
        fi
        # shellcheck disable=SC2086
        su -s /bin/bash -c "
            cd '$SERVER_DIR' &&
            nohup '$BINARY' >> '$LOGFILE' 2>&1 &
            echo \$! > '$PIDFILE'
        " "$UNIX_USER"
        echo "Server started (PID $(cat "$PIDFILE" 2>/dev/null || echo unknown))"
        echo "ok" > "$JOB_DIR/status"
        ;;

    stop)
        if [ -f "$PIDFILE" ]; then
            PID=$(cat "$PIDFILE")
            kill "$PID" 2>/dev/null && echo "Server stopped (PID $PID)" || echo "Process not running"
            rm -f "$PIDFILE"
        else
            echo "No PID file — server may not be running"
        fi
        echo "ok" > "$JOB_DIR/status"
        ;;

    update)
        APP_ID_FILE="$SERVER_DIR/.steam_app_id"
        if [ ! -f "$APP_ID_FILE" ]; then
            echo "ERROR: .steam_app_id not found in $SERVER_DIR" >&2
            echo "failed" > "$JOB_DIR/status"
            exit 1
        fi
        STEAM_APP_ID=$(cat "$APP_ID_FILE")
        echo "=== Updating App ID $STEAM_APP_ID via SteamCMD ==="
        if ! su -s /bin/bash -c "
            steamcmd +force_install_dir '$SERVERFILES' \
                     +login anonymous \
                     +app_update '$STEAM_APP_ID' validate \
                     +quit
        " "$UNIX_USER"; then
            echo "hint_steamcmd_login" > "$JOB_DIR/error_hint"
            echo "failed" > "$JOB_DIR/status"
            exit 1
        fi
        echo "=== Update complete ==="
        echo "ok" > "$JOB_DIR/status"
        ;;

    *)
        echo "Unknown action: $ACTION" >&2
        echo "failed" > "$JOB_DIR/status"
        exit 1
        ;;
esac
