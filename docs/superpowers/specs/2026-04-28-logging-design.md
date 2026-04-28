# Logging-System — Design Spec

**Datum:** 2026-04-28
**Status:** Approved

---

## Ziel

Strukturiertes Logging für LinuxGSM-WebCore mit drei Ebenen:
- **Fehler** immer in `miniserv.error`
- **Admin-Aktionen** immer im Webmin Actions Log
- **Debug-Details** nur wenn Modulkonfiguration `debug_logging=1` gesetzt

---

## Architektur

Neue Datei `src/lib/logging.pl` mit drei Funktionen. Kein externes Framework, keine neuen Abhängigkeiten. `warn` in Webmin-CGI landet automatisch in `/var/webmin/miniserv.error`. `webmin_log()` schreibt in den Webmin Actions Log (sichtbar unter Webmin → Configuration → Webmin Actions Log).

---

## Komponenten

### 1. `src/lib/logging.pl` — drei Funktionen

```perl
our (%config);

sub log_error {
    my ($msg) = @_;
    warn "[LGSM-ERROR] $msg\n";
}

sub log_action {
    my ($action, $object, $params) = @_;
    $params //= {};
    &webmin_log($action, 'lgsm', $object, $params);
}

sub log_debug {
    my ($msg) = @_;
    return unless $config{debug_logging};
    warn "[LGSM-DEBUG] $msg\n";
}
```

Alle CGIs und Libs laden `logging.pl` via `require './lib/logging.pl'` (bereits in manage.cgi-Pattern etabliert).

---

### 2. Ereignisse

#### `log_error($msg)` — immer, → miniserv.error

| Wo | Beispiel-Nachricht |
|---|---|
| Ungültige job_id / instance_id nach Sanitisierung | `"Invalid job_id after sanitize: '$raw'"` |
| `system_logged` schlägt fehl | `"system_logged failed (rc=$rc): $cmd"` |
| Datei nicht lesbar/schreibbar in jobs.pl | `"Cannot write meta for job $job_id: $!"` |
| Unerwarteter Status in get_all_jobs | `"Unknown status '$status' for job $job_id"` |

#### `log_action($action, $object, \%params)` — immer, → Actions Log

| Action-String | Objekt | Parameter | Wann |
|---|---|---|---|
| `server_provisioned` | instance_id | `user`, `game` | Wizard abgeschlossen |
| `server_deleted` | instance_id | `unix_user`, `scope` | scan.cgi delete |
| `job_started` | job_id | `instance_id`, `action` | nach create_job() + write_job_meta() |
| `job_aborted` | job_id | `instance_id` | abort_job() aufgerufen |
| `acl_saved` | webmin_user | `role` | acl_manage.cgi save_acl |
| `config_saved` | instance_id | `config_type` | manage.cgi Config-Save |

#### `log_debug($msg)` — nur wenn `$config{debug_logging}`, → miniserv.error

| Wo | Beispiel-Nachricht |
|---|---|
| manage.cgi Action-Dispatch | `"action=install_game instance=windrose_1"` |
| ACL-Check-Ergebnis | `"ACL: user=knoellix role=admin instance=windrose_1 → allowed"` |
| Worker-Start | `"Starting worker: setsid nohup bash /path/to/script.sh ..."` |
| Job-Status-Übergang | `"Job abc123: running → ok"` |
| Instance geladen | `"Loaded instance windrose_1 source=steamcmd"` |

---

### 3. Debug-Schalter in `src/config.cgi`

Neuer Eintrag in der Modulkonfigurations-Tabelle:

```perl
print &ui_table_row(
    $text{'config_debug_logging'},
    &ui_radio('debug_logging', $config{debug_logging} ? 1 : 0,
        [[1, $text{'yes'}], [0, $text{'no'}]])
);
```

Kein Webmin-Neustart nötig — wirkt ab dem nächsten CGI-Request.

---

### 4. Lang-Strings

**`src/lang/de`:**
```
config_debug_logging=Debug-Logging aktivieren (schreibt Details in miniserv.error)
```

**`src/lang/en`:**
```
config_debug_logging=Enable debug logging (writes details to miniserv.error)
```

---

## Integrationsplan

| Datei | Änderung |
|---|---|
| `src/lib/logging.pl` | Neu — drei Funktionen |
| `src/config.cgi` | Neuer `debug_logging`-Eintrag |
| `src/lang/de` + `src/lang/en` | Neuer Lang-Key |
| `src/manage.cgi` | `require logging.pl`; log_debug für Action-Dispatch; log_action für job_started, job_aborted, config_saved |
| `src/scan.cgi` | `require logging.pl`; log_action für server_deleted |
| `src/wizard.cgi` | `require logging.pl`; log_action für server_provisioned |
| `src/acl_manage.cgi` | `require logging.pl`; log_action für acl_saved |
| `src/jobs.cgi` | `require logging.pl`; log_debug für Job-Operationen |
| `src/lib/jobs.pl` | log_error bei Datei-Fehlern; log_debug für Status-Übergänge |
| `src/lib/acl.pl` | log_debug für ACL-Check-Ergebnisse |

---

## Nicht im Scope

- Log-Rotation (liegt bei Webmin / miniserv)
- Log-Viewer im Webmin-UI (miniserv.error ist direkt über File Manager zugänglich)
- Syslog-Integration
- Separate Log-Datei
