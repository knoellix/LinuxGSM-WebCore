#!/bin/bash
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
GAME_SCRIPT="$4"
ACTION="${5:-install}"

echo $$ > "$JOB_DIR/pid"
exec >> "$JOB_DIR/output" 2>&1

echo "=== Performing '$ACTION': $GAME_SCRIPT ==="

if [ "$ACTION" = "reinstall" ]; then
    echo "=== Deleting serverfiles/ ==="
    su -s /bin/bash -c "rm -rf '$SERVER_DIR/serverfiles'" "$UNIX_USER" || {
        echo "failed" > "$JOB_DIR/status"
        exit 1
    }
    ACTION="install"
fi

if ! su -s /bin/bash -c "
    cd '$SERVER_DIR' &&
    ./'$GAME_SCRIPT' '$ACTION'
" "$UNIX_USER"; then
    echo "failed" > "$JOB_DIR/status"
    exit 1
fi

echo "=== '$ACTION' successfully completed ==="
echo "ok" > "$JOB_DIR/status"
