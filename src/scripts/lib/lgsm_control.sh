#!/usr/bin/env bash
# lgsm_control.sh — reliable LGSM start/stop without hanging on info_game/gamedig.
#
# LGSM stop/details often call info_game.sh (query). On modded Minecraft that can
# hang forever; WebCore jobs then never finish. These helpers:
#   - prefer tmux session probes (lgsm_online.sh)
#   - wrap LGSM CLI with timeout
#   - for Minecraft: graceful console "stop" + force kill if needed
#
# Source after lgsm_online.sh (or this file sources it when MODULE_ROOT is set).

_lgsm_control_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F lgsm_tmux_is_online >/dev/null 2>&1; then
    # shellcheck source=lgsm_online.sh
    . "$_lgsm_control_lib_dir/lgsm_online.sh"
fi

# Resolve tmux socket + session for an LGSM instance. Sets:
#   LGSM_TMUX_SOCK  LGSM_TMUX_SESS
# Returns 0 if a live session is found.
lgsm_tmux_resolve_live() {
    local server_dir="$1" script_name="$2"
    local uid_file uid sock sess
    LGSM_TMUX_SOCK=""
    LGSM_TMUX_SESS=""
    script_name="${script_name//[^a-zA-Z0-9_-]/}"
    [[ -n "$script_name" && -d "$server_dir" ]] || return 1

    uid_file="$server_dir/lgsm/data/${script_name}.uid"
    uid=""
    if [[ -f "$uid_file" ]]; then
        uid=$(tr -d '[:space:]' <"$uid_file" 2>/dev/null || true)
        uid="${uid//[^a-zA-Z0-9]/}"
    fi

    for sess in "$script_name" "${script_name%server}"; do
        sess="${sess//[^a-zA-Z0-9_-]/}"
        [[ -n "$sess" ]] || continue
        if [[ -n "$uid" ]]; then
            sock="${sess}-${uid}"
            if tmux -L "$sock" has-session -t "$sess" 2>/dev/null; then
                LGSM_TMUX_SOCK="$sock"
                LGSM_TMUX_SESS="$sess"
                return 0
            fi
        fi
        if tmux -L "$sess" has-session -t "$sess" 2>/dev/null; then
            LGSM_TMUX_SOCK="$sess"
            LGSM_TMUX_SESS="$sess"
            return 0
        fi
    done
    return 1
}

lgsm_run_timeout() {
    local secs="${1:?timeout seconds}"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 15 "$secs" "$@"
        return $?
    fi
    "$@"
}

