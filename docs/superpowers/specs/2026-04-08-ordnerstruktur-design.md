# Design: Ordnerstruktur LinuxGSM-WebCore

**Datum:** 2026-04-08  
**Status:** Abgesegnet

## Kontext

LinuxGSM-WebCore ist ein Webmin-Plugin zur Verwaltung von Game-Servern via LinuxGSM. Backend: Perl. Interaktion mit LGSM: Bash. UI-Sprache: Deutsch (Englisch als Webmin-Fallback). Ziel-Paketformate: `.deb` (Debian/Ubuntu) und `.rpm` (AlmaLinux/Rocky Linux/Fedora).

## Entscheidungen

- **Entwicklungsstruktur statt flacher Webmin-Struktur**: `src/` enthält den Plugin-Code; Packaging-Scripts deployen nach `/usr/share/webmin/linuxgsm-webcore/`.
- **Modulare `lib/`-Aufteilung** (Option B): Jede Aufgabe hat eine eigene Perl-Datei. CGI-Dateien liegen im Root von `src/` wie von Webmin erwartet.
- **Dual-Packaging**: `packaging/debian/` und `packaging/rpm/` von Anfang an eingeplant.
- **Zwei Sprachdateien**: `lang/en` (Webmin-Fallback) und `lang/de` (primäre UI-Sprache).

## Ordnerstruktur

```
LinuxGSM-WebCore/
├── CLAUDE.md
├── README.md
│
├── src/                              # Plugin-Quellcode
│   ├── module.info                   # Webmin-Modul-Metadaten (Name, Version, OS)
│   ├── index.cgi                     # Dashboard: Übersicht aller Server-Instanzen
│   ├── provision.cgi                 # Neuen Game-Server anlegen
│   ├── manage.cgi                    # Server verwalten (start/stop/restart/logs)
│   ├── config.cgi                    # Modul-Einstellungen
│   ├── lib/
│   │   ├── core.pl                   # Shared Helpers, Webmin-API-Wrapper
│   │   ├── instance.pl               # Instanz-Erkennung via /etc/passwd
│   │   ├── provision.pl              # User-Anlage, Port-Kollisionsprüfung, LGSM-Install
│   │   ├── firewall.pl               # ufw/iptables via Webmin-API
│   │   └── sftp.pl                   # SFTP-Only-User + SSH-Config (Chroot)
│   ├── scripts/
│   │   ├── install_lgsm.sh           # LGSM herunterladen & installieren
│   │   ├── server_control.sh         # start/stop/restart/monitor/update
│   │   └── engine_switch.sh          # Server-Executable tauschen (z.B. Vanilla → Paper)
│   ├── lang/
│   │   ├── en                        # Englische Basis-Texte (Webmin-Fallback)
│   │   └── de                        # Deutsche Übersetzungen (primäre UI-Sprache)
│   └── images/
│       └── icon.png                  # Modul-Icon für Webmin-Navigation
│
├── packaging/
│   ├── debian/
│   │   ├── control                   # Paket-Metadaten, Abhängigkeiten
│   │   ├── rules                     # Build-Regeln
│   │   ├── changelog                 # Debian-Changelog
│   │   ├── install                   # Mapping: src/ → /usr/share/webmin/linuxgsm-webcore/
│   │   └── postinst                  # Webmin nach Installation neu laden
│   └── rpm/
│       └── linuxgsm-webcore.spec     # RPM-Spec für AlmaLinux/Rocky/Fedora
│
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-04-08-ordnerstruktur-design.md
```

## Sicherheitsrelevante Invarianten (aus CLAUDE.md)

- Game-User erhalten `/usr/sbin/nologin` — kein direkter Shell-Login.
- Plugin führt Binaries niemals als `root` aus (`su -s /bin/bash -c ...`).
- Alle Eingaben werden in Bash-Scripts und Perl strikt sanitized.
- SFTP: Chroot auf Home-Verzeichnis, `internal-sftp` in SSH-Config.
