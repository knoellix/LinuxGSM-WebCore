# Panel-Grundfixes Design

**Ziel:** UTF-8-Darstellung, korrekte Datenerkennung aus LGSM-Configs, Bugfixes im Panel und manage.cgi verbessern.

**Architektur:** Geschichteter Config-Parser in `instance.pl`, Bugfix in `core.pl` (Script-Name), Erweiterung von `manage.cgi` um Firewall-Status, Warnungen und Quick-Fix.

**Tech Stack:** Perl, Webmin CGI (`ui_*`-Funktionen), LGSM-Konfigstruktur

---

## Bug 1: UTF-8-Encoding

**Problem:** Umlaute werden falsch dargestellt ("Ä–ffnen" statt "Öffnen").

**Fix:** In `index.cgi` und `manage.cgi` den Webmin-`header()`-Aufruf mit `charset=utf-8` versehen:
```perl
&header($text{'manage_title'}, '', undef, undef, undef, undef, undef, 'utf-8');
```
Webmin's `header()` akzeptiert Charset als 8. Parameter.

---

## Bug 2: Script-Name in run_server_action

**Problem:** `run_server_action($unix_user, $action)` in `core.pl` ruft `"./$unix_user $action"` auf. Bei einem Server `kekks` mit Script `pwserver` wird `./kekks start` ausgeführt — das ist falsch.

**Fix:** Dritter optionaler Parameter `$script_name`:
```perl
sub run_server_action {
    my ($user, $action, $script_name) = @_;
    $script_name //= $user;
    ...
    return &system_logged("su -s /bin/bash -c \"cd \Q$home\E && ./$script_name $action\" $user");
}
```

`manage.cgi` übergibt `$inst->{'id'}` (= Script-Basename) als dritten Parameter. Bestehende Aufrufe ohne dritten Parameter bleiben kompatibel.

---

## Feature: Geschichteter Config-Parser

**Datei:** `src/lib/instance.pl` — `_parse_lgsm_config()`

**Lesereihenfolge (niedrigste → höchste Priorität):**
1. `lgsm/config-default/_default.cfg`
2. `lgsm/config-default/$scriptname.cfg`
3. `lgsm/config-lgsm/common.cfg`
4. `lgsm/config-lgsm/$scriptname/$scriptname.cfg`

Jede Schicht überschreibt die vorherige. Gibt zusätzlich `_has_user_config` zurück:
- `1` wenn mindestens eine Datei aus Schicht 3 oder 4 existiert und nicht leer ist
- `0` wenn Daten nur aus config-default stammen

**Rückgabe:** Hash mit allen geparsten Werten plus `_has_user_config => 0|1`

---

## Feature: Quick Fix

**Trigger:** `$cfg{_has_user_config} == 0`

**Aktion (POST `action=fix_config` in `manage.cgi`):**
1. Liest `port` und `gamename` aus dem geparsten Config-Hash (Werte kommen aus Defaults)
2. Erstellt `$script_dir/lgsm/config-lgsm/common.cfg` mit diesen zwei Werten
3. Ausführung via `su -s /bin/bash -c "..." $unix_user` (nicht als root)
4. Redirect zurück auf `manage.cgi?instance_id=...`

**Sicherheit:** Nur `port` (Integer) und `gamename` (sanitized) werden geschrieben — keine freien Strings aus User-Input.

---

## manage.cgi Panel-Erweiterungen

### Neue Struktur (von oben nach unten):

**1. Server-Info-Tabelle**
- Spiel (`$inst->{'game'}`)
- Port (`$inst->{'port'}`)
- Status (`$inst->{'status'}`)
- Script (`$inst->{'script'}`)

**2. Firewall-Status**
```
Firewall: [offen/geschlossen]  [Port öffnen] / [Port schließen]
```
POST-Action `fw_open` / `fw_close` auf `manage.cgi`.

**3. Steuerungs-Buttons** (start/stop/restart/update — unverändert)

**4. Warnungen**
- Zeigt `@{$inst->{'warnings'}}` als `ui_table_row`-Liste
- Wenn `$cfg{_has_user_config} == 0`: zusätzliche Warnung + `[Quick Fix anlegen]`-Button

### check_referer entfernt
`check_referer()` existiert in dieser Webmin-Version nicht. POST-Schutz läuft über `ReadParse`. Kein Aufruf in `manage.cgi`.

---

## Betroffene Dateien

| Datei | Änderung |
|---|---|
| `src/lib/instance.pl` | Geschichteter Parser, `_has_user_config` Flag |
| `src/lib/core.pl` | `run_server_action` + optionaler `$script_name` |
| `src/manage.cgi` | UTF-8, Firewall-Sektion, Warnungen, Quick-Fix, script_name-Fix |
| `src/index.cgi` | UTF-8 |
| `src/lang/de` | Neue Keys: `manage_script`, `manage_fw_status`, `manage_fix_config`, `manage_fix_config_warn`, `manage_fix_config_btn` |
| `src/lang/en` | Dieselben Keys auf Englisch |
| `t/test_config_parser.pl` | Tests für geschichteten Parser |

---

## Nicht in diesem Sub-Projekt

- SFTP-Verwaltung im Panel (Sub-Projekt B)
- Config-Editor / Server-Configs bearbeiten (Sub-Projekt C)
