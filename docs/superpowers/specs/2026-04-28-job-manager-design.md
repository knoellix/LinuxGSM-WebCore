# Job Manager — Design Spec

**Datum:** 2026-04-28
**Status:** Approved

---

## Ziel

Hintergrund-Jobs (install, update, setup_lgsm, …) sichtbar machen, abbrechen können und automatisch bereinigen. Admins sehen alle Jobs, Operatoren nur ihre eigenen, Viewer gar keine.

## Architektur

Approach A: Metadaten-Datei pro Job. Jedes Job-Verzeichnis wird um eine `meta`-Datei erweitert. Die bestehende `pid`-Datei wird durch `pgid` ersetzt. Alle Worker-Scripts starten via `setsid`, damit sie eine eigene Process Group erhalten — `kill -- -$PGID` beendet den kompletten Prozessbaum inklusive SteamCMD/apt-get-Kinder.

---

## Datenmodell

### Job-Verzeichnis

```
$config_directory/jobs/{job_id}/
  meta        ← neu
  pgid        ← neu, ersetzt pid
  status      ← running | ok | failed | aborted
  output      ← vollständiger stdout/stderr des Workers
  error_hint  ← optional, Fehlerschlüssel für Lang-String
```

### `meta`-Datei (key=value)

```
instance_id=windrose_1
action=install_game
started_at=1745852400
unix_user=windrose
```

### Status-Werte

| Status | Bedeutung |
|---|---|
| `running` | Prozess läuft (PGID aktiv) |
| `ok` | Erfolgreich abgeschlossen |
| `failed` | Worker mit Fehler beendet |
| `aborted` | Manuell abgebrochen |

---

## Komponenten

### 1. `src/lib/jobs.pl` — Erweiterungen

**Neue Funktionen:**

```perl
write_job_meta($job_id, $instance_id, $action, $unix_user)
    # Schreibt meta-Datei; started_at = time()

get_all_jobs()
    # Scannt alle Job-Dirs, liest meta + status
    # Gibt Liste von Hashrefs zurück, sortiert nach started_at DESC
    # Felder: job_id, instance_id, action, unix_user, started_at, status

abort_job($job_id)
    # Liest pgid → kill -9 -- -$PGID (SIGKILL direkt — kein Warten, CGI-safe)
    # Schreibt status=aborted

delete_job($job_id)
    # Entfernt Job-Dir komplett
    # Nur erlaubt wenn status != running

_auto_cleanup_jobs()
    # Wird intern von create_job() aufgerufen
    # Zählt abgeschlossene Jobs (ok/failed/aborted)
    # Löscht älteste über 10 (nach started_at sortiert)
    # Laufende Jobs (running) werden nie gelöscht
```

**Geänderte Funktionen:**

```perl
create_job()
    # Wie bisher, zusätzlich:
    # → ruft _auto_cleanup_jobs() auf nach mkdir
    # → schreibt pgid-Datei erst durch Worker selbst (echo $$ > pgid via setsid)
```

**Zombie-Erkennung** (in `get_all_jobs()`):

```perl
# Für jeden Job mit status=running:
if (-f "$job_dir/pgid") {
    my $pgid = slurp("$job_dir/pgid"); chomp $pgid;
    if ($pgid =~ /^\d+$/) {
        my $alive = kill(0, -$pgid);  # kill -0 prüft ohne Signal zu senden
        if (!$alive) {
            # Prozess tot aber status noch running → zombie
            finish_job($job_id, 'failed');
            write_error_hint($job_id, 'hint_zombie');
        }
    }
}
```

---

### 2. `src/jobs.cgi` — Globale Job-Übersicht

**Neue Seite**, erreichbar per Button in `index.cgi`.

**Zugriff:**
- Viewer → `error('err_acl_admin_only')`
- Operator → sieht nur Jobs seiner eigenen Instanzen (`user_can_manage($inst_id)`)
- Admin → sieht alle Jobs

**Tabellenspalten:**

| Instanz | Aktion | Gestartet | Status | Ausgabe | Aktionen |
|---|---|---|---|---|---|
| windrose_1 | install_game | 14:32:01 | ✅ ok | — | Löschen |
| windrose_1 | install_game | 14:28:44 | 🔴 failed | Log | Löschen |
| mc_srv | update | 14:10:12 | ⏳ läuft | Live | Abbrechen |

**Status-Icons:**
- `running` → ⏳ + "Läuft…"
- `ok` → ✅
- `failed` → 🔴
- `aborted` → 🚫

**Ausgabe-Spalte:**
- `running` → Link zu `manage.cgi?…&action=poll_job&job=…` (Live-Ansicht)
- `failed` / `aborted` → Link zu `jobs.cgi?action=view_output&job_id=…`
- `ok` → `—`

**Aktionen-Spalte:**
- `running` → "Abbrechen"-Button (POST `action=abort_job`)
  - Admin: für alle Jobs
  - Operator: nur für eigene Instanzen
- `ok/failed/aborted` → "Löschen"-Button (POST `action=delete_job`)
  - Admin: alle Jobs
  - Operator: nur eigene Instanzen
  - Viewer: kein Button

**`view_output`-Action (GET):**

