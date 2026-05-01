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
- **Isolation:** Zwei Strategien moeglich: (A) geteilter Unix-User (`game_master` o.ae.) fuer mehrere Server — Admin traegt Verantwortung fuer reduzierte Isolation; (B) dedizierter Unix-User pro Server mit `/usr/sbin/nologin` — bevorzugt. Beide Strategien: LGSM laeuft immer im Unterordner `/home/{user}/{servername}/`, niemals direkt im Home-Root.
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
- **Instanz-Erkennung:** Primaer via Registry-TSV (`$config_directory/instances`). Auto-Erkennung via `/etc/passwd` + `linuxgsm.sh`-Suche nur als Fallback fuer Alt-Instanzen (Pre-Wizard).
- **Provisionierung (neu, zweistufig):** Wizard macht nur schnelle Ops: Unix-User anlegen + Unterordner `/home/{user}/{servername}/` + Registry-Eintrag (Status `fresh`). Alle langen Ops (LGSM-Download, Game-Install, Update) laufen in manage.cgi als Background-Worker-Jobs (`$config_directory/jobs/{job_id}/`).
- **register_instance-Signatur:** `register_instance($id, $user, $script_path, \%opts)` — 4. Argument ist immer ein **Hashref**, keine flache Hash-Liste. Schluessel: `source`, `sftp_user`, `owners`, `steam_account`, `instance_status`.
- **Fresh-Instanz-Lookup:** `get_instance_flexible($id)` statt `get_instance($id)` verwenden wenn die Instanz im Status `fresh`/`lgsm_ready` sein kann (Script noch nicht auf Disk) — gibt Hash zurueck auch ohne existierende Script-Datei.
- **poll_job/next_status-Pattern:** `poll_job` setzt `instance_status` via URL-Parameter `next_status` — bei `status=ok` ruft CGI `set_instance_status($id, $next_status)`. Worker schreiben finalen Status nur in `$JOB_DIR/status`, nie direkt in Registry.
- **Game-Server-Operationen:** Ausnahmslos via `su -s /bin/bash -c "..." {unix_user}` aus dem Serververzeichnis. `apt-get` nur als root fuer System-Abhaengigkeiten; alle Server-Dateien gehoeren dem Unix-User.
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
- **Webmin-Only-Target:** Fokus auf Webmin-Modul (`.wbm`); keine distro-spezifischen Paketziele (deb/rpm) pflegen.

### 5.1 Test-Gotchas (Perl)
- **`CORE::GLOBAL`-Mocks** muessen im `BEGIN`-Block stehen, nicht per `local *` nach `require`: `BEGIN { my $x = 0; *CORE::GLOBAL::getpwnam = sub { $x ? ('y') : () } }`
- **`\Q...\E` nur fuer echte Untrusted-Input** — escaped `/` in Pfadstrings, bricht Shell-Ausfuehrung und Test-Regex; bei bereits whitelist-sanitizierten Variablen weglassen.
- **Single-Quote-Escape in Shell-Pfaden:** Wenn `\Q...\E` nicht verwendbar ist (bricht Pfade), Pfad mit `$p =~ s/'/'\\''/g;` absichern und dann als `'cmd "$p"'` einbetten — sicher fuer Pfade mit Leerzeichen und Sonderzeichen.
- **`%text` in Test-Stubs vollstaendig halten** — fehlt ein Fehlerschluessel, gibt `validate_*` `undef` statt Fehlerstring zurueck; Test besteht dann faelschlicherweise.
- **STDERR-Capture in Tests:** `open(STDERR, '>>', \$scalar)` funktioniert nicht auf allen Perl-Versionen — stattdessen `File::Temp` nutzen: `my ($fh, $fname) = tempfile(UNLINK => 1); open(STDERR, '>&', $fh); ... seek $fh, 0, 0; my $out = do { local $/; <$fh> };`
- **Lib-Tests mit CGI-geladenen Funktionen:** Wenn eine Lib (`jobs.pl`, `acl.pl`) Funktionen aufruft die nur von CGIs per `require` geladen werden (z.B. `log_error`), muessen leere Stubs dieser Funktionen in `t/stubs.pl` stehen — sonst `Undefined subroutine`-Fehler in Standalone-Lib-Tests.

