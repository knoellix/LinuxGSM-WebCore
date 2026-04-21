# Wizard & Manage Redesign — Design-Spec

**Datum:** 2026-04-21
**Status:** Genehmigt

## Ziel

Den Wizard vollständig neu gestalten (schlanker, ohne lange Operationen) und manage.cgi um eine Setup-Phase sowie Lifecycle-Aktionen (Install, Reinstall, Update, Monitor) erweitern. Alle langen Operationen laufen über einen wiederverwendbaren Background-Job-Worker mit CGI-Polling.

---

## Designentscheidungen

### Unix-User-Strategie
Der Wizard bietet zwei Ansätze (Radio-Auswahl):

- **Geteilter User:** Ein Unix-User verwaltet mehrere Server. Username frei wählbar (z.B. `game_master`). Wenn der User bereits existiert, wird nur ein neuer Ordner angelegt.
- **Eigener User pro Server:** Pro Server ein dedizierter Unix-User (z.B. `gs_rust`). Volle Isolation.

### Servername = Ordnername
Der Servername ist frei wählbar und wird direkt als Unterordner im Home-Verzeichnis des Unix-Users angelegt:
```
/home/{unix_user}/{servername}/
```
Alle Dateien im Serververzeichnis gehören dem Unix-User — nie root.

### Aufgabenteilung Wizard / manage.cgi
- **Wizard:** Ausschließlich schnelle Operationen (Unix-User + Ordner anlegen, Registry-Eintrag). Kein Timeout-Risiko.
- **manage.cgi:** Alle langen Operationen (LGSM-Download, Game-Install, Update) über Background-Worker.

### Live-Output
Alle langen Operationen nutzen das Background-Worker-Pattern: Worker schreibt Output in Datei, CGI pollt alle 3 Sekunden neue Zeilen. Browser-Refresh verliert keinen Fortschritt.

---

## Abschnitt 1: Wizard (neu)

### Schritt 1 — Spiel auswählen
- Dropdown aus `games_meta.json`
- Standardport wird nach Spielauswahl automatisch vorgeschlagen
- Weiter-Button

### Schritt 2 — Unix-User & Servername
- Radio-Auswahl: Geteilter User vs. Eigener User
- **Geteilter User:** Username-Feld (Vorausfüllung `game_master`), Hinweis wenn User bereits existiert → Ordner wird nur angelegt
- **Eigener User:** Username-Feld mit Empfehlung (z.B. `gs_rust` aus Präfix + Spielname)
- Servername-Feld (= Ordnername, keine automatischen Präfixe)
- Validierung: Unix-Username `[a-z][a-z0-9_-]{0,30}`, Servername `[a-zA-Z0-9_-]{1,64}`

### Schritt 3 — Port, SFTP, Owner, Steam
- Port-Textfeld mit Standardwert aus games_meta.json
- SFTP-Checkbox (optional, kein Pflichtfeld)
- Webmin-Owner-Dropdown
- Steam-Account-Dropdown (nur wenn `game_requires_steam()`)

### Schritt 4 — Zusammenfassung + Bestätigen
- Übersicht aller Angaben
- "Erstellen"-Button

### POST (schnelle Operationen, kein Timeout-Risiko)
1. Unix-User anlegen wenn nicht vorhanden (`useradd -m -s /usr/sbin/nologin {user}`)
2. Ordner `/home/{user}/{servername}/` anlegen (`mkdir -p`, `chown {user}:{user}`)
3. Instanz in Registry registrieren (Status: `fresh`)
4. SFTP-User anlegen wenn gewünscht
5. Webmin-Owner zuweisen
6. Steam-Account speichern wenn angegeben
7. Redirect → `manage.cgi?instance_id=...`

**Rollback:** Bei Fehler nach `useradd` → `userdel -r` wenn der User neu angelegt wurde. Bei bereits existierendem User: nur Ordner entfernen.

---

## Abschnitt 2: manage.cgi Setup-Phase

Wenn eine Instanz den Status `fresh` oder `lgsm_ready` hat, erscheint oben eine Setup-Phase statt der normalen Aktionsbuttons.

### Phase 1 — LGSM + Abhängigkeiten installieren (Status: `fresh`)

