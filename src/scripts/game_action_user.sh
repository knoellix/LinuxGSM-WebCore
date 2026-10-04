#!/bin/bash
# game_action_user.sh — LGSM install/update/reinstall/validate/start/stop worker.
# Runs AS the game user (user-native): no internal su. Dispatched via
# user_worker_launch_cmd() (jobs.pl), which drops privileges from the Webmin
# root context. All files created here are owned by the game user.
# Usage: game_action_user.sh <job_dir> <unix_user> <server_dir> <game_script> [install|update|reinstall|validate|start|stop]
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
GAME_SCRIPT="$4"
ACTION="${5:-install}"

# Job dir is owned by the game user (create_job). Root must never write here —
# root-owned files cause "Permission denied" when this script runs via su.
if [[ ! -d "$JOB_DIR" ]]; then
    echo "ERROR: job dir missing: $JOB_DIR" >&2
    exit 1
fi
if [[ ! -w "$JOB_DIR" ]]; then
    echo "ERROR: job dir not writable by $(id -un): $JOB_DIR" >&2
    exit 1
fi

THIS_USER="$(id -un)"
if [[ "$THIS_USER" != "$UNIX_USER" ]]; then
    echo "ERROR: game_action_user.sh must run as $UNIX_USER (got $THIS_USER)" >&2
    exit 1
fi

_SCRIPT_LIB="$(cd "$(dirname "$0")"/lib && pwd)"
# shellcheck source=lib/job_log.sh
. "$_SCRIPT_LIB/job_log.sh"
job_log_init_as_user "$JOB_DIR"

# shellcheck source=lib/mc_java_env.sh
. "$_SCRIPT_LIB/mc_java_env.sh"
# shellcheck source=lib/lgsm_control.sh
. "$_SCRIPT_LIB/lgsm_control.sh"

# Process priority — install/update is a long, IO-heavy operation. PRIO_LOW
# keeps the LGSM child tree (steamcmd, tar, wineboot) out of the way of running
# games on neighbouring instances. PRIO_HIGH (negative nice) needs root, so the
# game-user worker only ever lowers priority.
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
PRIO_HIGH=""

# pgid lifecycle (see .cursor/rules/workers-shell.mdc): always unlink before writing the
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

if [ "$ACTION" = "start" ] || [ "$ACTION" = "stop" ] || [ "$ACTION" = "restart" ]; then
    echo "=== Performing '$ACTION': $GAME_SCRIPT ==="
    mc_java_env_apply "$SERVER_DIR"
    _ctrl_rc=0
    case "$ACTION" in
        start)
            _start_tmp=$(mktemp)
            set +e
            lgsm_start_reliable "$SERVER_DIR" "$GAME_SCRIPT" 2>&1 | tee "$_start_tmp"
            _ctrl_rc=${PIPESTATUS[0]}
            set -e
            if [[ "$_ctrl_rc" -eq 0 ]] \
                && grep -q 'WARNING: no Done in latest.log' "$_start_tmp" 2>/dev/null; then
                echo "hint_mc_start_still_loading" > "$JOB_DIR/error_hint"
            fi
            rm -f "$_start_tmp"
            ;;
        stop)
            lgsm_stop_reliable "$SERVER_DIR" "$GAME_SCRIPT" || _ctrl_rc=$?
            ;;
        restart)
            lgsm_restart_reliable "$SERVER_DIR" "$GAME_SCRIPT" || _ctrl_rc=$?
            ;;
    esac
    if [ "$_ctrl_rc" -ne 0 ]; then
        # Failed start/restart must release monitor "starting" grace — otherwise
        # cron skips recovery until starting_until (can be 20+ min for PZ workshop).
        if [[ "$ACTION" == "start" || "$ACTION" == "restart" ]]; then
            _MODULE_ROOT="${MODULE_ROOT:-}"
            if [[ -z "$_MODULE_ROOT" ]]; then
                _MODULE_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
            fi
            if [[ -f "$_MODULE_ROOT/scripts/monitor_mark_ready.pl" ]]; then
                perl "$_MODULE_ROOT/scripts/monitor_mark_ready.pl" "$SERVER_DIR" 2>/dev/null || true
                echo "Monitor starting grace cleared after failed $ACTION (recovery allowed)"
            fi
        fi
        set_final_status "failed"
        exit 1
    fi
    # After successful start/restart: clear monitor starting/paused → running.
    if [[ "$ACTION" == "start" || "$ACTION" == "restart" ]]; then
        _MODULE_ROOT="${MODULE_ROOT:-}"
        if [[ -z "$_MODULE_ROOT" ]]; then
            _MODULE_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
        fi
        if [[ -f "$_MODULE_ROOT/scripts/monitor_mark_ready.pl" ]]; then
            if ! perl "$_MODULE_ROOT/scripts/monitor_mark_ready.pl" "$SERVER_DIR"; then
                echo "WARNING: monitor_mark_ready.pl failed (UI may keep blinking until grace expires)" >&2
            fi
        else
            echo "WARNING: monitor_mark_ready.pl missing under $_MODULE_ROOT/scripts" >&2
        fi
    fi
    echo "=== '$ACTION' successfully completed ==="
    set_final_status "ok"
    exit 0
