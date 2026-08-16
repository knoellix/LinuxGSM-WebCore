#!/bin/bash
# mc_java_install_user.sh — Temurin JDK per instance + LGSM MC cfg + start wrapper.
# Runs AS THE GAME USER (dispatched via su privilege-drop, no internal su).
# Usage: mc_java_install_user.sh <job_dir> <unix_user> <server_dir> <lgsm_script>
#
# WEBCORE_SUBSTEP=1 : called as a sub-step of another job (e.g. modpack import).
#   -> do NOT init the job log or write the final status; the parent owns both.
#      Failures propagate via a non-zero exit code.
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

_PRIO_LIB_DIR="${MODULE_ROOT}/scripts/lib"
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
    # Parent job already redirected stdout to the log and owns the status file.
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

jl "=== Minecraft Java setup started ==="

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
        print join("\n", map { $_ . "=" . ($j->{$_}//"") } qw(loader mc_version java_major java_home lgsm_script mod_dir));
    ' "$PROFILE_FILE"
}

PROFILE_VARS="$(read_profile)" || {
    jl "ERROR: cannot parse $PROFILE_FILE"
    set_final_status "failed"
    exit 1
}

JAVA_MAJOR=""
JAVA_HOME_REL=""
MC_VERSION=""
while IFS= read -r line; do
    case "$line" in
        java_major=*) JAVA_MAJOR="${line#java_major=}" ;;
        java_home=*)  JAVA_HOME_REL="${line#java_home=}" ;;
        mc_version=*) MC_VERSION="${line#mc_version=}" ;;
    esac
done <<< "$PROFILE_VARS"

if [ -z "$JAVA_MAJOR" ] || [ -z "$JAVA_HOME_REL" ] || [ -z "$MC_VERSION" ]; then
    jl "ERROR: incomplete profile (java_major/java_home/mc_version)"
    set_final_status "failed"
    exit 1
fi

JAVA_DIR="$SERVER_DIR/$JAVA_HOME_REL"
JAVA_BIN="$JAVA_DIR/bin/java"

detect_arch() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|amd64) echo "x64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *) echo "x64" ;;
    esac
}

# Report installed JVM major (e.g. 21 / 25), or empty on failure.
java_runtime_major() {
    local bin="$1"
    [ -x "$bin" ] || return 0
    # Prefer specification.version (stable); fall back to parsing -version banner.
    local maj
    maj="$("$bin" -XshowSettings:properties -version 2>&1 \
        | sed -n 's/.*java\.specification\.version = *\([0-9][0-9]*\).*/\1/p' \
        | head -n1)"
    if [ -z "$maj" ]; then
        maj="$("$bin" -version 2>&1 \
            | sed -n 's/.*version "\([0-9][0-9]*\)\..*/\1/p' \
            | head -n1)"
    fi
    # Java 1.8 reports as 1.8 — treat as 8
    if [ "$maj" = "1" ]; then
        maj="$("$bin" -version 2>&1 \
            | sed -n 's/.*version "1\.\([0-9][0-9]*\)\..*/\1/p' \
            | head -n1)"
    fi
    printf '%s' "$maj"
}

install_temurin() {
    local major="$1"
    local arch os url tarball java_base
    arch="$(detect_arch)"
    os="linux"
    jl "=== Downloading Temurin JDK $major ($os/$arch) ==="
    url="https://api.adoptium.net/v3/binary/latest/${major}/ga/${os}/${arch}/jdk/hotspot/normal/eclipse"
    java_base="$SERVER_DIR/.java"
    tarball="$java_base/.temurin-${major}.tar.gz.download"
    mkdir -p "$java_base" || return 1
    if ! $PRIO_LOW curl -fsSL --max-time 600 -o "$tarball" "$url"; then
        rm -f "$tarball" 2>/dev/null || true
        jl "ERROR: Temurin download failed"
        return 1
    fi
    jl "=== Extracting Temurin JDK $major ==="
    if ! $PRIO_LOW bash -c "
        rm -rf '$JAVA_DIR' &&
        mkdir -p '$JAVA_DIR' &&
        tar -xzf '$tarball' -C '$JAVA_DIR' --strip-components=1 &&
        rm -f '$tarball'
    "; then
        rm -f "$tarball" 2>/dev/null || true
        jl "ERROR: Temurin extract failed"
        return 1
    fi
    return 0
}