Button "LGSM installieren" startet einen Background-Job:

1. `apt-get install -y curl wget tar bzip2 gzip unzip bc jq` — als root (LGSM-Mindestabhängigkeiten; vollständige Liste aus LGSM-Doku)
2. `linuxgsm.sh` herunterladen: `su -s /bin/bash -c "cd /home/{user}/{servername} && curl -Lo linuxgsm.sh https://linuxgsm.sh && chmod +x linuxgsm.sh && bash linuxgsm.sh {game_script}" {unix_user}`
3. Alle erzeugten Dateien gehören dem Unix-User (läuft als Unix-User via `su`)
4. Alle erzeugten Dateien gehören dem Unix-User

Live-Output in `<pre>`-Block mit Auto-Scroll. CGI pollt alle 3s.

Bei Fehler:
- Fehlermeldung aus `output`-Datei
- Automatischer Lösungshinweis wenn Fehlermuster erkannt (aus `error_hints.pl`)
- "Erneut versuchen"-Button
- Status bleibt `fresh`

Bei Erfolg → Status: `lgsm_ready`

### Phase 2 — Game-Server installieren (Status: `lgsm_ready`)

Button "Server installieren" startet zweiten Background-Job:

```bash
su -s /bin/bash -c "cd /home/{user}/{servername} && ./{script} install" {unix_user}
```

- Läuft vollständig als Unix-User, niemals als root
- Alle erzeugten Dateien (serverfiles/, logs/, etc.) gehören dem Unix-User
- Live-Output + Fehler-Hinweise wie Phase 1

Bei Erfolg → Status: `installed`, normaler manage.cgi-Betrieb

---

## Abschnitt 3: manage.cgi Lifecycle-Aktionen

Verfügbar nach Status `installed`:

### Vorhandene Aktionen (unverändert)
Start, Stop, Restart, Firewall, Config-Editor, FTP, Steam

### Neue Aktionen

| Aktion | Beschreibung | Ausführung |
|---|---|---|
| `update` | `./script update` | Background-Worker als Unix-User |
| `validate` | `./script validate` (Dateiintegrität) | Background-Worker als Unix-User |
| `monitor` | Live-Log streaming via `tail -f` auf LGSM-Logdatei | CGI pollt alle 2s neue Zeilen |
| `reinstall` | `serverfiles/` löschen + neu installieren | Worker; User, LGSM, Configs bleiben erhalten |

**Reinstall-Ablauf:**
1. Server stoppen falls online
2. `rm -rf {servername}/serverfiles/` als Unix-User
3. `./{script} install` als Unix-User
4. Config bleibt in `lgsm/config-lgsm/` erhalten

---

## Abschnitt 4: Background-Job-System

### Job-Verzeichnis
```
$config_directory/jobs/{job_id}/
  output      # Worker stdout/stderr (append)
  status      # running | ok | failed
  pid         # PID des Worker-Prozesses
  error_hint  # Erkannter Fehlerhinweis (optional)
```

Job-ID = 16-Zeichen Hex aus `/dev/urandom`. Cleanup: Jobs älter als 24h werden beim nächsten Poll gelöscht.

### CGI-Poll-Endpunkt
`manage.cgi?action=poll_job&job={job_id}&instance_id={id}`

- Liest neue Zeilen aus `output` seit letztem Poll (via `offset`-Parameter)
- Meta-Refresh alle 3s solange `status=running`
- Bei `ok`/`failed`: Ergebnis anzeigen, kein weiterer Refresh

### Worker-Scripts
Jedes Worker-Script:
1. Schreibt PID in `$JOB_DIR/pid`
2. Leitet stdout/stderr in `$JOB_DIR/output` um
3. Schreibt `running` → `ok` oder `failed` in `$JOB_DIR/status`
4. Bei Fehler: schreibt erkannten Hinweis in `$JOB_DIR/error_hint`

---

## Abschnitt 5: Fehler-Hinweis-System

Datei `src/lib/error_hints.pl` — Funktion `detect_error_hint($output_text)`:

Prüft Output auf bekannte Muster und gibt Hinweis-String zurück:

