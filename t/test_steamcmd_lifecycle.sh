#!/usr/bin/env bash
# Unit tests for SteamCMD/Windrose lifecycle twin (PID alive + R5.log ready).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../src/scripts/lib/lgsm_control.sh
. "$ROOT/src/scripts/lib/lgsm_control.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill "${_fake_pid:-}" 2>/dev/null || true' EXIT

export MODULE_ROOT="$ROOT/src"

# --- windrose meta dumps GenlandiaMulty ready ---
lgsm_lifecycle_eval_meta windrose \
    || { echo "fail: eval_meta windrose"; exit 1; }
echo "${WEBCORE_LC_READY_REGEX:-}" | grep -q 'GenlandiaMulty' \
    || { echo "fail: windrose READY_REGEX=${WEBCORE_LC_READY_REGEX:-}"; exit 1; }
[[ "${WEBCORE_LC_READY_LOG:-}" == "live_log" ]] \
    || { echo "fail: windrose READY_LOG=${WEBCORE_LC_READY_LOG:-}"; exit 1; }
[[ "${WEBCORE_LC_STOP_FORCE:-}" == "120" ]] \
    || { echo "fail: windrose STOP_FORCE=${WEBCORE_LC_STOP_FORCE:-}"; exit 1; }
[[ "${WEBCORE_LC_STOP_GRACE:-}" == "60" ]] \
    || { echo "fail: windrose STOP_GRACE=${WEBCORE_LC_STOP_GRACE:-}"; exit 1; }

# --- Temp R5.log + fake PID: wait_ready sees GenlandiaMulty ---
mkdir -p "$TMP/windrose/serverfiles/R5/Saved/Logs"
printf 'boot begin\n' >"$TMP/windrose/serverfiles/R5/Saved/Logs/R5.log"
printf '%s\n' "$TMP/windrose/serverfiles/R5/Saved/Logs/R5.log" >"$TMP/fake.pid"
sleep 90 &
_fake_pid=$!
printf '%s\n' "$_fake_pid" >"$TMP/windrose/run.pid"

(
    sleep 1
    printf 'Start preloading R5ServerLobby\n' \
        >>"$TMP/windrose/serverfiles/R5/Saved/Logs/R5.log"
    sleep 1
    printf 'Start preloading GenlandiaMulty\n' \
        >>"$TMP/windrose/serverfiles/R5/Saved/Logs/R5.log"
) &

wlog="$(lgsm_lifecycle_log_path "$TMP/windrose" windrose live_log)"
[[ "$wlog" == "$TMP/windrose/serverfiles/R5/Saved/Logs/R5.log" ]] \
    || { echo "fail: R5 log path: $wlog"; exit 1; }

export WEBCORE_LC_ALIVE_PID="$_fake_pid"
# Short stall so we do not hang if marker never appears
export WEBCORE_LC_STALL_SECS=60
export WEBCORE_LC_STALL_FAIL_SECS=90
set +e
out="$(lgsm_lifecycle_wait_ready "$TMP/windrose" windrose \
    "$wlog" 0 \
    "${WEBCORE_LC_READY_REGEX}" 20 0 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "fail: steamcmd ready wait rc=$rc: $out"; exit 1; }
echo "$out" | grep -q 'Ready: marker seen' \
    || { echo "fail: expected Ready marker for GenlandiaMulty: $out"; exit 1; }
echo "$out" | grep -qi 'session died' \
    && { echo "fail: must use PID alive, not session: $out"; exit 1; }

# --- Stop phase: saving match from R5.log chunk ---
chunk="$(mktemp)"
printf 'Saving world makebak...\n' >"$chunk"
phase="$(lgsm_lifecycle_detect_stop_phase "$chunk")"
rm -f "$chunk"
[[ "$phase" == "saving" ]] \
    || { echo "fail: expected stop phase saving, got '$phase'"; exit 1; }

# Clear first fake pid before cold-start case
kill "$_fake_pid" 2>/dev/null || true
wait "$_fake_pid" 2>/dev/null || true
_fake_pid=""

