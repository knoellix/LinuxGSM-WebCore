#!/bin/bash
# monitor_all.sh — root watchdog dispatcher for LinuxGSM-WebCore
# Runs every 2 minutes via /etc/cron.d/linuxgsm-webcore-monitor (as root).
#
# Responsibilities (root-only):
#   - Read instances file
#   - Dispatch per-instance monitoring as game-user via su
#   - Handle restart-requested signals: dispatch steamcmd_control.sh start
#
# Game-user responsibilities are in monitor_instance_user.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_ROOT="$(dirname "$SCRIPT_DIR")"

WEBMIN_CONF_BASE="${WEBMIN_CONF_BASE:-/etc/webmin}"
MODULE_NAME="linuxgsm-webcore"
CONFIG_DIR="$WEBMIN_CONF_BASE/$MODULE_NAME"
INSTANCES_FILE="$CONFIG_DIR/instances"

if [ ! -f "$INSTANCES_FILE" ]; then
    echo "[$(date '+%Y-%m-%d %T')] No instances file at $INSTANCES_FILE — nothing to do"
    exit 0
fi

_log() { echo "[$(date '+%Y-%m-%d %T')] $*"; }

# Dispatch one instance: run user-side monitor, then handle restart request.
_monitor_one() {
    local inst_id="$1" unix_user="$2" inst_source="$3" server_dir="$4" script_name="$5"

    _log "Monitoring $inst_id (user=$unix_user source=$inst_source)"

    # Single-quote-escape paths per CLAUDE.md §5.1
    local safe_server_dir="${server_dir//\'/\'\\\'\'}"
    local safe_module_root="${MODULE_ROOT//\'/\'\\\'\'}"
    local safe_script_dir="${SCRIPT_DIR//\'/\'\\\'\'}"
    local safe_config_dir="${CONFIG_DIR//\'/\'\\\'\'}"

    # Run game-user-side monitoring (PID check, A2S, state write, wineserver cleanup)
    su -s /bin/bash -c \
        "bash '$safe_script_dir/monitor_instance_user.sh' \
            '$inst_id' '$inst_source' '$safe_server_dir' '$script_name' \
            '$safe_config_dir' '$safe_module_root'" \
        "$unix_user" 2>&1 || true

    # Root restart handler: only for non-LGSM (LGSM manages its own restarts).
    # monitor_instance_user.sh writes restart-requested when it wants a restart.
    local restart_req="$server_dir/.monitor/restart-requested"
    if [[ "$inst_source" != "lgsm" ]] && [ -f "$restart_req" ]; then
        rm -f "$restart_req"
        _log "$inst_id: restart-requested — dispatching steamcmd_control.sh start"

        # Create a visible job record for the Job-Übersicht
        local job_dir=""
        local monitor_job_recorded=0
        if command -v perl >/dev/null 2>&1; then
            local _jid_out _jid
            _jid_out="$(MODULE_ROOT="$MODULE_ROOT" perl "$MODULE_ROOT/scripts/monitor_create_job.pl" \
                "$CONFIG_DIR" "$inst_id" "$unix_user" 2>/dev/null || true)"
            _jid="$(printf '%s' "$_jid_out" | tr -cd '0-9a-f')"
            if [[ "${#_jid}" -eq 16 ]]; then
                job_dir="$CONFIG_DIR/jobs/$_jid"
                monitor_job_recorded=1
            fi
        fi
        if [[ -z "$job_dir" ]]; then
            job_dir="$(mktemp -d)"
            chmod 755 "$job_dir"
            _log "WARN: $inst_id: could not create jobs/ record — using temp job dir"
        fi

        # Dispatch restart as root — nice -n -5 requires root privilege.
        MODULE_ROOT="$MODULE_ROOT" setsid nohup bash "$MODULE_ROOT/scripts/steamcmd_control.sh" \
            start "$job_dir" "$unix_user" "$server_dir" >/dev/null 2>&1 &

        if [[ "$monitor_job_recorded" -eq 1 ]] && [[ -d "$job_dir" ]]; then
            {
                echo ""
                echo "=== monitor restart dispatched ($(date -Is)) ==="
                echo "instance=$inst_id server_dir=$server_dir"
                echo "(live game log: $server_dir/server.log)"
            } >> "$job_dir/output" 2>/dev/null || true
        fi
    fi
}

while IFS=$'\t' read -r inst_id unix_user script_path inst_source sftp_user rest; do
    [[ "$inst_id" =~ ^# ]] && continue
    [[ -z "$inst_id"     ]] && continue
    [[ "$inst_id" == *"="* ]] && continue

    inst_source="${inst_source:-lgsm}"
    server_dir="${script_path%/*}"
    script_name="${script_path##*/}"

    [ -d "$server_dir" ] || continue

    # Background for parallel monitoring across multiple instances
    _monitor_one "$inst_id" "$unix_user" "$inst_source" "$server_dir" "$script_name" &

done < "$INSTANCES_FILE"

wait
_log "Monitor run complete"
exit 0
