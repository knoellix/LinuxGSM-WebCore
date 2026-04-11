# LinuxGSM-WebCore

A Webmin plugin for managing game servers via [LinuxGSM](https://linuxgsm.com/).

## Features

- Provision game server instances (isolated system users, no login shell)
- Start/Stop/Restart/Update via web UI
- SFTP-only file access (chrooted, separate password)
- Automatic firewall port management (ufw / iptables)
- Engine switching (e.g. Vanilla → Paper for Minecraft)

## Requirements

- Webmin
- Perl
- Bash
- curl

## Installation

```bash
sudo bash <(curl -sL https://github.com/knoellix/LinuxGSM-WebCore/releases/latest/download/install.sh)
```

Voraussetzung: [Webmin](https://webmin.com/install/) muss installiert sein.

### Manuelle Installation (.wbm)

Das `.wbm`-Archiv kann auch direkt in Webmin installiert werden:
**Webmin → Webmin-Konfiguration → Webmin-Module → Von lokaler Datei installieren**

## Development

Source lives in `src/`, deployed to `/usr/share/webmin/linuxgsm-webcore/` by the package.

## Security

- Game users get `/usr/sbin/nologin` — no SSH login possible
- Plugin never runs game binaries as `root`
- SFTP access is chrooted to the user's home directory
- All inputs are sanitized before shell execution

## License

MIT
