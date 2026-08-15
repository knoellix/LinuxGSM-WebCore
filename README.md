# LinuxGSM-WebCore

Webmin module (`.wbm`) for provisioning and managing [LinuxGSM](https://linuxgsm.com/), SteamCMD, and Wine game servers from a browser.

**Wiki:** [GitHub Wiki](https://github.com/knoellix/LinuxGSM-WebCore/wiki) (DE + EN)

## Project status

This project is maintained **solo by [knoellix](https://github.com/knoellix)**. It started because I needed it for my own servers — not as a polished product with a roadmap.

- There is **no fixed timeline** and no promise of feature completeness.
- Not everything works perfectly yet; some games are only scaffolded in metadata.
- I have used and extended it for real workloads (especially **Minecraft** and **Palworld**; also **Windrose**/SteamCMD).
- **Pushes and pull requests are welcome.** Please read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

## Features

- Provision instances (dedicated Unix users, `/usr/sbin/nologin`, LGSM under `/home/{user}/{server}/`)
- Start / stop / restart / update / validate via background jobs and live log
- Minecraft: loaders, Java per instance, dedicated **Mods page** (`mods.cgi`) — installed list, enable/disable, version picker, search/install, modpack import (Modrinth / CurseForge / Hangar)
- Monitoring (LGSM-native + SteamCMD/Wine paths) and scheduled restarts
- SFTP (chrooted), firewall helpers, integrations (Steam accounts, download API keys)
- Config editor for LGSM and game configs (with path validation)

See [CHANGELOG.md](CHANGELOG.md) for release notes.

## Requirements

- Linux with Webmin
- Perl, Bash, curl
- Root for install / provisioning (runtime game ops run as the game user)

## Installation

```bash
sudo bash <(curl -sL https://github.com/knoellix/LinuxGSM-WebCore/releases/latest/download/install.sh)
```

Webmin must already be installed. See the [wiki](https://github.com/knoellix/LinuxGSM-WebCore/wiki) for details.

### Manual `.wbm` install

1. Build or download `linuxgsm-webcore-*.wbm`
2. Webmin → Webmin Configuration → Webmin Modules → install from local file

### Development build

```bash
bash scripts/verify.sh
bash scripts/build.sh
```

## Security (short)

- Game binaries never run as root; Webmin dispatches via privilege drop to the game user
- Config writes never target LGSM `_default.cfg`
- Inputs sanitized / HTML escaped; see wiki **Security**

## License

MIT
