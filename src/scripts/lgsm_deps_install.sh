#!/bin/bash
# lgsm_deps_install.sh — ROOT-only: run LGSM "./script install" as root so
# LinuxGSM installs its own dependency list (apt). As root, LGSM performs the
# dependency step ONLY and does not install game files.
#
# Why root: game users have no sudo; provision_deps only covers base tools +
# optional games_meta apt_deps (non-LGSM / overrides). Per-game LGSM deps
# (e.g. rng-tools5 for PZ) come from LGSM's distro CSV via this step.
#
# Usage: lgsm_deps_install.sh <job_dir> <unix_user> <server_dir> <lgsm_script>
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
LGSM_SCRIPT="$4"

_SCRIPT_LIB="$(cd "$(dirname "$0")"/lib && pwd)"
# shellcheck source=lib/job_log.sh
. "$_SCRIPT_LIB/job_log.sh"
job_log_init "$JOB_DIR" "$UNIX_USER"

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

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: lgsm_deps_install.sh must run as root (got uid=$(id -u))"
    set_final_status "failed"
    exit 1
fi

LGSM_SCRIPT="${LGSM_SCRIPT##*/}"
LGSM_SCRIPT="${LGSM_SCRIPT//[^a-zA-Z0-9_-]/}"
if [ -z "$LGSM_SCRIPT" ]; then
    echo "ERROR: empty LGSM script name"
    set_final_status "failed"
    exit 1
fi

SCRIPT_PATH="$SERVER_DIR/$LGSM_SCRIPT"
if [ ! -x "$SCRIPT_PATH" ]; then
    echo "ERROR: LGSM script missing or not executable: $SCRIPT_PATH"
    echo "hint_command_not_found" > "$JOB_DIR/error_hint"
    set_final_status "failed"
    exit 1
fi

echo "=== LGSM dependency install (root) ==="
echo "script=$SCRIPT_PATH user=$UNIX_USER"
echo "Info: as root, LinuxGSM installs dependencies only (no game files)."

# Preseed grub like provision_deps to avoid interactive dpkg prompts.
if command -v debconf-set-selections >/dev/null 2>&1 && dpkg-query -W grub-pc >/dev/null 2>&1; then
    echo 'grub-pc grub-pc/install_devices_empty boolean true' | debconf-set-selections || true
    echo 'grub-pc grub-pc/install_devices multiselect' | debconf-set-selections || true
fi

cd "$SERVER_DIR"
# LGSM may still print warnings; treat non-zero as failure.
if ! ./"$LGSM_SCRIPT" install; then
    echo "ERROR: LGSM dependency install failed"
    echo "hint_apt_deps" > "$JOB_DIR/error_hint"
    set_final_status "failed"
    exit 1
fi

MARKER="$SERVER_DIR/.webcore_lgsm_deps_ok"
date -u +%Y-%m-%dT%H:%M:%SZ > "$MARKER"
if id "$UNIX_USER" >/dev/null 2>&1; then
    chown "$UNIX_USER:$UNIX_USER" "$MARKER" 2>/dev/null || true
fi
chmod 0644 "$MARKER" 2>/dev/null || true

echo "=== LGSM dependencies installed ==="
set_final_status "ok"
exit 0
