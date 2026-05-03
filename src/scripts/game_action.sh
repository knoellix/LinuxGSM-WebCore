#!/bin/bash
# game_action.sh — LGSM install/update/reinstall worker.
# Usage: game_action.sh <job_dir> <unix_user> <server_dir> <game_script> [install|update|reinstall]
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
GAME_SCRIPT="$4"
ACTION="${5:-install}"

echo $$ > "$JOB_DIR/pgid"
exec >> "$JOB_DIR/output" 2>&1

# Process priority — install/update is a long, IO-heavy operation. PRIO_LOW
# ensures it never starves a running game on the same host.
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

# pgid lifecycle (see CLAUDE.md §8.12): always unlink before writing the
# final status, plus an EXIT trap for abrupt aborts.
FINAL_STATUS_WRITTEN=0
set_final_status() {
    local s="$1"
    rm -f "$JOB_DIR/pgid" 2>/dev/null || true
    echo "$s" > "$JOB_DIR/status"
    FINAL_STATUS_WRITTEN=1
}
on_exit() {
    rm -f "$JOB_DIR/pgid" 2>/dev/null || true
    if [ "$FINAL_STATUS_WRITTEN" = "0" ] && [ ! -f "$JOB_DIR/status" ]; then
        echo "failed" > "$JOB_DIR/status"
    fi
}
trap on_exit EXIT

echo "=== Performing '$ACTION': $GAME_SCRIPT ==="
echo "Process priority: PRIO_LOW=[$PRIO_LOW]"

if [ "$ACTION" = "reinstall" ]; then
    echo "=== Deleting serverfiles/ ==="
    if ! su -s /bin/bash -c "rm -rf '$SERVER_DIR/serverfiles'" "$UNIX_USER"; then
        set_final_status "failed"
        exit 1
    fi
    ACTION="install"
fi

OUTPUT_FILE="$JOB_DIR/lgsm_output.txt"

# PRIO_LOW wraps the LGSM install/update — these spawn steamcmd, big tar
# extractions, and wineboot in some game branches. Inheriting nice/ionice
# across su(1) keeps the entire LGSM child tree out of the way of running
# games on neighbouring instances.
if ! $PRIO_LOW su -s /bin/bash -c "
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

    set_final_status "failed"
    exit 1
fi

echo "=== '$ACTION' successfully completed ==="
set_final_status "ok"
