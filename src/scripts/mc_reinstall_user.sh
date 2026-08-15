#!/bin/bash
# mc_reinstall_user.sh — Wipe serverfiles/ and reinstall Java + Fabric/Forge/NeoForge.
# Runs AS THE GAME USER (dispatched via su privilege-drop, no internal su).
# Does NOT run LGSM install — the mod loader owns serverfiles/ for modded MC.
# Usage: mc_reinstall_user.sh <job_dir> <unix_user> <server_dir> <lgsm_script>
#
# Java + loader run as WEBCORE_SUBSTEP=1 (parent owns job log + final status).
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
LGSM_SCRIPT="$4"

MODULE_ROOT="${MODULE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

_SCRIPT_LIB="$(cd "$(dirname "$0")"/lib && pwd)"
# shellcheck source=lib/job_log.sh
. "$_SCRIPT_LIB/job_log.sh"

jl() { job_log_line "$JOB_DIR" "$@"; }

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

if [ "$(id -un)" != "$UNIX_USER" ]; then
    jl "ERROR: expected unix user $UNIX_USER, got $(id -un)"
    set_final_status "failed"
    exit 1
fi

jl "=== Minecraft modded reinstall started ==="

PROFILE_FILE="$SERVER_DIR/.mcprofile.json"
if [ ! -f "$PROFILE_FILE" ]; then
    jl "ERROR: missing $PROFILE_FILE"
    set_final_status "failed"
    exit 1
fi

LOADER="$(perl -MJSON::PP=decode_json -e '
    open my $f, "<", shift or exit 1;
    local $/; my $j = decode_json(<$f>);
    print $j->{loader} // "";
' "$PROFILE_FILE")" || {
    jl "ERROR: cannot parse $PROFILE_FILE"
    set_final_status "failed"
    exit 1
}

case "$LOADER" in
    fabric|forge|neoforge) ;;
    *)
        jl "ERROR: loader '$LOADER' is not Fabric/Forge/NeoForge — use LGSM reinstall"
        set_final_status "failed"
        exit 1
        ;;
esac

SETUP_LGSM="$LGSM_SCRIPT"
PROFILE_LGSM="$(perl -MJSON::PP=decode_json -e '
    open my $f, "<", shift or exit 1;
    local $/; my $j = decode_json(<$f>);
    print $j->{lgsm_script} // "";
' "$PROFILE_FILE" 2>/dev/null || true)"
if [ -n "$PROFILE_LGSM" ]; then
    SETUP_LGSM="$PROFILE_LGSM"
fi
SETUP_LGSM="$(printf '%s' "$SETUP_LGSM" | tr -cd 'a-zA-Z0-9_-')"
if [ -z "$SETUP_LGSM" ]; then
    jl "ERROR: missing lgsm_script"
    set_final_status "failed"
    exit 1
fi

_SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
JAVA_SCRIPT="${MODULE_ROOT}/scripts/mc_java_install_user.sh"
[ -f "$JAVA_SCRIPT" ] || JAVA_SCRIPT="$_SELF_DIR/mc_java_install_user.sh"
LOADER_SCRIPT="${MODULE_ROOT}/scripts/mc_loader_install_user.sh"
[ -f "$LOADER_SCRIPT" ] || LOADER_SCRIPT="$_SELF_DIR/mc_loader_install_user.sh"

jl "=== Deleting serverfiles/ (profile and LGSM configs kept) ==="
if [ -e "$SERVER_DIR/serverfiles" ]; then
    if ! rm -rf "$SERVER_DIR/serverfiles"; then
        jl "ERROR: could not delete $SERVER_DIR/serverfiles"
        set_final_status "failed"
        exit 1
    fi
fi

jl "=== Installing Java ==="
if ! WEBCORE_SUBSTEP=1 MODULE_ROOT="${MODULE_ROOT}" \
    bash "$JAVA_SCRIPT" "$JOB_DIR" "$UNIX_USER" "$SERVER_DIR" "$SETUP_LGSM"; then
    jl "ERROR: Java setup failed"
    set_final_status "failed"
    exit 1
fi

jl "=== Installing $LOADER loader from profile ==="
if ! WEBCORE_SUBSTEP=1 MODULE_ROOT="${MODULE_ROOT}" \
    bash "$LOADER_SCRIPT" "$JOB_DIR" "$UNIX_USER" "$SERVER_DIR" "$SETUP_LGSM"; then
    jl "ERROR: loader setup failed"
    set_final_status "failed"
    exit 1
fi

jl "=== Minecraft modded reinstall completed ==="
set_final_status "ok"
exit 0
