# Projekt: LinuxGSM-WebCore
**Ziel:** Ein modulares Webmin-Plugin zur Verwaltung von Game-Servern via LinuxGSM (LGSM).

## 1. System-Architektur & Sicherheit (Golden Rules)
- **Native-First:** Es werden primär vorhandene Webmin-Funktionen und APIs genutzt (z.B. `useradmin`, `status`). Eigene Funktionen werden nur geschrieben, wenn Webmin keine Lösung bietet.
- **Isolation-First:** Jede Server-Instanz erhält einen eigenen System-User (z.B. `mc-survival`).
- **No-Shell Policy für Game-User:** Diese User erhalten `/usr/sbin/nologin` als Shell. Ein SSH-Login ist verboten.
- **Root-Sperre:** Das Plugin führt Game-Binaries niemals als `root` aus (Nutzung von `su -s /bin/bash -c ...`).
- **Modulare Struktur:** Webmin fungiert als GUI; die Logik liegt bei LinuxGSM.

## 2. Verhaltens-Codex & Integrität
- **Keine Halluzinationen:** Der Agent darf niemals Befehle oder Fakten erfinden.
- **Recherche-Pflicht:** Bei Unsicherheit MUSS das Web genutzt werden.
- **Ehrlichkeit:** Absolute Transparenz gegenüber dem Benutzer.

## 3. Tech-Stack & Lokalisierung
- **Sprachen:** Backend: Perl (WebminCore); Interaktion: Bash.
- **UI:** Deutsch; **Code/Kommentare:** Englisch.
- **Pfade:** Plugin unter `/usr/share/webmin/linuxgsm-webcore/`; Games unter `/home/[user]/`.

## 4. Kern-Logik (Backend)
- **Instanz-Erkennung:** Identifikation via `/etc/passwd`.
- **Provisionierung:** User-Anlage mit Suffix-Support, Port-Kollisionsprüfung und LGSM-Installation.
- **Engine-Switch:** Funktion zum Tausch von Server-Executables (z.B. Vanilla -> Paper).
- **Firewall:** Automatische Portfreigabe via `ufw` oder `iptables` (Webmin-API nutzen).

## 5. Datei-Zugriff & SFTP-Management
- **SFTP-Only User:** Jeder Game-User erhält ein separates Passwort NUR für SFTP.
- **Sicherheits-Konfiguration:** Integration von `internal-sftp` in die SSH-Config (Chroot auf Home-Verzeichnis).
- **GUI-Anzeige:** Host, Port, User und das separate SFTP-Passwort werden im Dashboard angezeigt.

## 6. UI & Dashboard (Frontend)
- **Smart-Connect:** DNS-Validierung für Wunsch-Domains (z.B. `play.knoellix.net`) mit Fallback auf die Server-IP.
- **Steuerungs-Zentrale:** Buttons für `start`, `stop`, `restart`, `monitor`, `update`.
- **Live-Konsole:** Log-Anzeige via `tail` im Webmin-Fenster.

## 7. Automatisierung & Selbstheilung (Monitoring)
- **Webmin-Monitor Integration:** Per Knopfdruck wird ein Eintrag im Webmin-Status-Modul erstellt.
- **Restart-Logik:** Automatischer Restart-Befehl (`su - [user] -c "./gameserver start"`) bei Downtime.
- **Eskalation:** Erst nach dem 3. fehlgeschlagenen Restart-Versuch erfolgt eine Benachrichtigung per E-Mail.
- **Cron-Jobs:** Verwaltung von Updates und LGSM-Checks via User-Crontabs.

## 8. Coding Style
- **Dynamik & Validierung:** Keine hartkodierten Pfade; strikte Sanitization aller Eingaben.
- **Atomarität:** Rollback-Logik bei Fehlern während der Installation.
