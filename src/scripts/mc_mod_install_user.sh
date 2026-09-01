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

read_meta_file() {
    local meta_file="$1"
    # IMPORTANT: never use `print (EXPR), "\n"` — Perl treats that as
    # (print EXPR), "\n" and drops the newline (sha1 then glues to prefer_disabled=0).
    perl -MJSON::PP=decode_json -e '
        open my $f, "<", shift or exit 1;
        local $/; my $m = decode_json(<$f>);
        my $sha1 = $m->{hashes}{sha1} // "";
        $sha1 = "" unless $sha1 =~ /^[0-9a-fA-F]{40}$/;
        print $m->{title} // "", "\n";
        print $m->{filename} // "", "\n";
        print $m->{download_url} // "", "\n";
        print $m->{mod_dir} // "mods", "\n";
        print $m->{source} // "", "\n";
        print $sha1, "\n";
        print(($m->{prefer_disabled} // 0) ? 1 : 0, "\n");
        print $m->{replace_basename} // "", "\n";
        print(($m->{force_replace} // 0) ? 1 : 0, "\n");
    ' "$meta_file"
}

_update_mod_index() {
    local meta_file="$1"
    perl -MJSON::PP=decode_json,encode_json -e '
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
        $rec->{title} = $m->{title} if defined $m->{title} && $m->{title} =~ /\S/;
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
    ' "$meta_file" "$SERVER_DIR"
}

install_one_mod() {
    local meta_file="$1"
    local step_label="${2:-}"

    if [ ! -f "$meta_file" ]; then
        echo "ERROR: missing meta file: $meta_file"
        set_final_status "failed"
        exit 1
    fi

    mapfile -t _META < <(read_meta_file "$meta_file") || {
        echo "ERROR: cannot parse $(basename "$meta_file")"
        set_final_status "failed"
        exit 1
    }

    local title="${_META[0]}"
    local fname="${_META[1]}"
    local dl_url="${_META[2]}"
    local mod_dir="${_META[3]}"
    local source="${_META[4]}"
    local sha1="${_META[5]}"
    local prefer_disabled="${_META[6]:-0}"
    local replace_basename="${_META[7]:-}"
    local force_replace="${_META[8]:-0}"

    if [ -z "$fname" ] || [ -z "$dl_url" ]; then
        echo "ERROR: missing filename or download URL in $(basename "$meta_file")"
        set_final_status "failed"
        exit 1
    fi

    local target="$SERVER_DIR/serverfiles/$mod_dir"
    local dest="$target/$fname"
    local tmp="$target/.$fname.download"

    if [ -n "$step_label" ]; then
        echo "=== $step_label: $title ($fname) ==="
    else
        echo "=== Installing: $title ($fname) ==="
    fi
    echo "=== Target: $dest ==="

    if ! mkdir -p "$target"; then
        echo "ERROR: cannot create target directory"
        set_final_status "failed"
        exit 1
    fi

    _remove_replace_target() {
        local base="$1"
        [[ "$base" =~ ^[A-Za-z0-9._-]+\.jar$ ]] \
            && [[ "$base" != *"/"* ]] \
            && [[ "$base" != *".."* ]] || return 0
        local old_base="$target/$base"
        rm -f "$old_base" "${old_base}.disabled" 2>/dev/null || true
    }

    if [ "$force_replace" = "1" ] || [ -n "$replace_basename" ]; then
        if [ -n "$replace_basename" ]; then
            _remove_replace_target "$replace_basename"
            echo "OK: prepared replace of $replace_basename"
        fi
        if [ -n "$fname" ] && [ "$replace_basename" != "$fname" ]; then
            _remove_replace_target "$fname"
        fi
    fi

    if [ -f "$dest" ]; then
        if [ "$force_replace" = "1" ] || [ -n "$replace_basename" ]; then
            rm -f "$dest" "${dest}.disabled" 2>/dev/null || true
            echo "OK: overwriting existing file $fname"
        else
            echo "ERROR: file already exists: $fname"
            set_final_status "failed"
            exit 1
        fi
    fi

    echo "--- Download ---"
    CF_FETCH_PL="$MODULE_ROOT/scripts/mc_modpack_cf_fetch.pl"
    _DL_OK=0
    if [ -f "$CF_FETCH_PL" ] && [[ "$dl_url" == *forgecdn.net* ]]; then
        if [ ! -f "$JOB_DIR/.worker_secrets" ]; then
            echo "WARN: missing .worker_secrets — CurseForge CDN download may fail"
        fi
        if MODULE_ROOT="${MODULE_ROOT:-}" WEBCORE_JOB_DIR="$JOB_DIR" \
            perl "$CF_FETCH_PL" download-url "$dl_url" "$tmp"; then
            _DL_OK=1
        fi
    elif $PRIO_LOW curl -fsSL --connect-timeout 30 --max-time 600 \
        --proto-redir '=https' -o "$tmp" "$dl_url"; then
        _DL_OK=1
    fi
    if [ "$_DL_OK" -ne 1 ]; then
        if [[ "$dl_url" == *forgecdn.net* ]]; then
            echo "ERROR: CurseForge download failed for $fname (check integrations API key)"
        else
            echo "ERROR: download failed for $fname"
        fi
        rm -f "$tmp" 2>/dev/null || true
        set_final_status "failed"
        exit 1
    fi

    if [ -n "$sha1" ]; then
        if [[ ! "$sha1" =~ ^[0-9a-fA-F]{40}$ ]]; then
            echo "WARN: ignoring invalid SHA1 from meta ($sha1)"
            sha1=""
        fi
    fi
    if [ -n "$sha1" ]; then
        local got_sha1
        got_sha1="$(sha1sum "$tmp" | awk '{print $1}' 2>/dev/null || true)"
        if [ -n "$got_sha1" ] && [ "${got_sha1,,}" != "${sha1,,}" ]; then
            echo "ERROR: SHA1 mismatch for $fname (expected $sha1 got $got_sha1)"
            rm -f "$tmp" 2>/dev/null || true
            set_final_status "failed"
            exit 1
        fi
    fi

    if ! mv -f "$tmp" "$dest"; then
        echo "ERROR: cannot install $fname"
        set_final_status "failed"
        exit 1
    fi

    if [ "$prefer_disabled" = "1" ]; then
        if ! mv -f "$dest" "${dest}.disabled"; then
            echo "ERROR: cannot mark $fname as disabled"
            set_final_status "failed"
            exit 1
        fi
        echo "OK: preserved disabled state for $fname"
    fi

    echo "OK: installed $fname"

    echo "=== Updating mod index ==="
    if ! _update_mod_index "$meta_file"; then
        echo "WARN: could not update .mc_mods_index.json for $fname"
    fi
}

PLAN_FILE="$JOB_DIR/mod_install_plan.json"
META_FILE="$JOB_DIR/mod_meta.json"
if [ ! -f "$META_FILE" ] && [ ! -f "$PLAN_FILE" ]; then
    echo "ERROR: missing mod_meta.json"
    set_final_status "failed"
    exit 1
fi

if [ -f "$PLAN_FILE" ]; then
    mapfile -t _INSTALL_QUEUE < <(perl -MJSON::PP=decode_json -e '
        open my $f, "<", shift or exit 1;
        local $/; my $p = decode_json(<$f>);
        exit 1 unless ref($p) eq "HASH";
        my @order = ref($p->{install_order}) eq "ARRAY" ? @{ $p->{install_order} } : ("mod_meta.json");
        print "$_\n" for @order;
    ' "$PLAN_FILE") || {
        echo "ERROR: cannot parse mod_install_plan.json"
        set_final_status "failed"
        exit 1
    }
else
    _INSTALL_QUEUE=("mod_meta.json")
fi

TOTAL="${#_INSTALL_QUEUE[@]}"
DEP_TOTAL=0
if [ "$TOTAL" -gt 1 ]; then
    DEP_TOTAL=$((TOTAL - 1))
fi
DEP_IDX=0

for rel in "${_INSTALL_QUEUE[@]}"; do
    rel="${rel//$'\r'/}"
    rel="${rel//$'\n'/}"
    [[ "$rel" =~ ^[A-Za-z0-9._-]+\.json$ ]] || {
        echo "ERROR: invalid install queue entry: $rel"
        set_final_status "failed"
        exit 1
    }
    full_meta="$JOB_DIR/$rel"
    label=""
    if [ "$rel" = "mod_meta.json" ]; then
        if [ "$DEP_TOTAL" -gt 0 ]; then
            label="Installing primary mod"
        fi
    else
        DEP_IDX=$((DEP_IDX + 1))
        label="Installing dependency $DEP_IDX/$DEP_TOTAL"
    fi
    install_one_mod "$full_meta" "$label"
done

set_final_status "ok"