## 6. Projektlayout
- **Wiki-Repo:** `/mnt/Lager/github/LinuxGSM-WebCore.wiki/`
- **Build-Artefakte:** `dist/` und `tmp/` bleiben gitignored.
- **Shell-Hilfsskripte:** `src/scripts/` — `install_lgsm.sh`, `server_control.sh`, `engine_switch.sh`; werden via `su` als Game-User ausgefuehrt.
- **Sprachdateien:** `src/lang/de` und `src/lang/en` — einfaches `key=value`-Format; neue Fehlertexte in beiden Dateien pflegen.
- **ACL-Defaults:** `src/defaultacl` — Fallback-ACL wenn noch keine Webmin-ACL fuer einen User existiert.
- **Funktions-Lokationen:** `list_webmin_users()` → `src/lib/acl.pl`; `get_game_list()` → `src/lib/games.pl` (nicht `games_meta.pl`); `get_game_fields/display_name/default_port()` → `src/lib/games_meta.pl`.

## 7. Webmin-CGI und ACL Lessons Learned (implementierungsnah)
Dieser Abschnitt dokumentiert zwingende Webmin-spezifische Details, die aus realen Fehlerbildern entstanden sind.

### 7.1 CGI-Bootstrap und Namespace
- Webmin fuehrt CGIs in `package $modulename` aus; Funktionen sind nicht automatisch global verfuegbar.
- Jede CGI-Datei muss in dieser Reihenfolge initialisieren:
  1. `do '../web-lib.pl';`
  2. `do '../ui-lib.pl';`
  3. `&init_config();`
- `our (%text, %config, %in, %gconfig);` muss nach den `require`/`do`-Zeilen stehen.
- `$module_root` explizit in `our()` aufnehmen wenn `load_games_meta()` oder andere `$module_root`-abhaengige Funktionen aufgerufen werden — z. B.: `our (%text, %in, $config_directory, $module_name, $module_root);`
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

### 7.3 CGI-Spezifika
- `$current_lang` explizit als `our $current_lang` deklarieren wenn Sprachlogik benoetigt wird.
- Lang-Strings kein Perl-Syntax wie `$script` enthalten — wird nicht interpoliert; Wert dynamisch im CGI bauen.
- `<details><summary>...</summary>...</details>` fuer einklappbare Abschnitte — funktioniert nativ in Authentic Theme ohne JS.
- **`save_module_config` kein Return-Check noetig:** Webmin-Core-Funktion ohne sinnvollen Rueckgabewert — kein Error-Handling implementieren, bestehende CGIs im Projekt machen das auch nicht.
- **`&redirect()` immer mit `exit` abschliessen:** Nach jedem `&redirect(...)` muss ein `exit;` folgen. Ohne `exit` laeuft der CGI weiter, kann eine zweite HTTP-Response rendern und Folgefehler ausloesen (z. B. "Ungueltige Aktion" weil `$is_fresh`-Block nach dem Redirect erneut ausgefuehrt wird).
- **`sanitize_input()` nur fuer Pflichtfelder:** Die Funktion ruft `&error()` wenn das Ergebnis leer ist. Optionale Parameter (z. B. `$in{'action'}` auf Uebersichtsseiten) immer manuell strippen: `$var = $in{'key'} // ''; $var =~ s/[^a-zA-Z0-9_\-]//g;`

### 7.4 Referenz-Recherche in Webmin
- Bei Unsicherheit zuerst `webmin/webmin` auf GitHub durchsuchen.
- Startpunkte:
  - `acl/edit_acl.cgi`
  - `acl/save_acl.cgi`
  - `net/acl_security.pl`

## 8. LGSM Domain-Wissen

### 8.1 Config-Ebenen (Prioritaet niedrig → hoch)
1. `lgsm/config-default/config-lgsm/$script/_default.cfg` — LGSM-generiert, **niemals** beschreiben
2. `lgsm/config-lgsm/common.cfg` — gilt fuer ALLE Instanzen des Unix-Users; nur wirklich geteilte Settings (Discord-Webhook, Log-Pfad)
3. `lgsm/config-lgsm/$script/$script.cfg` — instanz-spezifisch; Port, Spielname, Slots gehoeren hierher

### 8.2 Bekannte Fallen
- **`_has_user_config` Quirk:** LGSM erstellt `$script.cfg` selbst als Template mit nur Kommentaren — zaehlt NICHT als user config. Check prueft auf echte key=value-Paare, nicht nur Datei-Existenz.
- **Config-Sicherheit:** `validate_config_target($path)` aus `src/lib/config_editor.pl` vor jedem Config-Schreiben aufrufen. Niemals `_default.cfg` beschreiben.
- **JSON:** `JSON::PP` ist Perl-Core seit 5.14, kein externes Modul noetig.

