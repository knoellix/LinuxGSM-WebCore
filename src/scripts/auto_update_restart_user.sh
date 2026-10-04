#!/bin/bash
# auto_update_restart_user.sh — auto-update restart job (game user).
# Flow: optional msg_now broadcast → stop → [update if need_game] → start →
# clear pending → monitor_mark_ready → status ok/failed.
# Workshop: no explicit download — PZ pulls on boot (spec).
# Usage: auto_update_restart_user.sh <job_dir> <unix_user> <server_dir> <script_name> <module_root>
# Env hooks (tests): AUTO_UPDATE_STOP_CMD, AUTO_UPDATE_UPDATE_CMD, AUTO_UPDATE_START_CMD,
#   AUTO_UPDATE_BROADCAST_CMD, AUTO_UPDATE_MARK_READY_CMD
set -euo pipefail

JOB_DIR="${1:?missing job_dir}"
UNIX_USER="${2:?missing unix_user}"
SERVER_DIR="${3:?missing server_dir}"
SCRIPT_NAME="${4:?missing script_name}"
MODULE_ROOT="${5:?missing module_root}"

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
    echo "ERROR: auto_update_restart_user.sh must run as $UNIX_USER (got $THIS_USER)" >&2
    exit 1
fi

SCRIPT_NAME="${SCRIPT_NAME//[^a-zA-Z0-9_-]/}"
[[ -n "$SCRIPT_NAME" ]] || { echo "ERROR: invalid script_name" >&2; exit 1; }

export MODULE_ROOT

# shellcheck source=lib/job_log.sh
. "$MODULE_ROOT/scripts/lib/job_log.sh"
job_log_init_as_user "$JOB_DIR"

# shellcheck source=lib/mc_java_env.sh
. "$MODULE_ROOT/scripts/lib/mc_java_env.sh"
# shellcheck source=lib/lgsm_control.sh
. "$MODULE_ROOT/scripts/lib/lgsm_control.sh"

# Process priority — long ./script update (steamcmd) should not starve neighbours.
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

STATE_DIR="$SERVER_DIR/.monitor"
STATE_FILE="$STATE_DIR/auto_update"

FINAL_STATUS_WRITTEN=0
set_final_status() {
    local s="$1"
    rm -f "$JOB_DIR/pgid" 2>/dev/null || true
    echo "$s" >"$JOB_DIR/status"
    FINAL_STATUS_WRITTEN=1
}

_read_state_key() {
    local key="$1" default="${2:-}"
    if [[ -f "$STATE_FILE" ]]; then
        local v
        v=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2- | head -1) || true
        [[ -n "$v" ]] && echo "$v" && return
    fi
    echo "$default"
}

_write_state_merge() {
    declare -A ST=()
    if [[ -f "$STATE_FILE" ]]; then
        while IFS='=' read -r k v; do
            [[ -n "$k" ]] || continue
            ST[$k]="$v"
        done <"$STATE_FILE"
    fi
    for pair in "$@"; do
        local k="${pair%%=*}" v="${pair#*=}"
        ST[$k]="$v"
    done
    # Never put "{placeholder}" inside ${var:-default} — bash closes at the first "}"
    # and appends the leftovers, corrupting templates on every merge.
    local _msg_tpl="${ST[msg_template]-}"
    local _msg_now_v="${ST[msg_now]-}"
    [[ -n "$_msg_tpl" ]] || _msg_tpl='Server-Neustart in {minutes} Min — {reason}'
    [[ -n "$_msg_now_v" ]] || _msg_now_v='Server startet jetzt neu — {reason}'
    local tmp
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    tmp="$(mktemp "$STATE_DIR/.auto_update.XXXXXX")" || return 1
    {
        printf 'enabled=%s\n' "${ST[enabled]:-0}"
        printf 'check_game=%s\n' "${ST[check_game]:-1}"
        printf 'check_workshop=%s\n' "${ST[check_workshop]:-1}"
        printf 'interval_min=%s\n' "${ST[interval_min]:-30}"
        printf 'warn_minutes=%s\n' "${ST[warn_minutes]:-15,10,5,1,0}"
        printf 'msg_template=%s\n' "$_msg_tpl"
        printf 'msg_now=%s\n' "$_msg_now_v"
        printf 'pending=%s\n' "${ST[pending]:-0}"
        printf 'countdown_deadline=%s\n' "${ST[countdown_deadline]:-0}"
        printf 'need_game=%s\n' "${ST[need_game]:-0}"
        printf 'need_workshop=%s\n' "${ST[need_workshop]:-0}"
        [[ -n "${ST[reason]:-}" ]] && printf 'reason=%s\n' "${ST[reason]}"
        [[ -n "${ST[mods]:-}" ]] && printf 'mods=%s\n' "${ST[mods]}"
        [[ -n "${ST[msg_sent]:-}" ]] && printf 'msg_sent=%s\n' "${ST[msg_sent]}"
        [[ -n "${ST[last_check]:-}" ]] && printf 'last_check=%s\n' "${ST[last_check]}"
        [[ -n "${ST[last_restart_job]:-}" ]] && printf 'last_restart_job=%s\n' "${ST[last_restart_job]}"
    } >"$tmp"
    mv "$tmp" "$STATE_FILE"
}

_clear_pending_runtime() {
    # Keep config + last_restart_job / last_check; drop pending so next check can re-detect.
    _write_state_merge \
        "pending=0" \
        "countdown_deadline=0" \
        "need_game=0" \
        "need_workshop=0" \
        "msg_sent=" \
        "reason=" \
        "mods="
}

