#!/bin/bash
# module_bootstrap_deps.sh — root apt bootstrap for module-global dependencies.
# Invoked from Integrations (steamcmd, live-log Perl packages). Instance-scoped
# deps remain in provision_deps.sh. No game-data or SERVER_DIR access.
#
# Usage: module_bootstrap_deps.sh <mode>
#   mode: steamcmd | live_log
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

MODE="${1:-}"
case "$MODE" in
    steamcmd|live_log) ;;
    *)
        echo "ERROR: invalid mode (expected steamcmd or live_log): $MODE" >&2
        exit 1
        ;;
esac

_ensure_apt_repos() {
    if ! grep -qE "contrib|non-free" /etc/apt/sources.list 2>/dev/null; then
        sed -i 's/^\(deb .*debian\.org\/debian [a-z]* main\)$/\1 contrib non-free/' \
            /etc/apt/sources.list 2>/dev/null || true
    fi
    apt-get update -qq
}

if [ "$MODE" = "steamcmd" ]; then
    echo "=== Installing steamcmd (module bootstrap) ==="
    _ensure_apt_repos
    apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        steamcmd
    exit 0
fi

echo "=== Installing live-log Perl packages (module bootstrap) ==="
apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    libio-tty-perl libnet-websocket-server-perl
