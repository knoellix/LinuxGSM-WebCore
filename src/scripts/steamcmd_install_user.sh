#!/bin/bash
# steamcmd_install_user.sh — game-user-side SteamCMD installation
# Runs as the game user via su from steamcmd_install.sh.
# ALL files created here are owned by the game user — no chown needed.
# Args: <server_dir> <job_dir> <steam_app_id> <validate> <script_name> <runtime_mode> [preclean]
set -euo pipefail

SERVER_DIR="$1"
JOB_DIR="$2"
STEAM_APP_ID="$3"
VALIDATE="${4:-}"
SCRIPT_NAME="${5:-}"
RUNTIME_MODE="${6:-}"
PRECLEAN="${7:-}"

INSTALL_DIR="$SERVER_DIR/serverfiles"
LAUNCH_CMD_FILE="$SERVER_DIR/.steam_launch_cmd"
LAUNCH_WRAPPER="$SERVER_DIR/steamcmd-start.sh"

_PRIO_LIB_DIR="${MODULE_ROOT:-}/scripts/lib"
if [ -n "$_PRIO_LIB_DIR" ] && [ -f "$_PRIO_LIB_DIR/prio.sh" ]; then
    # shellcheck source=lib/prio.sh
    . "$_PRIO_LIB_DIR/prio.sh"
else
    PRIO_HIGH=""
    PRIO_LOW=""
fi

FORCE_PLATFORM_ARGS=""
[ "${RUNTIME_MODE:-}" = "wine" ] && FORCE_PLATFORM_ARGS="+@sSteamCmdForcePlatformType windows +@sSteamCmdForcePlatformBitness 64"

