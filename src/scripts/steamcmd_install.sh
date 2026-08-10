#!/bin/bash
# steamcmd_install.sh — root entry point for non-LGSM game install.
# Root responsibilities ONLY: job tracking + privilege drop (su) to the game user.
# apt system dependencies are installed once by provision_deps.sh (root) at
# provisioning time — this script no longer touches apt.
# ALL file creation inside SERVER_DIR is done by steamcmd_install_user.sh (as game user).
# Usage: steamcmd_install.sh <job_dir> <unix_user> <server_dir> <steam_app_id> [validate] [script_name] [preclean]
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
STEAM_APP_ID="$4"
VALIDATE="${5:-}"
SCRIPT_NAME="${6:-}"
PRECLEAN="${7:-}"

_SCRIPT_LIB="$(cd "$(dirname "$0")"/lib && pwd)"
# shellcheck source=lib/job_log.sh
. "$_SCRIPT_LIB/job_log.sh"
job_log_init "$JOB_DIR" "$UNIX_USER"

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

echo "=== steamcmd_install revision: 2026-05-10-user-owned-v1 ==="
echo "Process priority: PRIO_LOW=[$PRIO_LOW]"

# Read metadata — no file creation, root reads world-readable JSON.
RUNTIME_MODE=$(MODULE_ROOT="${MODULE_ROOT:-}" STEAM_APP_ID="$STEAM_APP_ID" perl -e '
use JSON::PP;
my $meta_file = "$ENV{MODULE_ROOT}/lib/games_meta.json";
open(my $f, "<", $meta_file) or exit 0;
local $/;
my $data = decode_json(<$f>);
for my $k (keys %$data) {
    next unless (($data->{$k}{steam_app_id} // 0) == $ENV{STEAM_APP_ID});
    print($data->{$k}{runtime} // "");
    last;
}
' 2>/dev/null || true)

# apt dependencies were installed once by provision_deps.sh (root) at
# provisioning time — nothing to install here.

# --- USER PHASE: all SERVER_DIR work as game user ---
# No files inside SERVER_DIR are created by root. steamcmd_install_user.sh owns everything.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

safe_srv="${SERVER_DIR//\'/\'\\\'\'}"
safe_job="${JOB_DIR//\'/\'\\\'\'}"
safe_sd="${SCRIPT_DIR//\'/\'\\\'\'}"
safe_rt="${RUNTIME_MODE//\'/\'\\\'\'}"
safe_validate="${VALIDATE//\'/\'\\\'\'}"
safe_sn="${SCRIPT_NAME//\'/\'\\\'\'}"
safe_pc="${PRECLEAN//\'/\'\\\'\'}"

echo "=== Dispatching installation to game user $UNIX_USER ==="
if ! MODULE_ROOT="${MODULE_ROOT:-}" \
   STEAMCMD_PATH="${STEAMCMD_PATH:-}" \
   $PRIO_LOW su -s /bin/bash -c \
     "bash '$safe_sd/steamcmd_install_user.sh' \
          '$safe_srv' '$safe_job' '$STEAM_APP_ID' '$safe_validate' '$safe_sn' '$safe_rt' '$safe_pc'" \
     "$UNIX_USER" 2>&1; then
    # error_hint may have been written into JOB_DIR by the user script
    set_final_status "failed"
    exit 1
fi

set_final_status "ok"
