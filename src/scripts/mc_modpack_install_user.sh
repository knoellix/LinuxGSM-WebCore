#!/bin/bash
# mc_modpack_install_user.sh — Modpack import as game user (invoked via mc_modpack_install.sh).
# Usage: mc_modpack_install_user.sh <job_dir> <unix_user> <server_dir> [resume]
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
RESUME_MODE="${4:-${WEBCORE_MODPACK_RESUME:-0}}"
if [ "$RESUME_MODE" = "resume" ] || [ "$RESUME_MODE" = "1" ]; then
    RESUME_MODE=1
else
    RESUME_MODE=0
fi

if [ "$(id -un)" != "$UNIX_USER" ]; then
    echo "ERROR: expected unix user $UNIX_USER, got $(id -un)" >&2
    exit 1
fi

export WEBCORE_JOB_DIR="$JOB_DIR"

_SCRIPT_LIB="$(cd "$(dirname "$0")"/lib && pwd)"
# shellcheck source=lib/job_log.sh
. "$_SCRIPT_LIB/job_log.sh"
if [ "$RESUME_MODE" = "1" ]; then
    job_log_resume_as_user "$JOB_DIR"
else
    job_log_init_as_user "$JOB_DIR"
fi

if [ "$RESUME_MODE" = "1" ]; then
    echo "=== Modpack import resume ==="
else
    echo "=== Modpack import started ==="
fi

log_modpack_mod() {
    local idx="$1" total="$2" msg="$3"
    job_log_line "$JOB_DIR" "=== Mod $((idx + 1))/${total}: ${msg} ==="
}

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

if [ ! -f "$JOB_DIR/.worker_secrets" ]; then
    echo "WARN: missing job integration secrets (.worker_secrets) — CurseForge downloads may fail"
fi

META_FILE="$JOB_DIR/pack_meta.json"
if [ ! -f "$META_FILE" ]; then
    echo "ERROR: missing pack_meta.json"
    set_final_status "failed"
    exit 1
fi

