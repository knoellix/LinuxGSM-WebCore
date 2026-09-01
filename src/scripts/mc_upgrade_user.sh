#!/bin/bash
# mc_upgrade_user.sh — Minecraft loader/MC version upgrade (game user)
# Usage: mc_upgrade_user.sh <job_dir> <unix_user> <server_dir> <lgsm_script>
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
LGSM_SCRIPT="$4"

MODULE_ROOT="${MODULE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

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

if [ "$(id -un)" != "$UNIX_USER" ]; then
    echo "ERROR: expected unix user $UNIX_USER, got $(id -un)"
    set_final_status "failed"
    exit 1
fi

PLAN_FILE="$JOB_DIR/upgrade_plan.json"
if [ ! -f "$PLAN_FILE" ]; then
    echo "ERROR: missing upgrade_plan.json"
    set_final_status "failed"
    exit 1
fi

read_plan() {
    perl -MJSON::PP=decode_json -e '
        open my $f, "<", shift or exit 1;
        local $/; my $p = decode_json(<$f>);
        print join("\n",
            $p->{mode} // "",
            $p->{target_loader_version} // "",
            $p->{loader} // "",
            $p->{mc_version} // "",
        );
    ' "$PLAN_FILE"
}

mapfile -t _PLAN < <(read_plan) || {
    echo "ERROR: cannot parse upgrade_plan.json"
    set_final_status "failed"
    exit 1
}

MODE="${_PLAN[0]}"
TARGET_PIN="${_PLAN[1]}"
LOADER="${_PLAN[2]}"
MC_VERSION="${_PLAN[3]}"

if [ "$MODE" != "loader" ]; then
    echo "ERROR: unsupported upgrade mode: $MODE"
    set_final_status "failed"
    exit 1
fi
if [ -z "$TARGET_PIN" ]; then
    echo "ERROR: missing target_loader_version in plan"
    set_final_status "failed"
    exit 1
fi

PROFILE_FILE="$SERVER_DIR/.mcprofile.json"
if [ ! -f "$PROFILE_FILE" ]; then
    echo "ERROR: missing $PROFILE_FILE"
    set_final_status "failed"
    exit 1
fi

echo "=== Minecraft loader upgrade started ==="
echo "=== Target: $LOADER $TARGET_PIN (MC $MC_VERSION) ==="

echo "--- Updating profile pin ---"
MERGE_ERR="$(perl "$MODULE_ROOT/scripts/mc_profile_merge.pl" "$PROFILE_FILE" "$UNIX_USER" \
    "loader_version=$TARGET_PIN" 2>&1)" || {
    echo "ERROR: could not update profile pin${MERGE_ERR:+ — $MERGE_ERR}"
    set_final_status "failed"
    exit 1
}
echo "OK: profile loader_version=$TARGET_PIN"

echo "--- Running loader installer ---"
export WEBCORE_SUBSTEP=1
if ! bash "$MODULE_ROOT/scripts/mc_loader_install_user.sh" \
    "$JOB_DIR" "$UNIX_USER" "$SERVER_DIR" "$LGSM_SCRIPT"; then
    echo "ERROR: loader install sub-step failed"
    set_final_status "failed"
    exit 1
fi

echo "--- Verifying profile read-back ---"
READ_PIN="$(perl -MJSON::PP=decode_json -e '
    open my $f, "<", shift or exit 1;
    local $/; my $p = decode_json(<$f>);
    print $p->{loader_version} // "";
' "$PROFILE_FILE")"
if [ "$READ_PIN" != "$TARGET_PIN" ]; then
    echo "ERROR: profile loader_version mismatch (expected $TARGET_PIN got $READ_PIN)"
    set_final_status "failed"
    exit 1
fi
echo "OK: verified loader_version=$READ_PIN"

set_final_status "ok"
