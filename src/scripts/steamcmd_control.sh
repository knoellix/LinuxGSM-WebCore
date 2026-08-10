#!/bin/bash
# steamcmd_control.sh — root entry point for non-LGSM start/stop/update.
# Root responsibilities ONLY: su dispatch to the game user (Webmin CGI runs as root).
# Job log files (pgid/output) MUST be written by the game user only — the job dir
# lives under /home/<user>/jobs/ and root-created files block the user worker.
# Usage: steamcmd_control.sh <action> <job_dir> <unix_user> <server_dir>
set -euo pipefail

ACTION="${1:?missing action}"
JOB_DIR="${2:?missing job_dir}"
UNIX_USER="${3:?missing unix_user}"
SERVER_DIR="${4:?missing server_dir}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_ROOT="${MODULE_ROOT:-$(dirname "$SCRIPT_DIR")}"
USER_SCRIPT="$SCRIPT_DIR/steamcmd_control_user.sh"

_sq() {
    local v="$1"
    v="${v//\'/\'\\\'\'}"
    printf "'%s'" "$v"
}

_mr=$(_sq "$MODULE_ROOT")
_us=$(_sq "$USER_SCRIPT")
_ac=$(_sq "$ACTION")
_jd=$(_sq "$JOB_DIR")
_u=$(_sq "$UNIX_USER")
_sd=$(_sq "$SERVER_DIR")

exec su -s /bin/bash -c "MODULE_ROOT=${_mr} exec bash ${_us} ${_ac} ${_jd} ${_u} ${_sd}" "$UNIX_USER"
