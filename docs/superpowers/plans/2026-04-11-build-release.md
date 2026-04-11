# Build & Release System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lokales Build-Script (`scripts/build.sh`) + GitHub Actions CI/Release, das bei `v*`-Tags eine `.wbm` + `install.sh` auf GitHub Releases veröffentlicht.

**Architecture:** `scripts/build.sh` liest die Version aus `src/module.info`, führt Tests aus, paketiert `src/` als `.wbm` (Webmin Module Archive = tar.gz) und generiert ein `install.sh`. Zwei GitHub Actions Workflows: CI (Tests bei jedem Push), Release (Build + GitHub Release bei Tags).

**Tech Stack:** Bash, Perl (Tests), GitHub Actions (`softprops/action-gh-release@v2`)

---

## Dateiübersicht

| Datei | Aktion |
|-------|--------|
| `t/test_build.sh` | Neu — Shell-Tests für build.sh |
| `scripts/build.sh` | Neu — Build-Script |
| `.gitignore` | Ändern — `dist/` und `tmp/` ergänzen |
| `.github/workflows/ci.yml` | Neu — CI Workflow |
| `.github/workflows/release.yml` | Neu — Release Workflow |

---

## Task 1: Failing Test für `scripts/build.sh`

**Files:**
- Create: `t/test_build.sh`

- [ ] **Schritt 1: Test-Datei anlegen**

```bash
cat > t/test_build.sh << 'EOF'
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
EOF
chmod +x t/test_build.sh
```

- [ ] **Schritt 2: Test ausführen — erwartet FAIL (build.sh fehlt noch)**

```bash
bash t/test_build.sh
```

Erwartetes Ergebnis: `not ok - build.sh exists` und weitere Fehler.

- [ ] **Schritt 3: Committen**

```bash
git add t/test_build.sh
git commit -m "test: failing test for build.sh"
```

---

## Task 2: `scripts/build.sh` implementieren

**Files:**
- Create: `scripts/build.sh`

- [ ] **Schritt 1: `scripts/` Verzeichnis und build.sh anlegen**

```bash
mkdir -p scripts
cat > scripts/build.sh << 'BUILDEOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Version aus src/module.info lesen
VERSION=$(grep '^version=' "$REPO_ROOT/src/module.info" | cut -d= -f2)
if [ -z "$VERSION" ]; then
    echo "ERROR: Could not read version from src/module.info" >&2
    exit 1
fi

# Tag-Versions-Prüfung (nur wenn $TAG gesetzt, z.B. in CI)
if [ -n "${TAG:-}" ]; then
    TAG_VERSION="${TAG#v}"
    if [ "$TAG_VERSION" != "$VERSION" ]; then
        echo "ERROR: Tag version ($TAG_VERSION) != module.info version ($VERSION)" >&2
        echo "Update src/module.info before tagging." >&2
        exit 1
    fi
fi

echo "==> Building linuxgsm-webcore v${VERSION}..."

# Tests ausführen
echo "==> Running tests..."
TEST_FAILED=0
while IFS= read -r -d '' test_file; do
    if ! perl "$test_file"; then
        TEST_FAILED=1
    fi
done < <(find "$REPO_ROOT/t" -name "test_*.pl" -print0 | sort -z)
if [ "$TEST_FAILED" -ne 0 ]; then
    echo "ERROR: Tests failed. Aborting build." >&2
    exit 1
fi

# Verzeichnisse vorbereiten
DIST_DIR="$REPO_ROOT/dist"
TMP_MODULE="$REPO_ROOT/tmp/linuxgsm-webcore"
rm -rf "$DIST_DIR" "$REPO_ROOT/tmp"
mkdir -p "$DIST_DIR" "$TMP_MODULE"

# src/ → tmp/linuxgsm-webcore/ kopieren
cp -r "$REPO_ROOT/src/." "$TMP_MODULE/"

# .wbm bauen (tar.gz mit Modul-Verzeichnis an der Wurzel)
WBM_FILE="$DIST_DIR/linuxgsm-webcore-${VERSION}.wbm"
tar czf "$WBM_FILE" -C "$REPO_ROOT/tmp" linuxgsm-webcore/
echo "==> Built: $WBM_FILE"

# install.sh generieren
INSTALL_SH="$DIST_DIR/install.sh"
cat > "$INSTALL_SH" << INSTALL_EOF
#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION}"
WBM_URL="https://github.com/knoellix/LinuxGSM-WebCore/releases/download/v\${VERSION}/linuxgsm-webcore-\${VERSION}.wbm"
TMP_WBM="/tmp/linuxgsm-webcore.wbm"

if [ "\$EUID" -ne 0 ]; then
    echo "ERROR: Root-Rechte erforderlich. Bitte als root ausführen:" >&2
    echo "  sudo bash <(curl -sL https://github.com/knoellix/LinuxGSM-WebCore/releases/latest/download/install.sh)" >&2
    exit 1
fi

if [ ! -d /usr/share/webmin ]; then
    echo "ERROR: Webmin nicht gefunden unter /usr/share/webmin." >&2
    echo "Bitte zuerst Webmin installieren: https://webmin.com/install/" >&2
    exit 1
fi

echo "Installiere LinuxGSM-WebCore v\${VERSION}..."
curl -sL "\$WBM_URL" -o "\$TMP_WBM"
perl /usr/share/webmin/install-module.pl "\$TMP_WBM"
rm -f "\$TMP_WBM"

if [ -f /etc/webmin/restart ]; then
    /etc/webmin/restart
fi

echo ""
echo "Fertig! LinuxGSM-WebCore v\${VERSION} installiert."
echo "Webmin → Server → LinuxGSM Game Server Manager"
INSTALL_EOF

chmod +x "$INSTALL_SH"
echo "==> Generated: $INSTALL_SH"

# tmp/ aufräumen
rm -rf "$REPO_ROOT/tmp"

echo "==> Build complete."
echo "    $WBM_FILE"
echo "    $INSTALL_SH"
BUILDEOF
chmod +x scripts/build.sh
```