# Re-read launch candidates from world-readable metadata JSON
LAUNCH_CANDIDATES=""
if [ -n "${MODULE_ROOT:-}" ] && [ -f "$MODULE_ROOT/lib/games_meta.json" ]; then
    LAUNCH_CANDIDATES=$(MODULE_ROOT="${MODULE_ROOT:-}" STEAM_APP_ID="$STEAM_APP_ID" perl -e '
use JSON::PP;
my $meta_file = "$ENV{MODULE_ROOT}/lib/games_meta.json";
open(my $f, "<", $meta_file) or exit 0;
local $/;
my $data = decode_json(<$f>);
for my $k (keys %$data) {
    next unless (($data->{$k}{steam_app_id} // 0) == $ENV{STEAM_APP_ID});
    my $arr = $data->{$k}{launch_candidates} // [];
    print join("\n", @$arr);
    last;
}
' 2>/dev/null || true)
fi

if [ "$PRECLEAN" = "1" ]; then
    echo "=== Deleting serverfiles/ (reinstall preclean) ==="
    rm -rf "$INSTALL_DIR"
fi

echo "=== Downloading via SteamCMD (App ID: $STEAM_APP_ID) ==="
# mkdir as game user — correct ownership from the start, no chown needed
mkdir -p "$INSTALL_DIR"

VALIDATE_FLAG=""
[ "$VALIDATE" = "validate" ] && VALIDATE_FLAG="validate"
STEAMCMD="${STEAMCMD_PATH:-steamcmd}"

echo "Using SteamCMD: $STEAMCMD"
# shellcheck disable=SC2086
if ! $PRIO_LOW "$STEAMCMD" $FORCE_PLATFORM_ARGS \
                +force_install_dir "$INSTALL_DIR" \
                +login anonymous \
                +app_update "$STEAM_APP_ID" $VALIDATE_FLAG \
                +quit; then
    echo "hint_steamcmd_login" > "$JOB_DIR/error_hint"
    exit 1
fi

echo "=== Detecting server binary ==="
DETECTED_BIN=""

# Meta-first detection: try explicit launch candidates from games_meta
if [ -n "${LAUNCH_CANDIDATES:-}" ]; then
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        case "$candidate" in
            *\**|\?*|\[*)
                MATCH=$(find "$INSTALL_DIR" -type f 2>/dev/null | grep -E "/${candidate//\*/.*}$" | head -1 || true)
                if [ -n "${MATCH:-}" ]; then
                    DETECTED_BIN="$MATCH"
                    break
                fi
                ;;
            *)
                if [ -f "$INSTALL_DIR/$candidate" ]; then
                    DETECTED_BIN="$INSTALL_DIR/$candidate"
                    break
                fi
                ;;
        esac
    done <<< "$LAUNCH_CANDIDATES"
fi

# First pass: executable candidates
if [ -z "${DETECTED_BIN:-}" ]; then
    DETECTED_BIN=$(find "$INSTALL_DIR" -type f -perm /111 2>/dev/null \
        | grep -E '/Binaries/Linux/|Server\.sh$|\.x86_64$|Linux-Shipping$|Server-Linux' \
        | grep -Eiv 'CrashReport|crashreport|unins|uninstall|steamcmd' \
        | head -1 || true)
fi

# Second pass: common Linux server binaries that may miss execute bit
if [ -z "${DETECTED_BIN:-}" ]; then
    DETECTED_BIN=$(find "$INSTALL_DIR" -type f 2>/dev/null \
        | grep -E '/Binaries/Linux/|Server\.sh$|\.x86_64$|Linux-Shipping$|Server-Linux' \
        | grep -Eiv 'CrashReport|crashreport|unins|uninstall|steamcmd' \
        | head -1 || true)
    if [ -n "${DETECTED_BIN:-}" ]; then
        chmod +x "$DETECTED_BIN" 2>/dev/null || true
    fi
fi

if [ -n "${DETECTED_BIN:-}" ]; then
    chmod +x "$DETECTED_BIN" 2>/dev/null || true
fi

if [ -z "${DETECTED_BIN:-}" ]; then
    echo "ERROR: No executable server binary found after install in $INSTALL_DIR" >&2
    echo "=== Diagnostic: possible files in install dir ===" >&2
    find "$INSTALL_DIR" -maxdepth 8 -type f 2>/dev/null | head -80 >&2 || true
    echo "=== Diagnostic: install dir ownership ===" >&2
    ls -ld "$INSTALL_DIR" >&2 || true
    echo "hint_no_server_binary" > "$JOB_DIR/error_hint"
    exit 1
fi

# Write launch cmd file as game user — correct ownership, no chown needed
echo "$DETECTED_BIN" > "$LAUNCH_CMD_FILE"
chmod 600 "$LAUNCH_CMD_FILE"

# Wine binary detection
WINE_BIN=""
if [ "${RUNTIME_MODE:-}" = "wine" ] || [[ "${DETECTED_BIN:-}" == *.exe ]]; then
    if command -v wine >/dev/null 2>&1; then
        WINE_BIN=$(command -v wine)
    elif command -v wine64 >/dev/null 2>&1; then
        WINE_BIN=$(command -v wine64)
    else
        echo "ERROR: Wine runtime required but not found in PATH." >&2
        echo "hint_wine_required" > "$JOB_DIR/error_hint"
        exit 1
    fi
fi

# Wine prefix setup — runs as game user, all files game-user-owned
if [ "${RUNTIME_MODE:-}" = "wine" ] || [[ "${DETECTED_BIN:-}" == *.exe ]]; then
    echo "=== Preparing Wine runtime ==="
    WINE_PREFIX_DIR="$SERVER_DIR/.wine-windrose"
    WINE_READY_MARKER="$SERVER_DIR/.wine_runtime_ready"
    WINE_SETUP_SCRIPT="$SERVER_DIR/.wine_runtime_setup.sh"
    if [ ! -f "$WINE_READY_MARKER" ]; then
        cat > "$WINE_SETUP_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail
export WINEPREFIX="$WINE_PREFIX_DIR"
export WINEARCH=win64
WINE_BIN="$WINE_BIN"
CACHE_DIR="$SERVER_DIR/.wine-cache"
VCREDIST_X86_URL="https://aka.ms/vs/17/release/vc_redist.x86.exe"
VCREDIST_X64_URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
export WINEDEBUG="-all"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-winemenubuilder.exe=d}"
export WINEESYNC=0
export WINEFSYNC=0
LOCK_FILE="$SERVER_DIR/.wine_runtime.lock"

cleanup_stale_wine_runtime() {
    echo "Cleaning up stale wine runtime processes ..."
    local self_pid="\$\$"
    local stale_regex="vc_redist|wineboot -u|xvfb-run|Xvfb :"
    pgrep -a -u "\$(id -u)" -f "\$stale_regex" 2>/dev/null | while read -r line; do
        local pid
        pid="\$(printf "%s\n" "\$line" | awk '{print \$1}')"
        [ -n "\$pid" ] || continue
        [ "\$pid" = "\$self_pid" ] && continue
        local etimes
        etimes="\$(ps -o etimes= -p "\$pid" 2>/dev/null | tr -d ' ' || true)"
        [ -n "\$etimes" ] || continue
        case "\$etimes" in
            ''|*[!0-9]* ) continue ;;
        esac
        if [ "\$etimes" -gt 300 ]; then
            echo "Cleanup: killing stale pid=\$pid etimes=\$etimes cmd=\$line"
            kill "\$pid" >/dev/null 2>&1 || true
            sleep 1
            kill -9 "\$pid" >/dev/null 2>&1 || true
        fi
    done || true
    if command -v wineserver >/dev/null 2>&1; then
        wineserver -k >/dev/null 2>&1 || true
    fi
}

