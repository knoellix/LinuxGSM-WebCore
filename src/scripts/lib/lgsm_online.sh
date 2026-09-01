#!/usr/bin/env bash
# lgsm_online.sh — probe LGSM tmux session (matches LinuxGSM socket naming).
# Usage: lgsm_tmux_is_online <server_dir> <script_name>
#        lgsm_is_online <server_dir> <script_name> [details_fallback]
lgsm_tmux_is_online() {
    local server_dir="$1" script_name="$2"
    local uid_file uid sock sess
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
            tmux -L "$sock" has-session -t "$sess" 2>/dev/null && return 0
        fi
        tmux -L "$sess" has-session -t "$sess" 2>/dev/null && return 0
    done
    return 1
}

# LGSM details/gamedig (slow; modded MC). Used when tmux probe is inconclusive.
lgsm_details_is_online() {
    local server_dir="$1" script_name="$2"
    script_name="${script_name//[^a-zA-Z0-9_-]/}"
    [[ -n "$script_name" && -d "$server_dir" ]] || return 1
    local out
    if command -v timeout >/dev/null 2>&1; then
        out=$(timeout -k 5 8 bash -c 'cd "$1" && "./$2" details' bash "$server_dir" "$script_name" 2>/dev/null) || return 1
    else
        out=$(cd "$server_dir" && "./$script_name" details 2>/dev/null) || return 1
    fi
    echo "$out" | grep -Eqi 'Status:[[:space:]]*STARTED'
}

# Prefer tmux; optional details fallback for monitor/scheduled-restart probes.
lgsm_is_online() {
    local server_dir="$1" script_name="$2" fallback="${3:-}"
    lgsm_tmux_is_online "$server_dir" "$script_name" && return 0
    [[ "$fallback" == "details_fallback" || "$fallback" == "1" ]] || return 1
    lgsm_details_is_online "$server_dir" "$script_name"
}
