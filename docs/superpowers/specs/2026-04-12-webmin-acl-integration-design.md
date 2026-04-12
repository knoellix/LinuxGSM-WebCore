# Design: Webmin-native ACL-Integration

**Datum:** 2026-04-12  
**Status:** Genehmigt  
**Scope:** Rechtesystem für LinuxGSM-WebCore vollständig auf Webmins natives ACL-System umstellen

---

## Kontext & Problem

Das Plugin nutzt bisher eine eigene `is_admin()`-Funktion, die `$ENV{REMOTE_USER} eq 'root'` oder den `alls`-Flag aus `acl::list_users()` prüft. Das ist fragil: Nicht-root-Admins (z.B. `knoellix`) werden nicht erkannt, Admin-Buttons erscheinen nicht.

Außerdem liegt die Server-Zuordnung in eigenen Dateien unter `/etc/webmin/linuxgsm-webcore/<game_user>`. Das ist ein zweiter, nicht-Webmin-kompatibler Datenspeicher.

**Ziel:** Alles auf Webmins `get_module_acl()` / `save_module_acl()` / `%access` umstellen. Kein eigener Datenspeicher, keine Halluzinations-Checks für Admin-Status.

---

## User Cases

| User-Typ | Beispiel | Rechte |
|---|---|---|
| Webmin-Admin | `knoellix` | Alle Server, Wizard, Scan |
| Game-Server-User | `alice` | Nur zugewiesene Server, kein Wizard/Scan |
| Neuer User (default) | beliebig | Keine Rechte bis Admin setzt |
| FTP-User | System-User | Kein Webmin-Login, nur SFTP-Zugang |

---

## Architektur: Drei Schichten

```
┌─────────────────────────────────────────────────────────┐
│  Schicht 1: Webmin-Modul-ACL  (wer darf was TUN)        │
│  /etc/webmin/linuxgsm-webcore/<webmin_user>             │
│  can_create=1  can_scan=1  servers=mc-test tf2-test     │
├─────────────────────────────────────────────────────────┤
│  Schicht 2: %access-Hash  (von init_config() befüllt)   │
│  Automatisch aus Schicht 1 → in jedem CGI verfügbar     │
├─────────────────────────────────────────────────────────┤
│  Schicht 3: Unix-User / Game-Server  (wer existiert)    │
│  /etc/passwd → list_instances() → get_instance()        │
└─────────────────────────────────────────────────────────┘
```

---

## Permission-Schema

### `src/defaultacl`
```
can_create=0
can_scan=0
servers=
```

| Feld | Typ | Bedeutung |
|---|---|---|
| `can_create` | `0`/`1` | Wizard aufrufen, neue Server anlegen |
| `can_scan` | `0`/`1` | Scan-Seite aufrufen, Owner zuweisen |
| `servers` | `*` oder Leerzeichen-getrennte Unix-Namen | Welche Server dieser User sehen/steuern darf |

**Default:** Alle Felder leer/0 — neuer User sieht nichts bis Admin Rechte setzt. Kein hardcodierter Username im Code.

### Beispiel-Belegungen

| Webmin-User | `can_create` | `can_scan` | `servers` |
|---|---|---|---|
| Admin (beliebiger Name) | `1` | `1` | `*` |
| `alice` (Game-User) | `0` | `0` | `mc-survival cs2-server` |
| Neuer User | `0` | `0` | *(leer)* |

---

## Komponenten

### Neue Dateien
- `src/defaultacl` — Permission-Schema
- `src/acl_edit.cgi` — Webmin ACL-Editor-Integration

### Geänderte Dateien
- `src/lib/acl.pl` — komplett umgeschrieben
- `src/index.cgi` — `is_admin()` → `%access`-Checks
- `src/wizard.cgi` — `is_admin()` → `$access{'can_create'}`
- `src/scan.cgi` — `is_admin()` → `$access{'can_scan'}`

### Entfernte Funktionen
- `is_admin()` — ersetzt durch direkte `%access`-Checks
- `get_owner()` / `set_owner()` — ersetzt durch `get_module_acl()` / `save_module_acl()`
- Eigene Owner-Dateien unter `/etc/webmin/linuxgsm-webcore/<game_user>` — nicht mehr nötig

---

## `lib/acl.pl` — neue API

```perl
# Aktions-Checks (lesen aus %access, befüllt von init_config())
sub can_create { return $access{'can_create'} ? 1 : 0 }
sub can_scan   { return $access{'can_scan'}   ? 1 : 0 }

# Server-Sichtbarkeit
sub allowed_servers()
  # Gibt ('*') oder Liste von Unix-Usernamen zurück

sub user_can_manage($game_user)
  # 1 wenn $game_user in allowed_servers() oder '*'

sub list_managed_instances()
  # list_instances() gefiltert durch user_can_manage()

# Wizard: Zugriff nach Installation automatisch gewähren
sub grant_server_access($webmin_user, $game_user)
  # get_module_acl() → $game_user in servers-Feld eintragen
  # → save_module_acl()

# Scan: Wer hat Zugriff auf einen Server?
sub get_server_owners($game_user)
  # Alle Webmin-User deren servers-Feld $game_user enthält

# Hilfsfunktionen
sub list_webmin_users()
  # Bleibt: acl::list_users() → sortierte Namen
```

