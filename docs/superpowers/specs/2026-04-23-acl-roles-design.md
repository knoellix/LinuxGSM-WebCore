# LinuxGSM-WebCore ACL-Rollen — Design-Spec

**Datum:** 2026-04-23
**Status:** Genehmigt

## Ziel

Ersetze das bisherige flache ACL-Modell (`servers=*` / Liste) durch ein rollenbasiertes System, das vollständig mit Webmins nativem Berechtigungssystem integriert ist. Webmin-Admins erhalten automatisch vollen Zugriff ohne manuelle Modul-ACL-Einträge.

---

## Rollen-Modell

Drei Rollen, gespeichert als `role`-Feld in der Modul-ACL:

| Rolle | Erstellen | Server verwalten | FTP verwalten | Admin-Seite |
|-------|-----------|------------------|---------------|-------------|
| `admin` | ✅ alle | ✅ alle | ✅ immer | ✅ |
| `operator` | ❌ | ✅ zugewiesene Server | 🔘 `can_manage_ftp` (default: 0) | ❌ |
| `viewer` | ❌ | 👁️ read-only | 🔘 `can_manage_ftp` (default: 0) | ❌ |

**Webmin-Admin-Erkennung:**
Wer in Webmin selbst als Admin gilt (`acl::master_admin($remote_user)`), bekommt automatisch die `admin`-Rolle — unabhängig vom `role`-Feld in der Modul-ACL. Kein manuelles Setzen nötig.

**FTP-Berechtigung:**
`can_manage_ftp` (0/1) gilt für `operator` und `viewer` gleichermaßen. Admins haben FTP immer. Default: 0.

---

## ACL-Datenspeicherung

Felder in der Modul-ACL-Datei (`/etc/webmin/<module>/<webmin_user>`):

```
role           = admin | operator | viewer
servers        = Leerzeichen-getrennte Instance-IDs (z.B. "gs_mc_myserver gs_ark")
can_manage_ftp = 0 | 1
```

**Rückwärtskompatibilität:**
Bestehende ACL-Dateien ohne `role`-Feld werden wie folgt behandelt:
- `servers=*` → Rolle `admin`
- Alles andere → Rolle `operator`, `can_manage_ftp=0`

---

## `acl_security.pl` — Änderungen

Neues Formular mit drei Feldern:

1. **Dropdown `role`**: Admin / Operator / Zuschauer
2. **Textfeld `servers`**: Leerzeichen-getrennte Instance-IDs — erscheint nur bei `operator` und `viewer`
3. **Radio `can_manage_ftp`**: Ja/Nein — erscheint bei `operator` und `viewer`

`acl_security_save` sanitisiert `servers` (nur `[a-z0-9_\-\s]`) und setzt `role` auf gültigen Wert.

---

## `src/lib/acl.pl` — neue/geänderte Funktionen

```perl
# Effektive Rolle: 'admin' wenn Webmin-Admin, sonst $access{'role'} // 'operator'
sub effective_role()

# 1 wenn effective_role() eq 'admin'
sub is_admin()

# 1 wenn is_admin() — Erstellen ist Admin-only
sub can_create()

# 1 wenn is_admin() — Scan ist Admin-only
sub can_scan()

# 1 wenn is_admin() ODER $access{'can_manage_ftp'} bei operator/viewer
sub can_manage_ftp()

# 1 wenn is_admin() ODER $id in servers-Liste
sub user_can_manage($id)

# 1 wenn role eq 'viewer' UND user_can_manage($id)
sub user_is_readonly($id)

# Alle Instanzen die der aktuelle User sehen darf
sub list_managed_instances()
```

**Webmin-Admin-Erkennung in `effective_role()`:**

```perl
sub effective_role {
    foreign_require('acl', 'acl-lib.pl');
    return 'admin' if acl::master_admin($remote_user);
    return $access{'role'} // 'operator';
}
```

---

## `acl_manage.cgi` — neue Datei

**Zugang:** Nur Admins (`is_admin()` oder `error()`).

**Ansicht:** Tabelle aller Webmin-User mit:
- Webmin-Username
- Effektive Rolle (inkl. "(Webmin-Admin)"-Markierung für native Admins)
- Zugewiesene Server (als Liste)
- `can_manage_ftp`-Status
- "Bearbeiten"-Button (öffnet Formular)