| Muster | Hinweis |
|---|---|
| `Unable to locate package` | Paketname hat sich geändert — apt update ausführen oder Paket manuell suchen |
| `lib*.so.*: cannot open` | Fehlende Bibliothek — Paketname kann je nach Debian-Version variieren |
| `command not found` | Abhängigkeit fehlt — LGSM-Abhängigkeitsliste prüfen |
| `Permission denied` | Dateiberechtigung falsch — chown auf Unix-User prüfen |
| `No space left on device` | Kein Speicherplatz — Festplatte prüfen |
| `curl: (6)` / `wget: unable to resolve` | Netzwerkproblem — DNS und Internetverbindung prüfen |

Hinweise werden in `src/lang/de` und `src/lang/en` als `hint_*`-Keys gepflegt.

---

## Abschnitt 6: Instanz-Status

Neue 8. TSV-Spalte `instance_status` in der Registry:

```
id<TAB>user<TAB>script<TAB>source<TAB>sftp_user<TAB>owners<TAB>steam_account<TAB>instance_status
```

Status-Werte: `fresh` | `lgsm_ready` | `installed`

Für bestehende Instanzen (ohne 8. Spalte): Fallback auf `installed` (Rückwärtskompatibilität).

---

## Neue/geänderte Dateien

| Datei | Änderung |
|---|---|
| `src/wizard.cgi` | Komplett neu: 4 Schritte, nur schnelle Ops |
| `src/lib/provision.pl` | `provision_fast()`: nur User+Ordner, kein LGSM-Download |
| `src/lib/jobs.pl` | NEU: Job-System (create_job, poll_job, cleanup_jobs) |
| `src/lib/error_hints.pl` | NEU: Fehlermuster → Lösungsvorschläge |
| `src/scripts/setup_lgsm.sh` | NEU: LGSM+Deps installieren |
| `src/scripts/game_install.sh` | NEU: `./script install` als Unix-User |
| `src/scripts/game_update.sh` | NEU: `./script update` als Unix-User |
| `src/manage.cgi` | Setup-Phase + Update/Validate/Monitor/Reinstall |
| `src/lib/instance.pl` | 8. TSV-Spalte `instance_status` |
| `src/lang/de` + `src/lang/en` | Neue Wizard/Manage/Hint-Strings |

---

## Sicherheits-Checkliste

- [ ] Alle Game-Server-Operationen (Install, Update, Validate) laufen via `su` als Unix-User
- [ ] `apt-get` läuft als root nur für System-Pakete
- [ ] Alle erzeugten Dateien in Serververzeichnis gehören dem Unix-User
- [ ] Servername-Validierung: `[a-zA-Z0-9_-]{1,64}` (kein Pfad-Traversal)
- [ ] Job-ID aus `/dev/urandom` (16 Hex-Zeichen)
- [ ] Job-Verzeichnis `chmod 700`
- [ ] Alle dynamischen HTML-Werte via `html_escape()`
- [ ] Rollback bei Wizard-Fehler (userdel wenn neu angelegt)

---

## Abweichungen von CLAUDE.md (bewusst, begründet)

**CLAUDE.md §2 "Isolation: Jede Instanz bekommt eigenen System-User"** — der neue `game_master`-Ansatz erlaubt mehrere Server unter einem Unix-User. Diese Abweichung ist bewusst: Der Admin wählt selbst den Ansatz und trägt die Verantwortung für die reduzierte Isolation. Der dedizierte-User-Ansatz (Option B) erfüllt die ursprüngliche Regel vollständig.

**Auto-Erkennung in `list_instances()`** — die bisherige Auto-Erkennung sucht nach `$home/$user` (Script direkt im Home). Mit Unterordner-Struktur findet sie neue Server nicht mehr. Lösung: Alle über den neuen Wizard erstellten Server werden zwingend in der Registry registriert. `list_instances()` wird so angepasst, dass es bei registrierten Instanzen den `script`-Pfad aus der Registry nutzt (bereits implementiert) und die Auto-Erkennung nur als Fallback für Alt-Instanzen bleibt.

---

## Nicht im Scope (bewusst ausgelassen)

- Automatische Fehleranalyse während LGSM lädt (kommt in separatem Spec)
- Mehrere gleichzeitige laufende Jobs pro Instanz
- WebSocket/SSE für echtes Streaming
- Automatisches Update-Scheduling
