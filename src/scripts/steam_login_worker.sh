#!/bin/bash
# steam_login_worker.sh SESSION_DIR USERNAME PASS_FILE
# Manages a steamcmd login session via FIFO.
# Writes status to $SESSION_DIR/status:
#   connecting | guard_required | ok | failed | timeout
set -euo pipefail

SESSION_DIR="$1"
USERNAME="$2"
PASS_FILE="$3"

FINAL_STATUS_WRITTEN=0

set_final_status() {
    local status="$1"
    echo "$status" > "$SESSION_DIR/status"
    FINAL_STATUS_WRITTEN=1
}

on_exit() {
    if [ "${FINAL_STATUS_WRITTEN:-0}" -eq 0 ]; then
        echo "failed" > "$SESSION_DIR/status"
        echo "[LGSM-DEBUG] steam_login_worker exited without final status for user $USERNAME" >> /var/webmin/miniserv.error
    fi
}

trap on_exit EXIT

if [ -z "$SESSION_DIR" ] || [ -z "$USERNAME" ] || [ -z "$PASS_FILE" ]; then
    echo "Usage: $0 SESSION_DIR USERNAME PASS_FILE" >&2
    exit 1
fi

# Read and immediately delete the password temp file
PASSWORD=$(cat "$PASS_FILE")
rm -f "$PASS_FILE"

set_final_status "connecting"
FINAL_STATUS_WRITTEN=0

# Create FIFO for steamcmd stdin
mkfifo "$SESSION_DIR/steam_in"

STEAMCMD="${STEAMCMD_PATH:-steamcmd}"

# Start steamcmd reading from FIFO, writing output to file
"$STEAMCMD" < "$SESSION_DIR/steam_in" > "$SESSION_DIR/steam_out" 2>&1 &
STEAM_PID=$!
echo $STEAM_PID > "$SESSION_DIR/pid"

# Send login command in background (FIFO write blocks until steamcmd reads)
(
    printf "login %s %s\nquit\n" "$USERNAME" "$PASSWORD"
) > "$SESSION_DIR/steam_in" &

START=$(date +%s)

while kill -0 $STEAM_PID 2>/dev/null; do
    NOW=$(date +%s)

    if grep -qEi "invalid password|login failure|failed to authenticate|account name or password|incorrect login|two-factor code.*invalid|steam guard.*invalid|invalid code" "$SESSION_DIR/steam_out" 2>/dev/null; then
        set_final_status "failed"
        kill "$STEAM_PID" 2>/dev/null || true
        exit 1
    fi

    # Timeout after 300 seconds
    if [ $((NOW - START)) -gt 300 ]; then
        set_final_status "timeout"
        kill "$STEAM_PID" 2>/dev/null
        exit 1
    fi

    # Allow CGI fallback to drop guard code even when prompt detection is imperfect.
    if [ -f "$SESSION_DIR/guard_code" ]; then
        (
            cat "$SESSION_DIR/guard_code"
            printf "\nquit\n"
        ) > "$SESSION_DIR/steam_in"
        rm -f "$SESSION_DIR/guard_code"
        set_final_status "connecting"
        FINAL_STATUS_WRITTEN=0
    fi

    # Steam can request either:
    # 1) push confirmation in mobile app (no code input needed), or
    # 2) an actual guard/authenticator code.
    # Only case (2) should switch to guard_required.
    if grep -qEi "please confirm the login in the steam mobile app|waiting for confirmation" "$SESSION_DIR/steam_out" 2>/dev/null; then
        :
    elif grep -qEi "steam[^[:alnum:]]*guard|two-factor|authenticator|email[^[:alnum:]]*code|enter[^[:alnum:]]*(the )?(current )?code|device[^[:alnum:]]*code" "$SESSION_DIR/steam_out" 2>/dev/null; then
        set_final_status "guard_required"
        FINAL_STATUS_WRITTEN=0

        # Wait for CGI to write the guard code
        while [ ! -f "$SESSION_DIR/guard_code" ]; do
            sleep 1
            NOW=$(date +%s)
            if [ $((NOW - START)) -gt 300 ]; then
                set_final_status "timeout"
                kill "$STEAM_PID" 2>/dev/null
                exit 1
            fi
        done

        # Send guard code if provided by CGI.
        if [ -f "$SESSION_DIR/guard_code" ]; then
            (
                cat "$SESSION_DIR/guard_code"
                printf "\nquit\n"
            ) > "$SESSION_DIR/steam_in"
            rm -f "$SESSION_DIR/guard_code"
            set_final_status "connecting"
            FINAL_STATUS_WRITTEN=0
        fi
    fi

    sleep 1
done

# Evaluate outcome
if grep -qEi "Login.*OK|Logged in OK|Waiting for user info.*OK|Waiting for client config.*OK|Logging in user .* to Steam Public.*OK" "$SESSION_DIR/steam_out" 2>/dev/null; then
    set_final_status "ok"
else
    set_final_status "failed"
    # Log steamcmd output for debugging
    echo "[LGSM-DEBUG] steam_login_worker failed for user $USERNAME" >> /var/webmin/miniserv.error
    sed 's/^/[LGSM-DEBUG] steamcmd: /' "$SESSION_DIR/steam_out" >> /var/webmin/miniserv.error 2>/dev/null || true
fi
