#!/usr/bin/env bash
# Smoke test for scripts/lib/job_log.sh init helpers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOB_LOG="$ROOT/src/scripts/lib/job_log.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=/dev/null
. "$JOB_LOG"

JOB_DIR="$TMP/job1"
mkdir -p "$JOB_DIR"
(
  job_log_init "$JOB_DIR" ""
  echo "root worker line"
) &
wait $! || true

grep -q "Job log started" "$JOB_DIR/output" || { echo "missing start banner"; exit 1; }
grep -q "root worker line" "$JOB_DIR/output" || { echo "output not captured"; exit 1; }

JOB_DIR2="$TMP/job2"
mkdir -p "$JOB_DIR2"
(
  job_log_init_as_user "$JOB_DIR2"
  echo "user worker line"
) &
wait $! || true

grep -q "user worker line" "$JOB_DIR2/output" || { echo "user output not captured"; exit 1; }

# job_log_line must appear before subshell exits (live poll during long network waits).
JOB_DIR3="$TMP/job3"
mkdir -p "$JOB_DIR3"
job_log_line "$JOB_DIR3" "immediate-line"
grep -q "immediate-line" "$JOB_DIR3/output" || { echo "job_log_line failed"; exit 1; }

echo "ok test_job_log.sh"