run_wine() {
    if [ -z "\${DISPLAY:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
        xvfb-run -a "\$@"
    else
        "\$@"
    fi
}

download_file() {
    local url="\$1"
    local out="\$2"
    echo "Downloading \$(basename "\$out") ..."
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --connect-timeout 20 --max-time 900 -o "\$out" "\$url"
    else
        wget --timeout=20 -O "\$out" "\$url"
    fi
}

run_wine_with_timeout() {
    local label="\$1"
    local max_wait="\$2"
    shift
    shift
    echo "Running: \$label"
    if [ -z "\${DISPLAY:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout "\$max_wait" xvfb-run -a "\$@" || {
                local rc=\$?
                echo "ERROR: \$label timed out or failed (rc=\$rc) after \${max_wait}s" >&2
                return \$rc
            }
        else
            xvfb-run -a "\$@"
        fi
    else
        if command -v timeout >/dev/null 2>&1; then
            timeout "\$max_wait" "\$@" || {
                local rc=\$?
                echo "ERROR: \$label timed out or failed (rc=\$rc) after \${max_wait}s" >&2
                return \$rc
            }
        else
            "\$@"
        fi
    fi
}

run_wine_install_diag() {
    local label="\$1"
    local max_wait="\$2"
    local log_file="\$3"
    shift 3

    echo "Running: \$label"
    echo "Diagnostic: command=\$*"
    echo "Diagnostic: WINEPREFIX=\${WINEPREFIX:-unset}"
    ps -eo pid,ppid,user,etime,cmd | grep -E "wine|wineserver|xvfb" | grep -v grep || true

    local start_ts
    start_ts="\$(date +%s)"

    (
        if [ -z "\${DISPLAY:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
            xvfb-run -a "\$@" >"\$log_file" 2>&1
        else
            "\$@" >"\$log_file" 2>&1
        fi
    ) &
    local cmd_pid=\$!

    while kill -0 "\$cmd_pid" >/dev/null 2>&1; do
        local now elapsed
        now="\$(date +%s)"
        elapsed=\$((now - start_ts))
        if [ "\$elapsed" -ge "\$max_wait" ]; then
            echo "ERROR: \$label timed out after \${max_wait}s"
            kill "\$cmd_pid" >/dev/null 2>&1 || true
            sleep 2
            kill -9 "\$cmd_pid" >/dev/null 2>&1 || true
            if command -v wineserver >/dev/null 2>&1; then
                wineserver -k >/dev/null 2>&1 || true
            fi
            echo "=== Last installer log lines (\$log_file) ==="
            tail -n 120 "\$log_file" 2>/dev/null || true
            return 124
        fi
        echo "Diagnostic: \$label still running (\${elapsed}s)"
        pgrep -a -u "\$(id -u)" -f "wine|wineserver|vc_redist|xvfb-run" || true
        sleep 10
    done

    wait "\$cmd_pid"
    local rc=\$?
    echo "Diagnostic: \$label exit_code=\$rc"
    echo "=== Last installer log lines (\$log_file) ==="
    tail -n 120 "\$log_file" 2>/dev/null || true
    return "\$rc"
}

mkdir -p "\$CACHE_DIR"
cleanup_stale_wine_runtime
if command -v flock >/dev/null 2>&1; then
    exec 9>"\$LOCK_FILE"
    if ! flock -n 9; then
        echo "Another wine runtime setup is already running. Trying stale cleanup and lock retry ..."
        cleanup_stale_wine_runtime
        sleep 2
        if ! flock -n 9; then
            echo "Lock still busy. Waiting up to 20s for lock ..."
            timeout 20 flock 9 || {
                echo "ERROR: Could not acquire wine runtime lock at \$LOCK_FILE" >&2
                exit 1
            }
        fi
    fi
fi
echo "Skipping wineboot pre-init in headless mode (known to hang on some hosts)."
echo "Skipping vc_redist installers on automated path (headless stability mode)."
echo "If runtime DLL errors occur at server start, install redistributables manually once."
echo "Wine runtime setup finished."
EOF
        chmod 700 "$WINE_SETUP_SCRIPT"
        # Run as self (already game user) — no su needed
        if ! $PRIO_LOW bash "$WINE_SETUP_SCRIPT"; then
            echo "hint_wine_required" > "$JOB_DIR/error_hint"
            exit 1
        fi
        touch "$WINE_READY_MARKER"
        rm -f "$WINE_SETUP_SCRIPT" 2>/dev/null || true
    fi
fi

# Launch wrapper — written as game user, correct ownership
cat > "$LAUNCH_WRAPPER" <<EOF
#!/bin/bash
set -euo pipefail
SERVER_DIR="$SERVER_DIR"
CMD_FILE="\$SERVER_DIR/.steam_launch_cmd"
SERVERFILES_DIR="\$SERVER_DIR/serverfiles"

# CRITICAL: this wrapper is also installed as ./<scriptname> in SERVER_DIR. Webmin's
# instance status detection used to call './<scriptname> details' (LGSM convention).
# For non-LGSM SteamCMD games that would launch a NEW wine on every status poll —
# zombie pairs piled up in the same WINEPREFIX until the real start hung silently.
# Handle non-launch actions explicitly here so any leftover caller can no longer
# accidentally fork wine.
case "\${1:-}" in
    details|monitor|status)
        if [ -f "\$SERVER_DIR/run.pid" ]; then
            PID=\$(cat "\$SERVER_DIR/run.pid" 2>/dev/null || true)
            if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then
                echo "Status: Online (PID \$PID)"
                exit 0
            fi
        fi
        echo "Status: Offline"
        exit 0
        ;;
    restart|update|backup|console|debug)
        echo "Action '\$1' is not supported on this SteamCMD wrapper." >&2
        echo "Please use the Webmin UI for non-LGSM games." >&2
        exit 2
        ;;
