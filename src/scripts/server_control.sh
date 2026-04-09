#!/usr/bin/env bash
# server_control.sh - Control a LinuxGSM game server instance
# Usage: server_control.sh <user> <action>
# Actions: start stop restart monitor update
# Must be run as root (will su to game user).
set -euo pipefail

USER="${1:?Usage: server_control.sh <user> <action>}"
ACTION="${2:?Usage: server_control.sh <user> <action>}"

# Validate inputs (alphanumeric only)
if [[ ! "$USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: Invalid user: $USER" >&2
    exit 1
fi

VALID_ACTIONS="start stop restart monitor update details"
if [[ ! " $VALID_ACTIONS " =~ " $ACTION " ]]; then
    echo "ERROR: Invalid action: $ACTION" >&2
    exit 1
fi

# Execute as game user — never as root
su -s /bin/bash -c "./$USER $ACTION" "$USER"
