#!/usr/bin/env bash
# install_lgsm.sh - Download and install LinuxGSM for a game server user
# Usage: install_lgsm.sh <game_id>
# Must be run as the game user (not root).
set -euo pipefail

GAME_ID="${1:?Usage: install_lgsm.sh <game_id>}"

# Validate game ID (alphanumeric only)
if [[ ! "$GAME_ID" =~ ^[a-zA-Z0-9]+$ ]]; then
    echo "ERROR: Invalid game ID: $GAME_ID" >&2
    exit 1
fi

# Refuse to run as root
if [[ "$EUID" -eq 0 ]]; then
    echo "ERROR: Must not run as root" >&2
    exit 1
fi

HOME_DIR="$(eval echo ~"$USER")"
cd "$HOME_DIR"

# Download LGSM
curl -Lo linuxgsm.sh "https://linuxgsm.sh" && chmod +x linuxgsm.sh

# Create game server script
bash linuxgsm.sh "$GAME_ID"

# Run auto-install
"./${GAME_ID}" auto-install
