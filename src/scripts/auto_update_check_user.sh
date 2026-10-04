#!/bin/bash
# auto_update_check_user.sh — periodic auto-update check (game user, cron).
# Args: <instance_id> <kind:lgsm|native> <server_dir> <script_name> <module_root>
set -euo pipefail

INSTANCE_ID="${1:?missing instance_id}"
KIND="${2:?missing kind}"
SERVER_DIR="${3:?missing server_dir}"
SCRIPT_NAME="${4:?missing script_name}"
MODULE_ROOT="${5:?missing module_root}"

STATE_DIR="$SERVER_DIR/.monitor"
STATE_FILE="$STATE_DIR/auto_update"
LOG_DIR="$SERVER_DIR/logs"
LOG_FILE="$LOG_DIR/auto_update.log"

mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null || true

# shellcheck source=lib/lgsm_control.sh
. "$MODULE_ROOT/scripts/lib/lgsm_control.sh"

_log() {
    local msg="[$(date '+%Y-%m-%d %T')] [$INSTANCE_ID] $*"
    echo "$msg"
    echo "$msg" >>"$LOG_FILE" 2>/dev/null || true
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
    # and appends the leftovers, corrupting templates on every merge (countdown ticks).
    local _msg_tpl="${ST[msg_template]-}"
    local _msg_now_v="${ST[msg_now]-}"
    [[ -n "$_msg_tpl" ]] || _msg_tpl='Server-Neustart in {minutes} Min — {reason}'
    [[ -n "$_msg_now_v" ]] || _msg_now_v='Server startet jetzt neu — {reason}'
    local tmp
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

_adapter_ok() {
    if [[ -n "${AUTO_UPDATE_ADAPTER_CMD:-}" ]]; then
        bash -c "$AUTO_UPDATE_ADAPTER_CMD"
        return $?
    fi
    perl -I"$MODULE_ROOT/lib" -e '
        require "auto_update_pz.pl";
        exit(auto_update_adapter_for_script($ARGV[0]) ne "" ? 0 : 1);
    ' "$SCRIPT_NAME"
}

_has_blocking_job() {
    local iid="$1"
    if [[ -n "${AUTO_UPDATE_JOB_CHECK_CMD:-}" ]]; then
        bash -c "$AUTO_UPDATE_JOB_CHECK_CMD"
        return $?
    fi
    local jobs_home="${HOME}/jobs"
    [[ -d "$jobs_home" ]] || return 1
    local jdir
    for jdir in "$jobs_home"/*/; do
        [[ -f "${jdir}status" && -f "${jdir}meta" ]] || continue
        grep -qx 'running' "${jdir}status" 2>/dev/null || continue
        grep -q "^instance_id=${iid}$" "${jdir}meta" 2>/dev/null || continue
        return 0
    done
    return 1
}

_run_detect() {
    local check_game="$1" check_workshop="$2"
    if [[ -n "${AUTO_UPDATE_DETECT_CMD:-}" ]]; then
        # shellcheck disable=SC1090
        eval "$AUTO_UPDATE_DETECT_CMD"
        return 0
    fi
    # shellcheck disable=SC1090
    eval "$(
        perl "$MODULE_ROOT/scripts/auto_update_detect.pl" \
            "$(id -un)" "$SERVER_DIR" "$SCRIPT_NAME" "$check_game" "$check_workshop"
    )"
}

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

_launch_restart_job() {
    _log "launching auto-update restart"
    if [[ -n "${AUTO_UPDATE_RESTART_LAUNCHER:-}" ]]; then
        "$AUTO_UPDATE_RESTART_LAUNCHER" "$INSTANCE_ID" "$KIND" "$SERVER_DIR" "$SCRIPT_NAME" "$MODULE_ROOT"
        return $?
    fi
    perl -I"$MODULE_ROOT/lib" -e '
        require "auto_update.pl";
        my $jid = auto_update_launch_restart_job($ARGV[0], $ARGV[1], $ARGV[2], $ARGV[3], $ARGV[4]);
        exit($jid ne "" ? 0 : 1);
    ' "$INSTANCE_ID" "$SERVER_DIR" "$SCRIPT_NAME" "$(id -un)" "$MODULE_ROOT"
}

_msg_sent_has() {
    local csv="$1" minute="$2"
    [[ -z "$csv" ]] && return 1
    local part
    IFS=',' read -ra _parts <<<"$csv"
    for part in "${_parts[@]}"; do
        [[ "$part" == "$minute" ]] && return 0
    done
    return 1
}

_msg_sent_add() {
    local csv="$1" minute="$2"
    _msg_sent_has "$csv" "$minute" && { echo "$csv"; return; }
    if [[ -z "$csv" ]]; then
        echo "$minute"
    else
        echo "${csv},${minute}"
    fi
}

_max_warn_minute() {
    local csv="$1"
    local max=0 part
    IFS=',' read -ra _parts <<<"$csv"
    for part in "${_parts[@]}"; do
        [[ "$part" =~ ^[0-9]+$ ]] || continue
        (( part > max )) && max=$part
    done
    echo "$max"
}

# --- main -------------------------------------------------------------------

_enabled=$(_read_state_key enabled 0)
if [[ "$_enabled" != "1" && "$_enabled" != "true" ]]; then
    exit 0
fi

if ! _adapter_ok; then
    _log "skip: no auto-update adapter for $SCRIPT_NAME"
    exit 0
fi

NOW="$(date +%s)"
_interval=$(_read_state_key interval_min 30)
_last_check=$(_read_state_key last_check 0)
_pending_early=$(_read_state_key pending 0)
_countdown_early=$(_read_state_key countdown_deadline 0)
# While a warned countdown is active, keep ticking (cron */5) even if
# last_check is within interval_min — otherwise T−10/5/1 never fire.
_countdown_tick=0
if [[ "$_pending_early" == "1" && "$_countdown_early" =~ ^[0-9]+$ && "$_countdown_early" -gt 0 ]]; then
    _countdown_tick=1
fi
if [[ "$_countdown_tick" -eq 0 && "$_last_check" =~ ^[0-9]+$ && "$_interval" =~ ^[0-9]+$ && "$_interval" -gt 0 ]]; then
    if (( NOW - _last_check < _interval * 60 )); then
        exit 0
    fi
fi

if _has_blocking_job "$INSTANCE_ID"; then
    _log "skip: job already running for instance"
    exit 0
fi

_check_game=$(_read_state_key check_game 1)
_check_workshop=$(_read_state_key check_workshop 1)

NEED_GAME=0
NEED_WORKSHOP=0
MODS=''
PLAYERS=-1
REASON=''
ERR=''
if [[ "$_countdown_tick" -eq 1 ]]; then
    NEED_GAME=$(_read_state_key need_game 0)
    NEED_WORKSHOP=$(_read_state_key need_workshop 0)
    MODS=$(_read_state_key mods '')
    REASON=$(_read_state_key reason '')
    if [[ -n "${AUTO_UPDATE_DETECT_CMD:-}" ]]; then
        _run_detect "$_check_game" "$_check_workshop"
    else
        PLAYERS=$(perl -I"$MODULE_ROOT/lib" -e '
            require "auto_update_pz.pl";
            print int(auto_update_pz_player_count($ARGV[0], $ARGV[1]));
        ' "$SERVER_DIR" "$SCRIPT_NAME" 2>/dev/null || echo -1)
    fi
else
    _run_detect "$_check_game" "$_check_workshop"
fi

_countdown=$(_read_state_key countdown_deadline 0)
_pending=$(_read_state_key pending 0)
_msg_sent=$(_read_state_key msg_sent '')
_warn_minutes=$(_read_state_key warn_minutes '15,10,5,1,0')
_msg_template=$(_read_state_key msg_template 'Server-Neustart in {minutes} Min — {reason}')
_msg_now=$(_read_state_key msg_now 'Server startet jetzt neu — {reason}')

if [[ -n "$ERR" && "$NEED_GAME" != "1" && "$NEED_WORKSHOP" != "1" ]]; then
    _log "detect error (no update signal): $ERR"
    _write_state_merge "last_check=$NOW"
    exit 0
fi

if [[ "$NEED_GAME" != "1" && "$NEED_WORKSHOP" != "1" ]]; then
    if [[ "$_pending" == "1" && "$_countdown" =~ ^[0-9]+$ && "$_countdown" -gt 0 ]]; then
        _log "no update detected; countdown active — keep pending"
    elif [[ "$_pending" == "1" ]]; then
        _log "no update detected; clearing stale pending"
        _write_state_merge \
            "pending=0" "need_game=0" "need_workshop=0" \
            "countdown_deadline=0" "msg_sent=" "reason=" "mods=" \
            "last_check=$NOW"
        exit 0
    else
        _write_state_merge "last_check=$NOW"
        exit 0
    fi
else
    _pending=1
    _write_state_merge \
        "pending=1" \
        "need_game=$NEED_GAME" \
        "need_workshop=$NEED_WORKSHOP" \
        "reason=$REASON" \
        "mods=$MODS" \
        "last_check=$NOW"
fi

_countdown=$(_read_state_key countdown_deadline 0)
# Exact 0 players → immediate restart even mid-countdown (empty server, no wait).
# Unknown (-1) stays on the warn path. Require an update signal (need_*).
if [[ "$PLAYERS" =~ ^[0-9]+$ && "$PLAYERS" -eq 0 ]]; then
    if [[ "$NEED_GAME" == "1" || "$NEED_WORKSHOP" == "1" ]]; then
        _launch_restart_job || _log "restart launch failed (will retry next tick)"
        exit 0
    fi
fi

# players > 0, unknown (-1), or countdown already running
_countdown=$(_read_state_key countdown_deadline 0)
if [[ "$_countdown" =~ ^[0-9]+$ && "$_countdown" -eq 0 ]]; then
    _max=$(_max_warn_minute "$_warn_minutes")
    _countdown=$((NOW + _max * 60))
    _write_state_merge "countdown_deadline=$_countdown" "msg_sent="
    _log "countdown started (deadline=$_countdown, max=${_max}m, players=$PLAYERS)"
    _msg_sent=''
fi

_countdown=$(_read_state_key countdown_deadline 0)
_msg_sent=$(_read_state_key msg_sent '')
_reason=$(_read_state_key reason "$REASON")
_mods=$(_read_state_key mods "$MODS")

if [[ "$_countdown" =~ ^[0-9]+$ && "$_countdown" -gt 0 ]]; then
    _minutes_left=$(( (_countdown - NOW + 59) / 60 ))
    (( _minutes_left < 0 )) && _minutes_left=0

    local_minute=''
    for local_minute in $(echo "$_warn_minutes" | tr ',' ' '); do
        [[ "$local_minute" =~ ^[0-9]+$ ]] || continue
        if (( _minutes_left <= local_minute )) && ! _msg_sent_has "$_msg_sent" "$local_minute"; then
            if [[ "$local_minute" == "0" ]]; then
                _text=$(_fill_message "$_msg_now" 0 "$_reason" "$_mods")
            else
                _text=$(_fill_message "$_msg_template" "$local_minute" "$_reason" "$_mods")
            fi
            _log "broadcast warn minute=$local_minute"
            _broadcast "$_text"
            _msg_sent=$(_msg_sent_add "$_msg_sent" "$local_minute")
            _write_state_merge "msg_sent=$_msg_sent"
        fi
    done
fi

if [[ "$_countdown" =~ ^[0-9]+$ && "$NOW" -ge "$_countdown" ]]; then
    _launch_restart_job || _log "restart launch failed (will retry next tick)"
fi

exit 0
