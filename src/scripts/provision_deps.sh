#!/bin/bash
# provision_deps.sh — one-time ROOT dependency bootstrap for a new instance.
# Root responsibilities ONLY: apt/dpkg system packages. No file creation in
# SERVER_DIR, no game data. After this ran once, the whole runtime (install,
# update, start/stop, mods, loader) is user-native and never touches apt.
#
# Installs, as root:
#   - i386 arch + contrib/non-free (LGSM base needs lib32gcc)
#   - LGSM/base tools: curl wget tar bzip2 gzip unzip bc jq lib32gcc-s1 netcat-openbsd
#   - per-game apt_deps from games_meta.json (matched by steam_app_id or game key)
#   - Wine runtime deps when runtime=wine
#
# Usage: provision_deps.sh <job_dir> <unix_user> <server_dir> <game_key> <source> <steam_app_id> <runtime>
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="${3:-}"
GAME_KEY="${4:-}"
SOURCE="${5:-}"
STEAM_APP_ID="${6:-}"
RUNTIME_MODE="${7:-}"

_SCRIPT_LIB="$(cd "$(dirname "$0")"/lib && pwd)"
# shellcheck source=lib/job_log.sh
. "$_SCRIPT_LIB/job_log.sh"
job_log_init "$JOB_DIR" "$UNIX_USER"

FINAL_STATUS_WRITTEN=0
set_final_status() {
    local s="$1"
    rm -f "$JOB_DIR/pgid" 2>/dev/null || true
    echo "$s" > "$JOB_DIR/status"
    FINAL_STATUS_WRITTEN=1
}
on_exit() {
    rm -f "$JOB_DIR/pgid" 2>/dev/null || true
    if [ "$FINAL_STATUS_WRITTEN" = "0" ] && [ ! -f "$JOB_DIR/status" ]; then
        echo "failed" > "$JOB_DIR/status"
    fi
}
trap on_exit EXIT

echo "=== Dependency bootstrap started ==="
echo "game=$GAME_KEY source=$SOURCE app_id=$STEAM_APP_ID runtime=$RUNTIME_MODE"

_preseed_grub_noninteractive() {
    command -v debconf-set-selections >/dev/null 2>&1 || return 0
    dpkg-query -W grub-pc >/dev/null 2>&1 || return 0
    echo 'grub-pc grub-pc/install_devices_empty boolean true' | debconf-set-selections
    echo 'grub-pc grub-pc/install_devices multiselect' | debconf-set-selections
    echo 'grub-pc grub-pc/install_devices_disks_changed boolean false' | debconf-set-selections
}

_finish_pending_dpkg() {
    _preseed_grub_noninteractive
    if dpkg --audit 2>/dev/null | grep -q .; then
        echo "=== Finishing pending package configuration ==="
        dpkg --configure -a
    fi
}

echo "=== Ensuring i386 architecture ==="
dpkg --add-architecture i386 2>/dev/null || true
apt-get update -qq

echo "=== Enabling contrib and non-free repos ==="
if ! grep -qE "contrib|non-free" /etc/apt/sources.list 2>/dev/null; then
    sed -i 's/^\(deb .*debian\.org\/debian [a-z]* main\)$/\1 contrib non-free/' \
        /etc/apt/sources.list 2>/dev/null || true
    apt-get update -qq
fi

_finish_pending_dpkg

echo "=== Installing base tools ==="
_preseed_grub_noninteractive
if ! apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    curl wget tar bzip2 gzip unzip bc jq lib32gcc-s1 netcat-openbsd; then
    echo "hint_package_not_found" > "$JOB_DIR/error_hint"
    set_final_status "failed"
    exit 1
fi

# Per-game apt_deps — matched by steam_app_id (preferred) or game key.
APT_DEPS=$(MODULE_ROOT="${MODULE_ROOT:-}" STEAM_APP_ID="$STEAM_APP_ID" GAME_KEY="$GAME_KEY" perl -e '
use JSON::PP;
my $meta_file = "$ENV{MODULE_ROOT}/lib/games_meta.json";
open(my $f, "<", $meta_file) or exit 0;
local $/;
my $data = eval { decode_json(<$f>) } or exit 0;
my $aid = $ENV{STEAM_APP_ID} // "";
my $gk  = $ENV{GAME_KEY} // "";
for my $k (keys %$data) {
    my $match = 0;
    if ($aid ne "" && $aid =~ /^[0-9]+$/ && (($data->{$k}{steam_app_id} // 0) == $aid)) {
        $match = 1;
    } elsif ($gk ne "" && $k eq $gk) {
        $match = 1;
    }
    next unless $match;
    my $deps = $data->{$k}{apt_deps} // [];
    print join(" ", @$deps);
    last;
}
' 2>/dev/null || true)

if [ -n "$APT_DEPS" ]; then
    echo "=== Installing per-game dependencies: $APT_DEPS ==="
    # shellcheck disable=SC2086
    if ! apt-get install -y $APT_DEPS; then
        echo "hint_package_not_found" > "$JOB_DIR/error_hint"
        set_final_status "failed"
        exit 1
    fi
fi

if [ "${RUNTIME_MODE:-}" = "wine" ]; then
    echo "=== Installing Wine runtime dependencies ==="
    if ! apt-get install -y winbind winetricks cabextract xvfb xauth; then
        echo "hint_wine_required" > "$JOB_DIR/error_hint"
        set_final_status "failed"
        exit 1
    fi
fi

if [ "$SOURCE" = "steamcmd" ]; then
    echo "=== Installing steamcmd ==="
    if ! apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        steamcmd; then
        echo "hint_package_not_found" > "$JOB_DIR/error_hint"
        set_final_status "failed"
        exit 1
    fi
fi

echo "=== Dependency bootstrap complete ==="
set_final_status "ok"