- [ ] **Schritt 2: Tests ausführen — erwartet alle PASS**

```bash
bash t/test_build.sh
```

Erwartetes Ergebnis:
```
ok - build.sh exists
ok - .wbm exists
ok - .wbm is valid tar.gz
ok - .wbm contains module.info
ok - .wbm contains index.cgi
ok - install.sh exists
ok - install.sh is executable
ok - install.sh has correct version
ok - install.sh has correct download URL
ok - tag mismatch aborts correctly
ok - tmp/ cleaned up

1..11
# Passed: 11, Failed: 0
```

- [ ] **Schritt 3: Committen**

```bash
git add scripts/build.sh
git commit -m "feat: build.sh — tests, .wbm packaging, install.sh generation"
```

---

## Task 3: `.gitignore` aktualisieren

**Files:**
- Modify: `.gitignore`

- [ ] **Schritt 1: `dist/` und `tmp/` ergänzen**

Folgende Zeilen ans Ende von `.gitignore` anfügen:

```
# Build output
dist/
tmp/
```

- [ ] **Schritt 2: Prüfen**

```bash
git status
```

Erwartetes Ergebnis: `dist/` erscheint nicht in untracked files.

- [ ] **Schritt 3: Committen**

```bash
git add .gitignore
git commit -m "chore: ignore dist/ and tmp/ build output"
```

---

## Task 4: `.github/workflows/ci.yml`

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Schritt 1: Verzeichnis und Datei anlegen**

```bash
mkdir -p .github/workflows
```

Datei `.github/workflows/ci.yml` mit folgendem Inhalt anlegen:

```yaml
name: CI

on:
  push:
    branches: ["**"]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Run Perl unit tests
        run: find t/ -name "test_*.pl" | sort | xargs -I{} perl {}
```

- [ ] **Schritt 2: YAML-Syntax prüfen**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo "YAML OK"
```

Erwartetes Ergebnis: `YAML OK`

- [ ] **Schritt 3: Committen**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add CI workflow (tests on every push)"
```

---

## Task 5: `.github/workflows/release.yml`

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Schritt 1: Datei anlegen**

Datei `.github/workflows/release.yml` mit folgendem Inhalt anlegen:

```yaml
name: Release

on:
  push:
    tags:
      - "v*"

permissions:
  contents: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build artifacts
        run: TAG=${{ github.ref_name }} bash scripts/build.sh

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ github.ref_name }}
          name: "LinuxGSM-WebCore ${{ github.ref_name }}"
          body: |
            ## Installation

            ```bash
            sudo bash <(curl -sL https://github.com/knoellix/LinuxGSM-WebCore/releases/latest/download/install.sh)
            ```

            Voraussetzung: [Webmin](https://webmin.com/install/) muss installiert sein.
          files: |
            dist/linuxgsm-webcore-*.wbm
            dist/install.sh
```

- [ ] **Schritt 2: YAML-Syntax prüfen**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))" && echo "YAML OK"
```

Erwartetes Ergebnis: `YAML OK`

- [ ] **Schritt 3: Committen**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add Release workflow (build + publish on v* tags)"
```

---

## Task 6: README aktualisieren

**Files:**
- Modify: `README.md`

- [ ] **Schritt 1: Installation-Abschnitt durch One-Liner ersetzen**

Den bestehenden `## Installation`-Abschnitt in `README.md` ersetzen mit:

```markdown
## Installation

```bash
sudo bash <(curl -sL https://github.com/knoellix/LinuxGSM-WebCore/releases/latest/download/install.sh)
```

Voraussetzung: [Webmin](https://webmin.com/install/) muss installiert sein.

### Manuelle Installation (.wbm)

Das `.wbm`-Archiv kann auch direkt in Webmin installiert werden:
**Webmin → Webmin-Konfiguration → Webmin-Module → Von lokaler Datei installieren**
```

- [ ] **Schritt 2: Committen**

```bash
git add README.md
git commit -m "docs: update installation instructions with one-liner"
```
