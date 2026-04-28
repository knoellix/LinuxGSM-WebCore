#!/bin/bash
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
GAME_SCRIPT="$4"
ACTION="${5:-install}"

echo $$ > "$JOB_DIR/pgid"
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

OUTPUT_FILE="$JOB_DIR/lgsm_output.txt"

if ! su -s /bin/bash -c "
    cd '$SERVER_DIR' &&
    ./'$GAME_SCRIPT' '$ACTION'
" "$UNIX_USER" 2>&1 | tee "$OUTPUT_FILE"; then

    if grep -qiE "unable to locate package|E: Package" "$OUTPUT_FILE" 2>/dev/null; then
        echo "hint_package_not_found" > "$JOB_DIR/error_hint"
    elif grep -qiE "error.*libssl|cannot open shared object|no such file.*\.so" "$OUTPUT_FILE" 2>/dev/null; then
        echo "hint_lib_missing" > "$JOB_DIR/error_hint"
    elif grep -qiE "command not found|No such file or directory" "$OUTPUT_FILE" 2>/dev/null; then
        echo "hint_command_not_found" > "$JOB_DIR/error_hint"
    else
        echo "hint_generic_install_error" > "$JOB_DIR/error_hint"
    fi

    echo "failed" > "$JOB_DIR/status"
    exit 1
fi

echo "=== '$ACTION' successfully completed ==="
echo "ok" > "$JOB_DIR/status"