NEED_INSTALL=0
if [ ! -x "$JAVA_BIN" ]; then
    NEED_INSTALL=1
else
    ACTUAL_MAJOR="$(java_runtime_major "$JAVA_BIN")"
    if [ -z "$ACTUAL_MAJOR" ]; then
        jl "=== WARNING: could not detect Java major at $JAVA_BIN — reinstalling ==="
        NEED_INSTALL=1
    elif [ "$ACTUAL_MAJOR" != "$JAVA_MAJOR" ]; then
        jl "=== Java major mismatch: have $ACTUAL_MAJOR, need $JAVA_MAJOR — reinstalling ==="
        NEED_INSTALL=1
    else
        jl "=== Java $JAVA_MAJOR already present at $JAVA_BIN — skipping download ==="
    fi
fi

if [ "$NEED_INSTALL" = "1" ]; then
    if ! install_temurin "$JAVA_MAJOR"; then
        jl "ERROR: Temurin JDK $JAVA_MAJOR install failed"
        set_final_status "failed"
        exit 1
    fi
fi

if ! "$JAVA_BIN" -version >/dev/null 2>&1; then
    jl "ERROR: Java binary not executable: $JAVA_BIN"
    set_final_status "failed"
    exit 1
fi
ACTUAL_MAJOR="$(java_runtime_major "$JAVA_BIN")"
if [ -n "$ACTUAL_MAJOR" ] && [ "$ACTUAL_MAJOR" != "$JAVA_MAJOR" ]; then
    jl "ERROR: Java at $JAVA_BIN reports major $ACTUAL_MAJOR, expected $JAVA_MAJOR"
    set_final_status "failed"
    exit 1
fi
jl "=== Java OK: $JAVA_BIN (major ${ACTUAL_MAJOR:-$JAVA_MAJOR}) ==="

WRAPPER="$SERVER_DIR/mc_start_wrapper.sh"
jl "=== Writing start wrapper ==="
if ! cat > "$WRAPPER" <<EOF
#!/bin/bash
set -euo pipefail
SERVER_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
export JAVA_HOME="\$SERVER_DIR/$JAVA_HOME_REL"
export PATH="\$JAVA_HOME/bin:\$PATH"
if [ ! -x "\$JAVA_HOME/bin/java" ]; then
    echo "Java not found at \$JAVA_HOME" >&2
    exit 1
fi
exec "\$@"
EOF
then
    jl "ERROR: cannot write $WRAPPER"
    set_final_status "failed"
    exit 1
fi
chmod +x "$WRAPPER"

CFG_DIR="$SERVER_DIR/lgsm/config-lgsm/$LGSM_SCRIPT"
CFG_FILE="$CFG_DIR/$LGSM_SCRIPT.cfg"
mkdir -p "$CFG_DIR"
if [ ! -f "$CFG_FILE" ]; then
    touch "$CFG_FILE"
fi

jl "=== Patching LGSM config for MC $MC_VERSION ==="
PATCHED="$(perl "$MODULE_ROOT/scripts/mc_patch_lgsm_cfg.pl" "$CFG_FILE" "$PROFILE_FILE" "$SERVER_DIR")" || {
    jl "ERROR: LGSM cfg patch failed"
    set_final_status "failed"
    exit 1
}

if ! cat > "$CFG_FILE" <<< "$PATCHED"; then
    jl "ERROR: cannot write $CFG_FILE"
    set_final_status "failed"
    exit 1
fi

if ! grep -q "serverversion=\"$MC_VERSION\"" "$CFG_FILE" 2>/dev/null; then
    jl "ERROR: serverversion not verified in $CFG_FILE"
    set_final_status "failed"
    exit 1
fi

if [ -f "$SERVER_DIR/serverfiles/server.properties" ]; then
    jl "=== Ensuring enable-query + query.port=server-port ==="
    perl -I"$MODULE_ROOT/lib" -e '
        require "mc_profile.pl";
        write_mc_server_properties_query($ARGV[0], $ARGV[1]) or exit 1;
    ' "$SERVER_DIR" "$UNIX_USER" 2>/dev/null \
        || jl "WARN: could not patch server.properties query settings"
fi

jl "=== Minecraft profile applied (MC $MC_VERSION, Java $JAVA_MAJOR) ==="
set_final_status "ok"
