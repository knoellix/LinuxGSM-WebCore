#!/bin/bash
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
GAME_SCRIPT="$4"

echo $$ > "$JOB_DIR/pid"
exec >> "$JOB_DIR/output" 2>&1

echo "=== Ensuring i386 architecture ==="
dpkg --add-architecture i386 2>/dev/null || true
apt-get update -qq

echo "=== Enabling contrib and non-free repos ==="
if ! grep -qE "contrib|non-free" /etc/apt/sources.list 2>/dev/null; then
    sed -i 's/^\(deb .*debian\.org\/debian [a-z]* main\)$/\1 contrib non-free/' \
        /etc/apt/sources.list 2>/dev/null || true
    apt-get update -qq
fi

echo "=== Installing system dependencies ==="
if ! apt-get install -y curl wget tar bzip2 gzip unzip bc jq lib32gcc-s1 netcat-openbsd; then
    echo "failed" > "$JOB_DIR/status"
    exit 1
fi

echo "=== Downloading LinuxGSM ==="
if ! su -s /bin/bash -c "
    cd '$SERVER_DIR' &&
    curl -Lo linuxgsm.sh https://linuxgsm.sh &&
    chmod +x linuxgsm.sh &&
    bash linuxgsm.sh '$GAME_SCRIPT'
" "$UNIX_USER"; then
    echo "failed" > "$JOB_DIR/status"
    exit 1
fi

echo "=== LinuxGSM successfully installed ==="
echo "ok" > "$JOB_DIR/status"
