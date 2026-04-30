# ACL-System Vervollständigung — Design Spec

**Datum:** 2026-04-30  
**Status:** Approved

## Ziel

Das bestehende Rollenmodell (admin/operator/viewer) ist architektonisch korrekt. Drei konkrete Lücken werden geschlossen:

1. Admin-Erkennung schlägt fehl wenn eine veraltete user-spezifische ACL-Datei kein `role`-Feld enthält
2. FTP-User-Liste zeigt Operatoren alle FTP-User statt nur die ihrer eigenen Server
3. Mehrere CGIs haben keinen ACL-Guard am Seitenanfang

Kein Umbau des Rollenmodells. Kein neues Granularitätslevel. YAGNI.

---

## Betroffene Dateien

| Datei | Änderung |
|---|---|
| `src/lib/acl.pl` | `_compute_role()` Merge-Fix + neue `allowed_ftp_users()` |
| `src/ftp_settings.cgi` | Guard + gefilterte FTP-User-Liste |
| `src/games_admin.cgi` | Admin-only Guard |
| `src/steam_settings.cgi` | Admin-only Guard |
| `src/config.cgi` | Admin-only Guard |
| `src/jobs.cgi` | Job-Liste nach `allowed_servers()` filtern |
| `t/test_acl_complete.pl` | Neue Tests für alle Änderungen |

---

## Komponenten

### 1. `_compute_role()` — Merge statt Override

**Problem:** Wenn eine user-spezifische ACL-Datei existiert aber kein `role`-Feld hat (Altdatei vor Einführung des Rollenfelds), bricht der aktuelle Code: Schritt 3 (direkter Datei-Fallback) liest die Datei, findet kein `role` und gibt `undef` zurück — der Code fällt durch auf Legacy-Checks oder Default `operator`. Der `defaultacl`-Wert (`role=admin`) wird nie gelesen.

**Fix:** In Schritt 3 wird die user-spezifische Datei geladen. Falls `role` fehlt, wird `defaultacl` als Ergänzung eingelesen (merge: user-Felder haben Vorrang, `defaultacl` füllt fehlende Felder). Danach `return $facl{'role'}` wie bisher.

**Logging:** `log_debug("ACL role resolved: user=$remote_user role=$role source=<file|default|legacy>")` damit `is_admin=nein`-Probleme nachvollziehbar sind.

```perl
# Pseudocode — _compute_role() Schritt 3
my %facl;
&read_file($ufile, \%facl) if -r $ufile;
if (!defined $facl{'role'}) {
    my %dflt;
    &read_file($dfile, \%dflt) if -r $dfile;
    $facl{'role'} //= $dflt{'role'};   # defaultacl ergänzt fehlende Felder
}
return $facl{'role'} if defined $facl{'role'};
```

---

### 2. `allowed_ftp_users()` — neue Funktion in `acl.pl`

Gibt die Liste der FTP-Usernamen zurück die der aktuelle Webmin-User sehen und verwalten darf.

```
allowed_ftp_users(@all_ftp_users):
  if is_admin() → return @all_ftp_users
  
  my @my_instances = allowed_servers()   # Instance-IDs des Operators
  my %allowed_ftp  = ()
  for each $instance_id in @my_instances:
      $sftp = resolve_instance_sftp_user($instance_id, undef)
      $allowed_ftp{$sftp} = 1 if defined $sftp
  
  return grep { $allowed_ftp{$_} } @all_ftp_users
```

Parameter: Liste aller vorhandenen FTP-Usernamen (von `ftp_settings.cgi` übergeben, da `acl.pl` keine FTP-Logik enthält).  
Rückgabe: gefilterte Liste.

---

### 3. `ftp_settings.cgi` — Guard + gefilterter Aufruf

**Guard am Seitenanfang** (nach `init_config()`):
```perl
&error($text{'err_access_denied'}) unless can_manage_ftp();
```

**Gefilterter Aufruf** beim Aufbau der FTP-User-Tabelle:
```perl
my @all_ftp = list_virtual_ftp_users();          # bestehende Funktion
my @visible  = allowed_ftp_users(@all_ftp);       # neu: ACL-Filter
# @visible statt @all_ftp für die Tabelle verwenden
```

---

### 4. Admin-only Guards

Drei CGIs bekommen identischen Guard direkt nach `init_config()` + `require`-Block:

```perl
&error($text{'err_acl_admin_only'}) unless is_admin();
```

Betroffen: `games_admin.cgi`, `steam_settings.cgi`, `config.cgi`.

`acl_manage.cgi` hat den Guard bereits — kein Change.  
`scan.cgi` und `wizard.cgi` haben bereits `can_scan()` / `can_create()` — kein Change.

---

### 5. `jobs.cgi` — Instanzfilter

Die Job-Liste lädt aktuell alle Jobs ungefiltert. Operators dürfen nur Jobs ihrer eigenen Instanzen sehen.

**Fix:** Nach dem Laden aller Jobs filtern:
```perl
my @jobs = list_jobs();
@jobs = grep {
    my $iid = $_->{'instance_id'} // '';
    is_admin() || !$iid || user_can_manage($iid)
} @jobs;
```

Jobs ohne `instance_id` (z.B. System-Jobs) sind für alle sichtbar — oder nur für Admins, je nach Konvention. Hier: nur Admins (leere `instance_id` → Admin-only).

---

## Nicht in Scope

- Neues Flag `can_delete`, `can_update` o.ä. (Ansatz C — YAGNI)
- Umbau der Rollen-Hierarchie
- Neues UI für ACL-Zuweisung (`acl_manage.cgi` ist vollständig)
- Webmin-Gruppen-Support

---

## Tests (`t/test_acl_complete.pl`)

| Test | Was wird geprüft |
|---|---|
| role merge: user-Datei ohne role-Feld | `effective_role()` gibt admin zurück (aus defaultacl) |
| role merge: user-Datei mit role=operator | `effective_role()` gibt operator zurück (user hat Vorrang) |
| allowed_ftp_users admin | gibt alle FTP-User zurück |
| allowed_ftp_users operator mit sftp_user=mc-ftp | gibt nur mc-ftp zurück, filtert andere |
| allowed_ftp_users operator ohne sftp_user | gibt leere Liste zurück |
| jobs filter admin | sieht alle Jobs |
| jobs filter operator | sieht nur Jobs seiner Instanzen |
