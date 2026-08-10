#!/usr/bin/env bash
# LGSM monitor path: when ./script monitor does not recover, WebCore must call start.
# Also records a monitor_restart job under $HOME/jobs for the UI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_ROOT="$ROOT/src"
MONITOR="$MODULE_ROOT/scripts/monitor_instance_user.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GAME_USER="$(id -un)"
SERVER_DIR="$TMP/pw-1"
JOBS_HOME="$TMP/home/$GAME_USER"
export HOME="$JOBS_HOME"
mkdir -p "$SERVER_DIR/logs" "$SERVER_DIR/.monitor" "$JOBS_HOME"

cat >"$SERVER_DIR/pwserver" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
FLAG="$PWD/.mock_running"
case "${1:-}" in
  status)
    if [[ -f "$FLAG" ]]; then echo "STARTED"; else echo "STOPPED"; fi
    ;;
  details)
    if [[ -f "$FLAG" ]]; then echo "Status: STARTED"; else echo "Status: STOPPED"; fi
    ;;
  monitor)
    # Simulate LGSM: monitor alone does not recreate a crashed server.
    exit 0
    ;;
  start)
    touch "$FLAG"
    ;;
  *)
    echo "unknown: $1" >&2
    exit 1
    ;;
esac
MOCK
chmod +x "$SERVER_DIR/pwserver"
chmod -R u+rwX "$SERVER_DIR" "$JOBS_HOME"

printf 'status=running\nrestart_count=0\nwindow_start=%s\n' "$(date +%s)" >"$SERVER_DIR/.monitor/state"

WEBCORE_MONITOR_WAIT_TRIES=1 WEBCORE_MONITOR_WAIT_DELAY=0 \
    bash "$MONITOR" "pw_test" lgsm "$SERVER_DIR" pwserver "$MODULE_ROOT" >/dev/null

[[ -f "$SERVER_DIR/.mock_running" ]] || { echo "mock server not started"; exit 1; }
grep -q '^status=running$' "$SERVER_DIR/.monitor/state" || { echo "state not running"; exit 1; }
grep -q "still offline after monitor" "$SERVER_DIR/logs/monitor.log" || { echo "missing start fallback log"; exit 1; }
grep -q "monitor_restart job recorded" "$SERVER_DIR/logs/monitor.log" || { echo "missing monitor_restart job log"; exit 1; }

jid="$(grep '^last_restart_job=' "$SERVER_DIR/.monitor/state" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
[[ "$jid" =~ ^[0-9a-f]{16}$ ]] || { echo "no monitor job id in log"; exit 1; }
[[ -f "$JOBS_HOME/jobs/$jid/meta" ]] || { echo "monitor job meta missing"; exit 1; }
grep -q '^action=monitor_restart$' "$JOBS_HOME/jobs/$jid/meta" || { echo "wrong job action"; exit 1; }
grep -q "^last_restart_job=$jid$" "$SERVER_DIR/.monitor/state" || { echo "state missing last_restart_job"; exit 1; }

echo "ok test_monitor_lgsm.sh"
