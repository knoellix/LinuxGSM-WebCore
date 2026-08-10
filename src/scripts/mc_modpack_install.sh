#!/bin/bash
# mc_modpack_install.sh — root entry: su dispatch only (see steamcmd_control.sh).
# Job log, downloads, and serverfiles writes run as the game user.
# Usage: mc_modpack_install.sh <job_dir> <unix_user> <server_dir>
set -euo pipefail

JOB_DIR="${1:?missing job_dir}"
UNIX_USER="${2:?missing unix_user}"
SERVER_DIR="${3:?missing server_dir}"
RESUME_MODE="${4:-${WEBCORE_MODPACK_RESUME:-0}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_ROOT="${MODULE_ROOT:-$(dirname "$SCRIPT_DIR")}"
USER_SCRIPT="$SCRIPT_DIR/mc_modpack_install_user.sh"

_sq() {
    local v="$1"
    v="${v//\'/\'\\\'\'}"
    printf "'%s'" "$v"
}

_mr=$(_sq "$MODULE_ROOT")
_us=$(_sq "$USER_SCRIPT")
_jd=$(_sq "$JOB_DIR")
_u=$(_sq "$UNIX_USER")
_sd=$(_sq "$SERVER_DIR")
_rs=$(_sq "$RESUME_MODE")

# Everything (download, adopt profile, Java/loader sub-steps, mods) runs as the
# game user in mc_modpack_install_user.sh. Root here only drops privileges.
exec su -s /bin/bash -c "MODULE_ROOT=${_mr} WEBCORE_JOB_DIR=${_jd} WEBCORE_MODPACK_RESUME=${_rs} exec bash ${_us} ${_jd} ${_u} ${_sd} ${_rs}" "$UNIX_USER"
