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

echo "[verify] perl test suite"
for test_file in t/test_*.pl; do
  [ -f "$test_file" ] || continue
  perl "$test_file"
done

if [ -f "t/test_build.sh" ]; then
  echo "[verify] build smoke test"
  bash "t/test_build.sh"
fi

echo "[verify] completed"