### 8.3 Game-Metadaten-DB
- Statische DB: `src/lib/games_meta.json` — Felder, Typen und Labels pro LGSM-Script-Name
- Lokale Ueberschreibung: `$config_directory/games_meta_local.json`
- Bibliothek: `src/lib/games_meta.pl` — `get_game_fields($script)`, `get_game_display_name($script)`
- In Tests: `_reset_meta_cache()` zwischen verschiedenen Fixtures aufrufen
- **Non-LGSM-Spiele (source=steamcmd):** `get_custom_game_list()` liefert Eintraege mit `source != 'lgsm'`. `get_game_source($script)` gibt den Installations-Source zurueck. Wizard-Registrierung mit `source=steamcmd` → Setup-Phase ueberspringt LGSM-Schritt, geht direkt zu `install_game` via `steamcmd_install.sh`.
- **Lokale Verwaltung:** `save_local_game_meta($script, $entry_ref)` / `delete_local_game_meta($script)` schreiben in `games_meta_local.json`. `local_game_scripts()` gibt die dort definierten Script-Namen zurueck.

### 8.4 GitHub-Referenzen
- LGSM Config-Struktur: `GameServerManagers/LinuxGSM` (Repo)

### 8.5 Game-Config Pfad-Aufloesung (LGSM)
- Game-Server-Config nie raten: aus LGSM-Variablen aufloesen (`servercfgfullpath`, fallback `servercfgdir + servercfg`), z. B. via `_parse_lgsm_config()` + `resolve_game_server_config_path()`.

### 8.6 INI-Formattreue (kritisch)
- Bei `.ini`-Speichern byte-genau schreiben (`>:raw`, kein Auto-Formatting, kein erzwungener Zeilenumbruch); fuer Raw-Content `write_file_exact()` verwenden.
- Palworld-Formmodus nur `OptionSettings=(...)` aktualisieren; restliche INI-Inhalte unveraendert lassen (`parse_option_settings_from_ini` / `update_option_settings_in_ini`).

### 8.7 Config-Editor UX-Pattern
- Drei In-Page-Ansichten im `manage.cgi`: `common` | `instance` | `game` ueber `config_view` halten (kein Reload nur fuer Umschalten).
- Wenn Game-Config fehlt: zuerst Bootstrap-Flow anbieten (`init_game_config`: kurz Start/Stop), dann Bearbeitung freigeben.
- Fuer Datei-Navigation im Webmin-UI File Manager Link auf Server-Root anzeigen (`/filemin/?path=<urlencoded-root>`).

### 8.8 ProFTPD / FTP-Checks
- ProFTPD-Hauptconfig zuerst robust finden (`proftpd_main_config` override > systemd ExecStart `-c` > Standardpfade), sonst nur Basiswarnung statt Folgefehlern.
- `Include`/`IncludeOptional` relativ zur einbindenden Datei aufloesen (z. B. `conf.d/*.conf`), nicht relativ zum CWD.
- ProFTPD-Include-Dirs robust behandeln: `Include /etc/proftpd/conf.d/` als Verzeichnis erkennen und `*.conf` innerhalb expandieren.
- ProFTPD-Audit im UI um `main_config` + geladene Config-Dateien anzeigen, damit Warnungen nachvollziehbar sind.

### 8.9 Virtuelle FTP-User (ProFTPD)
- Virtuelle FTP-User nicht mit `getpwnam` validieren; Mapping kann bewusst keinen Unix-Account haben.
- FTP-User-CRUD nur via `ftpasswd` (`--passwd`, `--change-password`, `--delete-user`), niemals direkt `AuthUserFile` schreiben.

### 8.10 SFTP-User-Lookup
- **Immer `resolve_instance_sftp_user($id, $user)` aus `src/lib/instance.pl`** verwenden — liest aus Registry-TSV. Die alte `get_sftp_user()` (Convention `<user>-ftp`) war toter Code und wurde entfernt.

### 8.11 Scan-/Registry-Pattern
- Scan-Listen fuer stabile Darstellung mit `ui_columns_table(...)` rendern; `ui_columns_header/row` kann Theme-Layout brechen.
- Instanz-Registry: TSV mit `source`/`sftp_user`; Legacy-Format `id=user:script` weiter einlesen.
- `ui_submit` immer mit expliziter CSS-Klasse aufrufen (5. Argument): `btn-danger` fuer destruktive Aktionen, `btn-default` fuer neutrale — verhindert Theme-Farb-Roulette bei mehreren Buttons in einer Zelle.

## 9. Deployment
- **Install auf Server:** `.wbm` nach `/tmp/` kopieren, dann `/usr/share/webmin/install-module.pl /tmp/linuxgsm-webcore-0.1.0.wbm`
- Kein Symlink/Auto-Sync — jede Aenderung erfordert expliziten Rebuild und Reinstall.

