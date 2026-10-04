#!/usr/bin/env bash
# auto_update_check_user.sh: detect → pending / countdown / restart launcher (mocked).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_ROOT="$ROOT/src"
WORKER="$MODULE_ROOT/scripts/auto_update_check_user.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GAME_USER="$(id -un)"
SERVER_DIR="$TMP/pz-1"
JOBS_HOME="$TMP/home/$GAME_USER"
export HOME="$JOBS_HOME"
mkdir -p "$SERVER_DIR/logs" "$SERVER_DIR/.monitor" "$JOBS_HOME"

LAUNCH_MARKER="$SERVER_DIR/.monitor/.auto_update_restart_launch"
BROADCAST_LOG="$TMP/broadcast.log"
: >"$BROADCAST_LOG"

# Isolate check logic from real restart job launch (Task 4).
MOCK_LAUNCHER="$TMP/mock_restart_launcher.sh"
cat >"$MOCK_LAUNCHER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Args: instance_id kind server_dir script_name module_root
mkdir -p "$3/.monitor"
date +%s >>"$3/.monitor/.auto_update_restart_launch"
EOF
chmod +x "$MOCK_LAUNCHER"

export AUTO_UPDATE_ADAPTER_CMD='exit 0'
export AUTO_UPDATE_BROADCAST_CMD='echo "$1" >>'"$BROADCAST_LOG"
export AUTO_UPDATE_RESTART_LAUNCHER="$MOCK_LAUNCHER"

_write_state() {
    cat >"$SERVER_DIR/.monitor/auto_update"
}

# --- players 0 + update → restart launcher (mock marker) --------------------
_write_state <<'EOF'
enabled=1
check_game=1
check_workshop=1
interval_min=5
warn_minutes=15,10,5,1,0
pending=0
countdown_deadline=0
EOF

export AUTO_UPDATE_DETECT_CMD="NEED_GAME=1
NEED_WORKSHOP=0
MODS=''
PLAYERS=0
REASON='Spiel-Update'
"

bash "$WORKER" "pz_test" lgsm "$SERVER_DIR" pzserver "$MODULE_ROOT" >/dev/null
[[ -f "$LAUNCH_MARKER" ]] || { echo "missing restart launch marker"; exit 1; }
grep -q '^pending=1' "$SERVER_DIR/.monitor/auto_update" || { echo "pending not set"; exit 1; }

# --- players >0 → countdown, no second deadline on re-run ---------------------
rm -f "$LAUNCH_MARKER"
_write_state <<'EOF'
enabled=1
check_game=1
check_workshop=1
interval_min=5
warn_minutes=15,10,5,1,0
pending=0
countdown_deadline=0
EOF

export AUTO_UPDATE_DETECT_CMD="NEED_GAME=1
NEED_WORKSHOP=0
MODS=''
PLAYERS=3
REASON='Spiel-Update'
"

bash "$WORKER" "pz_test" lgsm "$SERVER_DIR" pzserver "$MODULE_ROOT" >/dev/null
deadline1="$(grep '^countdown_deadline=' "$SERVER_DIR/.monitor/auto_update" | cut -d= -f2-)"
[[ "$deadline1" =~ ^[0-9]+$ && "$deadline1" -gt 0 ]] || { echo "no countdown deadline"; exit 1; }
[[ ! -f "$LAUNCH_MARKER" ]] || { echo "restart launched during countdown start"; exit 1; }

# Second run: still pending update, countdown must not reset
sed -i 's/^last_check=.*/last_check=0/' "$SERVER_DIR/.monitor/auto_update"
bash "$WORKER" "pz_test" lgsm "$SERVER_DIR" pzserver "$MODULE_ROOT" >/dev/null
deadline2="$(grep '^countdown_deadline=' "$SERVER_DIR/.monitor/auto_update" | cut -d= -f2-)"
[[ "$deadline2" == "$deadline1" ]] || { echo "countdown deadline changed on second run ($deadline1 -> $deadline2)"; exit 1; }

