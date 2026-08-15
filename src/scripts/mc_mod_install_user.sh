#!/bin/bash
# mc_mod_install_user.sh — Install a single mod/plugin into serverfiles/
# Runs AS THE GAME USER (dispatched via su privilege-drop, no internal su).
# Usage: mc_mod_install_user.sh <job_dir> <unix_user> <server_dir>
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"

MODULE_ROOT="${MODULE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
WEBCORE_SUBSTEP="${WEBCORE_SUBSTEP:-0}"

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

if [ "$WEBCORE_SUBSTEP" = "1" ]; then
    set_final_status() { :; }
else
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
fi

if [ "$(id -un)" != "$UNIX_USER" ]; then
    echo "ERROR: expected unix user $UNIX_USER, got $(id -un)"
    set_final_status "failed"
    exit 1
fi

echo "=== Mod install started ==="

META_FILE="$JOB_DIR/mod_meta.json"
if [ ! -f "$META_FILE" ]; then
    echo "ERROR: missing mod_meta.json"
    set_final_status "failed"
    exit 1
fi

read_meta() {
    perl -MJSON::PP=decode_json -e '
        open my $f, "<", shift or exit 1;
        local $/; my $m = decode_json(<$f>);
        print $m->{title} // "", "\n";
        print $m->{filename} // "", "\n";
        print $m->{download_url} // "", "\n";
        print $m->{mod_dir} // "mods", "\n";
        print $m->{source} // "", "\n";
        print ($m->{hashes}{sha1} // ""), "\n";
        print (($m->{prefer_disabled} // 0) ? 1 : 0), "\n";
        print $m->{replace_basename} // "", "\n";
    ' "$META_FILE"
}

mapfile -t _META < <(read_meta) || {
    echo "ERROR: cannot parse mod_meta.json"
    set_final_status "failed"
    exit 1
}

TITLE="${_META[0]}"
FNAME="${_META[1]}"
DL_URL="${_META[2]}"
MOD_DIR="${_META[3]}"
SOURCE="${_META[4]}"
SHA1="${_META[5]}"
PREFER_DISABLED="${_META[6]:-0}"
REPLACE_BASENAME="${_META[7]:-}"

if [ -z "$FNAME" ] || [ -z "$DL_URL" ]; then
    echo "ERROR: missing filename or download URL"
    set_final_status "failed"
    exit 1
fi

TARGET="$SERVER_DIR/serverfiles/$MOD_DIR"
DEST="$TARGET/$FNAME"
TMP="$TARGET/.$FNAME.download"

echo "=== Installing: $TITLE ($FNAME) ==="
echo "=== Target: $DEST ==="

if ! mkdir -p "$TARGET"; then
    echo "ERROR: cannot create target directory"
    set_final_status "failed"
    exit 1
fi

if [ -f "$DEST" ]; then
    echo "ERROR: file already exists: $FNAME"
    set_final_status "failed"
    exit 1
fi

echo "--- Download ---"
if ! $PRIO_LOW curl -fsSL --max-time 600 -o "$TMP" "$DL_URL"; then
    echo "ERROR: download failed"
    rm -f "$TMP" 2>/dev/null || true
    set_final_status "failed"
    exit 1
fi

if [ -n "$SHA1" ]; then
    GOT_SHA1="$(sha1sum "$TMP" | awk '{print $1}' 2>/dev/null || true)"
    if [ -n "$GOT_SHA1" ] && [ "$GOT_SHA1" != "$SHA1" ]; then
        echo "ERROR: SHA1 mismatch (expected $SHA1 got $GOT_SHA1)"
        rm -f "$TMP" 2>/dev/null || true
        set_final_status "failed"
        exit 1
    fi
fi

if ! mv -f "$TMP" "$DEST"; then
    echo "ERROR: cannot install $FNAME"
    set_final_status "failed"
    exit 1
fi

if [ "$PREFER_DISABLED" = "1" ]; then
    if ! mv -f "$DEST" "${DEST}.disabled"; then
        echo "ERROR: cannot mark $FNAME as disabled"
        set_final_status "failed"
        exit 1
    fi
    echo "OK: preserved disabled state for $FNAME"
fi

if [ -n "$REPLACE_BASENAME" ] && [ "$REPLACE_BASENAME" != "$FNAME" ]; then
    if [[ "$REPLACE_BASENAME" =~ ^[A-Za-z0-9._-]+\.jar$ ]] \
        && [[ "$REPLACE_BASENAME" != *"/"* ]] \
        && [[ "$REPLACE_BASENAME" != *".."* ]]; then
        OLD_BASE="$TARGET/$REPLACE_BASENAME"
        rm -f "$OLD_BASE" "${OLD_BASE}.disabled" 2>/dev/null || true
        echo "OK: replaced previous mod file $REPLACE_BASENAME"
    else
        echo "WARN: ignoring invalid replace_basename metadata"
    fi
fi

echo "OK: installed $FNAME"

echo "=== Updating mod index ==="
if ! perl -MJSON::PP=decode_json,encode_json -e '
    my ($meta_f, $server_dir) = @ARGV;
    open my $mf, "<", $meta_f or exit 1;
    local $/; my $m = decode_json(<$mf>);
    close $mf;
    my $idx_path = "$server_dir/.mc_mods_index.json";
    my $idx = {};
    if (-f $idx_path) {
        open my $if, "<", $idx_path or exit 1;
        local $/; eval { $idx = decode_json(<$if>); };
        close $if;
        $idx = {} unless ref($idx) eq "HASH";
    }
    my $mod_dir = $m->{mod_dir} // "mods";
    my $replace = $m->{replace_basename} // "";
    $replace =~ s/[\t\n\r\0]//g;
    $replace =~ s/^\s+|\s+$//g;
    $replace =~ s/\.disabled\z//i;
    $replace = "" unless $replace =~ /\A[\w.\-]+\.jar\z/;
    if ($replace ne "" && $replace ne ($m->{filename} // "")) {
        my $old_key = $mod_dir . "/" . $replace;
        delete $idx->{$old_key};
    }
    my $key = $mod_dir . "/" . ($m->{filename} // "mod.jar");
    my $rec = { env => ($m->{env} // "unknown"), source => ($m->{source} // "") };
    if (($m->{source} // "") eq "modrinth") {
        $rec->{modrinth_project} = $m->{project_id} if $m->{project_id};
        $rec->{modrinth_version} = $m->{version_id} if $m->{version_id};
    } elsif (($m->{source} // "") eq "curseforge") {
        $rec->{project_id} = $m->{project_id} if $m->{project_id};
        $rec->{file_id} = $m->{file_id} if $m->{file_id};
    } elsif (($m->{source} // "") eq "hangar") {
        $rec->{hangar_owner} = $m->{hangar_owner} if $m->{hangar_owner};
        $rec->{hangar_slug} = $m->{hangar_slug} if $m->{hangar_slug};
        $rec->{version_id} = $m->{version_id} if $m->{version_id};
    }
    $idx->{$key} = $rec;
    open my $of, ">", $idx_path or exit 1;
    print $of encode_json($idx);
    close $of;
' "$META_FILE" "$SERVER_DIR"; then
    echo "WARN: could not update .mc_mods_index.json"
fi

set_final_status "ok"
