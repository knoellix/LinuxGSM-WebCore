#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS+1)); }
fail() { echo "not ok - $1"; FAIL=$((FAIL+1)); }

cd "$REPO_ROOT"
VERSION=$(grep '^version=' src/module.info | cut -d= -f2)

# Test 1: build.sh existiert
[ -f "scripts/build.sh" ] && pass "build.sh exists" || fail "build.sh exists"

# Test 2: .wbm wird erzeugt
bash scripts/build.sh > /dev/null 2>&1 || true
[ -f "dist/linuxgsm-webcore-${VERSION}.wbm" ] && pass ".wbm exists" || fail ".wbm exists"

# Test 3: .wbm ist gültiges tar.gz
tar tzf "dist/linuxgsm-webcore-${VERSION}.wbm" > /dev/null 2>&1 && pass ".wbm is valid tar.gz" || fail ".wbm is valid tar.gz"

# Test 4: .wbm enthält module.info
tar tzf "dist/linuxgsm-webcore-${VERSION}.wbm" | grep -q "linuxgsm-webcore/module.info" \
    && pass ".wbm contains module.info" || fail ".wbm contains module.info"

# Test 5: .wbm enthält index.cgi
tar tzf "dist/linuxgsm-webcore-${VERSION}.wbm" | grep -q "linuxgsm-webcore/index.cgi" \
    && pass ".wbm contains index.cgi" || fail ".wbm contains index.cgi"

# Test 6: install.sh wird erzeugt
[ -f "dist/install.sh" ] && pass "install.sh exists" || fail "install.sh exists"

# Test 7: install.sh ist executable
[ -x "dist/install.sh" ] && pass "install.sh is executable" || fail "install.sh is executable"

# Test 8: install.sh enthält korrekte Version
grep -q "VERSION=\"${VERSION}\"" "dist/install.sh" \
    && pass "install.sh has correct version" || fail "install.sh has correct version"

# Test 9: install.sh enthält korrekte Download-URL
grep -q "knoellix/LinuxGSM-WebCore/releases/download/v${VERSION}" "dist/install.sh" \
    && pass "install.sh has correct download URL" || fail "install.sh has correct download URL"

# Test 10: Tag-Mismatch bricht ab
TAG="v999.0.0" bash scripts/build.sh > /dev/null 2>&1 \
    && fail "tag mismatch should abort" || pass "tag mismatch aborts correctly"

# Test 11: tmp/ wird aufgeräumt
[ ! -d "tmp" ] && pass "tmp/ cleaned up" || fail "tmp/ cleaned up"

echo ""
echo "1..$((PASS+FAIL))"
echo "# Passed: $PASS, Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