---

## `acl_edit.cgi` — Webmin ACL-Editor

Webmin übergibt `?user=<webmin_username>`. Aufgerufen wenn Admin in  
"Webmin → Webmin-Benutzer → User → LinuxGSM" klickt.

**GET:** Zeigt Formular mit aktuellem ACL des Users:
- Checkbox: "Darf neue Game-Server erstellen" (`can_create`)
- Checkbox: "Darf Server scannen und zuweisen" (`can_scan`)
- Checkboxliste: alle Game-Server aus `list_instances()`

**POST:** Validiert Input → `save_module_acl(\%acl, $user, 'linuxgsm-webcore')`  
→ Redirect zurück zu Webmin-Benutzer-Übersicht

---

## Flows

### Flow 1: Erstmaliger Setup (einmalig)
```
Admin → Webmin-Benutzer → eigener User → LinuxGSM → Rechte bearbeiten
→ can_create=1, can_scan=1, servers=*
→ Speichern → Admin sieht ab sofort alle Buttons
```

### Flow 2: Wizard — neuer Server für anderen Webmin-User
```
Admin → Wizard → Schritt 1 (Spiel/User/Port/SFTP)
→ Schritt 2: Webmin-User auswählen
→ Schritt 3: Bestätigen → provision_server()
→ grant_server_access($webmin_user, $game_user)
     get_module_acl() → servers anfügen → save_module_acl()
→ Webmin-User sieht beim nächsten Login seinen Server
```

### Flow 3: ACL-Editor — nachträgliche Änderung
```
Admin → Webmin-Benutzer → alice → LinuxGSM → acl_edit.cgi?user=alice
→ can_create=☐  can_scan=☐
→ Server: ☑ mc-survival  ☐ tf2-test  ☐ cs2
→ Admin aktiviert ☑ tf2-test → Speichern
→ save_module_acl({servers=>'mc-survival tf2-test'}, 'alice', ...)
```

### Flow 4: Normaler User öffnet Modul
```
alice → LinuxGSM
→ init_config(): %access = {can_create=>0, can_scan=>0, servers=>'mc-survival tf2-test'}
→ index.cgi: keine Admin-Buttons
→ list_managed_instances(): nur mc-survival + tf2-test
→ manage.cgi: start/stop/restart/update erlaubt
→ SFTP-Credentials: sichtbar, kein Reset-Button (nur can_create-User dürfen)
```

### Flow 5: Scan
```
Admin ($access{'can_scan'}=1) → scan.cgi
→ list_instances() zeigt alle Unix-User mit LGSM-Script
→ get_server_owners() zeigt wer bereits Zugriff hat
→ Admin weist zu → grant_server_access()
```

---

## SFTP-Credentials

- **Alle User** sehen SFTP-Host, Port, Username ihrer zugewiesenen Server (read-only)
- **Nur `can_create`-User** sehen Reset-Button für SFTP-Passwort

---

## Tests

### `t/test_acl.pl` — angepasst
- `can_create()` / `can_scan()` mit gemocktem `%access`
- `user_can_manage()` mit `servers=*` und `servers=mc-test`
- `list_managed_instances()` mit Fixture-Instanzen
- `grant_server_access()` schreibt korrekt in Webmin-ACL-Datei
- `get_server_owners()` liest korrekt zurück

### `t/stubs.pl` — Erweiterungen
- `get_module_acl($user, $module)` — liest aus temp. Testverzeichnis
- `save_module_acl(\%acl, $user, $module)` — schreibt in temp. Testverzeichnis

---

## Nicht im Scope

- Automatische ACL-Migration von alten Owner-Dateien (Plugin ist noch in Entwicklung, kein Produktivdaten-Bestand)
- Feinrechte pro Server (start/stop/update einzeln steuerbar) — YAGNI, kann später ergänzt werden
- Webmin-User selbst anlegen/löschen — außerhalb des Plugins

---

## Verifikation

1. `bash scripts/build.sh` — alle Tests grün
2. `.wbm` installieren, als Nicht-root-Admin: Rechte einmalig setzen → Buttons erscheinen
3. Zweiten Webmin-User anlegen, Server zuweisen → User sieht nur seinen Server
4. `acl_edit.cgi` öffnen: Checkboxliste zeigt vorhandene Server korrekt
5. Wizard erstellt Server + gewährt Zugriff automatisch