Zeigt vollständigen Job-Output in einer `<pre>`-Box.
Zugriffsschutz: gleiche Logik wie Tabelle.

**Aktions-Handler (POST):**

```
abort_job:  is_admin() || user_can_manage($inst_id) → abort_job($job_id) → redirect
delete_job: is_admin() || user_can_manage($inst_id) → delete_job($job_id) → redirect
```

---

### 3. `src/manage.cgi` — Änderungen

**`poll_job`-Seite:**

Neuer "Abbrechen"-Button für laufende Jobs:

```
[Ausgabe]              ← h3
Läuft…                 ← p
[... output pre ...]

[ ← Zurück ]   [ Abbrechen ]
```

POST `action=abort_job&job=$job_id` → `abort_job($job_id)` → Redirect zur Setup-Phase der Instanz (Status bleibt `fresh`/`lgsm_ready`, damit direkt neu gestartet werden kann).

**`install_game` / `setup_lgsm` / `update` / `validate` / `reinstall`:**

Alle `create_job()`-Aufrufe ergänzen sofort `write_job_meta($job_id, $instance_id, $action, $unix_user)`.

Alle `nohup bash ...` werden zu `setsid nohup bash ...`.

**Per-Instanz-Job-Liste** (am Ende der manage.cgi-Seite, vor Footer):

Kompakte Tabelle mit den letzten 5 Jobs dieser Instanz (gefiltert aus `get_all_jobs()`):

| Aktion | Gestartet | Status | Ausgabe |
|---|---|---|---|
| install_game | 14:32 | ✅ | — |
| install_game | 14:28 | 🔴 | Log |

Nur sichtbar für Admins und Operatoren.

---

### 4. Worker-Scripts — Änderungen

**5 Background-Job-Scripts** (`steamcmd_install.sh`, `game_action.sh`, `setup_lgsm.sh`, `steamcmd_control.sh`, `steam_login_worker.sh`) — `server_control.sh` ist kein Background-Job-Worker (LGSM start/stop läuft synchron):

Zeile direkt nach `JOB_DIR="$1"`:

```bash
echo $$ > "$JOB_DIR/pgid"   # $$ = PID = PGID wenn via setsid gestartet
```

Die bisherige `echo $$ > "$JOB_DIR/pid"` entfällt (oder wird durch pgid ersetzt).

**`manage.cgi`** — alle Worker-Starts:

```perl
# Vorher:
"nohup bash " . quotemeta($worker) . " ..."

# Nachher:
"setsid nohup bash " . quotemeta($worker) . " ..."
```

---

### 5. `src/index.cgi` — Button

Neuer Button in der Hauptnavigation (neben "Instanzen verwalten"):

```perl
if (!&user_is_viewer()) {
    print "<a href='jobs.cgi' class='btn btn-default'>$text{'jobs_title'}</a>\n";
}
```

---

### 6. Lang-Strings (de + en)

Neue Keys in `src/lang/de` und `src/lang/en`:

```
jobs_title=Job-Übersicht
jobs_col_instance=Instanz
jobs_col_action=Aktion
jobs_col_started=Gestartet
jobs_col_status=Status
jobs_col_output=Ausgabe
jobs_col_actions=Aktionen
jobs_status_running=Läuft…
jobs_status_ok=Erfolgreich
jobs_status_failed=Fehlgeschlagen
jobs_status_aborted=Abgebrochen
jobs_abort_btn=Abbrechen
jobs_abort_confirm=Job wirklich abbrechen?
jobs_delete_btn=Löschen
jobs_output_title=Job-Ausgabe
jobs_no_jobs=Keine Jobs vorhanden.
jobs_action_install_game=Spiel installieren
jobs_action_setup_lgsm=LGSM einrichten
jobs_action_update=Update
jobs_action_validate=Dateien prüfen
jobs_action_reinstall=Neu installieren
jobs_action_start=Starten
jobs_action_stop=Stoppen
hint_zombie=Prozess unerwartet beendet — Worker-Prozess ist nicht mehr aktiv.
```

---

## Cleanup-Logik

`_auto_cleanup_jobs()` wird bei jedem `create_job()` aufgerufen:

1. Alle Job-Dirs scannen
2. Jobs mit `status != running` (abgeschlossen) nach `started_at` sortieren
3. Wenn mehr als 10 → älteste löschen bis 10 übrig
4. Laufende Jobs werden nie angefasst

Zusätzlich: manuelles Löschen über "Löschen"-Button in `jobs.cgi` (Operator: nur eigene, Admin: alle).

---

## Sicherheit

- Alle `job_id`-Parameter werden mit `/[^0-9a-f]/` gesanitiert (wie bisher)
- `abort_job` und `delete_job` prüfen ACL vor der Aktion
- `kill -- -$PGID` nur wenn PGID eine Zahl ist (`/^\d+$/`)
- `delete_job` verweigert Löschen wenn `status=running`

---

## Nicht im Scope

- Echtzeit-Streaming via WebSocket oder SSE (zu komplex für Webmin-CGI)
- E-Mail-Benachrichtigung bei Job-Fehler (separates Feature)
- Strukturiertes Activity-Log (separates Feature, wird nach dem Job-Manager gebaut)
