#!/bin/bash
# scheduled_restart_user.sh — daily scheduled restart (game user, cron).
# Args: <instance_id> <kind:lgsm|native> <server_dir> <script_name> <module_root>
# Only restarts when the server is online; otherwise skip + log.
set -euo pipefail

INSTANCE_ID="${1:?missing instance_id}"
KIND="${2:?missing kind}"
SERVER_DIR="${3:?missing server_dir}"
SCRIPT_NAME="${4:?missing script_name}"
MODULE_ROOT="${5:?missing module_root}"

STATE_DIR="$SERVER_DIR/.monitor"
SCHEDULE_FILE="$STATE_DIR/schedule"
LOG_DIR="$SERVER_DIR/logs"
LOG_FILE="$LOG_DIR/schedule.log"

mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null || true

_log() {
    local msg="[$(date '+%Y-%m-%d %T')] [$INSTANCE_ID] $*"
    echo "$msg"
    echo "$msg" >>"$LOG_FILE" 2>/dev/null || true
}

_read_schedule_key() {
    local key="$1" default="${2:-}"
    if [[ -f "$SCHEDULE_FILE" ]]; then
        local v
        v=$(grep "^${key}=" "$SCHEDULE_FILE" 2>/dev/null | cut -d= -f2- | head -1) || true
        [[ -n "$v" ]] && echo "$v" && return
    fi
    echo "$default"
}

_write_schedule_merge() {
    declare -A ST=()
    if [[ -f "$SCHEDULE_FILE" ]]; then
        while IFS='=' read -r k v; do
            [[ -n "$k" ]] || continue
            ST[$k]="$v"
        done <"$SCHEDULE_FILE"
    fi
    for pair in "$@"; do
        local k="${pair%%=*}" v="${pair#*=}"
        ST[$k]="$v"
    done
    local tmp
    tmp="$(mktemp "$STATE_DIR/.schedule.XXXXXX")" || return 1
    {
        printf 'enabled=%s\n' "${ST[enabled]:-0}"
        printf 'time=%s\n' "${ST[time]:-04:00}"
        [[ -n "${ST[last_run]:-}" ]] && printf 'last_run=%s\n' "${ST[last_run]}"
        [[ -n "${ST[last_skip_at]:-}" ]] && printf 'last_skip_at=%s\n' "${ST[last_skip_at]}"
        [[ -n "${ST[last_schedule_job]:-}" ]] && printf 'last_schedule_job=%s\n' "${ST[last_schedule_job]}"
    } >"$tmp"
    mv "$tmp" "$SCHEDULE_FILE"
}

_enabled=$(_read_schedule_key enabled 0)
if [[ "$_enabled" != "1" && "$_enabled" != "true" ]]; then
    exit 0
fi

NOW="$(date +%s)"
TODAY="$(date +%Y%m%d)"
_last_run=$(_read_schedule_key last_run 0)
if [[ "$_last_run" =~ ^[0-9]+$ && "$_last_run" -gt 0 ]]; then
    _last_day="$(date -d "@$_last_run" +%Y%m%d 2>/dev/null || date -r "$_last_run" +%Y%m%d 2>/dev/null || true)"
    if [[ "$_last_day" == "$TODAY" ]]; then
        _log "skip: already ran today (last_run=$_last_run)"
        exit 0
    fi
fi

_lgsm_is_online() {
    local LGSM_ONLINE_SH="$MODULE_ROOT/scripts/lib/lgsm_online.sh"
    if [[ -f "$LGSM_ONLINE_SH" ]]; then
        # shellcheck source=lib/lgsm_online.sh
        . "$LGSM_ONLINE_SH"
        lgsm_tmux_is_online "$SERVER_DIR" "$SCRIPT_NAME" && return 0
    fi
    ( cd "$SERVER_DIR" && "./$SCRIPT_NAME" details ) 2>/dev/null \
        | grep -Eqi 'Status:[[:space:]]*STARTED'
}

_native_is_online() {
    local pidfile="$SERVER_DIR/run.pid"
    [[ -f "$pidfile" ]] || return 1
    local pid
    pid=$(tr -d '[:space:]' <"$pidfile" 2>/dev/null || true)
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

_online=0
if [[ "$KIND" == "lgsm" ]]; then
    _lgsm_is_online && _online=1
else
    _native_is_online && _online=1
fi

if [[ "$_online" -eq 0 ]]; then
    _log "skip: server offline (scheduled restart only when online)"
    _write_schedule_merge "last_skip_at=$NOW"
    exit 0
fi

_job_id() {
    od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
}

JOB_ID="$(_job_id)"
[[ "$JOB_ID" =~ ^[0-9a-f]{16}$ ]] || { _log "ERROR: job id generation failed"; exit 1; }

JOB_HOME="$HOME/jobs/$JOB_ID"
mkdir -p "$HOME/jobs" "$JOB_HOME" || exit 1
chmod 700 "$HOME/jobs" "$JOB_HOME" 2>/dev/null || true

{
    printf 'instance_id=%s\n' "$INSTANCE_ID"
    printf 'action=scheduled_restart\n'
    printf 'started_at=%s\n' "$NOW"
    printf 'unix_user=%s\n' "$(id -un)"
    printf 'trigger=schedule\n'
} >"$JOB_HOME/meta"
printf 'running\n' >"$JOB_HOME/status"
: >"$JOB_HOME/output"
chmod 600 "$JOB_HOME/meta" "$JOB_HOME/status" 2>/dev/null || true

printf '%s\n' "$JOB_ID" >>"$STATE_DIR/pending_job_ids"

_log "scheduled restart starting (job $JOB_ID)"

_rc=0
{
    echo "=== Scheduled restart $(date '+%Y-%m-%d %T') ==="
    echo "instance=$INSTANCE_ID kind=$KIND"
    if [[ "$KIND" == "lgsm" ]]; then
        echo "--- stop ---"
        ( cd "$SERVER_DIR" && "./$SCRIPT_NAME" stop ) || _rc=1
        sleep 3
        echo "--- start ---"
        ( cd "$SERVER_DIR" && "./$SCRIPT_NAME" start ) || _rc=1
    else
        STOP_DIR="$JOB_HOME/.phase_stop"
        START_DIR="$JOB_HOME/.phase_start"
        mkdir -p "$STOP_DIR" "$START_DIR"
        echo "--- stop ---"
        if ! bash "$MODULE_ROOT/scripts/steamcmd_control_user.sh" stop \
            "$STOP_DIR" "$(id -un)" "$SERVER_DIR"; then
            _rc=1
        fi
        sleep 3
        echo "--- start ---"
        if ! bash "$MODULE_ROOT/scripts/steamcmd_control_user.sh" start \
            "$START_DIR" "$(id -un)" "$SERVER_DIR"; then
            _rc=1
        fi
        [[ -f "$STOP_DIR/output" ]] && cat "$STOP_DIR/output"
        [[ -f "$START_DIR/output" ]] && cat "$START_DIR/output"
        rm -rf "$STOP_DIR" "$START_DIR"
    fi
} >>"$JOB_HOME/output" 2>&1 || _rc=1

if [[ "$_rc" -eq 0 ]]; then
    printf 'ok\n' >"$JOB_HOME/status"
    _log "scheduled restart completed (job $JOB_ID)"
else
    printf 'failed\n' >"$JOB_HOME/status"
    _log "scheduled restart failed (job $JOB_ID) — see job output"
fi

_write_schedule_merge \
    "enabled=$(_read_schedule_key enabled 0)" \
    "time=$(_read_schedule_key time 04:00)" \
    "last_run=$NOW" \
    "last_schedule_job=$JOB_ID"

exit 0
