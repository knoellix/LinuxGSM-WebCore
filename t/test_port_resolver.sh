#!/usr/bin/env bash
# t/test_port_resolver.sh — TAP-style tests for scripts/lib/ports.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS+1)); }
fail() { echo "not ok - $1 :: $2"; FAIL=$((FAIL+1)); }

# shellcheck source=../src/scripts/lib/ports.sh
. "$REPO_ROOT/src/scripts/lib/ports.sh"

mk_tmp() { mktemp -d; }

# --- 1: defaults when no cfg files exist
TD=$(mk_tmp)
SERVER_DIR="$TD"
INSTANCE_GAME_PORT=""; INSTANCE_QUERY_PORT=""; INSTANCE_BEACON_PORT=""
_resolve_instance_ports windrose
if [ "$INSTANCE_GAME_PORT" = "7777" ] && [ "$INSTANCE_QUERY_PORT" = "27015" ] && [ "$INSTANCE_BEACON_PORT" = "15000" ]; then
    pass "defaults applied when no cfg present"
else
    fail "defaults applied when no cfg present" "got game=$INSTANCE_GAME_PORT query=$INSTANCE_QUERY_PORT beacon=$INSTANCE_BEACON_PORT"
fi
rm -rf "$TD"

# --- 2: per-instance cfg overrides defaults
TD=$(mk_tmp)
SERVER_DIR="$TD"
mkdir -p "$TD/lgsm/config-lgsm/windrose"
cat > "$TD/lgsm/config-lgsm/windrose/windrose.cfg" <<EOF
# instance config
port="30020"
queryport="30021"
beaconport="30022"
EOF
INSTANCE_GAME_PORT=""; INSTANCE_QUERY_PORT=""; INSTANCE_BEACON_PORT=""
_resolve_instance_ports windrose
if [ "$INSTANCE_GAME_PORT" = "30020" ] && [ "$INSTANCE_QUERY_PORT" = "30021" ] && [ "$INSTANCE_BEACON_PORT" = "30022" ]; then
    pass "per-instance cfg wins over defaults"
else
    fail "per-instance cfg wins over defaults" "got game=$INSTANCE_GAME_PORT query=$INSTANCE_QUERY_PORT beacon=$INSTANCE_BEACON_PORT"
fi
rm -rf "$TD"

# --- 3: common.cfg used as fallback when instance cfg lacks the key
TD=$(mk_tmp)
SERVER_DIR="$TD"
mkdir -p "$TD/lgsm/config-lgsm/windrose"
cat > "$TD/lgsm/config-lgsm/common.cfg" <<EOF
queryport="40000"
EOF
cat > "$TD/lgsm/config-lgsm/windrose/windrose.cfg" <<EOF
port="30100"
EOF
INSTANCE_GAME_PORT=""; INSTANCE_QUERY_PORT=""; INSTANCE_BEACON_PORT=""
_resolve_instance_ports windrose
# port from instance, queryport from common.cfg, beaconport from default
if [ "$INSTANCE_GAME_PORT" = "30100" ] && [ "$INSTANCE_QUERY_PORT" = "40000" ] && [ "$INSTANCE_BEACON_PORT" = "15000" ]; then
    pass "common.cfg fills missing keys, default fills the rest"
else
    fail "common.cfg fills missing keys, default fills the rest" "got game=$INSTANCE_GAME_PORT query=$INSTANCE_QUERY_PORT beacon=$INSTANCE_BEACON_PORT"
fi
rm -rf "$TD"

# --- 4: trailing comments and unquoted values are accepted
TD=$(mk_tmp)
SERVER_DIR="$TD"
mkdir -p "$TD/lgsm/config-lgsm/windrose"
cat > "$TD/lgsm/config-lgsm/windrose/windrose.cfg" <<'EOF'
port=31000   # trailing comment
queryport=31001
beaconport='31002'
EOF
INSTANCE_GAME_PORT=""; INSTANCE_QUERY_PORT=""; INSTANCE_BEACON_PORT=""
_resolve_instance_ports windrose
if [ "$INSTANCE_GAME_PORT" = "31000" ] && [ "$INSTANCE_QUERY_PORT" = "31001" ] && [ "$INSTANCE_BEACON_PORT" = "31002" ]; then
    pass "unquoted/single-quoted values and trailing comments parsed"
else
    fail "unquoted/single-quoted values and trailing comments parsed" "got game=$INSTANCE_GAME_PORT query=$INSTANCE_QUERY_PORT beacon=$INSTANCE_BEACON_PORT"
fi
rm -rf "$TD"

# --- 5: malformed garbage falls back to default (defensive)
TD=$(mk_tmp)
SERVER_DIR="$TD"
mkdir -p "$TD/lgsm/config-lgsm/windrose"
cat > "$TD/lgsm/config-lgsm/windrose/windrose.cfg" <<'EOF'
port="abc"
queryport=""
EOF
INSTANCE_GAME_PORT=""; INSTANCE_QUERY_PORT=""; INSTANCE_BEACON_PORT=""
_resolve_instance_ports windrose
if [ "$INSTANCE_GAME_PORT" = "7777" ] && [ "$INSTANCE_QUERY_PORT" = "27015" ] && [ "$INSTANCE_BEACON_PORT" = "15000" ]; then
    pass "garbage cfg falls back to UE5 defaults"
else
    fail "garbage cfg falls back to UE5 defaults" "got game=$INSTANCE_GAME_PORT query=$INSTANCE_QUERY_PORT beacon=$INSTANCE_BEACON_PORT"
fi
rm -rf "$TD"

echo ""
echo "1..$((PASS+FAIL))"
echo "# Passed: $PASS, Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
