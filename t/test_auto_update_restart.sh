#!/usr/bin/env bash
# auto_update_restart_user.sh + auto_update_launch_restart_job (mocked stop/update/start).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_ROOT="$ROOT/src"
WORKER="$MODULE_ROOT/scripts/auto_update_restart_user.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GAME_USER="$(id -un)"
SERVER_DIR="$TMP/pz-1"
JOBS_HOME="$TMP/home/$GAME_USER"
export HOME="$JOBS_HOME"
mkdir -p "$SERVER_DIR/logs" "$SERVER_DIR/.monitor" "$JOBS_HOME/jobs"

STOP_LOG="$TMP/stop.log"
UPDATE_LOG="$TMP/update.log"
START_LOG="$TMP/start.log"
BROADCAST_LOG="$TMP/broadcast.log"
READY_LOG="$TMP/ready.log"
: >"$STOP_LOG"
: >"$UPDATE_LOG"
: >"$START_LOG"
: >"$BROADCAST_LOG"
: >"$READY_LOG"

export AUTO_UPDATE_STOP_CMD='echo stop >>'"$STOP_LOG"
export AUTO_UPDATE_UPDATE_CMD='echo update >>'"$UPDATE_LOG"
export AUTO_UPDATE_START_CMD='echo start >>'"$START_LOG"
export AUTO_UPDATE_BROADCAST_CMD='echo "$1" >>'"$BROADCAST_LOG"
export AUTO_UPDATE_MARK_READY_CMD='echo ready >>'"$READY_LOG"

_write_state() {
    cat >"$SERVER_DIR/.monitor/auto_update"
}

_make_job() {
    local jid="$1"
    local jdir="$JOBS_HOME/jobs/$jid"
    mkdir -p "$jdir"
    {
        printf 'instance_id=pz_test\n'
        printf 'action=auto_update_restart\n'
        printf 'started_at=%s\n' "$(date +%s)"
        printf 'unix_user=%s\n' "$GAME_USER"
        printf 'trigger=auto_update\n'
    } >"$jdir/meta"
    printf 'running\n' >"$jdir/status"
    : >"$jdir/output"
    echo "$jdir"
}

bash -n "$WORKER" || { echo "bash -n failed"; exit 1; }

# --- need_game=0: stop+start, skip update -----------------------------------
: >"$STOP_LOG" ; : >"$UPDATE_LOG" ; : >"$START_LOG" ; : >"$READY_LOG"
JDIR="$(_make_job aaaaaaaaaaaaaaaa)"
_write_state <<'EOF'
enabled=1
pending=1
countdown_deadline=1700000000
need_game=0
need_workshop=1
reason=Workshop-Update
mods=111,222
msg_now=Server startet jetzt neu — {reason}
msg_sent=15,10,5,1,0
EOF

bash "$WORKER" "$JDIR" "$GAME_USER" "$SERVER_DIR" pzserver "$MODULE_ROOT"
grep -qx 'ok' "$JDIR/status" || { echo "need_game=0: status not ok"; exit 1; }
grep -q '^stop$' "$STOP_LOG" || { echo "need_game=0: stop not called"; exit 1; }
grep -q '^start$' "$START_LOG" || { echo "need_game=0: start not called"; exit 1; }
[[ ! -s "$UPDATE_LOG" ]] || { echo "need_game=0: update must not run"; exit 1; }
grep -q '^ready$' "$READY_LOG" || { echo "need_game=0: mark_ready missing"; exit 1; }
grep -q '^pending=0' "$SERVER_DIR/.monitor/auto_update" || { echo "need_game=0: pending not cleared"; exit 1; }
grep -q '^need_game=0' "$SERVER_DIR/.monitor/auto_update" || { echo "need_game=0: need_game not cleared"; exit 1; }
grep -q '^need_workshop=0' "$SERVER_DIR/.monitor/auto_update" || { echo "need_game=0: need_workshop not cleared"; exit 1; }
grep -q '^countdown_deadline=0' "$SERVER_DIR/.monitor/auto_update" || { echo "need_game=0: countdown not cleared"; exit 1; }
grep -q 'Server startet jetzt neu' "$BROADCAST_LOG" || { echo "need_game=0: msg_now not broadcast"; exit 1; }

# --- need_game=1: update invoked --------------------------------------------
: >"$STOP_LOG" ; : >"$UPDATE_LOG" ; : >"$START_LOG" ; : >"$READY_LOG" ; : >"$BROADCAST_LOG"
JDIR="$(_make_job bbbbbbbbbbbbbbbb)"
_write_state <<'EOF'
enabled=1
pending=1
countdown_deadline=0
need_game=1
need_workshop=0
reason=Spiel-Update
msg_now=Now — {reason}
EOF

