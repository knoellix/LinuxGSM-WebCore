#!/bin/bash
# mc_loader_install_user.sh — Install Fabric / Forge / NeoForge server in serverfiles/
# Runs AS THE GAME USER (dispatched via su privilege-drop, no internal su).
# Reads the pinned loader_version from the profile when present.
# Usage: mc_loader_install_user.sh <job_dir> <unix_user> <server_dir> <lgsm_script>
#
# WEBCORE_SUBSTEP=1 : called as a sub-step of another job (modpack import).
#   -> do NOT init the job log or write the final status; the parent owns both.
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
LGSM_SCRIPT="$4"

MODULE_ROOT="${MODULE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
WEBCORE_SUBSTEP="${WEBCORE_SUBSTEP:-0}"

_SCRIPT_LIB="$(cd "$(dirname "$0")"/lib && pwd)"
# shellcheck source=lib/job_log.sh
. "$_SCRIPT_LIB/job_log.sh"

jl() { job_log_line "$JOB_DIR" "$@"; }

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
    jl "ERROR: expected unix user $UNIX_USER, got $(id -un)"
    set_final_status "failed"
    exit 1
fi

jl "=== Minecraft loader setup started ==="

PROFILE_FILE="$SERVER_DIR/.mcprofile.json"
if [ ! -f "$PROFILE_FILE" ]; then
    jl "ERROR: missing $PROFILE_FILE"
    set_final_status "failed"
    exit 1
fi

read_profile() {
    perl -MJSON::PP=decode_json -e '
        open my $f, "<", shift or exit 1;
        local $/; my $j = decode_json(<$f>);
        print join("\n", map { $_ . "=" . ($j->{$_}//"") } qw(loader mc_version java_major java_home lgsm_script mod_dir loader_version));
    ' "$PROFILE_FILE"
}

PROFILE_VARS="$(read_profile)" || {
    jl "ERROR: cannot parse $PROFILE_FILE"
    set_final_status "failed"
    exit 1
}

LOADER=""
MC_VERSION=""
JAVA_HOME_REL=""
LOADER_VERSION_PIN=""
while IFS= read -r line; do
    case "$line" in
        loader=*)     LOADER="${line#loader=}" ;;
        mc_version=*) MC_VERSION="${line#mc_version=}" ;;
        java_home=*)  JAVA_HOME_REL="${line#java_home=}" ;;
        loader_version=*) LOADER_VERSION_PIN="${line#loader_version=}" ;;
    esac
done <<< "$PROFILE_VARS"

case "$LOADER" in
    fabric|forge|neoforge) ;;
    *)
        jl "ERROR: loader '$LOADER' does not use mc_loader_install"
        set_final_status "failed"
        exit 1
        ;;
esac

if [ -z "$MC_VERSION" ] || [ -z "$JAVA_HOME_REL" ]; then
    jl "ERROR: incomplete profile (mc_version/java_home)"
    set_final_status "failed"
    exit 1
fi

JAVA_BIN="$SERVER_DIR/$JAVA_HOME_REL/bin/java"
if [ ! -x "$JAVA_BIN" ]; then
    jl "ERROR: Java not installed at $JAVA_BIN — run mc_java_setup first"
    set_final_status "failed"
    exit 1
fi

SERVERFILES="$SERVER_DIR/serverfiles"
INSTALLER_JAR="$SERVERFILES/.loader-installer.jar"
LOCK_FILE="$SERVER_DIR/.mc_loader_install.lock"

jl "=== Resolving $LOADER installer for MC $MC_VERSION ==="
RESOLVE_ARGS=("$LOADER" "$MC_VERSION")
if [ -n "$LOADER_VERSION_PIN" ]; then
    RESOLVE_ARGS+=("$LOADER_VERSION_PIN")
    jl "=== Pinned loader version: $LOADER_VERSION_PIN ==="
fi
RESOLVE_FILE="$JOB_DIR/.loader_resolve.env"
rm -f "$RESOLVE_FILE" 2>/dev/null || true
if ! perl "$MODULE_ROOT/scripts/mc_resolve_loader.pl" "${RESOLVE_ARGS[@]}" > "$RESOLVE_FILE"; then
    jl "ERROR: could not resolve $LOADER installer for MC $MC_VERSION"
    rm -f "$RESOLVE_FILE" 2>/dev/null || true
    set_final_status "failed"
    exit 1
fi
# shellcheck source=/dev/null
set -a
. "$RESOLVE_FILE"
set +a
rm -f "$RESOLVE_FILE" 2>/dev/null || true

if [ -z "${installer_url:-}" ] || [ -z "${loader_version:-}" ]; then
    jl "ERROR: resolver returned incomplete data"
    set_final_status "failed"
    exit 1