_mc_modpack_perl() {
    MODULE_ROOT="${MODULE_ROOT:-}" perl -e '
        my $root = $ENV{MODULE_ROOT} or exit 1;
        push @INC, "$root/lib";
        if ($ENV{WEBCORE_JOB_DIR}) {
            do "$root/lib/module_config.pl" or exit 1;
            module_config_bootstrap_standalone($root);
        }
        do "$root/lib/mc_mods.pl" or exit 1;
        do "$root/lib/mc_modpack.pl" or exit 1;
        require JSON::PP;
        no strict "refs";
        my $fn = shift @ARGV;
        exit 1 unless defined $fn && $fn =~ /^modpack_[a-z0-9_]+$/;
        my @args = @ARGV;
        if ($fn eq "modpack_worker_bootstrap") {
            exit(modpack_worker_bootstrap($args[0], $args[1], $args[2]) ? 0 : 1);
        }
        if ($fn eq "modpack_needs_expand_prepare") {
            print(modpack_needs_expand_prepare($args[0]) ? "1\n" : "0\n");
            exit 0;
        }
        if ($fn eq "modpack_install_progress") {
            my $p = modpack_install_progress($args[0], $args[1]) or exit 1;
            print join("\t", map { $_ // "" } @{$p}{qw(installed total missing last_installed resume_index)}), "\n";
            exit 0;
        }
        if ($fn eq "modpack_install_progress_light") {
            my $p = modpack_install_progress_light($args[0], $args[1]) or exit 1;
            print join("\t", map { $_ // "" } @{$p}{qw(installed total missing last_installed resume_index)}), "\n";
            exit 0;
        }
        if ($fn eq "modpack_worker_entry_plan") {
            my @plan = modpack_worker_entry_plan($args[0], $args[1], $args[2]);
            print join("\t", @plan), "\n";
            exit 0;
        }
        if ($fn eq "modpack_update_install_state") {
            exit(modpack_update_install_state($args[0], $args[1], $args[2], $args[3]) ? 0 : 1);
        }
        if ($fn eq "modpack_cf_bulk_install_log") {
            modpack_cf_bulk_install_log($args[0]);
            exit 0;
        }
        if ($fn eq "modpack_cdn_rate_limit_message") {
            my $msg = mc_modpack_error_message("curseforge_cdn_rate_limited", {
                mod_num  => $args[0],
                basename => $args[1],
                total    => $args[2],
            }, {}, {});
            print(($msg // ""), "\n");
            exit 0;
        }
        if ($fn eq "modpack_cf_auto_resume_enabled") {
            print(modpack_cf_auto_resume_enabled() ? "1\n" : "0\n");
            exit 0;
        }
        if ($fn eq "modpack_cf_auto_resume_wait_sec") {
            print(modpack_cf_auto_resume_wait_sec(), "\n");
            exit 0;
        }
        if ($fn eq "modpack_cf_auto_resume_sleep") {
            modpack_cf_auto_resume_sleep($args[0] // "CDN");
            exit 0;
        }
        if ($fn eq "modpack_index_add_installed_mod") {
            open my $mf, "<", $args[4] or exit 1;
            local $/; my $meta = JSON::PP::decode_json(<$mf>);
            close $mf;
            my $entry = ($meta->{files} // [])->[$args[3]] // {};
            exit(modpack_index_add_installed_mod($args[0], $args[1], $args[2], $entry, $args[5]) ? 0 : 1);
        }
        exit 1;
    ' "$@"
}

REMOTE_PREP=$(_mc_modpack_perl modpack_needs_expand_prepare "$JOB_DIR" 2>/dev/null || echo "0")
if [ "$REMOTE_PREP" = "1" ]; then
    echo "=== Downloading modpack ==="
    EXPAND_PL="${MODULE_ROOT:-}/scripts/mc_modpack_expand_meta.pl"
    if [ ! -f "$EXPAND_PL" ]; then
        EXPAND_PL="$(cd "$(dirname "$0")" && pwd)/mc_modpack_expand_meta.pl"
    fi
    if ! MODULE_ROOT="${MODULE_ROOT:-}" WEBCORE_JOB_DIR="$JOB_DIR" WEBCORE_UNIX_USER="$UNIX_USER" perl "$EXPAND_PL" "$JOB_DIR" "$SERVER_DIR"; then
        echo "ERROR: remote modpack prepare failed (see messages above)"
        set_final_status "failed"
        exit 1
    fi
    echo "=== Modpack downloaded and validated ==="
fi

# Adopt mode (modpack-first): the pack manifest is the source of truth. Rewrite
# the profile from the pack (loader / pinned loader_version / mc_version), then
# install Java and the loader (pinned) as sub-steps — all in this one user job,
# before the mods are placed. Idempotent via the .mc_setup_done marker (resume).
_read_profile_field() {
    perl -MJSON::PP=decode_json -e '
        open my $f, "<", $ARGV[0] or exit 0;
        local $/; my $j = eval { decode_json(<$f>) } // {};
        print $j->{$ARGV[1]} // "";
    ' "$SERVER_DIR/.mcprofile.json" "$1" 2>/dev/null || true
}

ADOPT_PROFILE=$(perl -MJSON::PP=decode_json -e '
    open my $f, "<", $ARGV[0] or exit 0;
    local $/; my $m = eval { decode_json(<$f>) } // {};
    print $m->{adopt_profile} ? 1 : 0;
' "$META_FILE" 2>/dev/null || echo 0)
if [ "${ADOPT_PROFILE:-0}" = "1" ] && [ ! -f "$JOB_DIR/.mc_setup_done" ]; then
    _SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
    ADOPT_PL="${MODULE_ROOT:-}/scripts/mc_modpack_adopt.pl"
    [ -f "$ADOPT_PL" ] || ADOPT_PL="$_SELF_DIR/mc_modpack_adopt.pl"
    JAVA_SCRIPT="${MODULE_ROOT:-}/scripts/mc_java_install_user.sh"
    [ -f "$JAVA_SCRIPT" ] || JAVA_SCRIPT="$_SELF_DIR/mc_java_install_user.sh"
    LOADER_SCRIPT="${MODULE_ROOT:-}/scripts/mc_loader_install_user.sh"
    [ -f "$LOADER_SCRIPT" ] || LOADER_SCRIPT="$_SELF_DIR/mc_loader_install_user.sh"

    echo "=== Adopting profile from modpack (loader / version / MC) ==="
    if ! MODULE_ROOT="${MODULE_ROOT:-}" perl "$ADOPT_PL" "$JOB_DIR" "$SERVER_DIR" "$UNIX_USER"; then
        echo "WARN: profile adopt failed — continuing with existing profile (loader may not be pinned)"
    fi

    SETUP_LGSM_SCRIPT="$(_read_profile_field lgsm_script)"
    SETUP_LOADER="$(_read_profile_field loader)"

    echo "=== Installing Java for the pack ==="
    if ! WEBCORE_SUBSTEP=1 MODULE_ROOT="${MODULE_ROOT:-}" \
        bash "$JAVA_SCRIPT" "$JOB_DIR" "$UNIX_USER" "$SERVER_DIR" "$SETUP_LGSM_SCRIPT"; then
        echo "ERROR: Java setup failed"
        set_final_status "failed"
        exit 1
    fi

    case "$SETUP_LOADER" in
        fabric|forge|neoforge)
            echo "=== Installing $SETUP_LOADER loader (pinned from pack) ==="
            if ! WEBCORE_SUBSTEP=1 MODULE_ROOT="${MODULE_ROOT:-}" \
                bash "$LOADER_SCRIPT" "$JOB_DIR" "$UNIX_USER" "$SERVER_DIR" "$SETUP_LGSM_SCRIPT"; then
                echo "ERROR: loader setup failed"
                set_final_status "failed"
                exit 1
            fi
            ;;
    esac

    touch "$JOB_DIR/.mc_setup_done" 2>/dev/null || true
    echo "=== Pack base ready — installing mods ==="
fi

read_meta() {
    perl -MJSON::PP=decode_json -e '
        open my $f, "<", shift or exit 1;
        local $/; my $j = decode_json(<$f>);
        print $j->{pack_file} // "", "\n";
        print $j->{mod_dir} // "mods", "\n";
        print $j->{format} // "", "\n";
        print scalar(@{ $j->{files} // [] }), "\n";
    ' "$META_FILE"
}

mapfile -t _META_LINES < <(read_meta) || {
    echo "ERROR: cannot parse pack_meta.json"
    set_final_status "failed"
    exit 1
}

PACK_FILE="${_META_LINES[0]:-}"
MOD_DIR="${_META_LINES[1]:-mods}"
PACK_FORMAT="${_META_LINES[2]:-}"
FILE_COUNT="${_META_LINES[3]:-0}"

if [ ! -f "$PACK_FILE" ]; then
    echo "ERROR: pack file missing: $PACK_FILE"
    set_final_status "failed"
    exit 1
fi

SERVERFILES="$SERVER_DIR/serverfiles"
TARGET_ROOT="$SERVERFILES/$MOD_DIR"

echo "=== Reconciling installed mods on disk ==="
_mc_modpack_perl modpack_worker_bootstrap "$JOB_DIR" "$SERVER_DIR" "$UNIX_USER" 2>/dev/null || true

echo "=== Target: $TARGET_ROOT ($FILE_COUNT mods, format=$PACK_FORMAT) ==="

RESUME_IDX=0
RESUME_ON_DISK=0
RESUME_STATS=$(_mc_modpack_perl modpack_install_progress_light "$JOB_DIR" "$SERVER_DIR" 2>/dev/null || true)
if [ -n "${RESUME_STATS:-}" ]; then
    IFS=$'\t' read -r RESUME_ON_DISK RESUME_TOTAL RESUME_MISSING RESUME_LAST RESUME_IDX \
        <<< "$RESUME_STATS" || true
    RESUME_IDX="${RESUME_IDX:-0}"
    if [ "${RESUME_ON_DISK:-0}" -gt 0 ]; then
        echo "=== Resume: ${RESUME_ON_DISK}/${RESUME_TOTAL:-$FILE_COUNT} mods already on disk ==="
        if [ -n "${RESUME_LAST:-}" ]; then
            echo "Last complete: $RESUME_LAST"
        fi
        if [ "$RESUME_IDX" -lt "$FILE_COUNT" ]; then
            echo "Continuing from mod index $((RESUME_IDX + 1)) of $FILE_COUNT"
        fi
    fi
fi

CF_BULK_THRESHOLD=90
MODPACK_CF_AUTO_RESUME=$(_mc_modpack_perl modpack_cf_auto_resume_enabled 2>/dev/null | tr -d '[:space:]')
MODPACK_CF_AUTO_RESUME="${MODPACK_CF_AUTO_RESUME:-0}"
if [ "$MODPACK_CF_AUTO_RESUME" = "1" ]; then
    echo "=== CurseForge Auto-Resume aktiv (Pause ~15,5 Min. bei Rate-Limits) ==="
fi

echo "=== Installing $FILE_COUNT mods ==="
if [ "$PACK_FORMAT" = "curseforge" ] && [ "$FILE_COUNT" -gt "$CF_BULK_THRESHOLD" ]; then
    _mc_modpack_perl modpack_cf_bulk_install_log "$FILE_COUNT" 2>/dev/null || true
fi

mkdir -p "$TARGET_ROOT" || {
    echo "ERROR: cannot create mod directory"
    set_final_status "failed"
    exit 1
}

CF_FETCH_PL="${MODULE_ROOT:-}/scripts/mc_modpack_cf_fetch.pl"
if [ ! -f "$CF_FETCH_PL" ]; then
    CF_FETCH_PL="$(cd "$(dirname "$0")" && pwd)/mc_modpack_cf_fetch.pl"
fi

fail_modpack() {
    echo "ERROR: $1"
    set_final_status "failed"
    exit 1
}

fail_modpack_download_fatal() {
    local idx="$1"
    local base="$2"
    local mod_num=$((idx + 1))
    if [[ "${DL_URL:-}" == *forgecdn.net* ]] && [ "${FILE_COUNT:-0}" -gt "$CF_BULK_THRESHOLD" ]; then
        echo "hint_modpack_cf_cdn_rate_limited" > "$JOB_DIR/error_hint"
        local msg
        msg=$(_mc_modpack_perl modpack_cdn_rate_limit_message "$mod_num" "$base" "$FILE_COUNT" 2>/dev/null || true)
        if [ -n "${msg:-}" ]; then
            echo "INFO: $msg"
        else
            echo "INFO: CurseForge CDN limit at mod $mod_num ($base) — normal for large packs ($FILE_COUNT mods). Wait 10-15 minutes, then use Download fortsetzen."
        fi
        set_final_status "failed"
        exit 1
    fi
    fail_modpack "download failed: $base (check DNS/outbound; do not retry via new Install — use Download fortsetzen)"
}

maybe_auto_resume_cdn_download() {
    local idx="$1"
    local base="$2"
    local mod_num=$((idx + 1))
    if [ "$MODPACK_CF_AUTO_RESUME" != "1" ]; then
        return 1
    fi
    if [[ "${DL_URL:-}" != *forgecdn.net* ]] || [ "${FILE_COUNT:-0}" -le "$CF_BULK_THRESHOLD" ]; then
        return 1
    fi
    rm -f "$JOB_DIR/error_hint" 2>/dev/null || true
    local msg
    msg=$(_mc_modpack_perl modpack_cdn_rate_limit_message "$mod_num" "$base" "$FILE_COUNT" 2>/dev/null || true)
    if [ -n "${msg:-}" ]; then
        echo "INFO: $msg"
    fi
        if ! _mc_modpack_perl modpack_cf_auto_resume_sleep "CDN" 2>/dev/null; then
            local wait_sec
            wait_sec=$(_mc_modpack_perl modpack_cf_auto_resume_wait_sec 2>/dev/null | tr -d '[:space:]')
            wait_sec="${wait_sec:-930}"
            sleep "$wait_sec"
        fi
    echo "=== CurseForge Auto-Resume: erneuter Download-Versuch Mod $mod_num ($base) ==="
    return 0
}

modpack_state_mark() {
    local idx="$1"
    local base="$2"
    _mc_modpack_perl modpack_update_install_state "$JOB_DIR" "$SERVER_DIR" "$idx" "$base" 2>/dev/null || true
}

modpack_index_add_one() {
    local base="$1"
    local idx="$2"
    _mc_modpack_perl modpack_index_add_installed_mod "$SERVER_DIR" "$MOD_DIR" "$base" "$idx" "$META_FILE" "$PACK_FORMAT" 2>/dev/null || true
}

INSTALLED=0
SKIPPED=0
IDX="${RESUME_IDX:-0}"
if [ "$IDX" -gt 0 ]; then
    echo "=== Skipping first $IDX mods (already on disk) ==="
fi
while [ "$IDX" -lt "$FILE_COUNT" ]; do
    if ! IFS=$'\t' read -r SKIP BASE_NAME DL_URL SHA1 \
        < <(_mc_modpack_perl modpack_worker_entry_plan "$JOB_DIR" "$SERVER_DIR" "$IDX" 2>/dev/null || echo -e "0\t\t\t"); then
        fail_modpack "mod entry $IDX invalid"
    fi
    SKIP="${SKIP:-0}"
    BASE_NAME="${BASE_NAME:-}"
    DL_URL="${DL_URL:-}"
    SHA1="${SHA1:-}"

    if [ "$SKIP" = "1" ]; then
        SKIPPED=$((SKIPPED + 1))
        IDX=$((IDX + 1))
        continue
    fi

    if [ -z "$BASE_NAME" ] || [ "$BASE_NAME" = "." ]; then
        fail_modpack "mod $IDX has no filename"
    fi

    if [ -z "$DL_URL" ]; then
        fail_modpack "no download URL for mod $IDX ($BASE_NAME) — CurseForge rate limit or missing cache; wait a few minutes and use Download fortsetzen"
    fi

    DEST="$TARGET_ROOT/$BASE_NAME"
    TMP="$TARGET_ROOT/.$BASE_NAME.download"
    rm -f "$TMP" 2>/dev/null || true

    log_modpack_mod "$IDX" "$FILE_COUNT" "download $BASE_NAME"

    _DL_OK=0
    while [ "$_DL_OK" -ne 1 ]; do
        _DL_OK=0
        if [ -f "$CF_FETCH_PL" ] && [[ "$DL_URL" == *forgecdn.net* ]]; then
            if MODULE_ROOT="${MODULE_ROOT:-}" WEBCORE_JOB_DIR="$JOB_DIR" \
                perl "$CF_FETCH_PL" download-url "$DL_URL" "$TMP"; then
                _DL_OK=1
            fi
        elif $PRIO_LOW curl -fsSL --connect-timeout 30 --max-time 600 --proto-redir '=https' -o "$TMP" "$DL_URL"; then
            _DL_OK=1
        fi
        if [ "$_DL_OK" -eq 1 ]; then
            break
        fi
        rm -f "$TMP" 2>/dev/null || true
        if maybe_auto_resume_cdn_download "$IDX" "$BASE_NAME"; then
            continue
        fi
        fail_modpack_download_fatal "$IDX" "$BASE_NAME"
    done

    if [ -n "$SHA1" ] && [[ "$SHA1" =~ ^[0-9a-fA-F]{40}$ ]]; then
        GOT_SHA1="$(sha1sum "$TMP" | awk '{print $1}' 2>/dev/null || true)"
        if [ -n "$GOT_SHA1" ] && [ "$GOT_SHA1" != "$SHA1" ]; then
            rm -f "$TMP" 2>/dev/null || true
            fail_modpack "SHA1 mismatch for $BASE_NAME (expected $SHA1 got $GOT_SHA1)"
        fi
    fi

    if ! mv -f "$TMP" "$DEST"; then
        fail_modpack "cannot install $BASE_NAME"
    fi
    modpack_index_add_one "$BASE_NAME" "$IDX"
    modpack_state_mark "$IDX" "$BASE_NAME"
    INSTALLED=$((INSTALLED + 1))
    log_modpack_mod "$IDX" "$FILE_COUNT" "$BASE_NAME"
    IDX=$((IDX + 1))
done

if command -v unzip >/dev/null 2>&1; then
    echo "=== Extracting overrides (if present) ==="
    for pattern in 'overrides/*' 'server-overrides/*'; do
        if unzip -l "$PACK_FILE" 2>/dev/null | grep -q "${pattern%\*}"; then
            if (cd "$SERVERFILES" && unzip -o -q "$PACK_FILE" "$pattern" 2>/dev/null || true); then
                echo "Extracted: $pattern"
            fi
        fi
    done
fi

echo "=== Summary: installed=$INSTALLED skipped=$SKIPPED total=$FILE_COUNT ==="

echo "=== Updating mod index ==="
if ! perl -MJSON::PP=decode_json,encode_json -e '
    my ($meta_f, $server_dir, $mod_dir) = @ARGV;
    open my $mf, "<", $meta_f or exit 1;
    local $/; my $meta = decode_json(<$mf>);
    close $mf;
    my $idx_path = "$server_dir/.mc_mods_index.json";
    my $idx = {};
    if (-f $idx_path) {
        open my $if, "<", $idx_path or exit 1;
        local $/; eval { $idx = decode_json(<$if>); };
        close $if;
        $idx = {} unless ref($idx) eq "HASH";
    }
    for my $e (@{ $meta->{files} // [] }) {
        next unless ref($e) eq "HASH";
        my $base = $e->{path} // "";
        $base = (split m{/}, $base)[-1];
        next unless $base =~ /\S/;
        my $key = $mod_dir . "/" . $base;
        my $rec = { env => ($e->{env} // "unknown") };
        if ($e->{modrinth_project}) {
            $rec->{source} = "modrinth";
            $rec->{modrinth_project} = $e->{modrinth_project};
            $rec->{modrinth_version} = $e->{modrinth_version} if $e->{modrinth_version};
        } elsif ($e->{project_id} && $e->{file_id}) {
            $rec->{source} = "curseforge";
            $rec->{project_id} = $e->{project_id};
            $rec->{file_id} = $e->{file_id};
        } elsif ($meta->{format}) {
            $rec->{source} = $meta->{format};
        }
        $idx->{$key} = $rec;
    }
    open my $of, ">", $idx_path or exit 1;
    print $of encode_json($idx);
    close $of;
' "$META_FILE" "$SERVER_DIR" "$MOD_DIR"; then
    echo "WARN: could not update .mc_mods_index.json"
fi

if [ $((INSTALLED + SKIPPED)) -eq 0 ]; then
    fail_modpack "no mods installed"
fi

set_final_status "ok"
