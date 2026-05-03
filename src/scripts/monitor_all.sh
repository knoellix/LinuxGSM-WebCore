#!/bin/bash
# monitor_all.sh — watchdog for all registered LinuxGSM-WebCore instances
# Runs every 2 minutes via /etc/cron.d/linuxgsm-webcore-monitor
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

while IFS=$'\t' read -r inst_id unix_user script_path inst_source sftp_user rest; do
    # Skip comment lines and blank lines
    [[ "$inst_id" =~ ^# ]] && continue
    [[ -z "$inst_id"     ]] && continue
    # Skip legacy key=value format (no tab)
    [[ "$inst_id" == *"="* ]] && continue

    inst_source="${inst_source:-lgsm}"
    server_dir="${script_path%/*}"
    script_name="${script_path##*/}"

    # Skip if server_dir doesn't exist
    [ -d "$server_dir" ] || continue

    echo "[$(date '+%Y-%m-%d %T')] Monitoring $inst_id (user=$unix_user source=$inst_source)"
    bash "$SCRIPT_DIR/monitor_instance.sh" \
        "$inst_id" "$unix_user" "$inst_source" "$server_dir" "$script_name" \
        "$CONFIG_DIR" "$MODULE_ROOT" 2>&1 &

done < "$INSTANCES_FILE"

wait
echo "[$(date '+%Y-%m-%d %T')] Monitor run complete"
exit 0
