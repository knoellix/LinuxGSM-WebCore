#!/bin/bash
# steam_login_worker.sh SESSION_DIR USERNAME PASS_FILE
# Manages a steamcmd login session via FIFO.
# Writes status to $SESSION_DIR/status:
#   connecting | guard_required | ok | failed | timeout
set -euo pipefail

SESSION_DIR="$1"
USERNAME="$2"
PASS_FILE="$3"

if [ -z "$SESSION_DIR" ] || [ -z "$USERNAME" ] || [ -z "$PASS_FILE" ]; then
    echo "Usage: $0 SESSION_DIR USERNAME PASS_FILE" >&2
    exit 1
fi

# Read and immediately delete the password temp file
PASSWORD=$(cat "$PASS_FILE")
rm -f "$PASS_FILE"

echo "connecting" > "$SESSION_DIR/status"

# Create FIFO for steamcmd stdin
mkfifo "$SESSION_DIR/steam_in"

STEAMCMD="${STEAMCMD_PATH:-steamcmd}"

# Start steamcmd reading from FIFO, writing output to file
"$STEAMCMD" < "$SESSION_DIR/steam_in" > "$SESSION_DIR/steam_out" 2>&1 &
STEAM_PID=$!
echo $STEAM_PID > "$SESSION_DIR/pid"

# Send login command in background (FIFO write blocks until steamcmd reads)
(
    printf "+login %s %s\n+quit\n" "$USERNAME" "$PASSWORD"
) > "$SESSION_DIR/steam_in" &

START=$(date +%s)

while kill -0 $STEAM_PID 2>/dev/null; do
    NOW=$(date +%s)

    # Timeout after 300 seconds
    if [ $((NOW - START)) -gt 300 ]; then
        echo "timeout" > "$SESSION_DIR/status"
        kill "$STEAM_PID" 2>/dev/null
        exit 1
    fi

    # Check for Steam Guard prompt (email code or mobile authenticator)
    if grep -qE "Steam Guard|Two-factor code|Enter the current code" "$SESSION_DIR/steam_out" 2>/dev/null; then
        echo "guard_required" > "$SESSION_DIR/status"

        # Wait for CGI to write the guard code
        while [ ! -f "$SESSION_DIR/guard_code" ]; do
            sleep 1
            NOW=$(date +%s)
            if [ $((NOW - START)) -gt 300 ]; then
                echo "timeout" > "$SESSION_DIR/status"
                kill "$STEAM_PID" 2>/dev/null
                exit 1
            fi
        done

        # Send guard code followed by quit
        (
            cat "$SESSION_DIR/guard_code"
            printf "\n+quit\n"
        ) > "$SESSION_DIR/steam_in"
        rm -f "$SESSION_DIR/guard_code"
        echo "connecting" > "$SESSION_DIR/status"
    fi

    sleep 1
done

# Evaluate outcome
if grep -qE "Login.*OK|Logged in OK" "$SESSION_DIR/steam_out" 2>/dev/null; then
    echo "ok" > "$SESSION_DIR/status"
else
    echo "failed" > "$SESSION_DIR/status"
    # Log steamcmd output for debugging
    echo "[LGSM-DEBUG] steam_login_worker failed for user $USERNAME" >> /var/webmin/miniserv.error
    sed 's/^/[LGSM-DEBUG] steamcmd: /' "$SESSION_DIR/steam_out" >> /var/webmin/miniserv.error 2>/dev/null || true
fi