bash "$WORKER" "$JDIR" "$GAME_USER" "$SERVER_DIR" pzserver "$MODULE_ROOT"
grep -qx 'ok' "$JDIR/status" || { echo "need_game=1: status not ok"; exit 1; }
grep -q '^stop$' "$STOP_LOG" || { echo "need_game=1: stop missing"; exit 1; }
grep -q '^update$' "$UPDATE_LOG" || { echo "need_game=1: update missing"; exit 1; }
grep -q '^start$' "$START_LOG" || { echo "need_game=1: start missing"; exit 1; }
grep -q '^pending=0' "$SERVER_DIR/.monitor/auto_update" || { echo "need_game=1: pending not cleared"; exit 1; }

# --- failure: stop fails → pending=0 + mark_ready ---------------------------
: >"$STOP_LOG" ; : >"$UPDATE_LOG" ; : >"$START_LOG" ; : >"$READY_LOG"
export AUTO_UPDATE_STOP_CMD='echo stop >>'"$STOP_LOG"'; exit 1'
JDIR="$(_make_job cccccccccccccccc)"
_write_state <<'EOF'
enabled=1
pending=1
countdown_deadline=99
need_game=1
need_workshop=1
reason=Spiel-Update
EOF

set +e
bash "$WORKER" "$JDIR" "$GAME_USER" "$SERVER_DIR" pzserver "$MODULE_ROOT"
_rc=$?
set -e
[[ "$_rc" -ne 0 ]] || { echo "failure path: worker should exit non-zero"; exit 1; }
grep -qx 'failed' "$JDIR/status" || { echo "failure path: status not failed"; exit 1; }
grep -q '^pending=0' "$SERVER_DIR/.monitor/auto_update" || { echo "failure path: pending not cleared"; exit 1; }
grep -q '^need_game=0' "$SERVER_DIR/.monitor/auto_update" || { echo "failure path: need_game not cleared"; exit 1; }
grep -q '^countdown_deadline=0' "$SERVER_DIR/.monitor/auto_update" || { echo "failure path: countdown not cleared"; exit 1; }
grep -q '^ready$' "$READY_LOG" || { echo "failure path: mark_ready missing"; exit 1; }
[[ ! -s "$UPDATE_LOG" ]] || { echo "failure path: update must not run after stop fail"; exit 1; }

# restore stop mock
export AUTO_UPDATE_STOP_CMD='echo stop >>'"$STOP_LOG"

# --- failure: stop ok + update fails → pending=0 + mark_ready ---------------
: >"$STOP_LOG" ; : >"$UPDATE_LOG" ; : >"$START_LOG" ; : >"$READY_LOG"
export AUTO_UPDATE_UPDATE_CMD='echo update >>'"$UPDATE_LOG"'; exit 1'
JDIR="$(_make_job dddddddddddddddd)"
_write_state <<'EOF'
enabled=1
pending=1
countdown_deadline=88
need_game=1
need_workshop=1
reason=Spiel-Update
EOF

set +e
bash "$WORKER" "$JDIR" "$GAME_USER" "$SERVER_DIR" pzserver "$MODULE_ROOT"
_rc=$?
set -e
[[ "$_rc" -ne 0 ]] || { echo "update-fail: worker should exit non-zero"; exit 1; }
grep -qx 'failed' "$JDIR/status" || { echo "update-fail: status not failed"; exit 1; }
grep -q '^stop$' "$STOP_LOG" || { echo "update-fail: stop missing"; exit 1; }
grep -q '^update$' "$UPDATE_LOG" || { echo "update-fail: update missing"; exit 1; }
[[ ! -s "$START_LOG" ]] || { echo "update-fail: start must not run after update fail"; exit 1; }
grep -q '^pending=0' "$SERVER_DIR/.monitor/auto_update" || { echo "update-fail: pending not cleared"; exit 1; }
grep -q '^need_game=0' "$SERVER_DIR/.monitor/auto_update" || { echo "update-fail: need_game not cleared"; exit 1; }
grep -q '^need_workshop=0' "$SERVER_DIR/.monitor/auto_update" || { echo "update-fail: need_workshop not cleared"; exit 1; }
grep -q '^countdown_deadline=0' "$SERVER_DIR/.monitor/auto_update" || { echo "update-fail: countdown not cleared"; exit 1; }
grep -q '^ready$' "$READY_LOG" || { echo "update-fail: mark_ready missing"; exit 1; }

# restore update mock
export AUTO_UPDATE_UPDATE_CMD='echo update >>'"$UPDATE_LOG"

