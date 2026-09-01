#!/bin/bash
# mc_upgrade_user.sh — Minecraft loader/MC version upgrade (game user)
# Usage: mc_upgrade_user.sh <job_dir> <unix_user> <server_dir> <lgsm_script>
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
LGSM_SCRIPT="$4"

MODULE_ROOT="${MODULE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

_SCRIPT_LIB="$(cd "$(dirname "$0")"/lib && pwd)"
# shellcheck source=lib/job_log.sh
. "$_SCRIPT_LIB/job_log.sh"

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

PLAN_FILE="$JOB_DIR/upgrade_plan.json"
PROFILE_FILE="$SERVER_DIR/.mcprofile.json"
if [ ! -f "$PLAN_FILE" ]; then
    echo "ERROR: missing upgrade_plan.json"
    set_final_status "failed"
    exit 1
fi
if [ ! -f "$PROFILE_FILE" ]; then
    echo "ERROR: missing $PROFILE_FILE"
    set_final_status "failed"
    exit 1
fi

read_plan_field() {
    perl -MJSON::PP=decode_json -e '
        open my $f, "<", shift or exit 1;
        local $/; my $p = decode_json(<$f>);
        my $k = shift;
        print $p->{$k} // "";
    ' "$PLAN_FILE" "$1"
}

MODE="$(read_plan_field mode)"
LOADER="$(read_plan_field loader)"
NEEDS_JAVA="$(read_plan_field needs_java)"

_apply_profile_for_mc_upgrade() {
    local target_mc="$1"
    local target_java="$2"
    MERGE_ERR="$(perl -I"$MODULE_ROOT/lib" -MJSON::PP=decode_json,encode_json -e '
        use mc_profile qw(validate_mc_profile write_mc_profile mc_java_home_rel);
        my ($pf, $user, $mc, $java) = @ARGV;
        open my $f, "<", $pf or die "read profile\n";
        local $/; my $p = decode_json(<$f>);
        close $f;
        die "invalid profile\n" unless ref($p) eq "HASH";
        $p->{mc_version} = $mc;
        $p->{java_major} = 0 + $java;
        $p->{java_home} = mc_java_home_rel(0 + $java);
        delete $p->{loader_version};
        my $err = validate_mc_profile($p);
        die "$err\n" if $err;
        (my $sd = $pf) =~ s{/[^/]+$}{};
        write_mc_profile($sd, $user, $p) or die "write_mc_profile failed\n";
    ' "$PROFILE_FILE" "$UNIX_USER" "$target_mc" "$target_java" 2>&1)" || {
        echo "ERROR: could not update profile for MC upgrade${MERGE_ERR:+ — $MERGE_ERR}"
        set_final_status "failed"
        exit 1
    }
}

_run_loader_upgrade() {
    local target_pin="$1"
    local mc_version="$2"
    echo "=== Minecraft loader upgrade started ==="
    echo "=== Target: $LOADER $target_pin (MC $mc_version) ==="
    echo "--- Updating profile pin ---"
    MERGE_ERR="$(perl "$MODULE_ROOT/scripts/mc_profile_merge.pl" "$PROFILE_FILE" "$UNIX_USER" \
        "loader_version=$target_pin" 2>&1)" || {
        echo "ERROR: could not update profile pin${MERGE_ERR:+ — $MERGE_ERR}"
        set_final_status "failed"
        exit 1
    }
    echo "OK: profile loader_version=$target_pin"
    echo "--- Running loader installer ---"
    export WEBCORE_SUBSTEP=1
    if ! bash "$MODULE_ROOT/scripts/mc_loader_install_user.sh" \
        "$JOB_DIR" "$UNIX_USER" "$SERVER_DIR" "$LGSM_SCRIPT"; then
        echo "ERROR: loader install sub-step failed"
        set_final_status "failed"
        exit 1
    fi
    echo "--- Verifying profile read-back ---"
    READ_PIN="$(perl -MJSON::PP=decode_json -e '
        open my $f, "<", shift or exit 1;
        local $/; my $p = decode_json(<$f>);
        print $p->{loader_version} // "";
    ' "$PROFILE_FILE")"
    if [ "$READ_PIN" != "$target_pin" ]; then
        echo "ERROR: profile loader_version mismatch (expected $target_pin got $READ_PIN)"
        set_final_status "failed"
        exit 1
    fi
    echo "OK: verified loader_version=$READ_PIN"
}

_run_mc_upgrade() {
    local target_mc="$1"
    local target_java="$2"
    local from_mc
    from_mc="$(read_plan_field mc_version)"
    echo "=== Minecraft version upgrade started ==="
    echo "=== Target: MC $target_mc (Java $target_java) loader $LOADER ==="
    echo "--- Updating profile (mc_version, Java, clear loader pin) ---"
    _apply_profile_for_mc_upgrade "$target_mc" "$target_java"
    echo "OK: profile mc_version=$target_mc java_major=$target_java"

    if [ "$NEEDS_JAVA" = "1" ]; then
        echo "--- Installing Java $target_java ---"
        export WEBCORE_SUBSTEP=1
        if ! bash "$MODULE_ROOT/scripts/mc_java_install_user.sh" \
            "$JOB_DIR" "$UNIX_USER" "$SERVER_DIR" "$LGSM_SCRIPT"; then
            echo "ERROR: Java install sub-step failed"
            set_final_status "failed"
            exit 1
        fi
        echo "OK: Java $target_java installed"
    fi

    echo "--- Running loader installer for MC $target_mc ---"
    export WEBCORE_SUBSTEP=1
    if ! bash "$MODULE_ROOT/scripts/mc_loader_install_user.sh" \
        "$JOB_DIR" "$UNIX_USER" "$SERVER_DIR" "$LGSM_SCRIPT"; then
        echo "ERROR: loader install sub-step failed"
        set_final_status "failed"
        exit 1
    fi

    echo "--- Verifying profile read-back ---"
    VERIFY_ERR="$(perl -MJSON::PP=decode_json -e '
        open my $f, "<", shift or exit 1;
        local $/; my $p = decode_json(<$f>);
        my ($want_mc, $want_java) = @ARGV;
        exit 1 if ($p->{mc_version} // "") ne $want_mc;
        exit 1 if int($p->{java_major} // 0) != int($want_java);
        exit 0;
    ' "$PROFILE_FILE" "$target_mc" "$target_java" 2>&1)" || {
        echo "ERROR: profile read-back mismatch after MC upgrade${VERIFY_ERR:+ — $VERIFY_ERR}"
        set_final_status "failed"
        exit 1
    }
    echo "OK: verified mc_version=$target_mc java_major=$target_java"
}

case "$MODE" in
    loader)
        TARGET_PIN="$(read_plan_field target_loader_version)"
        MC_VERSION="$(read_plan_field mc_version)"
        if [ -z "$TARGET_PIN" ]; then
            echo "ERROR: missing target_loader_version in plan"
            set_final_status "failed"
            exit 1
        fi
        _run_loader_upgrade "$TARGET_PIN" "$MC_VERSION"
        ;;
    mc)
        TARGET_MC="$(read_plan_field target_mc_version)"
        TARGET_JAVA="$(read_plan_field target_java_major)"
        if [ -z "$TARGET_MC" ] || [ -z "$TARGET_JAVA" ]; then
            echo "ERROR: incomplete MC upgrade plan"
            set_final_status "failed"
            exit 1
        fi
        _run_mc_upgrade "$TARGET_MC" "$TARGET_JAVA"
        ;;
    *)
        echo "ERROR: unsupported upgrade mode: $MODE"
        set_final_status "failed"
        exit 1
        ;;
esac

set_final_status "ok"
