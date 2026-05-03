#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"
WBM_URL="https://github.com/knoellix/LinuxGSM-WebCore/releases/download/v0.1.0/linuxgsm-webcore-0.1.0.wbm"
TMP_WBM="/tmp/linuxgsm-webcore.wbm"

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Root-Rechte erforderlich. Bitte als root ausführen:" >&2
    echo "  sudo bash <(curl -sL https://github.com/knoellix/LinuxGSM-WebCore/releases/latest/download/install.sh)" >&2
    exit 1
fi

if [ ! -d /usr/share/webmin ]; then
    echo "ERROR: Webmin nicht gefunden unter /usr/share/webmin." >&2
    echo "Bitte zuerst Webmin installieren: https://webmin.com/install/" >&2
    exit 1
fi

echo "Installiere LinuxGSM-WebCore v${VERSION}..."
curl -sL "$WBM_URL" -o "$TMP_WBM"
perl /usr/share/webmin/install-module.pl "$TMP_WBM"
rm -f "$TMP_WBM"

if [ -f /etc/webmin/restart ]; then
    /etc/webmin/restart
fi

echo ""
echo "Fertig! LinuxGSM-WebCore v${VERSION} installiert."
echo "Webmin → Server → LinuxGSM Game Server Manager"