# --- PLAYERS=-1 (unknown) → countdown, not immediate restart ----------------
rm -f "$LAUNCH_MARKER"
_write_state <<'EOF'
enabled=1
check_game=1
check_workshop=1
interval_min=5
pending=0
countdown_deadline=0
EOF

export AUTO_UPDATE_DETECT_CMD="NEED_GAME=1
NEED_WORKSHOP=0
MODS=''
PLAYERS=-1
REASON='Spiel-Update'
"

bash "$WORKER" "pz_test" lgsm "$SERVER_DIR" pzserver "$MODULE_ROOT" >/dev/null
[[ ! -f "$LAUNCH_MARKER" ]] || { echo "restart launched on PLAYERS=-1"; exit 1; }
grep -qE '^countdown_deadline=[1-9]' "$SERVER_DIR/.monitor/auto_update" \
    || { echo "no countdown on PLAYERS=-1"; exit 1; }

# --- ERR-only with no need_* → no restart -----------------------------------
rm -f "$LAUNCH_MARKER"
_write_state <<'EOF'
enabled=1
check_game=1
check_workshop=1
interval_min=5
pending=0
countdown_deadline=0
EOF

export AUTO_UPDATE_DETECT_CMD="NEED_GAME=0
NEED_WORKSHOP=0
MODS=''
PLAYERS=0
REASON=''
ERR='game:steam_api_fail'
"

bash "$WORKER" "pz_test" lgsm "$SERVER_DIR" pzserver "$MODULE_ROOT" >/dev/null
[[ ! -f "$LAUNCH_MARKER" ]] || { echo "restart launched on ERR-only detect"; exit 1; }
grep -q '^last_check=' "$SERVER_DIR/.monitor/auto_update" || { echo "last_check not updated on ERR"; exit 1; }

# --- job running → skip action, keep pending --------------------------------
rm -f "$LAUNCH_MARKER"
_write_state <<'EOF'
enabled=1
check_game=1
check_workshop=1
interval_min=5
pending=1
need_game=1
countdown_deadline=0
EOF

JOB_ID="abcd1234abcd1234"
mkdir -p "$JOBS_HOME/jobs/$JOB_ID"
printf 'running\n' >"$JOBS_HOME/jobs/$JOB_ID/status"
printf 'instance_id=pz_test\naction=start\n' >"$JOBS_HOME/jobs/$JOB_ID/meta"

export AUTO_UPDATE_DETECT_CMD="NEED_GAME=1
NEED_WORKSHOP=0
PLAYERS=0
REASON='Spiel-Update'
"

bash "$WORKER" "pz_test" lgsm "$SERVER_DIR" pzserver "$MODULE_ROOT" >/dev/null
[[ ! -f "$LAUNCH_MARKER" ]] || { echo "restart launched while job running"; exit 1; }
grep -q '^pending=1' "$SERVER_DIR/.monitor/auto_update" || { echo "pending cleared while job running"; exit 1; }

# --- I1: PLAYERS=0 mid-countdown → immediate restart -----------------------
rm -f "$LAUNCH_MARKER" "$JOBS_HOME/jobs/$JOB_ID/status"
rm -rf "$JOBS_HOME/jobs/$JOB_ID"
: >"$BROADCAST_LOG"
_now="$(date +%s)"
_deadline=$((_now + 900))
_write_state <<EOF
enabled=1
check_game=1
check_workshop=1
interval_min=5
warn_minutes=15,10,5,1,0
pending=1
need_game=1
countdown_deadline=$_deadline
msg_sent=15
last_check=0
EOF

export AUTO_UPDATE_DETECT_CMD="NEED_GAME=1
NEED_WORKSHOP=0
MODS=''
PLAYERS=0
REASON='Spiel-Update'
"

bash "$WORKER" "pz_test" lgsm "$SERVER_DIR" pzserver "$MODULE_ROOT" >/dev/null
[[ -f "$LAUNCH_MARKER" ]] || { echo "I1: restart not launched when players=0 mid-countdown"; exit 1; }

# --- I2a: just after countdown start → only max warn minute broadcast ------
rm -f "$LAUNCH_MARKER"
: >"$BROADCAST_LOG"
_write_state <<'EOF'
enabled=1
check_game=1
check_workshop=1
interval_min=5
warn_minutes=15,10,5,1,0
pending=0
countdown_deadline=0
EOF