fi

if [ "$ACTION" = "bootstrap_game_config" ]; then
    echo "=== Bootstrap game config: start then stop ==="
    mc_java_env_apply "$SERVER_DIR"
    if ! lgsm_start_reliable "$SERVER_DIR" "$GAME_SCRIPT"; then
        set_final_status "failed"
        exit 1
    fi
    sleep 2
    if ! lgsm_stop_reliable "$SERVER_DIR" "$GAME_SCRIPT"; then
        set_final_status "failed"
        exit 1
    fi
    echo "=== Game config bootstrap completed ==="
    set_final_status "ok"
    exit 0
fi

if [ "$ACTION" = "reinstall" ]; then
    echo "=== Deleting serverfiles/ ==="
    if ! rm -rf "$SERVER_DIR/serverfiles"; then
        set_final_status "failed"
        exit 1
    fi
    ACTION="install"
fi

echo "=== Performing '$ACTION': $GAME_SCRIPT ==="
echo "Process priority: PRIO_LOW=[$PRIO_LOW]"

OUTPUT_FILE="$JOB_DIR/lgsm_output.txt"

_run_lgsm_action() {
    # LGSM install/update prompts (fn_yn) need answers on stdin — background
    # workers have no TTY. Without this, LGSM loops forever on
    # "Please answer yes or no." and floods the job log.
    # yes|cmd with pipefail returns yes' SIGPIPE exit (141), not LGSM's — use
    # PIPESTATUS[1] after temporarily disabling errexit.
    local rc=0
    if [ "$ACTION" = "install" ] || [ "$ACTION" = "update" ] || [ "$ACTION" = "validate" ]; then
        set +e
        yes | ( cd "$SERVER_DIR" && $PRIO_LOW ./"$GAME_SCRIPT" "$ACTION" )
        rc="${PIPESTATUS[1]}"
        set -e
    else
        ( cd "$SERVER_DIR" && $PRIO_LOW ./"$GAME_SCRIPT" "$ACTION" )
        rc=$?
    fi
    return "$rc"
}

# PRIO_LOW wraps the LGSM install/update — these spawn steamcmd, big tar
# extractions, and wineboot in some game branches. Keeping the child tree at low
# priority protects running games on neighbouring instances.
set +e
_run_lgsm_action 2>&1 | tee "$OUTPUT_FILE"
LGSM_RC="${PIPESTATUS[0]}"
set -e
if [ "$LGSM_RC" -ne 0 ]; then

    if grep -qiE "unable to locate package|E: Package" "$OUTPUT_FILE" 2>/dev/null; then
        echo "hint_package_not_found" > "$JOB_DIR/error_hint"
    elif grep -qiE "error.*libssl|cannot open shared object|no such file.*\.so" "$OUTPUT_FILE" 2>/dev/null; then
        echo "hint_lib_missing" > "$JOB_DIR/error_hint"
    elif grep -qiE "command not found|No such file or directory" "$OUTPUT_FILE" 2>/dev/null; then
        echo "hint_command_not_found" > "$JOB_DIR/error_hint"
    elif grep -qi "Please answer yes or no" "$OUTPUT_FILE" 2>/dev/null; then
        echo "hint_lgsm_interactive" > "$JOB_DIR/error_hint"
    else
        echo "hint_generic_install_error" > "$JOB_DIR/error_hint"
    fi

    set_final_status "failed"
    exit 1
fi

echo "=== '$ACTION' successfully completed ==="
set_final_status "ok"
