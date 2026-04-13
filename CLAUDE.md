# Projekt: LinuxGSM-WebCore (Technical Manifest)

Dieses Dokument trennt verbindliche Projektregeln (Policy) von Webmin-spezifischen Implementierungsdetails.

## 0. Ziel und Prioritaet
- Diese Regeln gelten fuer alle Agenten und Mitwirkenden in diesem Repository.
- Sicherheits- und Laufzeitstabilitaet haben Vorrang vor Komfort und Geschwindigkeit.
- Bei Konflikten gilt: User-Anweisung > Projektrichtlinie > Agent-Standardverhalten.

## 1. Agent-Workflow (verbindlich)
- **Architect Mode:** Vor jeder Code-Aenderung muss ein `IMPLEMENTATION_PLAN.md` erstellt oder aktualisiert werden.
- **Ressourcenpruefung:** Vor Provisionierungs- oder Service-Aenderungen Ports, User und Abhaengigkeiten pruefen.
- **Executor Mode:** Shell-Aktionen nachvollziehbar ausfuehren und bei Perl-Dateien vor dem Speichern `perl -c` validieren.
- **Verification:** Nach jeder Aenderung mindestens ein passender Test-Stub in `t/` oder ein Syntax-/Integritaetscheck.

## 2. Architektur und Sicherheit (verbindlich)
- **Isolation:** Jede Instanz bekommt einen eigenen System-User mit `/usr/sbin/nologin`.
- **Privilege Separation:** Game-Binaries nur via `su -s /bin/bash -c ...`, niemals als `root`.
- **SFTP-Chroot:** `internal-sftp` in `/etc/ssh/sshd_config` mit separatem SFTP-Passwort ohne Shell-Zugriff.
- **Firewall-Automation:** Freigaben ausschliesslich ueber die Webmin-Firewall-API (UFW/Iptables).
- **Input-Hardening:** Alle Eingaben strikt validieren und sanitisieren.
- **Output-Hardening:** Alle dynamischen HTML-Ausgaben escapen (`html_escape()`).

## 3. Code- und UI-Standards (verbindlich)
- **Sprache:** UI-Texte auf Deutsch, Code und Kommentare auf Englisch.
- **UI-Framework:** Nur `ui_*`-Funktionen verwenden; keine hardcodierten Styles/Farben.
- **Webmin-Native-First:** Bei Webmin-basierten Anforderungen immer zuerst native Webmin-Funktionen, Libraries und etablierte Core-Patterns nutzen. Eigene Workarounds oder Custom-Implementierungen nur, wenn es keine native Option gibt oder diese nachweislich nicht ausreicht.
- **Pfade:** Keine hartkodierten projektfremden Pfade; dynamisch und robust aufloesen.
- **Atomaritaet:** Bei Fehlern in User-Anlage/Installation verpflichtende Rollback-Logik.
- **Commit-Stil:**
  1. Lokale Git-Config als Haupt-Autor nutzen.
  2. Commit-Message endet mit zwei Leerzeilen Abstand und:

     Co-authored-by: Claude <claude-code@anthropic.com>

## 4. Kernlogik und Betriebsfluss
- **Instanz-Erkennung:** Via `/etc/passwd` und Suche nach `linuxgsm.sh` in `/home/`.
- **Provisionierung:** User-Anlage (inkl. Suffix) -> Port-Check -> LGSM-Install -> Firewall-Entry.
- **Live-Konsole:** Echtzeit-Log-Streaming per `tail`-Simulation im Webmin-Interface.
- **Monitoring:** Integration ins Webmin-Status-Modul mit 3-Stufen-Eskalation (Restart -> Mail).

## 5. Test-, Build- und Release-Regeln
- **Webmin-Stubs:** `t/stubs.pl` stellt notwendige Funktionen fuer Standalone-Tests bereit.
- **Tests:** TAP-kompatibel, Ausfuehrung z. B. via `perl t/test_<name>.pl`.
- **Standard-Verifikation:** Vor Abschluss von Aenderungen `bash scripts/verify.sh` ausfuehren.
- **Full-Verifikation:** Vor Releases oder groesseren Refactorings zusaetzlich `bash scripts/verify-full.sh`.
- **Mindestumfang Verifikation:** Perl-Syntaxchecks fuer `src/` und `t/` plus kritische Security-/Provisioning-Tests.
- **Kritische Regressionstests:** `t/test_security_guards.pl` und `t/test_provisioning_flow.pl` muessen bei sicherheitsrelevanten oder Provisioning-Aenderungen gruen sein.
- **Build:** `bash scripts/build.sh` erzeugt die `.wbm`-Datei (Modul-Ordner an Tar-Wurzel).
- **Distro-Kompatibilitaet:** `module.info` darf kein `os_support=linux` enthalten (Debian-Installationsproblem).

## 6. Projektlayout
- **Wiki-Repo:** `/mnt/Lager/github/LinuxGSM-WebCore.wiki/`
- **Build-Artefakte:** `dist/` und `tmp/` bleiben gitignored.

## 7. Webmin-CGI und ACL Lessons Learned (implementierungsnah)
Dieser Abschnitt dokumentiert zwingende Webmin-spezifische Details, die aus realen Fehlerbildern entstanden sind.

### 7.1 CGI-Bootstrap und Namespace
- Webmin fuehrt CGIs in `package $modulename` aus; Funktionen sind nicht automatisch global verfuegbar.
- Jede CGI-Datei muss in dieser Reihenfolge initialisieren:
  1. `do '../web-lib.pl';`
  2. `do '../ui-lib.pl';`
  3. `&init_config();`
- `our (%text, %config, %in, %gconfig);` muss nach den `require`/`do`-Zeilen stehen.
- Charset fuer Header in `package main` setzen: `$main::gconfig{'charset'} = 'utf-8';`
- `&ReadParse(\%in);` global initialisieren.
- `check_referer()` nicht verwenden (in dieser Webmin-Version nicht verfuegbar).

### 7.2 ACL-Editor (`acl_security.pl`)
- Nicht `acl_edit.cgi` implementieren; Webmin nutzt fuer ACL nur `acl_security.pl`.
- Pflichtfunktionen:
  - `acl_security_form(\%maccess)`
  - `acl_security_save(\%maccess, \%in)`
  - `load_theme_library()` als leerer Stub
- Bei `foreign_require`-Flow gilt:
  - `BEGIN { push(@INC, ".."); } use WebminCore;`
  - `ui_*`-Funktionen sind dann im Modul-Package verfuegbar.
- Ja/Nein-Felder als `ui_radio('name', $val, [[1, $yes],[0, $no]])`.
- Schutz gegen stale ACL-Dateien mit Default-Fallback:
  - `!defined($access{'key'}) ? 1 : $access{'key'}`

### 7.3 Referenz-Recherche in Webmin
- Bei Unsicherheit zuerst `webmin/webmin` auf GitHub durchsuchen.
- Startpunkte:
  - `acl/edit_acl.cgi`
  - `acl/save_acl.cgi`
  - `net/acl_security.pl`