_mark_ready() {
    if [[ -n "${AUTO_UPDATE_MARK_READY_CMD:-}" ]]; then
        bash -c "$AUTO_UPDATE_MARK_READY_CMD" || true
        return 0
    fi
    if [[ -f "$MODULE_ROOT/scripts/monitor_mark_ready.pl" ]]; then
        perl "$MODULE_ROOT/scripts/monitor_mark_ready.pl" "$SERVER_DIR" 2>/dev/null || true
    fi
}

on_exit() {
    rm -f "$JOB_DIR/pgid" 2>/dev/null || true
    # Unexpected set -e / abort: finalize failed AND release pending/monitor starting.
    # When _fail already ran, FINAL_STATUS_WRITTEN=1 so we skip (no double-clear).
    if [[ "$FINAL_STATUS_WRITTEN" = "0" ]] && [[ ! -f "$JOB_DIR/status" || "$(tr -d '[:space:]' <"$JOB_DIR/status" 2>/dev/null || true)" == "running" ]]; then
        echo "failed" >"$JOB_DIR/status"
        _clear_pending_runtime || true
        _mark_ready
    fi
}
trap on_exit EXIT

_fill_message() {
    local tpl="$1" minutes="$2" reason="$3" mods="$4"
    perl -I"$MODULE_ROOT/lib" -e '
        require "auto_update.pl";
        print auto_update_fill_message(
            $ARGV[0],
            { minutes => $ARGV[1], reason => $ARGV[2], mods => $ARGV[3], game => "PZ" },
        );
    ' "$tpl" "$minutes" "$reason" "$mods"
}

_broadcast() {
    local text="$1"
    if [[ -n "${AUTO_UPDATE_BROADCAST_CMD:-}" ]]; then
        bash -c "$AUTO_UPDATE_BROADCAST_CMD" _ "$text"
        return 0
    fi
    if lgsm_tmux_resolve_live "$SERVER_DIR" "$SCRIPT_NAME"; then
        local cmd
        cmd=$(perl -I"$MODULE_ROOT/lib" -e '
            require "auto_update_pz.pl";
            print auto_update_pz_broadcast_cmd($ARGV[0]);
        ' "$text")
        lgsm_tmux_send_console "$LGSM_TMUX_SOCK" "$LGSM_TMUX_SESS" "$cmd" || true
    fi
}

_do_stop() {
    if [[ -n "${AUTO_UPDATE_STOP_CMD:-}" ]]; then
        bash -c "$AUTO_UPDATE_STOP_CMD"
        return $?
    fi
    lgsm_stop_reliable "$SERVER_DIR" "$SCRIPT_NAME"
}

_do_update() {
    if [[ -n "${AUTO_UPDATE_UPDATE_CMD:-}" ]]; then
        bash -c "$AUTO_UPDATE_UPDATE_CMD"
        return $?
    fi
    local secs="${WEBCORE_AUTO_UPDATE_SECS:-3600}"
    [[ "$secs" =~ ^[0-9]+$ ]] || secs=3600
    echo "Game update: ./$SCRIPT_NAME update (timeout ${secs}s)"
    local rc=0
    set +e
    # yes|… feeds LGSM fn_yn; PIPESTATUS[1] is the update command (not yes SIGPIPE).
    # PRIO_LOW matches game_action_user.sh install/update workers (word-split into -c string).
    if command -v timeout >/dev/null 2>&1; then
        yes | timeout -k 15 "$secs" bash -c 'cd "$1" && '"${PRIO_LOW:-}"' "./$2" update' bash "$SERVER_DIR" "$SCRIPT_NAME"
        rc="${PIPESTATUS[1]}"
    else
        yes | bash -c 'cd "$1" && '"${PRIO_LOW:-}"' "./$2" update' bash "$SERVER_DIR" "$SCRIPT_NAME"
        rc="${PIPESTATUS[1]}"
    fi
    set -e
    return "$rc"
}

_do_start() {
    if [[ -n "${AUTO_UPDATE_START_CMD:-}" ]]; then
        bash -c "$AUTO_UPDATE_START_CMD"
        return $?
    fi
    mc_java_env_apply "$SERVER_DIR"
    lgsm_start_reliable "$SERVER_DIR" "$SCRIPT_NAME"
}

_fail() {
    local msg="$1"
    echo "ERROR: $msg"
    _clear_pending_runtime || true
    _mark_ready
    set_final_status "failed"
    exit 1
}

echo "=== Auto-update restart $(date '+%Y-%m-%d %T') ==="
echo "server_dir=$SERVER_DIR script=$SCRIPT_NAME user=$UNIX_USER"

NEED_GAME="$(_read_state_key need_game 0)"
REASON="$(_read_state_key reason '')"
MODS="$(_read_state_key mods '')"
MSG_NOW="$(_read_state_key msg_now 'Server startet jetzt neu — {reason}')"

echo "need_game=$NEED_GAME reason=$REASON"

if [[ -n "$MSG_NOW" ]]; then
    _text="$(_fill_message "$MSG_NOW" 0 "$REASON" "$MODS")"
    if [[ -n "$_text" ]]; then
        echo "Broadcast msg_now"
        _broadcast "$_text" || true
    fi
fi

echo "=== Stop ==="
if ! _do_stop; then
    _fail "stop failed"
fi

if [[ "$NEED_GAME" == "1" || "$NEED_GAME" == "true" ]]; then
    echo "=== Update (need_game=1) ==="
    if ! _do_update; then
        _fail "game update failed"
    fi
else
    echo "=== Skip update (need_game=0; workshop pulls on boot) ==="
fi

echo "=== Start ==="
if ! _do_start; then
    _fail "start failed"
fi

_clear_pending_runtime || _fail "failed to clear auto_update pending state"
_mark_ready

echo "=== Auto-update restart completed ==="
set_final_status "ok"
exit 0