# True when this instance is Minecraft (profile or LGSM cfg).
lgsm_is_minecraft_instance() {
    local server_dir="$1" script_name="${2:-}"
    [[ -f "$server_dir/.mcprofile.json" ]] && return 0
    local cfg=""
    if [[ -n "$script_name" ]]; then
        script_name="${script_name//[^a-zA-Z0-9_-]/}"
        cfg="$server_dir/lgsm/config-lgsm/${script_name}/${script_name}.cfg"
    fi
    if [[ -n "$cfg" && -f "$cfg" ]] && grep -Eq '^gamename="?Minecraft"?$' "$cfg" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Java PIDs belonging to this server dir (cwd or cmdline). Prints one PID per line.
lgsm_java_pids_for_server() {
    local server_dir="$1"
    local abs pid cwd cmd
    abs=$(cd "$server_dir" 2>/dev/null && pwd -P) || return 0
    [[ -n "$abs" ]] || return 0
    while read -r pid cmd; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)
        if [[ -n "$cwd" && ( "$cwd" == "$abs" || "$cwd" == "$abs"/* ) ]]; then
            echo "$pid"
            continue
        fi
        if [[ "$cmd" == *"$abs"* || "$cmd" == *"$server_dir"* ]]; then
            echo "$pid"
        fi
    done < <(pgrep -u "$(id -u)" -af '[j]ava' 2>/dev/null || true)
}

lgsm_tmux_send_console() {
    local sock="$1" sess="$2" cmd="$3"
    [[ -n "$sock" && -n "$sess" && -n "$cmd" ]] || return 1
    # Clear any half-typed console line, then send command (LGSM pattern).
    TERM=screen tmux -L "$sock" send-keys -t "$sess" C-u 2>/dev/null || true
    TERM=screen tmux -L "$sock" send -t "$sess" ENTER "$cmd" ENTER >/dev/null 2>&1
}

lgsm_tmux_kill_live() {
    local server_dir="$1" script_name="$2"
    if lgsm_tmux_resolve_live "$server_dir" "$script_name"; then
        echo "Force: tmux kill-session -L ${LGSM_TMUX_SOCK} -t ${LGSM_TMUX_SESS}"
        TERM=screen tmux -L "$LGSM_TMUX_SOCK" kill-session -t "$LGSM_TMUX_SESS" >/dev/null 2>&1 || true
        return 0
    fi
    return 1
}

# Wait until tmux session is gone (and optional java cleanup). Returns 0 when offline.
lgsm_wait_offline() {
    local server_dir="$1" script_name="$2" secs="${3:-45}"
    local i
    for ((i = 1; i <= secs; i++)); do
        if ! lgsm_tmux_is_online "$server_dir" "$script_name"; then
            # Allow brief linger of java after tmux death.
            local pids
            pids=$(lgsm_java_pids_for_server "$server_dir" | tr '\n' ' ')
            if [[ -z "${pids// /}" ]]; then
                return 0
            fi
        fi
        sleep 1
    done
    ! lgsm_tmux_is_online "$server_dir" "$script_name"
}

lgsm_kill_java_for_server() {
    local server_dir="$1"
    local pid
    local any=0
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        any=1
        echo "Force: kill java pid=$pid"
        kill -TERM "$pid" 2>/dev/null || true
    done < <(lgsm_java_pids_for_server "$server_dir")
    [[ "$any" -eq 1 ]] || return 0
    sleep 2
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        echo "Force: kill -9 java pid=$pid"
        kill -KILL "$pid" 2>/dev/null || true
    done < <(lgsm_java_pids_for_server "$server_dir")
}

# Direct Minecraft-style stop: console "stop" → wait → kill tmux → kill leftover java.
lgsm_stop_direct() {
    local server_dir="$1" script_name="$2" console_cmd="${3:-stop}"
    local wait_secs="${4:-45}"

    if ! lgsm_tmux_is_online "$server_dir" "$script_name"; then
        echo "Already offline (no tmux session)"
        lgsm_kill_java_for_server "$server_dir"
        return 0
    fi

    if lgsm_tmux_resolve_live "$server_dir" "$script_name"; then
        echo "Graceful: tmux send \"${console_cmd}\" (-L ${LGSM_TMUX_SOCK} -t ${LGSM_TMUX_SESS})"
        lgsm_tmux_send_console "$LGSM_TMUX_SOCK" "$LGSM_TMUX_SESS" "$console_cmd" || true
    fi

    if lgsm_wait_offline "$server_dir" "$script_name" "$wait_secs"; then
        echo "Stopped gracefully"
        lgsm_kill_java_for_server "$server_dir"
        return 0
    fi

    echo "Graceful wait timed out — forcing session kill"
    lgsm_tmux_kill_live "$server_dir" "$script_name" || true
    sleep 1
    lgsm_kill_java_for_server "$server_dir"
    if lgsm_tmux_is_online "$server_dir" "$script_name"; then
        echo "ERROR: still online after force stop" >&2
        return 1
    fi
    echo "Stopped (forced)"
    return 0
}

# Public stop: Minecraft → direct path; others → timed LGSM + force fallback.
lgsm_stop_reliable() {
    local server_dir="$1" script_name="$2"
    script_name="${script_name//[^a-zA-Z0-9_-]/}"

    if lgsm_is_minecraft_instance "$server_dir" "$script_name"; then
        echo "Stop path: direct (Minecraft — avoid LGSM info_game hang)"
        lgsm_stop_direct "$server_dir" "$script_name" stop 60
        return $?
    fi

    echo "Stop path: LGSM CLI (timeout 90s)"
    local rc=0
    if ! lgsm_run_timeout 90 bash -c "cd \"\$1\" && \"./\$2\" stop" bash "$server_dir" "$script_name"; then
        rc=$?
        echo "LGSM stop exited $rc (may be timeout) — verifying"
    fi
    if lgsm_tmux_is_online "$server_dir" "$script_name"; then
        echo "Still online after LGSM stop — force"
        lgsm_stop_direct "$server_dir" "$script_name" quit 15 || \
            lgsm_stop_direct "$server_dir" "$script_name" stop 15
        return $?
    fi
    echo "Stopped"
    return 0
}

# True if LGSM reports the process/session as started (tmux or short status CLI).
lgsm_is_started() {
    local server_dir="$1" script_name="$2"
    script_name="${script_name//[^a-zA-Z0-9_-]/}"
    lgsm_tmux_is_online "$server_dir" "$script_name" && return 0
    # status is session-based in LGSM (no gamedig) — keep timeout tight.
    local out
    if command -v timeout >/dev/null 2>&1; then
        out=$(lgsm_run_timeout 8 bash -c "cd \"\$1\" && \"./\$2\" status" bash "$server_dir" "$script_name" 2>/dev/null) || return 1
    else
        out=$(cd "$server_dir" && "./$script_name" status 2>/dev/null) || return 1
    fi
    echo "$out" | grep -Eqi 'STARTED|ONLINE|running'
}

# Prefer Minecraft/Forge/NeoForge latest.log under the instance.
lgsm_mc_latest_log() {
    local server_dir="$1"
    local c
    for c in \
        "$server_dir/serverfiles/logs/latest.log" \
        "$server_dir/serverfiles/latest.log" \
        "$server_dir/logs/latest.log"
    do
        if [[ -f "$c" ]]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

# True if new log bytes (after offset) contain a vanilla/Forge "Done (...)" boot line.
lgsm_mc_log_has_done_after() {
    local log="$1"
    local offset="${2:-0}"
    [[ -f "$log" ]] || return 1
    local size
    size=$(wc -c <"$log" 2>/dev/null | tr -d ' ') || return 1
    [[ "$size" -gt "$offset" ]] || return 1
    # Only scan bytes written after start; large packs append a lot during boot.
    tail -c +"$((offset + 1))" "$log" 2>/dev/null \
        | grep -Eq 'Done \([0-9.]+s\)!'
}

# Minecraft: spawn via timed LGSM CLI, then wait for session + optional "Done" (large modpacks).
# Env:
#   WEBCORE_MC_START_CLI_SECS   — LGSM start command timeout (default 90)
#   WEBCORE_MC_START_SPAWN_SECS — wait for tmux/session after CLI (default 60)
#   WEBCORE_MC_START_READY_SECS — wait for Done in latest.log (default 900 = 15m for 300+ mods)
# Returns 0 if session is up; Ready logged when Done appears. If Done times out but
# session still up → 0 with warning (joinable once mods finish).
lgsm_start_minecraft() {
    local server_dir="$1" script_name="$2"
    local cli_secs="${WEBCORE_MC_START_CLI_SECS:-90}"
    local spawn_secs="${WEBCORE_MC_START_SPAWN_SECS:-60}"
    local ready_secs="${WEBCORE_MC_START_READY_SECS:-900}"
    script_name="${script_name//[^a-zA-Z0-9_-]/}"

    if lgsm_is_started "$server_dir" "$script_name"; then
        echo "Already online"
        return 0
    fi

    local log="" log_offset=0
    if log=$(lgsm_mc_latest_log "$server_dir"); then
        log_offset=$(wc -c <"$log" 2>/dev/null | tr -d ' ') || log_offset=0
    fi

    echo "Minecraft start: LGSM CLI (timeout ${cli_secs}s), then wait session≤${spawn_secs}s, Done≤${ready_secs}s"
    local rc=0
    lgsm_run_timeout "$cli_secs" bash -c "cd \"\$1\" && \"./\$2\" start" bash "$server_dir" "$script_name" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "LGSM start exited $rc (often timeout after spawn — continuing)"
    fi

    local elapsed=0
    while (( elapsed < spawn_secs )); do
        if lgsm_is_started "$server_dir" "$script_name"; then
            echo "Session up after ${elapsed}s — waiting for Minecraft ready (Done in latest.log)"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    if ! lgsm_is_started "$server_dir" "$script_name"; then
        echo "ERROR: Minecraft session did not spawn within ${spawn_secs}s" >&2
        return 1
    fi

    # Refresh log path (may appear after first boot writes).
    if [[ -z "$log" ]]; then
        log=$(lgsm_mc_latest_log "$server_dir" || true)
        log_offset=0
    fi

    elapsed=0
    local last_report=0
    while (( elapsed < ready_secs )); do
        if ! lgsm_is_started "$server_dir" "$script_name"; then
            echo "ERROR: Minecraft session died while loading mods" >&2
            return 1
        fi
        if [[ -n "$log" ]] && lgsm_mc_log_has_done_after "$log" "$log_offset"; then
            echo "Ready: Done seen in $(basename "$log") after ${elapsed}s"
            return 0
        fi
        # Log may be created mid-boot.
        if [[ -z "$log" ]]; then
            log=$(lgsm_mc_latest_log "$server_dir" || true)
            log_offset=0
        fi
        if (( elapsed - last_report >= 30 )); then
            echo "Still loading mods… ${elapsed}s / ${ready_secs}s (large packs can take several minutes)"
            last_report=$elapsed
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done

    if lgsm_is_started "$server_dir" "$script_name"; then
        echo "WARNING: no Done in latest.log within ${ready_secs}s — session still up (mods may still be loading)"
        return 0
    fi
    echo "ERROR: Minecraft failed to become ready" >&2
    return 1
}

# Public start: MC uses spawn+Done wait; others timed LGSM CLI + session check.
lgsm_start_reliable() {
    local server_dir="$1" script_name="$2"
    local wait_secs="${3:-90}"
    script_name="${script_name//[^a-zA-Z0-9_-]/}"

    if lgsm_is_minecraft_instance "$server_dir" "$script_name"; then
        lgsm_start_minecraft "$server_dir" "$script_name"
        return $?
    fi

    if lgsm_is_started "$server_dir" "$script_name"; then
        echo "Already online"
        return 0
    fi

    echo "Start path: LGSM CLI (timeout ${wait_secs}s)"
    local rc=0
    lgsm_run_timeout "$wait_secs" bash -c "cd \"\$1\" && \"./\$2\" start" bash "$server_dir" "$script_name" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "LGSM start exited $rc (may be timeout after spawn) — verifying"
    fi

    local i
    for ((i = 1; i <= 30; i++)); do
        if lgsm_is_started "$server_dir" "$script_name"; then
            echo "Started (session/status up)"
            return 0
        fi
        sleep 2
    done

    echo "ERROR: server did not come online" >&2
    return 1
}

lgsm_restart_reliable() {
    local server_dir="$1" script_name="$2"
    lgsm_stop_reliable "$server_dir" "$script_name" || true
    sleep 2
    lgsm_start_reliable "$server_dir" "$script_name"
}
