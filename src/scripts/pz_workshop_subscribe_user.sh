#!/bin/bash
# pz_workshop_subscribe_user.sh — Download PZ workshop items (with deps) and patch server INI once.
# Runs AS THE GAME USER (dispatched via su privilege-drop, no internal su).
# Usage: pz_workshop_subscribe_user.sh <job_dir> <unix_user> <server_dir> <script_name>
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
SCRIPT_NAME="${4:-pzserver}"

MODULE_ROOT="${MODULE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

_SCRIPT_LIB="$(cd "$(dirname "$0")"/lib && pwd)"
# shellcheck source=lib/job_log.sh
. "$_SCRIPT_LIB/job_log.sh"

_PRIO_LIB_DIR="${MODULE_ROOT:-}/scripts/lib"
if [ ! -f "$_PRIO_LIB_DIR/prio.sh" ]; then
    _PRIO_LIB_DIR="$(cd "$(dirname "$0")"/lib && pwd)" 2>/dev/null || _PRIO_LIB_DIR=""
fi
if [ -n "$_PRIO_LIB_DIR" ] && [ -f "$_PRIO_LIB_DIR/prio.sh" ]; then
    # shellcheck source=lib/prio.sh
    . "$_PRIO_LIB_DIR/prio.sh"
else
    PRIO_LOW=""
fi

job_log_init_as_user "$JOB_DIR"
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

if [ "$(id -un)" != "$UNIX_USER" ]; then
    echo "ERROR: expected unix user $UNIX_USER, got $(id -un)"
    set_final_status "failed"
    exit 1
fi

echo "=== PZ Workshop subscribe started ==="
echo "Server dir: $SERVER_DIR"
echo "Script: $SCRIPT_NAME"

META_JSON="$JOB_DIR/pz_workshop_item.json"
if [ ! -f "$META_JSON" ]; then
    echo "ERROR: missing $META_JSON"
    set_final_status "failed"
    exit 1
fi

# Load optional steam_web_api_key into env for Perl (closure resolve reads .worker_secrets via bootstrap).
if [ -f "$JOB_DIR/.worker_secrets" ]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    . "$JOB_DIR/.worker_secrets"
    set +a
fi

read_item_meta() {
    perl -MJSON::PP=decode_json -e '
        open my $f, "<", shift or exit 1;
        local $/; my $m = decode_json(<$f>);
        my $id = $m->{workshop_id} // "";
        $id =~ s/[^0-9]//g;
        exit 1 unless $id =~ /^\d{5,20}$/;
        my $app = $m->{workshop_appid} // 108600;
        $app =~ s/[^0-9]//g;
        $app = 108600 unless $app =~ /^\d+$/ && $app > 0;
        print "$id\n$app\n";
    ' "$META_JSON"
}

ITEM_ID=""
APP_ID=""
{
    read -r ITEM_ID
    read -r APP_ID
} < <(read_item_meta) || {
    echo "ERROR: invalid workshop item meta"
    set_final_status "failed"
    exit 1
}

echo "Workshop item: $ITEM_ID (appid $APP_ID)"

find_steamcmd() {
    if command -v steamcmd >/dev/null 2>&1; then
        command -v steamcmd
        return 0
    fi
    for p in \
        "$HOME/steamcmd/steamcmd.sh" \
        "$SERVER_DIR/steamcmd/steamcmd.sh" \
        /usr/games/steamcmd
    do
        if [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

STEAMCMD="$(find_steamcmd)" || {
    echo "ERROR: steamcmd not found"
    set_final_status "failed"
    exit 1
}
echo "SteamCMD: $STEAMCMD"

export WEBCORE_JOB_DIR="$JOB_DIR"
export MODULE_ROOT

find_workshop_content_dir() {
    local appid="$1"
    local wid="$2"
    local base
    for base in \
        "$HOME/Steam/steamapps/workshop/content/$appid/$wid" \
        "$HOME/.steam/steam/steamapps/workshop/content/$appid/$wid" \
        "$HOME/steamapps/workshop/content/$appid/$wid" \
        "$SERVER_DIR/steamapps/workshop/content/$appid/$wid" \
        "$SERVER_DIR/serverfiles/steamapps/workshop/content/$appid/$wid"
    do
        if [ -d "$base" ]; then
            echo "$base"
            return 0
        fi
    done
    return 1
}

download_workshop_item() {
    local appid="$1"
    local wid="$2"
    echo "=== Downloading workshop item $wid via SteamCMD ==="
    set +e
    $PRIO_LOW "$STEAMCMD" +login anonymous \
        +workshop_download_item "$appid" "$wid" \
        +quit
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        echo "WARN: steamcmd exit $rc for item $wid — checking for downloaded content anyway"
    fi
}

echo "=== Resolving workshop dependency closure ==="
ORDERED_IDS=()
RESOLVE_RC=0
RESOLVE_OUT=""
RESOLVE_OUT="$(perl "$MODULE_ROOT/scripts/pz_workshop_subscribe_helper.pl" resolve "$ITEM_ID" 2>&1)" || RESOLVE_RC=$?
while IFS= read -r line; do
    case "$line" in
        WARN:*)
            echo "$line"
            ;;
        ERROR:*)
            echo "$line"
            RESOLVE_RC=1
            ;;
        ID:*)
            ORDERED_IDS+=("${line#ID:}")
            ;;
        *)
            [ -n "$line" ] && echo "$line"
            ;;
    esac
done <<< "$RESOLVE_OUT"

if [ "$RESOLVE_RC" -ne 0 ] || [ "${#ORDERED_IDS[@]}" -eq 0 ]; then
    echo "ERROR: dependency resolution failed"
    set_final_status "failed"
    exit 1
fi

echo "Closure order: ${ORDERED_IDS[*]}"

declare -A CONTENT_DIRS=()
for wid in "${ORDERED_IDS[@]}"; do
    CONTENT_DIR=""
    if CONTENT_DIR="$(find_workshop_content_dir "$APP_ID" "$wid")"; then
        echo "Content dir exists for $wid: $CONTENT_DIR"
    else
        download_workshop_item "$APP_ID" "$wid"
        CONTENT_DIR="$(find_workshop_content_dir "$APP_ID" "$wid" || true)"
    fi
    if [ -z "$CONTENT_DIR" ]; then
        echo "ERROR: workshop content directory not found for item $wid"
        echo "Looked under Steam/steamapps/workshop/content/$APP_ID/$wid"
        set_final_status "failed"
        exit 1
    fi
    CONTENT_DIRS["$wid"]="$CONTENT_DIR"
done

echo "=== Patching server INI (WorkshopItems + Mods) ==="
PATCH_ARGS=()
for wid in "${ORDERED_IDS[@]}"; do
    PATCH_ARGS+=("${wid}:${CONTENT_DIRS[$wid]}")
done

export WEBCORE_SERVER_DIR="$SERVER_DIR"
perl "$MODULE_ROOT/scripts/pz_workshop_subscribe_helper.pl" patch \
    "$UNIX_USER" "$SCRIPT_NAME" "$ITEM_ID" "${PATCH_ARGS[@]}" || {
    set_final_status "failed"
    exit 1
}

echo "=== Done — restart the server for mods to load ==="
set_final_status "ok"
exit 0
