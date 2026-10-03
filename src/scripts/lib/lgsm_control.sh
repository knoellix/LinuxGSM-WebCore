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

# Project Zomboid: first boot often blocks on interactive admin password; LGSM
# "quit" is consumed as password input and never stops the session. Prefer a
# short direct/force path like Minecraft.
lgsm_is_project_zomboid_instance() {
    local server_dir="$1" script_name="${2:-}"
    script_name="${script_name//[^a-zA-Z0-9_-]/}"
    [[ "$script_name" == "pzserver" || "$script_name" == pz* ]] && return 0
    local cfg=""
    if [[ -n "$script_name" ]]; then
        cfg="$server_dir/lgsm/config-lgsm/${script_name}/${script_name}.cfg"
    fi
    if [[ -n "$cfg" && -f "$cfg" ]] && grep -Eqi '^gamename="?Project Zomboid"?$|^engine="?projectzomboid"?$' "$cfg" 2>/dev/null; then
        return 0
    fi
    local def="$server_dir/lgsm/config-default/config-lgsm/${script_name}/_default.cfg"
    if [[ -n "$script_name" && -f "$def" ]] && grep -Eqi '^gamename="?Project Zomboid"?$|^engine="?projectzomboid"?$' "$def" 2>/dev/null; then
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

# Resolve log used during stop grace (meta READY_LOG, else MC latest / console).
lgsm_lifecycle_stop_log() {
    local server_dir="$1" script_name="$2"
    local key="${WEBCORE_LC_READY_LOG:-}" path=""
    if [[ -n "$key" ]]; then
        if path="$(lgsm_lifecycle_log_path "$server_dir" "$script_name" "$key" 2>/dev/null)"; then
            printf '%s\n' "$path"
            return 0
        fi
    fi
    if lgsm_is_minecraft_instance "$server_dir" "$script_name"; then
        lgsm_mc_latest_log "$server_dir"
        return $?
    fi
    lgsm_console_log "$server_dir" "$script_name"
}

# Detect stop phase id from chunk using WEBCORE_LC_STOP_PHASE_N=id|match.
# Last matching phase in array order wins.
lgsm_lifecycle_detect_stop_phase() {
    local chunk_file="$1"
    local best="" i=0 entry id match
    [[ -f "$chunk_file" ]] || { printf '%s\n' ""; return 0; }
    while true; do
        eval "entry=\${WEBCORE_LC_STOP_PHASE_${i}-}"
        [[ -n "${entry:-}" ]] || break
        id="${entry%%|*}"
        match="${entry#*|}"
        if [[ -n "$match" ]] && grep -Eq -- "$match" "$chunk_file" 2>/dev/null; then
            best="$id"
        fi
        i=$((i + 1))
        (( i > 64 )) && break
    done
    printf '%s\n' "$best"
}

# Direct stop: console command → save-aware grace wait → tmux/java force.
# Env WEBCORE_LC_STOP_GRACE / STOP_FORCE (from eval_meta) override $4 when set (>0).
# While stop-phase id=saving matches and elapsed < force: do not force; log still saving.
# Force after stop_force, or after stop_grace when not saving.
lgsm_stop_direct() {
    local server_dir="$1" script_name="$2" console_cmd="${3:-stop}"
    local wait_secs="${4:-45}"
    local stop_grace="${WEBCORE_LC_STOP_GRACE:-}"
    local stop_force="${WEBCORE_LC_STOP_FORCE:-}"
    local elapsed=0 last_save_msg=-999 phase="" phase_hit=""
    local log="" offset=0 size=0 chunk=""

    script_name="${script_name//[^a-zA-Z0-9_-]/}"
    [[ "$wait_secs" =~ ^[0-9]+$ ]] || wait_secs=45
    if [[ "$stop_grace" =~ ^[0-9]+$ ]] && (( stop_grace > 0 )); then
        :
    else
        stop_grace=$wait_secs
    fi
    if [[ "$stop_force" =~ ^[0-9]+$ ]] && (( stop_force > 0 )); then
        :
    else
        stop_force=$wait_secs
    fi
    (( stop_force < stop_grace )) && stop_force=$stop_grace

    if ! lgsm_tmux_is_online "$server_dir" "$script_name"; then
        echo "Already offline (no tmux session)"
        lgsm_kill_java_for_server "$server_dir"
        return 0
    fi

    if lgsm_tmux_resolve_live "$server_dir" "$script_name"; then
        echo "Graceful: tmux send \"${console_cmd}\" (-L ${LGSM_TMUX_SOCK} -t ${LGSM_TMUX_SESS})"
        lgsm_tmux_send_console "$LGSM_TMUX_SOCK" "$LGSM_TMUX_SESS" "$console_cmd" || true
    fi

    log="$(lgsm_lifecycle_stop_log "$server_dir" "$script_name" 2>/dev/null || true)"
    if [[ -n "$log" && -f "$log" ]]; then
        size=$(wc -c <"$log" 2>/dev/null | tr -d ' ') || size=0
        offset=$size
        # Seed phase from recent pre-stop bytes (save may already be in flight).
        local seed_skip=0
        (( size > 8192 )) && seed_skip=$((size - 8192))
        if (( size > seed_skip )); then
            chunk="$(mktemp)"
            dd if="$log" bs=1 skip="$seed_skip" count=$((size - seed_skip)) of="$chunk" 2>/dev/null || true
            phase_hit="$(lgsm_lifecycle_detect_stop_phase "$chunk")"
            rm -f "$chunk"
            [[ -n "$phase_hit" ]] && phase="$phase_hit"
        fi
    fi

    echo "Stop wait: grace=${stop_grace}s force_cap=${stop_force}s"
    while (( elapsed < stop_force )); do
        if ! lgsm_tmux_is_online "$server_dir" "$script_name"; then
            local pids
            pids=$(lgsm_java_pids_for_server "$server_dir" | tr '\n' ' ')
            if [[ -z "${pids// /}" ]]; then
                echo "Stopped gracefully"
                return 0
            fi
        fi

        if [[ -n "$log" && -f "$log" ]]; then
            size=$(wc -c <"$log" 2>/dev/null | tr -d ' ') || size=0
            if (( size > offset )); then
                chunk="$(mktemp)"
                dd if="$log" bs=1 skip="$offset" count=$((size - offset)) of="$chunk" 2>/dev/null || true
                phase_hit="$(lgsm_lifecycle_detect_stop_phase "$chunk")"
                rm -f "$chunk"
                [[ -n "$phase_hit" ]] && phase="$phase_hit"
                offset=$size
            fi
        fi

        if [[ "$phase" == "saving" ]]; then
            if (( elapsed - last_save_msg >= 5 )); then
                echo "Stop: still saving…"
                last_save_msg=$elapsed
            fi
        elif (( elapsed >= stop_grace )); then
            echo "Stop grace expired (${stop_grace}s, phase=${phase:-none}) — forcing"
            break
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    if ! lgsm_tmux_is_online "$server_dir" "$script_name"; then
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

# Public stop: load lifecycle meta, then Minecraft/PZ direct or LGSM + force.
lgsm_stop_reliable() {
    local server_dir="$1" script_name="$2"
    local unix_user="${WEBCORE_UNIX_USER:-$(id -un 2>/dev/null || true)}"
    script_name="${script_name//[^a-zA-Z0-9_-]/}"

    lgsm_lifecycle_eval_meta "$script_name" "$unix_user" "$server_dir" || true

    if lgsm_is_minecraft_instance "$server_dir" "$script_name"; then
        echo "Stop path: direct (Minecraft — avoid LGSM info_game hang)"
        # Fallback 60s when meta unset; WEBCORE_LC_STOP_* raise grace/force.
        lgsm_stop_direct "$server_dir" "$script_name" stop 60
        return $?
    fi

    if lgsm_is_project_zomboid_instance "$server_dir" "$script_name"; then
        # Short quit fallback (8s) when meta unset; with meta + saving phase,
        # stop_direct raises wait toward STOP_GRACE / STOP_FORCE.
        echo "Stop path: direct (Project Zomboid — avoid password-prompt hang)"
        lgsm_stop_direct "$server_dir" "$script_name" quit 8
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

# True if bytes after offset match ERE $3 (grep -E).
lgsm_log_has_ready_after() {
    local log="$1" offset="${2:-0}" regex="${3:-}"
    [[ -f "$log" && -n "$regex" ]] || return 1
    local size
    size=$(wc -c <"$log" 2>/dev/null | tr -d ' ') || return 1
    [[ "$size" -gt "$offset" ]] || return 1
    tail -c +"$((offset + 1))" "$log" 2>/dev/null | grep -Eq -- "$regex"
}

# True if the last $4 bytes (default 512KiB) of log match ERE $2.
lgsm_log_has_ready_recent() {
    local log="$1" regex="${2:-}" window="${3:-524288}"
    [[ -f "$log" && -n "$regex" ]] || return 1
    local size
    size=$(wc -c <"$log" 2>/dev/null | tr -d ' ') || return 1
    [[ "$size" -gt 0 ]] || return 1
    if [[ "$size" -gt "$window" ]]; then
        tail -c "$window" "$log" 2>/dev/null | grep -Eq -- "$regex"
    else
        grep -Eq -- "$regex" "$log" 2>/dev/null
    fi
}

# Resolve console log path (LGSM).
lgsm_console_log() {
    local server_dir="$1" script_name="$2"
    local f="$server_dir/log/console/${script_name}-console.log"
    [[ -f "$f" ]] || return 1
    printf '%s\n' "$f"
    return 0
}

# Load lifecycle meta from MODULE_ROOT/scripts/lifecycle_env.pl into WEBCORE_LC_* env.
# Keys: READY_LOG, READY_REGEX, READY_SECS, STALL_SECS, STALL_FAIL_SECS,
#       STOP_GRACE, STOP_FORCE, LIVE_LOG_REL, START_PHASE_N, STOP_PHASE_N,
#       WORKSHOP_STALL_PAUSE, WORKSHOP_ITEMS, WORKSHOP_PENDING (workshop games).
# Optional $2=unix_user $3=server_dir enable workshop scale overrides.
# Returns non-zero on empty script_name, missing helper, or Perl failure.
lgsm_lifecycle_eval_meta() {
    local script_name="$1"
    local unix_user="${2:-}"
    local server_dir="${3:-}"
    local helper="${MODULE_ROOT:-}/scripts/lifecycle_env.pl"
    local out i
    [[ -n "$script_name" ]] || return 1
    [[ -n "${MODULE_ROOT:-}" && -f "$helper" ]] || return 1
    for ((i = 0; i < 64; i++)); do
        unset "WEBCORE_LC_START_PHASE_$i" "WEBCORE_LC_STOP_PHASE_$i" 2>/dev/null || true
    done
    unset WEBCORE_LC_WORKSHOP_STALL_PAUSE WEBCORE_LC_WORKSHOP_ITEMS \
        WEBCORE_LC_WORKSHOP_PENDING 2>/dev/null || true
    if [[ -n "$unix_user" && -n "$server_dir" ]]; then
        out="$(set -o pipefail; perl "$helper" "$script_name" "$unix_user" "$server_dir" \
            | sed 's/^/export WEBCORE_LC_/')" || return 1
    else
        out="$(set -o pipefail; perl "$helper" "$script_name" \
            | sed 's/^/export WEBCORE_LC_/')" || return 1
    fi
    eval "$out"
}

# True if $1 is a safe relative path under $server_dir (no absolute, no .. components).
# Aligns with get_lifecycle_config live_log_path sanitization in games_meta.pl.
lgsm_lifecycle_rel_safe() {
    local rel="$1"
    [[ -n "$rel" ]] || return 1
    [[ "$rel" != /* ]] || return 1
    [[ "$rel" =~ (^|/)\.\.(/|$) ]] && return 1
    return 0
}

# Resolve a lifecycle log by key: console | latest_log | live_log | relative path.
# live_log prefers WEBCORE_LC_LIVE_LOG_REL, then Windrose/common fallbacks.
# Relative keys and LIVE_LOG_REL must be under $server_dir (no .. / absolute).
#
# When LIVE_LOG_REL is set and safe: do NOT fall through to server.log while the
# preferred file is still missing (Windrose R5.log appears mid-boot). Return 1 so
# wait_ready keeps refreshing until the preferred path exists.
lgsm_lifecycle_log_path() {
    local server_dir="$1" script_name="$2" log_key="${3:-}"
    case "$log_key" in
        console) lgsm_console_log "$server_dir" "$script_name" ;;
        latest_log) lgsm_mc_latest_log "$server_dir" ;;
        live_log)
            if [[ -n "${WEBCORE_LC_LIVE_LOG_REL:-}" ]] \
                && lgsm_lifecycle_rel_safe "${WEBCORE_LC_LIVE_LOG_REL}"; then
                if [[ -f "$server_dir/${WEBCORE_LC_LIVE_LOG_REL}" ]]; then
                    printf '%s\n' "$server_dir/${WEBCORE_LC_LIVE_LOG_REL}"
                    return 0
                fi
                # Preferred path configured but not present yet — wait for it.
                return 1
            fi
            local c
            for c in \
                "$server_dir/serverfiles/R5/Saved/Logs/R5.log" \
                "$server_dir/server.log" \
                "$server_dir/serverfiles/server.log"
            do
                if [[ -f "$c" ]]; then
                    printf '%s\n' "$c"
                    return 0
                fi
            done
            return 1
            ;;
        *)
            lgsm_lifecycle_rel_safe "$log_key" || return 1
            [[ -f "$server_dir/$log_key" ]] || return 1
            printf '%s\n' "$server_dir/$log_key"
            return 0
            ;;
    esac
}

# Count enabled Minecraft mods: serverfiles/mods/*.jar (excludes *.jar.disabled).
lgsm_mc_count_enabled_mods() {
    local server_dir="$1"
    local mods_dir="$server_dir/serverfiles/mods"
    local n=0 f
    [[ -d "$mods_dir" ]] || { printf '0\n'; return 0; }
    shopt -s nullglob
    for f in "$mods_dir"/*.jar; do
        [[ -f "$f" ]] || continue
        n=$((n + 1))
    done
    shopt -u nullglob
    printf '%s\n' "$n"
}

# Apply MC mod-count tiers into WEBCORE_LC_READY_SECS / STALL_* (replaces meta for start).
lgsm_mc_apply_mod_count_tiers() {
    local n="${1:-0}"
    local ready stall stall_fail
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    if (( n >= 300 )); then
        ready=1200; stall=240; stall_fail=480
    elif (( n >= 150 )); then
        ready=600; stall=150; stall_fail=300
    elif (( n >= 50 )); then
        ready=480; stall=120; stall_fail=240
    else
        ready=300; stall=90; stall_fail=180
    fi
    export WEBCORE_LC_READY_SECS="$ready"
    export WEBCORE_LC_STALL_SECS="$stall"
    export WEBCORE_LC_STALL_FAIL_SECS="$stall_fail"
    echo "Minecraft: ${n} enabled mods → ready≤${ready}s stall warn/fail=${stall}/${stall_fail}"
}

# Detect start phase id from chunk file using WEBCORE_LC_START_PHASE_N=id|match.
# Last matching phase in array order wins (later boot stages overwrite).
lgsm_lifecycle_detect_phase() {
    local chunk_file="$1"
    local best="" i=0 entry id match
    [[ -f "$chunk_file" ]] || { printf '%s\n' ""; return 0; }
    while true; do
        eval "entry=\${WEBCORE_LC_START_PHASE_${i}-}"
        [[ -n "${entry:-}" ]] || break
        id="${entry%%|*}"
        match="${entry#*|}"
        if [[ -n "$match" ]] && grep -Eq -- "$match" "$chunk_file" 2>/dev/null; then
            best="$id"
        fi
        i=$((i + 1))
        (( i > 64 )) && break
    done
    printf '%s\n' "$best"
}

# True while stall-fail must be frozen (workshop_download, or pre-phase with pending).
lgsm_lifecycle_workshop_stall_pause() {
    local phase="${1:-}"
    [[ "${WEBCORE_LC_WORKSHOP_STALL_PAUSE:-0}" == "1" ]] || return 1
    if [[ "$phase" == "workshop_download" ]]; then
        return 0
    fi
    if [[ -z "$phase" ]]; then
        local pending="${WEBCORE_LC_WORKSHOP_PENDING:-0}"
        [[ "$pending" =~ ^[0-9]+$ ]] || pending=0
        (( pending > 0 )) && return 0
    fi
    return 1
}

# Alive check for ready/stop waits.
# When WEBCORE_LC_ALIVE_PID is set (SteamCMD/Windrose twin), use kill -0 on that PID
# instead of LGSM tmux/status (no session for native Wine processes).
lgsm_lifecycle_alive() {
    local server_dir="$1" script_name="$2"
    if [[ -n "${WEBCORE_LC_ALIVE_PID:-}" ]]; then
        [[ "${WEBCORE_LC_ALIVE_PID}" =~ ^[0-9]+$ ]] || return 1
        kill -0 "$WEBCORE_LC_ALIVE_PID" 2>/dev/null
        return $?
    fi
    lgsm_is_started "$server_dir" "$script_name"
}

# Sliding-stall + phase-aware ready wait.
# Env: WEBCORE_START_LOG_STALL_* wins when set (operator override); else WEBCORE_LC_*
# from eval_meta / MC tiers; workshop pause via WORKSHOP_STALL_PAUSE / WORKSHOP_PENDING.
# SteamCMD: export WEBCORE_LC_ALIVE_PID=<pid> so alive check uses kill -0 (not tmux).
lgsm_lifecycle_wait_ready() {
    local server_dir="$1" script_name="$2" log="$3" offset="${4:-0}"
    local regex="${5:-${WEBCORE_LC_READY_REGEX:-}}"
    local ready_secs="${6:-${WEBCORE_LC_READY_SECS:-900}}"
    local allow_existing="${7:-0}"
    local stall_secs="${WEBCORE_START_LOG_STALL_SECS:-${WEBCORE_LC_STALL_SECS:-120}}"
    local stall_fail="${WEBCORE_START_LOG_STALL_FAIL_SECS:-${WEBCORE_LC_STALL_FAIL_SECS:-300}}"
    local elapsed=0 last_report=0
    local size=0 start_size=0 grown=0 last_size=0 last_growth_at=0
    local phase="" stall_warned=0 workshop_info_warned=0
    local chunk="" phase_hit="" stalled=0
    script_name="${script_name//[^a-zA-Z0-9_-]/}"
    [[ "$stall_secs" =~ ^[0-9]+$ ]] || stall_secs=120
    [[ "$stall_fail" =~ ^[0-9]+$ ]] || stall_fail=300
    [[ "$ready_secs" =~ ^[0-9]+$ ]] || ready_secs=900
    [[ -n "$regex" ]] || return 0

    if [[ -n "$log" && -f "$log" ]]; then
        start_size=$(wc -c <"$log" 2>/dev/null | tr -d ' ') || start_size=0
        last_size=$start_size
        if [[ "$allow_existing" -eq 1 ]] && lgsm_log_has_ready_recent "$log" "$regex"; then
            echo "Ready: marker already present in console (session already up)"
            return 0
        fi
        # Seed phase from bytes already present after ready offset.
        if (( start_size > offset )); then
            chunk="$(mktemp)"
            dd if="$log" bs=1 skip="$offset" count=$((start_size - offset)) of="$chunk" 2>/dev/null || true
            phase_hit="$(lgsm_lifecycle_detect_phase "$chunk")"
            rm -f "$chunk"
            [[ -n "$phase_hit" ]] && phase="$phase_hit"
        fi
    fi

    echo "Waiting for ready marker (≤${ready_secs}s): $regex"
    while (( elapsed < ready_secs )); do
        if ! lgsm_lifecycle_alive "$server_dir" "$script_name"; then
            if [[ -n "${WEBCORE_LC_ALIVE_PID:-}" ]]; then
                echo "ERROR: process died before ready marker (pid=${WEBCORE_LC_ALIVE_PID})" >&2
            else
                echo "ERROR: session died before ready marker" >&2
            fi
            return 1
        fi
        if [[ -z "$log" || ! -f "$log" ]]; then
            # Refresh: live_log / READY_LOG for SteamCMD; console for LGSM.
            # When LIVE_LOG_REL is set, log_path returns 1 until preferred file exists
            # (never sticks to server.log) — keep refreshing each loop.
            if [[ -n "${WEBCORE_LC_READY_LOG:-}" ]]; then
                log=$(lgsm_lifecycle_log_path "$server_dir" "$script_name" "$WEBCORE_LC_READY_LOG" 2>/dev/null || true)
            else
                log=$(lgsm_console_log "$server_dir" "$script_name" || true)
            fi
            if [[ -n "$log" && -f "$log" ]]; then
                offset=0
                start_size=$(wc -c <"$log" 2>/dev/null | tr -d ' ') || start_size=0
                last_size=$start_size
                last_growth_at=$elapsed
                echo "Watching log: $log"
            else
                log=""
                # Freeze stall while preferred live_log (e.g. R5.log) has not appeared yet.
                if [[ -n "${WEBCORE_LC_LIVE_LOG_REL:-}" \
                    || "${WEBCORE_LC_READY_LOG:-}" == "live_log" ]]; then
                    last_growth_at=$elapsed
                fi
            fi
        fi
        if [[ -n "$log" && -f "$log" ]]; then
            size=$(wc -c <"$log" 2>/dev/null | tr -d ' ') || size=0
            # LGSM often truncates/rotates console on start. An offset captured
            # before truncate would skip past EOF forever (UI tail still shows
            # SERVER STARTED; wait hung until ready_secs / workshop stall pause).
            if (( size < offset || size < last_size )); then
                echo "Console log truncated/rotated (was offset=${offset} last=${last_size}, now ${size}) — resetting watch"
                offset=0
                start_size=$size
                last_size=$size
                last_growth_at=$elapsed
                stall_warned=0
                phase=""
            fi
            grown=$((size - start_size))
            [[ "$grown" -lt 0 ]] && grown=0
            if [[ "$size" -gt "$last_size" ]]; then
                chunk="$(mktemp)"
                dd if="$log" bs=1 skip="$last_size" count=$((size - last_size)) of="$chunk" 2>/dev/null || true
                phase_hit="$(lgsm_lifecycle_detect_phase "$chunk")"
                rm -f "$chunk"
                [[ -n "$phase_hit" ]] && phase="$phase_hit"
                last_size=$size
                last_growth_at=$elapsed
                stall_warned=0
            fi
            if lgsm_log_has_ready_after "$log" "$offset" "$regex"; then
                echo "Ready: marker seen after ${elapsed}s (console +${grown} bytes)"
                return 0
            fi
        fi
        if (( elapsed - last_report >= 30 )); then
            echo "Still starting… ${elapsed}s / ${ready_secs}s phase=${phase:-?} +${grown} bytes"
            last_report=$elapsed
        fi

        if lgsm_lifecycle_workshop_stall_pause "$phase"; then
            # Freeze sliding stall clock during workshop download / pre-phase pending.
            last_growth_at=$elapsed
            if (( stall_fail > 0 && elapsed >= 2 * stall_fail && workshop_info_warned == 0 )); then
                echo "WARNING: workshop download in progress, log quiet for ${elapsed}s (phase=${phase:-pre})"
                workshop_info_warned=1
            fi
        else
            stalled=$((elapsed - last_growth_at))
            if (( stall_secs > 0 && stalled >= stall_secs && stall_warned == 0 )); then
                echo "WARNING: start log stalled for ${stalled}s (phase=${phase:-?})"
                stall_warned=1
            fi
            if (( stall_fail > 0 && stalled >= stall_fail )); then
                echo "ERROR: start log stalled for ${stalled}s (phase=${phase:-?})" >&2
                return 1
            fi
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    if lgsm_lifecycle_alive "$server_dir" "$script_name"; then
        if (( grown <= 0 )); then
            echo "ERROR: no ready marker and no console output within ${ready_secs}s" >&2
            return 1
        fi
        echo "WARNING: no ready marker within ${ready_secs}s — session still up (console +${grown} bytes)"
        return 0
    fi
    echo "ERROR: failed to become ready" >&2
    return 1
}

# Back-compat wrapper: same args as historical lgsm_start_wait_ready_marker.
lgsm_start_wait_ready_marker() {
    lgsm_lifecycle_wait_ready "$@"
}

# Minecraft: spawn via timed LGSM CLI, then wait for session + Done (mod-count tiers).
# Env:
#   WEBCORE_MC_START_CLI_SECS   — LGSM start command timeout (default 90)
#   WEBCORE_MC_START_SPAWN_SECS — wait for tmux/session after CLI (default 60)
#   WEBCORE_MC_START_READY_SECS — overrides mod-count / meta ready when set
# Returns 0 if session is up; Ready logged when Done appears. If Done times out but
# session still up → 0 with warning (joinable once mods finish).
lgsm_start_minecraft() {
    local server_dir="$1" script_name="$2"
    local cli_secs="${WEBCORE_MC_START_CLI_SECS:-90}"
    local spawn_secs="${WEBCORE_MC_START_SPAWN_SECS:-60}"
    local unix_user="${WEBCORE_UNIX_USER:-$(id -un 2>/dev/null || true)}"
    local ready_secs regex n
    script_name="${script_name//[^a-zA-Z0-9_-]/}"

    if lgsm_is_started "$server_dir" "$script_name"; then
        echo "Already online"
        return 0
    fi

    lgsm_lifecycle_eval_meta "$script_name" "$unix_user" "$server_dir" || true
    n="$(lgsm_mc_count_enabled_mods "$server_dir")"
    lgsm_mc_apply_mod_count_tiers "$n"
    ready_secs="${WEBCORE_MC_START_READY_SECS:-${WEBCORE_LC_READY_SECS:-300}}"
    regex="${WEBCORE_LC_READY_REGEX:-Done \([0-9.]+s\)!}"

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

    lgsm_lifecycle_wait_ready "$server_dir" "$script_name" \
        "$log" "$log_offset" "$regex" "$ready_secs" 0
    return $?
}

# Public start: MC uses spawn+Done wait; PZ session + SERVER STARTED; others session only.
lgsm_start_reliable() {
    local server_dir="$1" script_name="$2"
    local wait_secs="${3:-90}"
    script_name="${script_name//[^a-zA-Z0-9_-]/}"
    local is_pz=0
    local pz_log="" pz_offset=0
    local unix_user="${WEBCORE_UNIX_USER:-$(id -un 2>/dev/null || true)}"
    local ready_secs regex

    if lgsm_is_minecraft_instance "$server_dir" "$script_name"; then
        lgsm_start_minecraft "$server_dir" "$script_name"
        return $?
    fi

    lgsm_lifecycle_eval_meta "$script_name" "$unix_user" "$server_dir" || true

    if lgsm_is_project_zomboid_instance "$server_dir" "$script_name"; then
        is_pz=1
        local _pz_sync="${MODULE_ROOT:-}/scripts/pz_sync_lgsm_cfg.pl"
        if [[ -n "${MODULE_ROOT:-}" && -f "$_pz_sync" ]]; then
            echo "PZ: syncing LGSM startparameters (adminpassword) before start"
            perl "$_pz_sync" "$server_dir" "$script_name" || true
        fi
        if [[ -n "${WEBCORE_LC_WORKSHOP_ITEMS:-}" ]]; then
            echo "Workshop: ${WEBCORE_LC_WORKSHOP_ITEMS} configured, ${WEBCORE_LC_WORKSHOP_PENDING:-0} pending download → ready≤${WEBCORE_LC_READY_SECS}s stall warn/fail=${WEBCORE_LC_STALL_SECS}/${WEBCORE_LC_STALL_FAIL_SECS}"
        elif [[ "${WEBCORE_LC_WORKSHOP_STALL_PAUSE:-0}" == "1" ]]; then
            echo "Workshop: stall-fail paused during workshop_download phase"
        fi
    fi

    # Capture console byte offset before start so prior boots do not false-match.
    # Also used when session is already up (mid-boot): wait from current EOF.
    if [[ "$is_pz" -eq 1 ]]; then
        if pz_log=$(lgsm_console_log "$server_dir" "$script_name"); then
            pz_offset=$(wc -c <"$pz_log" 2>/dev/null | tr -d ' ') || pz_offset=0
        else
            pz_log=""
            pz_offset=0
        fi
        regex="${WEBCORE_LC_READY_REGEX:-\*\*\* SERVER STARTED \*\*\*\*}"
        ready_secs="${WEBCORE_PZ_START_READY_SECS:-${WEBCORE_WORKSHOP_START_READY_SECS:-${WEBCORE_LC_READY_SECS:-900}}}"
    fi

    if lgsm_is_started "$server_dir" "$script_name"; then
        echo "Already online"
        # PZ: session may be up while workshop/world still loads — wait for marker.
        # allow_existing=1: if SERVER STARTED is already in the console, do not wait
        # for a *new* line after EOF (that hung Start for up to 900s).
        if [[ "$is_pz" -eq 1 ]]; then
            lgsm_lifecycle_wait_ready "$server_dir" "$script_name" \
                "$pz_log" "$pz_offset" \
                "$regex" \
                "$ready_secs" \
                1
            return $?
        fi
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
            if [[ "$is_pz" -eq 1 ]]; then
                lgsm_lifecycle_wait_ready "$server_dir" "$script_name" \
                    "$pz_log" "$pz_offset" \
                    "$regex" \
                    "$ready_secs" \
                    0
                return $?
            fi
            return 0
        fi
        sleep 2
    done

    echo "ERROR: server did not come online" >&2
    return 1
}

lgsm_restart_reliable() {
    local server_dir="$1" script_name="$2"
    echo "=== Restart: stop ==="
    if ! lgsm_stop_reliable "$server_dir" "$script_name"; then
        echo "ERROR: restart aborted — stop did not reach offline" >&2
        return 1
    fi
    if lgsm_is_started "$server_dir" "$script_name"; then
        echo "ERROR: restart aborted — still online after stop" >&2
        return 1
    fi
    sleep 2
    echo "=== Restart: start ==="
    lgsm_start_reliable "$server_dir" "$script_name"
}