**Bearbeitungsformular (gleiche Seite via `action=edit`):**
- Dropdown: Rolle
- Multiselect: Server aus allen bekannten Instanzen
- Radio: `can_manage_ftp`
- Speichert via `save_module_acl(\%acl, $user, $module_name)`

Webmin-native Admins werden angezeigt, aber ihr `role`-Feld ist nicht editierbar (grau, Hinweis "Webmin-Admin").

---

## Integration bestehender CGIs

### `index.cgi`
- `can_create()` → Admin-only → Wizard-Button nur für Admins sichtbar
- `list_managed_instances()` → unverändert, filtert nach Rolle/servers
- Viewer sehen Instanzen, "Verwalten"-Link führt zu read-only-Ansicht

### `manage.cgi`
- Alle schreibenden Aktionen prüfen `!user_is_readonly($id)` → sonst `error()`
- FTP-Tab/Sektion prüft `can_manage_ftp()` → ausgeblendet wenn 0

### `wizard.cgi`
- Prüft `is_admin()` am Anfang — nur Admins dürfen neue Server anlegen

### `scan.cgi`
- `can_scan()` bleibt, aber effektiv Admin-only

### `ftp_settings.cgi`
- Globale ProFTPD-Einstellungen bleiben Admin-only (keine Änderung)

---

## `src/lang/de` — neue Strings

```
acl_role=Rolle
acl_role_admin=Administrator
acl_role_operator=Operator
acl_role_viewer=Zuschauer
acl_can_manage_ftp=Darf FTP-User verwalten
acl_manage_title=Server-Zuweisungen verwalten
acl_manage_col_user=Webmin-User
acl_manage_col_role=Rolle
acl_manage_col_servers=Zugewiesene Server
acl_manage_col_ftp=FTP
acl_manage_col_actions=Aktionen
acl_manage_webmin_admin=(Webmin-Admin)
acl_manage_edit=Bearbeiten
acl_manage_save=Speichern
acl_manage_servers_hint=Instance-IDs, Leerzeichen-getrennt
err_acl_admin_only=Zugriff verweigert — nur für Administratoren
err_readonly=Dieser Server ist für Sie schreibgeschützt
```

---

## `src/lang/en` — neue Strings

```
acl_role=Role
acl_role_admin=Administrator
acl_role_operator=Operator
acl_role_viewer=Viewer
acl_can_manage_ftp=May manage FTP users
acl_manage_title=Manage server assignments
acl_manage_col_user=Webmin user
acl_manage_col_role=Role
acl_manage_col_servers=Assigned servers
acl_manage_col_ftp=FTP
acl_manage_col_actions=Actions
acl_manage_webmin_admin=(Webmin admin)
acl_manage_edit=Edit
acl_manage_save=Save
acl_manage_servers_hint=Instance IDs, space-separated
err_acl_admin_only=Access denied — administrators only
err_readonly=This server is read-only for your account
```

---

## Tests

- `t/test_acl_roles.pl`:
  - `effective_role()` für Webmin-Admin → `admin` (mock `acl::master_admin`)
  - `effective_role()` für User ohne `role`-Feld → `operator`
  - `effective_role()` für Legacy `servers=*` → `admin`
  - `is_admin()`, `can_create()`, `can_scan()`, `can_manage_ftp()` für alle Rollen
  - `user_is_readonly($id)` für Viewer mit/ohne Zugriff
  - `list_managed_instances()` filtert korrekt nach Rolle

---

## Sicherheits-Checkliste

- [ ] `acl_manage.cgi` prüft `is_admin()` als erste Aktion — kein Bypass möglich
- [ ] `manage.cgi` schreibende Aktionen prüfen `user_is_readonly()` vor Ausführung
- [ ] `servers`-Feld wird sanitisiert (nur alphanumerisch + `_-`) — kein Injection-Risiko
- [ ] `save_module_acl()` schreibt nur in `/etc/webmin/<module>/` — kein Path-Traversal
- [ ] Webmin-native Admins können nicht durch ACL-Edit auf Viewer degradiert werden

---

## Nicht im Scope

- Gruppen-basierte ACL (Webmin-Gruppen → Rolle)
- Per-Server-Berechtigungen (granularer als Server-Liste)
- Audit-Log für ACL-Änderungen
- Selbst-Service: Operators können ihre eigene Rolle nicht ändern