esac

[ -f "\$CMD_FILE" ] || { echo "Missing \$CMD_FILE" >&2; exit 1; }
BIN=\$(cat "\$CMD_FILE")
[ -f "\$BIN" ] || { echo "Binary not found: \$BIN" >&2; exit 1; }
BIN_NAME=\$(basename "\$BIN")
if [[ "\$BIN_NAME" == *.exe ]]; then
    WINE_BIN="$WINE_BIN"
    [ -n "\$WINE_BIN" ] || { echo "Wine runtime required but not configured" >&2; exit 1; }
    export WINEPREFIX="\$SERVER_DIR/.wine-windrose"
    export WINEARCH=win64
    unset WINEDLLOVERRIDES
    unset WINEDEBUG
    if [[ "\$BIN_NAME" == "WindroseServer-Win64-Shipping.exe" || "\$BIN_NAME" == "WindroseServer.exe" ]]; then
        if [ -f "\$SERVERFILES_DIR/R5/Binaries/Win64/WindroseServer-Win64-Shipping.exe" ]; then
            REL_BIN="R5/Binaries/Win64/WindroseServer-Win64-Shipping.exe"
        elif [ -f "\$SERVERFILES_DIR/WindroseServer.exe" ]; then
            REL_BIN="WindroseServer.exe"
        else
            REL_BIN="\${BIN#\$SERVERFILES_DIR/}"
            if [ "\$REL_BIN" = "\$BIN" ]; then
                REL_BIN="\$(basename "\$BIN")"
            fi
        fi
        echo "Windrose detected, starting executable directly with -log"
        echo "Windrose launch target: \$REL_BIN"
        cd "\$SERVERFILES_DIR"
        echo "Launch user: \$(id -un) (uid=\$(id -u))"
        echo "Launch cwd: \$(pwd)"
        echo "Launch wine: \$WINE_BIN"
        chmod +x "\$BIN" 2>/dev/null || true
        if [ -z "\${DISPLAY:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
            exec xvfb-run -a "\$WINE_BIN" "\$REL_BIN" -log
        fi
        exec "\$WINE_BIN" "\$REL_BIN" -log
    fi
    BATCH_FILE="\$SERVERFILES_DIR/StartServerForeground.bat"
    if [ -f "\$BATCH_FILE" ]; then
        cd "\$(dirname "\$BATCH_FILE")"
        echo "Using batch launcher: \$BATCH_FILE"
        BATCH_BASENAME="\$(basename "\$BATCH_FILE")"
        BATCH_START_TS=\$(date +%s)
        if [ -z "\${DISPLAY:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
            if xvfb-run -a "\$WINE_BIN" cmd /c "call \$BATCH_BASENAME" "\$@"; then
                BATCH_ELAPSED=\$(( \$(date +%s) - BATCH_START_TS ))
                echo "Batch launcher exited with code 0 after \${BATCH_ELAPSED}s"
                if [ "\$BATCH_ELAPSED" -ge 5 ]; then
                    exit 0
                fi
                echo "Batch launcher returned too quickly; falling back to direct EXE start"
            fi
            BATCH_RC=\$?
            echo "Batch launcher failed (rc=\$BATCH_RC), falling back to direct EXE start"
        else
            if "\$WINE_BIN" cmd /c "call \$BATCH_BASENAME" "\$@"; then
                BATCH_ELAPSED=\$(( \$(date +%s) - BATCH_START_TS ))
                echo "Batch launcher exited with code 0 after \${BATCH_ELAPSED}s"
                if [ "\$BATCH_ELAPSED" -ge 5 ]; then
                    exit 0
                fi
                echo "Batch launcher returned too quickly; falling back to direct EXE start"
            fi
            BATCH_RC=\$?
            echo "Batch launcher failed (rc=\$BATCH_RC), falling back to direct EXE start"
        fi
    fi
    cd "\$(dirname "\$BIN")"
    chmod +x "\$BIN" 2>/dev/null || true
    if [ -z "\${DISPLAY:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
        exec xvfb-run -a "\$WINE_BIN" "\$BIN" "\$@"
    fi
    exec "\$WINE_BIN" "\$BIN" "\$@"
else
    cd "\$(dirname "\$BIN")"
    exec "\$BIN" "\$@"
fi
EOF
chmod 750 "$LAUNCH_WRAPPER"

if [ -n "$SCRIPT_NAME" ]; then
    cp -f "$LAUNCH_WRAPPER" "$SERVER_DIR/$SCRIPT_NAME"
    chmod 750 "$SERVER_DIR/$SCRIPT_NAME"
fi

# All files in SERVER_DIR — written as game user, correct ownership
echo "$STEAM_APP_ID" > "$SERVER_DIR/.steam_app_id"

echo "=== Installation complete ==="
