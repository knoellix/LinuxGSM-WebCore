#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=lib/term_ui.sh
. "$ROOT_DIR/scripts/lib/term_ui.sh"

tui_section "[verify] shell syntax checks"
for file in src/scripts/*.sh src/scripts/lib/*.sh scripts/lib/*.sh; do
  [ -f "$file" ] || continue
  bash -n "$file"
  tui_ok "$file"
done

tui_section "[verify] perl syntax checks"
for file in src/*.cgi src/lib/*.pl src/scripts/*.pl t/*.pl; do
  [ -f "$file" ] || continue
  if [[ "$(basename "$file")" == "joblogserver.pl" ]] && ! perl -MWebminCore -e1 2>/dev/null; then
    tui_skip "$file (requires Webmin runtime)"
    continue
  fi
  perl -I. -c "$file" >/dev/null 2>&1
  tui_ok "$file"
done

tui_section "[verify] embedded perl checks"
# bash -n does not validate perl -e '...' bodies inside shell workers.
# Bodies use double-quoted strings only (no escaped single quotes), so each
# block runs from `perl -e '` to the next single quote.
EMBED_TMP="$(mktemp -d)"
trap 'rm -rf "$EMBED_TMP"' EXIT
for file in src/scripts/*.sh; do
  [ -f "$file" ] || continue
  grep -q "perl -e '" "$file" || continue
  nblocks=$(perl -0777 -ne '
    my @parts = split /perl -e \x27/, $_;
    shift @parts;
    my $n = 0;
    for my $seg (@parts) {
      my ($code) = $seg =~ /^(.*?)\x27/s;
      next unless defined $code && $code =~ /\S/;
      $n++;
      open(my $fh, ">", "'"$EMBED_TMP"'/block.$n.pl") or next;
      print $fh $code;
      close $fh;
    }
    print $n;
  ' "$file")
  file_ok=1
  for i in $(seq 1 "${nblocks:-0}"); do
    if ! perl -c "$EMBED_TMP/block.$i.pl" >/dev/null 2>&1; then
      file_ok=0
      tui_fail "$file (embedded perl block $i)"
      perl -c "$EMBED_TMP/block.$i.pl" || true
    fi
    rm -f "$EMBED_TMP/block.$i.pl"
  done
  if [ "$file_ok" = 1 ]; then
    tui_ok "$file (embedded perl)"
  else
    exit 1
  fi
done

tui_section "[verify] critical regression tests"
critical_tests=(
  "t/test_sanitize.pl"
  "t/test_run_action.pl"
  "t/test_security_guards.pl"
  "t/test_provisioning_flow.pl"
  "t/test_mc_compat.pl"
  "t/test_mc_profile.pl"
  "t/test_instance_profile.pl"
  "t/test_mc_loader.pl"
  "t/test_instance_status.pl"
  "t/test_instance_lgsm.pl"
  "t/test_instance_connect.pl"
  "t/test_instance_memory.pl"
  "t/test_mc_mods.pl"
  "t/test_mc_modpack.pl"
  "t/test_monitor_state.pl"
  "t/test_monitor_cron.pl"
  "t/test_monitor_lgsm.sh"
  "t/test_schedule_cron.pl"
  "t/test_schedule_restart.sh"
  "t/test_job_log.sh"
  "t/test_user_native_workers.pl"
)
for test_file in "${critical_tests[@]}"; do
  [ -f "$test_file" ] || continue
  case "$test_file" in
    *.sh)
      if bash "$test_file" >/dev/null 2>&1; then
        tui_ok "$test_file"
      else
        tui_fail "$test_file"
        bash "$test_file" || true
        exit 1
      fi
      ;;
    *)
      if perl "$test_file" >/dev/null 2>&1; then
        tui_ok "$test_file"
      else
        tui_fail "$test_file"
        perl "$test_file" || true
        exit 1
      fi
      ;;
  esac
done

tui_done "[verify] completed"
