#!/bin/bash
# setup_lgsm_user.sh — download & bootstrap LinuxGSM as the game user (user-native).
# Dispatched via user_worker_launch_cmd() from manage.cgi — no internal su.
# Usage: setup_lgsm_user.sh <job_dir> <unix_user> <server_dir> <lgsm_shortname> [verify_script]
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
LGSM_SHORT="$4"
VERIFY_SCRIPT="${5:-$LGSM_SHORT}"

if [[ ! -d "$JOB_DIR" ]] || [[ ! -w "$JOB_DIR" ]]; then
    echo "ERROR: job dir missing or not writable: $JOB_DIR" >&2
    exit 1
fi
THIS_USER="$(id -un)"
if [[ "$THIS_USER" != "$UNIX_USER" ]]; then
    echo "ERROR: setup_lgsm_user.sh must run as $UNIX_USER (got $THIS_USER)" >&2
    exit 1
fi

_SCRIPT_LIB="$(cd "$(dirname "$0")"/lib && pwd)"
# shellcheck source=lib/job_log.sh
. "$_SCRIPT_LIB/job_log.sh"
job_log_init_as_user "$JOB_DIR"

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

echo "=== LGSM setup started ==="
echo "linuxgsm shortname=$LGSM_SHORT expected_script=$VERIFY_SCRIPT"
echo "=== Downloading LinuxGSM ==="
if ! (
    cd "$SERVER_DIR" &&
    curl -Lo linuxgsm.sh https://linuxgsm.sh &&
    chmod +x linuxgsm.sh &&
    bash linuxgsm.sh "$LGSM_SHORT"
); then
    set_final_status "failed"
    exit 1
fi

if [ ! -x "$SERVER_DIR/$VERIFY_SCRIPT" ]; then
    echo "ERROR: LGSM script missing after setup: $SERVER_DIR/$VERIFY_SCRIPT" >&2
    echo "hint_command_not_found" > "$JOB_DIR/error_hint"
    set_final_status "failed"
    exit 1
fi

echo "=== LinuxGSM successfully installed ($VERIFY_SCRIPT) ==="
set_final_status "ok"
