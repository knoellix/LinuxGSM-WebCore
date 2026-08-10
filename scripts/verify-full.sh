#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=lib/term_ui.sh
. "$ROOT_DIR/scripts/lib/term_ui.sh"

tui_section "[verify-full] perl syntax checks"
for file in src/*.cgi src/lib/*.pl t/*.pl; do
  [ -f "$file" ] || continue
  perl -I. -c "$file" >/dev/null 2>&1
  tui_ok "$file"
done

tui_section "[verify-full] complete perl test suite"
for test_file in t/test_*.pl; do
  [ -f "$test_file" ] || continue
  if perl "$test_file" >/dev/null 2>&1; then
    tui_ok "$test_file"
  else
    tui_fail "$test_file"
    perl "$test_file" || true
    exit 1
  fi
done

if [ -f "t/test_port_resolver.sh" ]; then
  tui_section "[verify-full] bash port resolver test"
  if bash "t/test_port_resolver.sh" >/dev/null 2>&1; then
    tui_ok "t/test_port_resolver.sh"
  else
    tui_fail "t/test_port_resolver.sh"
    bash "t/test_port_resolver.sh" || true
    exit 1
  fi
fi

if [ -f "t/test_build.sh" ]; then
  tui_section "[verify-full] build smoke test"
  if bash "t/test_build.sh" >/dev/null 2>&1; then
    tui_ok "t/test_build.sh"
  else
    tui_fail "t/test_build.sh"
    bash "t/test_build.sh" || true
    exit 1
  fi
fi

tui_done "[verify-full] completed"
