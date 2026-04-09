#!/usr/bin/env bash
# engine_switch.sh - Switch server executable (e.g. Vanilla → Paper)
# Usage: engine_switch.sh <user> <new_engine>
# Must be run as root (will su to game user).
set -euo pipefail

USER="${1:?Usage: engine_switch.sh <user> <new_engine>}"
ENGINE="${2:?Usage: engine_switch.sh <user> <new_engine>}"

# Validate inputs
if [[ ! "$USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: Invalid user: $USER" >&2
    exit 1
fi

if [[ ! "$ENGINE" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: Invalid engine: $ENGINE" >&2
    exit 1
fi

HOME_DIR="$(getent passwd "$USER" | cut -d: -f6)"

# Stop server first
su -s /bin/bash -c "./$USER stop" "$USER" || true

# TODO: Download and replace engine binary
echo "INFO: Engine switch to $ENGINE not yet implemented" >&2

# Restart with new engine
su -s /bin/bash -c "./$USER start" "$USER"
