# Projekt: LinuxGSM-WebCore (Technical Manifest)

## 0. Advisor & Agent Workflow
- **Architect Mode (Advisor):** Vor jeder Code-Änderung erstellt der Agent einen `IMPLEMENTATION_PLAN.md`. Er prüft Abhängigkeiten und System-Ressourcen (Ports/User) via Superpowers.
- **Executor Mode (Skills):** Der Agent nutzt `system_logged` für Shell-Aktionen und validiert Perl-Code (`perl -c`) vor dem Speichern.
- **Verification:** Nach jeder Änderung wird ein Test-Stub in `t/` ausgeführt oder die Syntax-Integrität bestätigt.

## 1. System-Architektur & Sicherheit
- **Isolation:** Jede Instanz erhält einen eigenen System-User (Shell: `/usr/sbin/nologin`).
- **Privilege Separation:** Game-Binaries laufen via `su -s /bin/bash -c ...`. Niemals als `root`.
- **SFTP-Chroot:** Integration von `internal-sftp` in `/etc/ssh/sshd_config`. Separates SFTP-Passwort (kein Shell-Zugriff).
- **Firewall:** Automatische Freigabe via Webmin-Firewall-API (UFW/Iptables).

## 2. Webmin CGI-Standards & "Lessons Learned" (CRITICAL)
- **Namespace-Isolation:** Webmin führt CGIs in `package $modulename` aus. Funktionen sind NICHT automatisch verfügbar!
- **Header-Pflicht (Fix):** Jede Datei MUSS diese Reihenfolge einhalten, sonst crasht das Authentic Theme (ui_help fehlt):
    1. `do '../web-lib.pl';`
    2. `do '../ui-lib.pl';`
    3. `&init_config();`
- **Security-Boilerplate:**
    - `our (%text, %config, %in, %gconfig);` NACH den `require`-Zeilen — NICHT vorher, sonst schlägt `use strict` fehl.
    - `$gconfig{'charset'} = 'utf-8';` direkt nach der `our`-Deklaration für korrekte Umlaut-Darstellung.
    - `&ReadParse(\%in);` (Global verfügbar machen).
    - KEIN `check_referer()` — existiert in dieser Webmin-Version nicht (500-Fehler). CSRF-Schutz läuft über `ReadParse`.
    - `html_escape()` auf **alle** dynamischen Daten vor dem HTML-Output.
- **UI-Framework:** Ausschließlich `ui_*-Funktionen` nutzen. Keine hardcodierten Styles/Farben.

## 3. Kern-Logik (Backend & UI)
- **Instanz-Erkennung:** Identifikation via `/etc/passwd` und Suche nach `linuxgsm.sh` in `/home/`.
- **Provisionierung:** User-Anlage (Suffix-Support) -> Port-Check -> LGSM-Install -> Firewall-Entry.
- **Live-Konsole:** Echtzeit-Log-Streaming via `tail`-Simulation im Webmin-Interface.
- **Monitoring:** Integration in das Webmin-Status-Modul. 3-Stufen-Eskalation (Restart -> Mail).

## 4. Coding Style & Lokalisierung
- **Sprachen:** UI: **Deutsch**; Code/Kommentare: **Englisch**.
- **Dynamik:** Keine hartkodierten Pfade. Strikte Sanitisierung aller Inputs.
- **Atomarität:** Rollback-Logik bei Fehlern während der Installation oder User-Anlage.
- **Commit-Stil:** 
  1. Verwende meine lokale Git-Config als Haupt-Autor.
  2. Füge am Ende jeder Commit-Message folgende Zeile mit zwei Leerzeilen Abstand hinzu:
     
     Co-authored-by: Claude <claude-code@anthropic.com>

## 5. Test & Build System
- **Stubs:** `t/stubs.pl` definiert notwendige Webmin-Funktionen für Standalone-Tests.
- **Testing:** Bash-Tests nutzen `pass()`/`fail()` (TAP). Ausführung via `perl t/test_<name>.pl`.
- **Build:** `bash scripts/build.sh` erstellt `.wbm` Datei (Modul-Ordner an Tar-Wurzel).
- **Distro-Support:** `module.info` ohne `os_support=linux`, da dies die Installation auf Debian blockiert.

## 6. Projekt-Layout & Speicherorte
- **Wiki:** `/mnt/Lager/github/LinuxGSM-WebCore.wiki/` (Separates Repo).
- **Build-Artefakte:** `dist/` und `tmp/` sind gitignored.

## 14. Webmin ACL-Editor (acl_security.pl)
- **NICHT `acl_edit.cgi`:** Webmin's ACL-Editor nutzt ausschließlich `acl_security.pl` — `acl_edit.cgi` wird nie aufgerufen.
- **Zwei Pflicht-Funktionen:** `acl_security_form(\%maccess)` (gibt `ui_table_row`-Felder aus, Tabelle schon offen) und `acl_security_save(\%maccess, \%in)` (speichert POST-Werte).
- **Dritte Pflicht-Funktion:** `load_theme_library()` — wird von `edit_acl.cgi` vor `acl_security_form` aufgerufen, muss als leerer Stub definiert sein.
- **Namespace-Import:** `acl_security.pl` läuft via `foreign_require` in `package linuxgsm_webcore`. `BEGIN { push(@INC, ".."); } use WebminCore;` importiert alle `ui_*`-Funktionen in das aktuelle Package. Kein `main::` Präfix nötig.
- **Radio statt Checkbox:** ACL-Felder mit Ja/Nein nutzen `ui_radio('name', $val, [[1, $yes],[0, $no]])` — so wie andere Webmin-Module es machen.
- **Stale ACL-Files:** Wenn ein `.acl`/`.gacl`-File existiert (z.B. aus einem schlechten früheren Save), überschreibt es `defaultacl` auch wenn Keys fehlen. ACL-Funktionen deshalb mit `!defined($access{'key'}) ? 1 : $access{'key'}` absichern.

## 15. Webmin GitHub-Recherche
- **Bei Unsicherheit GitHub prüfen:** Wenn unklar ist wie ein Webmin-Mechanismus funktioniert, zuerst `webmin/webmin` auf GitHub durchsuchen. Echte Modul-Beispiele zeigen das korrekte Pattern.
- Besonders hilfreich: `acl/edit_acl.cgi` und `acl/save_acl.cgi` für den ACL-Editor-Flow, `net/acl_security.pl` als Referenz-Implementierung.