# --- failure: stop ok + start fails → pending=0 + mark_ready ----------------
: >"$STOP_LOG" ; : >"$UPDATE_LOG" ; : >"$START_LOG" ; : >"$READY_LOG"
export AUTO_UPDATE_START_CMD='echo start >>'"$START_LOG"'; exit 1'
JDIR="$(_make_job eeeeeeeeeeeeeeee)"
_write_state <<'EOF'
enabled=1
pending=1
countdown_deadline=77
need_game=0
need_workshop=1
reason=Workshop-Update
EOF

set +e
bash "$WORKER" "$JDIR" "$GAME_USER" "$SERVER_DIR" pzserver "$MODULE_ROOT"
_rc=$?
set -e
[[ "$_rc" -ne 0 ]] || { echo "start-fail: worker should exit non-zero"; exit 1; }
grep -qx 'failed' "$JDIR/status" || { echo "start-fail: status not failed"; exit 1; }
grep -q '^stop$' "$STOP_LOG" || { echo "start-fail: stop missing"; exit 1; }
[[ ! -s "$UPDATE_LOG" ]] || { echo "start-fail: update must not run (need_game=0)"; exit 1; }
grep -q '^start$' "$START_LOG" || { echo "start-fail: start missing"; exit 1; }
grep -q '^pending=0' "$SERVER_DIR/.monitor/auto_update" || { echo "start-fail: pending not cleared"; exit 1; }
grep -q '^need_game=0' "$SERVER_DIR/.monitor/auto_update" || { echo "start-fail: need_game not cleared"; exit 1; }
grep -q '^need_workshop=0' "$SERVER_DIR/.monitor/auto_update" || { echo "start-fail: need_workshop not cleared"; exit 1; }
grep -q '^countdown_deadline=0' "$SERVER_DIR/.monitor/auto_update" || { echo "start-fail: countdown not cleared"; exit 1; }
grep -q '^ready$' "$READY_LOG" || { echo "start-fail: mark_ready missing"; exit 1; }

# restore start mock
export AUTO_UPDATE_START_CMD='echo start >>'"$START_LOG"

# --- launcher: job dir + pending_job_ids + last_restart_job + worker --------
: >"$STOP_LOG" ; : >"$UPDATE_LOG" ; : >"$START_LOG" ; : >"$READY_LOG" ; : >"$BROADCAST_LOG"
rm -f "$SERVER_DIR/.monitor/pending_job_ids"
_write_state <<'EOF'
enabled=1
pending=1
countdown_deadline=0
need_game=0
need_workshop=1
reason=Workshop-Update
msg_now=Now — {reason}
EOF

JID="$(
    perl -I"$MODULE_ROOT/lib" -e '
        require "auto_update.pl";
        my $jid = auto_update_launch_restart_job(@ARGV);
        die "empty job id\n" if $jid eq "";
        print "$jid\n";
    ' "pz_test" "$SERVER_DIR" "pzserver" "$GAME_USER" "$MODULE_ROOT"
)"
[[ "$JID" =~ ^[0-9a-f]{16}$ ]] || { echo "launcher: bad job id '$JID'"; exit 1; }
[[ -d "$JOBS_HOME/jobs/$JID" ]] || { echo "launcher: job dir missing"; exit 1; }
grep -q '^action=auto_update_restart$' "$JOBS_HOME/jobs/$JID/meta" \
    || { echo "launcher: wrong meta action"; exit 1; }
grep -qx "$JID" "$SERVER_DIR/.monitor/pending_job_ids" \
    || { echo "launcher: pending_job_ids missing id"; exit 1; }
grep -q "^last_restart_job=$JID$" "$SERVER_DIR/.monitor/auto_update" \
    || { echo "launcher: last_restart_job not set"; exit 1; }

# Wait for background worker
for _i in $(seq 1 50); do
    _st="$(tr -d '[:space:]' <"$JOBS_HOME/jobs/$JID/status" 2>/dev/null || true)"
    [[ "$_st" == "ok" || "$_st" == "failed" ]] && break
    sleep 0.1
done
grep -qx 'ok' "$JOBS_HOME/jobs/$JID/status" || { echo "launcher: worker did not finish ok"; exit 1; }
grep -q '^stop$' "$STOP_LOG" || { echo "launcher: worker stop missing"; exit 1; }
grep -q '^start$' "$START_LOG" || { echo "launcher: worker start missing"; exit 1; }
grep -q '^pending=0' "$SERVER_DIR/.monitor/auto_update" || { echo "launcher: pending not cleared by worker"; exit 1; }

echo "ok test_auto_update_restart.sh"