fi
jl "=== Installer: $installer_url (loader $loader_version) ==="

mkdir -p "$SERVERFILES"

(
    flock -n 9 || { jl "ERROR: another loader install is running"; exit 1; }
    jl "=== Downloading installer ==="
    if ! $PRIO_LOW curl -fsSL --max-time 600 -o "$INSTALLER_JAR" "$installer_url"; then
        jl "ERROR: installer download failed"
        exit 1
    fi
    jl "=== Download complete: $(basename "$INSTALLER_JAR") ==="

    jl "=== Running installer in serverfiles/ (this may take several minutes) ==="
    case "$LOADER" in
        fabric)
            FABRIC_LOADER="${fabric_loader_version:-$loader_version}"
            if ! $PRIO_LOW bash -c "
                cd '$SERVERFILES' &&
                '$JAVA_BIN' -jar '$INSTALLER_JAR' server -mcversion '$MC_VERSION' -loader '$FABRIC_LOADER' -downloadMinecraft
            "; then
                echo "ERROR: Fabric installer failed"
                exit 1
            fi
            ;;
        forge|neoforge)
            if ! $PRIO_LOW bash -c "
                cd '$SERVERFILES' &&
                '$JAVA_BIN' -jar '$INSTALLER_JAR' --installServer .
            "; then
                echo "ERROR: $LOADER installer failed"
                exit 1
            fi
            ;;
    esac
) 9>"$LOCK_FILE" || {
    set_final_status "failed"
    exit 1
}

# Normalize Fabric launch jar name for LGSM executable=./fabric_server.jar
if [ "$LOADER" = "fabric" ]; then
    (
        cd "$SERVERFILES" &&
        if [ -f fabric-server-launch.jar ]; then
            ln -sf fabric-server-launch.jar fabric_server.jar
        elif [ -f server.jar ] && [ ! -f fabric_server.jar ]; then
            ln -sf server.jar fabric_server.jar
        fi
    )
fi

if [ "$LOADER" = "forge" ] || [ "$LOADER" = "neoforge" ]; then
    [ -f "$SERVERFILES/run.sh" ] && chmod +x "$SERVERFILES/run.sh" || true
fi

# Expected executable relative to serverfiles (LGSM executabledir)
EXPECTED=""
case "$LOADER" in
    fabric)   EXPECTED="fabric_server.jar" ;;
    forge|neoforge) EXPECTED="run.sh" ;;
esac

if [ ! -e "$SERVERFILES/$EXPECTED" ]; then
    jl "ERROR: expected server file missing after install: serverfiles/$EXPECTED"
    set_final_status "failed"
    exit 1
fi
jl "=== Verified serverfiles/$EXPECTED ==="

rm -f "$INSTALLER_JAR" 2>/dev/null || true

INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MERGE_ERR="$(perl "$MODULE_ROOT/scripts/mc_profile_merge.pl" "$PROFILE_FILE" "$UNIX_USER" \
    "loader_version=$loader_version" "loader_installed_at=$INSTALLED_AT" 2>&1)" || {
    jl "ERROR: could not update .mcprofile.json${MERGE_ERR:+ — $MERGE_ERR}"
    set_final_status "failed"
    exit 1
}

CFG_DIR="$SERVER_DIR/lgsm/config-lgsm/$LGSM_SCRIPT"
CFG_FILE="$CFG_DIR/$LGSM_SCRIPT.cfg"
mkdir -p "$CFG_DIR"
if [ ! -f "$CFG_FILE" ]; then
    touch "$CFG_FILE"
fi

PATCHED="$(perl "$MODULE_ROOT/scripts/mc_patch_lgsm_cfg.pl" "$CFG_FILE" "$PROFILE_FILE" "$SERVER_DIR")" || {
    echo "ERROR: LGSM cfg patch failed"
    set_final_status "failed"
    exit 1
}
if ! cat > "$CFG_FILE" <<< "$PATCHED"; then
    echo "ERROR: cannot write $CFG_FILE"
    set_final_status "failed"
    exit 1
fi

# Ensure eula.txt when wizard accepted EULA (file is created by the game user).
if [ -f "$PROFILE_FILE" ]; then
    perl -MJSON::PP=decode_json -e '
        open my $f, "<", shift or exit 0;
        local $/; my $p = eval { decode_json(<$f>) } // {};
        exit 0 unless $p->{eula_accepted};
        my $eula = shift;
        exit 0 if -f $eula;
        open my $o, ">", $eula or exit 1;
        print $o "eula=true\n";
    ' "$PROFILE_FILE" "$SERVERFILES/eula.txt" 2>/dev/null || true
fi

jl "=== Mod loader $LOADER $loader_version installed for MC $MC_VERSION ==="
set_final_status "ok"
