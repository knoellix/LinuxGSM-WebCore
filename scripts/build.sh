#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=lib/term_ui.sh
. "$SCRIPT_DIR/lib/term_ui.sh"

# Version aus src/module.info lesen
VERSION=$(grep '^version=' "$REPO_ROOT/src/module.info" | cut -d= -f2)
if [ -z "$VERSION" ]; then
    tui_error "Could not read version from src/module.info"
    exit 1
fi

# Tag-Versions-Prüfung (nur wenn $TAG gesetzt, z.B. in CI)
if [ -n "${TAG:-}" ]; then
    TAG_VERSION="${TAG#v}"
    if [ "$TAG_VERSION" != "$VERSION" ]; then
        tui_error "Tag version ($TAG_VERSION) != module.info version ($VERSION)"
        echo "Update src/module.info before tagging." >&2
        exit 1
    fi
fi

tui_step "Building linuxgsm-webcore v${VERSION}..."

# Tests ausführen (skip when already verified in CI, e.g. SKIP_TESTS=1)
if [ "${SKIP_TESTS:-0}" = "1" ]; then
    tui_step "Skipping tests (SKIP_TESTS=1)"
else
    tui_step "Running tests..."
    TEST_FAILED=0
    while IFS= read -r -d '' test_file; do
        if perl "$test_file" >/dev/null 2>&1; then
            tui_ok "$test_file"
        else
            tui_fail "$test_file"
            perl "$test_file" || true
            TEST_FAILED=1
        fi
    done < <(find "$REPO_ROOT/t" -name "test_*.pl" -print0 | sort -z)
    if [ "$TEST_FAILED" -ne 0 ]; then
        tui_error "Tests failed. Aborting build."
        exit 1
    fi
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
tui_ok "Built: $WBM_FILE"

# install.sh generieren
INSTALL_SH="$DIST_DIR/install.sh"
cat > "$INSTALL_SH" << INSTALL_EOF
#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION}"
WBM_URL="https://github.com/knoellix/LinuxGSM-WebCore/releases/download/v${VERSION}/linuxgsm-webcore-${VERSION}.wbm"
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
tui_ok "Generated: $INSTALL_SH"

# tmp/ aufräumen
rm -rf "$REPO_ROOT/tmp"

tui_done "Build complete."
echo "    $WBM_FILE"
echo "    $INSTALL_SH"