export AUTO_UPDATE_DETECT_CMD="NEED_GAME=1
NEED_WORKSHOP=0
MODS=''
PLAYERS=3
REASON='Spiel-Update'
"

bash "$WORKER" "pz_test" lgsm "$SERVER_DIR" pzserver "$MODULE_ROOT" >/dev/null
[[ ! -f "$LAUNCH_MARKER" ]] || { echo "I2a: restart launched at countdown start"; exit 1; }
grep -qE '^countdown_deadline=[1-9]' "$SERVER_DIR/.monitor/auto_update" \
    || { echo "I2a: no deadline"; exit 1; }
bc_count="$(wc -l <"$BROADCAST_LOG" | tr -d ' ')"
[[ "$bc_count" == "1" ]] || { echo "I2a: expected 1 broadcast, got $bc_count"; exit 1; }
grep -qE ' in 15 Min' "$BROADCAST_LOG" || { echo "I2a: max warn minute not broadcast"; exit 1; }
# Avoid substring false positives (e.g. "5 Min" inside "15 Min").
grep -qE ' in 10 Min| in 5 Min| in 1 Min|jetzt' "$BROADCAST_LOG" \
    && { echo "I2a: unexpected extra warn minutes broadcast"; exit 1; }
grep -q '^msg_sent=15$' "$SERVER_DIR/.monitor/auto_update" \
    || { echo "I2a: msg_sent should be only 15"; exit 1; }

# --- I2b: past deadline → launcher called ----------------------------------
rm -f "$LAUNCH_MARKER"
: >"$BROADCAST_LOG"
_write_state <<'EOF'
enabled=1
check_game=1
check_workshop=1
interval_min=5
warn_minutes=15,10,5,1,0
pending=1
need_game=1
countdown_deadline=1
msg_sent=15,10,5,1,0
last_check=0
EOF

export AUTO_UPDATE_DETECT_CMD="NEED_GAME=1
NEED_WORKSHOP=0
MODS=''
PLAYERS=3
REASON='Spiel-Update'
"

bash "$WORKER" "pz_test" lgsm "$SERVER_DIR" pzserver "$MODULE_ROOT" >/dev/null
[[ -f "$LAUNCH_MARKER" ]] || { echo "I2b: restart not launched past deadline"; exit 1; }

# --- regression: state merge must not corrupt {placeholder} templates ------
# Bash ${var:-…{reason}} closes at the first "}" and used to append leftovers
# on every countdown tick.
TPL_OK='Server-Neustart in {minutes} Min — {reason} {mods}'
NOW_OK='Server startet jetzt neu — {reason}'
_deadline=$(( $(date +%s) + 900 ))
_write_state <<EOF
enabled=1
check_game=1
check_workshop=1
interval_min=5
warn_minutes=15,10,5,1,0
msg_template=$TPL_OK
msg_now=$NOW_OK
pending=1
need_game=1
countdown_deadline=$_deadline
msg_sent=15
last_check=$(date +%s)
EOF

export AUTO_UPDATE_DETECT_CMD="NEED_GAME=1
NEED_WORKSHOP=0
MODS='1'
PLAYERS=3
REASON='Spiel-Update'
"
rm -f "$LAUNCH_MARKER"
for _i in 1 2 3 4 5; do
    bash "$WORKER" "pz_test" lgsm "$SERVER_DIR" pzserver "$MODULE_ROOT" >/dev/null
done
_got_tpl="$(grep '^msg_template=' "$SERVER_DIR/.monitor/auto_update" | cut -d= -f2-)"
_got_now="$(grep '^msg_now=' "$SERVER_DIR/.monitor/auto_update" | cut -d= -f2-)"
[[ "$_got_tpl" == "$TPL_OK" ]] || {
    echo "template corrupted after merges: [$_got_tpl]"; exit 1
}
[[ "$_got_now" == "$NOW_OK" ]] || {
    echo "msg_now corrupted after merges: [$_got_now]"; exit 1
}

echo "ok test_auto_update_check.sh"