# --- Cold start: LIVE_LOG_REL set, R5 missing, server.log present → must NOT stick to server.log ---
mkdir -p "$TMP/cold/serverfiles/R5/Saved/Logs"
printf 'wrapper noise — no GenlandiaMulty here\n' >"$TMP/cold/server.log"
# Prefer path from meta (re-eval to restore LIVE_LOG_REL after any prior unset)
export MODULE_ROOT="$ROOT/src"
lgsm_lifecycle_eval_meta windrose || { echo "fail: re-eval windrose for cold start"; exit 1; }
[[ -n "${WEBCORE_LC_LIVE_LOG_REL:-}" ]] \
    || { echo "fail: LIVE_LOG_REL expected after eval_meta"; exit 1; }
# Preferred file absent → return 1 (do not fall through to server.log)
set +e
sticky="$(lgsm_lifecycle_log_path "$TMP/cold" windrose live_log 2>/dev/null)"
lprc=$?
set -e
[[ "$lprc" -ne 0 ]] \
    || { echo "fail: missing R5 must not resolve while LIVE_LOG_REL set (got $sticky)"; exit 1; }
echo "${sticky:-}" | grep -q 'server\.log' \
    && { echo "fail: sticky server.log when R5 missing: $sticky"; exit 1; }

sleep 90 &
_fake_pid=$!
export WEBCORE_LC_ALIVE_PID="$_fake_pid"
export WEBCORE_LC_STALL_SECS=30
export WEBCORE_LC_STALL_FAIL_SECS=60
# Mid-wait: create R5.log with GenlandiaMulty (simulates Wine/UE cold boot)
(
    sleep 2
    mkdir -p "$TMP/cold/serverfiles/R5/Saved/Logs"
    printf 'Start preloading GenlandiaMulty\n' \
        >"$TMP/cold/serverfiles/R5/Saved/Logs/R5.log"
) &
set +e
out="$(lgsm_lifecycle_wait_ready "$TMP/cold" windrose \
    "" 0 \
    "${WEBCORE_LC_READY_REGEX}" 18 0 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "fail: cold-start R5 mid-wait ready: $out"; exit 1; }
echo "$out" | grep -q 'Ready: marker seen' \
    || { echo "fail: cold-start expected Ready via R5: $out"; exit 1; }
echo "$out" | grep -q 'Watching log:.*R5\.log' \
    || { echo "fail: cold-start should switch to R5.log: $out"; exit 1; }
echo "$out" | grep -qi 'WARNING: no ready marker' \
    && { echo "fail: cold-start must not soft-timeout on server.log: $out"; exit 1; }

# Clear LC + fake pid
kill "$_fake_pid" 2>/dev/null || true
wait "$_fake_pid" 2>/dev/null || true
_fake_pid=""
unset WEBCORE_LC_ALIVE_PID WEBCORE_LC_READY_REGEX WEBCORE_LC_READY_LOG \
    WEBCORE_LC_READY_SECS WEBCORE_LC_STALL_SECS WEBCORE_LC_STALL_FAIL_SECS \
    WEBCORE_LC_STOP_GRACE WEBCORE_LC_STOP_FORCE WEBCORE_LC_LIVE_LOG_REL
unset MODULE_ROOT

# --- steamcmd_control_user.sh: restart must not soft-fail stop (|| true gone) ---
grep -n 'WEBCORE_SKIP_FINAL=1 bash "\$0" stop' \
    "$ROOT/src/scripts/steamcmd_control_user.sh" | grep -q '|| true' \
    && { echo "fail: restart still ignores stop failure via || true"; exit 1; }
grep -q 'restart aborted' "$ROOT/src/scripts/steamcmd_control_user.sh" \
    || { echo "fail: restart hard-gate message missing"; exit 1; }
grep -q 'WEBCORE_LC_ALIVE_PID' "$ROOT/src/scripts/steamcmd_control_user.sh" \
    || { echo "fail: steamcmd start must set WEBCORE_LC_ALIVE_PID"; exit 1; }
grep -q '_steamcmd_stop_grace_wait\|Stop: soft TERM' \
    "$ROOT/src/scripts/steamcmd_control_user.sh" \
    || { echo "fail: stop grace wiring missing"; exit 1; }
grep -q 'ready marker pending' "$ROOT/src/scripts/steamcmd_control_user.sh" \
    || { echo "fail: soft-ready wording missing"; exit 1; }

echo "ok test_steamcmd_lifecycle.sh"
