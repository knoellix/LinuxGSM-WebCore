#!/bin/bash
# monitor_job.sh — record a monitor-driven restart as a Webmin-visible job (game user).
# Usage: monitor_job.sh <instance_id> <unix_user> <server_dir> [log_excerpt_file]
# Creates $HOME/jobs/<id>/, appends id to $server_dir/.monitor/pending_job_ids,
# updates $server_dir/.monitor/state (last_restart_at, last_restart_job).
set -euo pipefail

INSTANCE_ID="${1:?instance_id}"
UNIX_USER="${2:?unix_user}"
SERVER_DIR="${3:?server_dir}"
LOG_EXCERPT="${4:-}"

THIS_USER="$(id -un)"
if [[ "$THIS_USER" != "$UNIX_USER" ]]; then
    echo "ERROR: monitor_job.sh must run as $UNIX_USER (got $THIS_USER)" >&2
    exit 1
fi

STATE_DIR="$SERVER_DIR/.monitor"
mkdir -p "$STATE_DIR" 2>/dev/null || true

_job_id() {
    od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
}

JOB_ID="$(_job_id)"
[[ "$JOB_ID" =~ ^[0-9a-f]{16}$ ]] || { echo "ERROR: job id generation failed" >&2; exit 1; }

JOB_HOME="$HOME/jobs/$JOB_ID"
mkdir -p "$HOME/jobs" "$JOB_HOME" || exit 1
chmod 700 "$HOME/jobs" "$JOB_HOME" 2>/dev/null || true

NOW="$(date +%s)"
{
    printf 'instance_id=%s\n' "$INSTANCE_ID"
    printf 'action=monitor_restart\n'
    printf 'started_at=%s\n' "$NOW"
    printf 'unix_user=%s\n' "$UNIX_USER"
    printf 'trigger=monitor\n'
} >"$JOB_HOME/meta"

{
    echo "=== Monitor auto-restart $(date '+%Y-%m-%d %T') ==="
    if [[ -n "$LOG_EXCERPT" && -f "$LOG_EXCERPT" ]]; then
        cat "$LOG_EXCERPT" 2>/dev/null || true
    fi
} >"$JOB_HOME/output"

printf 'ok\n' >"$JOB_HOME/status"
chmod 600 "$JOB_HOME/meta" "$JOB_HOME/output" "$JOB_HOME/status" 2>/dev/null || true

printf '%s\n' "$JOB_ID" >>"$STATE_DIR/pending_job_ids"

# Merge last_restart_* into state (preserve status/restart_count/window_start).
STATE_FILE="$STATE_DIR/state"
declare -A ST=([status]=running [restart_count]=0 [window_start]="$NOW")
if [[ -f "$STATE_FILE" ]]; then
    while IFS='=' read -r k v; do
        [[ -n "$k" ]] || continue
        ST[$k]="$v"
    done <"$STATE_FILE"
fi
ST[last_restart_at]="$NOW"
ST[last_restart_job]="$JOB_ID"

tmp="$(mktemp "$STATE_DIR/.state.XXXXXX")" || exit 1
{
    printf 'status=%s\n' "${ST[status]:-running}"
    printf 'restart_count=%s\n' "${ST[restart_count]:-0}"
    printf 'window_start=%s\n' "${ST[window_start]:-$NOW}"
    printf 'last_restart_at=%s\n' "$NOW"
    printf 'last_restart_job=%s\n' "$JOB_ID"
} >"$tmp"
mv "$tmp" "$STATE_FILE"

echo "$JOB_ID"
