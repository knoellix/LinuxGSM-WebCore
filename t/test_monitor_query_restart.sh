#!/usr/bin/env bash
# LGSM query-fail → graceful stop → start must set monitor_recovery and record a job,
# even when the session looked online before/after (the Minecraft gamedig false-positive path).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_ROOT="$ROOT/src"
MONITOR="$MODULE_ROOT/scripts/monitor_instance_user.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GAME_USER="$(id -un)"
SERVER_DIR="$TMP/mc-1"
JOBS_HOME="$TMP/home/$GAME_USER"
export HOME="$JOBS_HOME"
mkdir -p "$SERVER_DIR/logs" "$SERVER_DIR/.monitor" "$JOBS_HOME"

cat >"$SERVER_DIR/mcserver" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
FLAG="$PWD/.mock_running"
case "${1:-}" in
  status)
    echo "STARTED"
    ;;
  details)
    echo "Status: STARTED"
    ;;
  monitor)
    # Session OK, but gamedig query fails → LGSM stops and starts (real mcserver log shape).
    cat <<'EOF'
[  OK  ] Monitoring mcserver: Checking session: OK
[ FAIL ] Monitoring mcserver: Querying port: gamedig: 127.0.0.1:25565 : 60/5 ... FAIL
[  OK  ] Stopping mcserver: Graceful: sending "stop": 5 ... OK
[  OK  ] Starting mcserver: LinuxGSM
EOF
    touch "$FLAG"
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
chmod +x "$SERVER_DIR/mcserver"
# Pretend server was already online before monitor ran.
touch "$SERVER_DIR/.mock_running"
chmod -R u+rwX "$SERVER_DIR" "$JOBS_HOME"

printf 'status=running\nrestart_count=0\nwindow_start=%s\n' "$(date +%s)" >"$SERVER_DIR/.monitor/state"

WEBCORE_MONITOR_WAIT_TRIES=1 WEBCORE_MONITOR_WAIT_DELAY=0 \
    bash "$MONITOR" "gs_mc_test_mc-1" lgsm "$SERVER_DIR" mcserver "$MODULE_ROOT" >/dev/null

grep -q "monitor triggered restart" "$SERVER_DIR/logs/monitor.log" \
    || { echo "missing query-fail restart detection log"; exit 1; }
grep -q "monitor_restart job recorded" "$SERVER_DIR/logs/monitor.log" \
    || { echo "missing monitor_restart job log"; exit 1; }

jid="$(grep '^last_restart_job=' "$SERVER_DIR/.monitor/state" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
[[ "$jid" =~ ^[0-9a-f]{16}$ ]] || { echo "no last_restart_job in state"; exit 1; }
[[ -f "$JOBS_HOME/jobs/$jid/meta" ]] || { echo "monitor job meta missing"; exit 1; }
grep -q '^action=monitor_restart$' "$JOBS_HOME/jobs/$jid/meta" || { echo "wrong job action"; exit 1; }
grep -q 'Querying port:.*FAIL' "$JOBS_HOME/jobs/$jid/output" || { echo "job output missing query fail excerpt"; exit 1; }

echo "ok test_monitor_query_restart.sh"
