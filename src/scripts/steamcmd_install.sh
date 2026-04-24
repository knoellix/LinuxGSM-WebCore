#!/bin/bash
# steamcmd_install.sh — install a non-LGSM game via SteamCMD
# Usage: steamcmd_install.sh <job_dir> <unix_user> <server_dir> <steam_app_id> [validate]
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
STEAM_APP_ID="$4"
VALIDATE="${5:-}"

echo $$ > "$JOB_DIR/pid"
exec >> "$JOB_DIR/output" 2>&1

INSTALL_DIR="$SERVER_DIR/serverfiles"

echo "=== Installing apt dependencies ==="
APT_DEPS=$(MODULE_ROOT="${MODULE_ROOT:-}" STEAM_APP_ID="$STEAM_APP_ID" perl -e '
use JSON::PP;
my $meta_file = "$ENV{MODULE_ROOT}/lib/games_meta.json";
open(my $f, "<", $meta_file) or exit 0;
local $/;
my $data = decode_json(<$f>);
for my $k (keys %$data) {
    if (($data->{$k}{steam_app_id} // 0) == $ENV{STEAM_APP_ID}) {
        my $deps = $data->{$k}{apt_deps} // [];
        print join(" ", @$deps);
        last;
    }
}
' 2>/dev/null || true)

if [ -n "$APT_DEPS" ]; then
    dpkg --add-architecture i386 2>/dev/null || true
    apt-get update -qq
    # shellcheck disable=SC2086
    if ! apt-get install -y $APT_DEPS; then
        echo "hint_package_not_found" > "$JOB_DIR/error_hint"
        echo "failed" > "$JOB_DIR/status"
        exit 1
    fi
fi

echo "=== Downloading via SteamCMD (App ID: $STEAM_APP_ID) ==="
mkdir -p "$INSTALL_DIR"

VALIDATE_FLAG=""
[ "$VALIDATE" = "validate" ] && VALIDATE_FLAG="validate"

if ! su -s /bin/bash -c "
    steamcmd +force_install_dir '$INSTALL_DIR' \
             +login anonymous \
             +app_update '$STEAM_APP_ID' $VALIDATE_FLAG \
             +quit
" "$UNIX_USER" 2>&1; then
    echo "hint_steamcmd_login" > "$JOB_DIR/error_hint"
    echo "failed" > "$JOB_DIR/status"
    exit 1
fi

echo "=== Installation complete ==="
echo "ok" > "$JOB_DIR/status"
