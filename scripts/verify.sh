#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[verify] perl syntax checks"
for file in src/*.cgi src/lib/*.pl t/*.pl; do
  [ -f "$file" ] || continue
  perl -I. -c "$file" >/dev/null
  echo "  ok  $file"
done

echo "[verify] critical regression tests"
critical_tests=(
  "t/test_sanitize.pl"
  "t/test_run_action.pl"
  "t/test_security_guards.pl"
  "t/test_provisioning_flow.pl"
)
for test_file in "${critical_tests[@]}"; do
  [ -f "$test_file" ] || continue
  perl "$test_file"
done

echo "[verify] completed"
