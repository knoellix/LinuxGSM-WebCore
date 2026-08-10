#!/usr/bin/env bash
# Scheduled restart worker: skip when offline, restart + job when online.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_ROOT="$ROOT/src"
WORKER="$MODULE_ROOT/scripts/scheduled_restart_user.sh"
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
  details)
    if [[ -f "$FLAG" ]]; then echo "Status: STARTED"; else echo "Status: STOPPED"; fi
    ;;
  stop)
    rm -f "$FLAG"
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

printf 'enabled=1\ntime=04:00\n' >"$SERVER_DIR/.monitor/schedule"

# --- offline: skip + last_skip_at, no job -----------------------------------
bash "$WORKER" "pw_test" lgsm "$SERVER_DIR" pwserver "$MODULE_ROOT" >/dev/null
grep -q 'skip: server offline' "$SERVER_DIR/logs/schedule.log" || { echo "missing offline skip log"; exit 1; }
grep -q '^last_skip_at=' "$SERVER_DIR/.monitor/schedule" || { echo "missing last_skip_at"; exit 1; }
[[ ! -d "$JOBS_HOME/jobs" ]] || [[ -z "$(ls -A "$JOBS_HOME/jobs" 2>/dev/null || true)" ]] \
    || { echo "job created on offline skip"; exit 1; }

# --- online: stop/start + job -----------------------------------------------
touch "$SERVER_DIR/.mock_running"
bash "$WORKER" "pw_test" lgsm "$SERVER_DIR" pwserver "$MODULE_ROOT" >/dev/null
[[ -f "$SERVER_DIR/.mock_running" ]] || { echo "server not running after scheduled restart"; exit 1; }
grep -q 'scheduled restart completed' "$SERVER_DIR/logs/schedule.log" || { echo "missing success log"; exit 1; }

jid="$(grep '^last_schedule_job=' "$SERVER_DIR/.monitor/schedule" | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
[[ "$jid" =~ ^[0-9a-f]{16}$ ]] || { echo "no schedule job id"; exit 1; }
[[ -f "$JOBS_HOME/jobs/$jid/meta" ]] || { echo "schedule job meta missing"; exit 1; }
grep -q '^action=scheduled_restart$' "$JOBS_HOME/jobs/$jid/meta" || { echo "wrong job action"; exit 1; }
grep -qx 'ok' "$JOBS_HOME/jobs/$jid/status" || { echo "job not ok"; exit 1; }
grep -q '^last_run=' "$SERVER_DIR/.monitor/schedule" || { echo "missing last_run"; exit 1; }

echo "ok test_schedule_restart.sh"
