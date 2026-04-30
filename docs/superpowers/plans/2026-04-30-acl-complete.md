# ACL-System Vervollständigung — Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drei Lücken im ACL-System schließen: `_compute_role()` erkennt Admin-Rolle nicht wenn user-ACL-Datei kein `role`-Feld hat; Operators sehen alle FTP-User statt nur ihre eigenen; `config.cgi` hat keinen Admin-Guard.

**Architecture:** Alle Änderungen bleiben innerhalb des bestehenden Rollenmodells (admin/operator/viewer). `acl.pl` bekommt den Merge-Fix und eine neue Funktion `allowed_ftp_users()`. `ftp_settings.cgi` filtert die angezeigte Liste. `config.cgi` bekommt einen Admin-Guard.

**Tech Stack:** Perl, Webmin module ACL (`%access`, `read_file`, `get_module_acl`), TAP-Tests

---

## Datei-Übersicht

| Datei | Änderung |
|---|---|
| `src/lib/acl.pl` | `_compute_role()` Merge-Fix + neue `allowed_ftp_users()` |
| `src/ftp_settings.cgi` | FTP-User-Liste nach `allowed_ftp_users()` filtern |
| `src/config.cgi` | `require './lib/acl.pl'` + Admin-Guard hinzufügen |
| `t/test_acl_complete.pl` | Neue Test-Datei (7 Tests, TAP) |

**Nicht zu ändern:** `games_admin.cgi` (Guard ✅), `steam_settings.cgi` (Guard via `can_scan` ✅), `ftp_settings.cgi` Guard (✅ Zeile 17), `jobs.cgi` Filter (✅ Zeilen 104-106).

---

## Task 1: Test-Datei erstellen (failing tests)

**Files:**
- Create: `t/test_acl_complete.pl`

- [ ] **Schritt 1: Test-Datei schreiben**

```perl
#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
use File::Temp qw(tempdir);
chdir "$Bin/.." or die "Cannot chdir: $!";

sub pass { print "ok - $_[0]\n" }
sub fail { print "not ok - $_[0]\n" }
sub error { die "error: $_[0]\n" }

require 't/stubs.pl';

our ($module_name, $remote_user, $config_directory, $_effective_role_cache);
our %access;
$module_name = 'linuxgsm-webcore';
$remote_user = 'testuser';
$config_directory = '/nonexistent';

# Stub: get_instance — für allowed_ftp_users Tests
my %_inst_db = (
    'mc1' => { id => 'mc1', user => 'mcuser', sftp_user => 'mc-ftp' },
    'tf1' => { id => 'tf1', user => 'tfuser', sftp_user => ''       },
);
sub get_instance { return $_inst_db{$_[0]} }

require 'src/lib/acl.pl';

print "1..7\n";

# Test 1: user-Datei ohne role-Feld → role aus defaultacl (admin)
{
    my $tmp = tempdir(CLEANUP => 1);
    mkdir "$tmp/linuxgsm-webcore";
    open(my $fh, '>', "$tmp/linuxgsm-webcore/testuser") or die $!;
    print $fh "can_manage_ftp=1\n";   # hat Felder aber KEIN role
    close $fh;
    open(my $df, '>', "$tmp/linuxgsm-webcore/defaultacl") or die $!;
    print $df "role=admin\n";
    close $df;

    $_effective_role_cache = undef;
    %access = ();
    $config_directory = $tmp;

    effective_role() eq 'admin'
        ? pass('_compute_role merge: user-Datei ohne role → admin von defaultacl')
        : fail('_compute_role merge: user-Datei ohne role → admin von defaultacl (got: ' . (effective_role()//'undef') . ')');

    $config_directory = '/nonexistent';
}

# Test 2: user-Datei MIT role=operator hat Vorrang vor defaultacl
{
    my $tmp = tempdir(CLEANUP => 1);
    mkdir "$tmp/linuxgsm-webcore";
    open(my $fh, '>', "$tmp/linuxgsm-webcore/testuser") or die $!;
    print $fh "role=operator\ncan_manage_ftp=0\n";
    close $fh;
    open(my $df, '>', "$tmp/linuxgsm-webcore/defaultacl") or die $!;
    print $df "role=admin\n";
    close $df;

    $_effective_role_cache = undef;
    %access = ();
    $config_directory = $tmp;

    effective_role() eq 'operator'
        ? pass('_compute_role: user-Datei mit role=operator hat Vorrang vor defaultacl')
        : fail('_compute_role: user-Datei mit role=operator hat Vorrang (got: ' . (effective_role()//'undef') . ')');

    $config_directory = '/nonexistent';
}

# Test 3: Admin sieht alle FTP-User
{
    $_effective_role_cache = undef;
    %access = (role => 'admin');
    my @r = allowed_ftp_users('mc-ftp', 'other-ftp', 'third-ftp');
    scalar(@r) == 3
        ? pass('allowed_ftp_users: admin bekommt alle 3 FTP-User')
        : fail('allowed_ftp_users: admin soll 3 bekommen, got ' . scalar(@r));
}

# Test 4: Operator mit Server mc1 (sftp_user=mc-ftp) → nur mc-ftp
{
    $_effective_role_cache = undef;
    %access = (role => 'operator', servers => 'mc1');
    my @r = allowed_ftp_users('mc-ftp', 'other-ftp');
    (scalar(@r) == 1 && $r[0] eq 'mc-ftp')
        ? pass('allowed_ftp_users: operator sieht nur FTP-User seines Servers')
        : fail('allowed_ftp_users: operator filter (got: ' . join(', ', @r) . ')');
}

# Test 5: Operator mit Server tf1 (sftp_user='') → leere Liste
{
    $_effective_role_cache = undef;
    %access = (role => 'operator', servers => 'tf1');
    my @r = allowed_ftp_users('mc-ftp', 'other-ftp');
    scalar(@r) == 0
        ? pass('allowed_ftp_users: operator ohne sftp_user sieht keine FTP-User')
        : fail('allowed_ftp_users: operator ohne sftp_user (got: ' . join(', ', @r) . ')');
}

# Test 6: Leerer Input → leere Liste
{
    $_effective_role_cache = undef;
    %access = (role => 'operator', servers => 'mc1');
    my @r = allowed_ftp_users();
    scalar(@r) == 0
        ? pass('allowed_ftp_users: leerer Input → leere Liste')
        : fail('allowed_ftp_users: leerer Input (got: ' . scalar(@r) . ')');
}

# Test 7: Operator mit wildcard servers ('*') → alle FTP-User
{
    $_effective_role_cache = undef;
    %access = (role => 'operator', servers => '*');
    my @r = allowed_ftp_users('mc-ftp', 'other-ftp');
    scalar(@r) == 2
        ? pass('allowed_ftp_users: operator mit servers=* sieht alle FTP-User')
        : fail('allowed_ftp_users: operator wildcard (got: ' . scalar(@r) . ')');
}
```

- [ ] **Schritt 2: Tests ausführen — müssen fehlschlagen (allowed_ftp_users fehlt noch)**

```bash
perl t/test_acl_complete.pl
```

Erwartetes Ergebnis: Test 1 schlägt fehl (gibt 'operator' statt 'admin' — Merge-Fix fehlt). Test 2 besteht bereits. Tests 3-7: Skript bricht ab mit `Undefined subroutine &main::allowed_ftp_users` beim ersten Aufruf in Test 3.

---

## Task 2: `acl.pl` — `_compute_role()` Merge-Fix + `allowed_ftp_users()`

**Files:**
- Modify: `src/lib/acl.pl:43-50` (innerhalb `_compute_role()`)
- Modify: `src/lib/acl.pl:152` (neue Funktion vor `1;`)

**Kontext:** `_compute_role()` Schritt 3 liest die user-spezifische ACL-Datei. Wenn sie kein `role`-Feld hat (Altdatei), wird `defaultacl` aktuell nur gelesen wenn `%facl` leer ist — das ist falsch, weil die Datei andere Felder enthalten kann.

- [ ] **Schritt 1: Merge-Fix in `_compute_role()` implementieren**

In `src/lib/acl.pl` den Block von Zeile 43-50 ersetzen (innerhalb des Schritt-3-`if`-Blocks):

Alter Code:
```perl
        my %facl;
        eval {
            my $ufile = "$config_directory/$module_name/$remote_user";
            my $dfile = "$config_directory/$module_name/defaultacl";
            &read_file($ufile, \%facl) if -r $ufile;
            &read_file($dfile, \%facl) if !%facl && -r $dfile;
        };
        return $facl{'role'} if defined $facl{'role'};
```

Neuer Code:
```perl
        my %facl;
        eval {
            my $ufile = "$config_directory/$module_name/$remote_user";
            my $dfile = "$config_directory/$module_name/defaultacl";
            &read_file($ufile, \%facl) if -r $ufile;
            if (!defined $facl{'role'} && -r $dfile) {
                my %dflt;
                &read_file($dfile, \%dflt);
                $facl{'role'} //= $dflt{'role'};
            }
        };
        &log_debug("ACL file fallback: user=" . ($remote_user // '?') . " role=" . ($facl{'role'} // 'undef'));
        return $facl{'role'} if defined $facl{'role'};
```

- [ ] **Schritt 2: `allowed_ftp_users()` ans Ende von `acl.pl` einfügen** (vor `1;`)

```perl
# Returns the subset of @all_ftp_names visible to the current user.
# Admins: all. Operators/viewers: only names linked via sftp_user to their instances.
sub allowed_ftp_users {
    my (@all_ftp_names) = @_;
    return @all_ftp_names if is_admin();
    my @srv = allowed_servers();
    return @all_ftp_names if grep { $_ eq '*' } @srv;
    my %allowed;
    for my $iid (@srv) {
        my $inst = eval { get_instance($iid) };
        next unless $inst;
        my $su = $inst->{'sftp_user'} // '';
        $allowed{$su} = 1 if $su ne '';
    }
    return grep { $allowed{$_} } @all_ftp_names;
}
```

- [ ] **Schritt 3: Syntax prüfen**

```bash
perl -c src/lib/acl.pl
```

Erwartetes Ergebnis: `src/lib/acl.pl syntax OK`

- [ ] **Schritt 4: Tests ausführen — alle 7 müssen grün sein**

```bash
perl t/test_acl_complete.pl
```

Erwartetes Ergebnis:
```
1..7
ok - _compute_role merge: user-Datei ohne role → admin von defaultacl
ok - _compute_role: user-Datei mit role=operator hat Vorrang vor defaultacl
ok - allowed_ftp_users: admin bekommt alle 3 FTP-User
ok - allowed_ftp_users: operator sieht nur FTP-User seines Servers
ok - allowed_ftp_users: operator ohne sftp_user sieht keine FTP-User
ok - allowed_ftp_users: leerer Input → leere Liste
ok - allowed_ftp_users: operator mit servers=* sieht alle FTP-User
```

- [ ] **Schritt 5: Bestehende ACL-Tests noch grün**

```bash
perl t/test_acl_roles.pl
perl t/test_acl.pl
```

Erwartetes Ergebnis: alle Tests `ok`

- [ ] **Schritt 6: Commit**

```bash
git add src/lib/acl.pl t/test_acl_complete.pl
git commit -m "feat: acl.pl — _compute_role merge-fix + allowed_ftp_users()

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 3: `ftp_settings.cgi` — FTP-User-Liste filtern

**Files:**
- Modify: `src/ftp_settings.cgi:127` (nach `parse_ftpd_passwd`)

**Kontext:** Zeile 127 liest alle FTP-User aus der Passwortdatei. Darunter (Zeile 128) beginnt der `if (@ftp_users)` Block der die Tabelle aufbaut. Operatoren sehen aktuell alle User — der Filter wird direkt nach dem Einlesen eingefügt.

- [ ] **Schritt 1: Filter nach Zeile 127 einfügen**

In `src/ftp_settings.cgi` nach:
```perl
my @ftp_users = &parse_ftpd_passwd($auth_file);
```

Folgendes einfügen:
```perl
unless (&is_admin()) {
    my @visible = &allowed_ftp_users(map { $_->{'name'} } @ftp_users);
    my %vis = map { $_ => 1 } @visible;
    @ftp_users = grep { $vis{$_->{'name'}} } @ftp_users;
}
```

- [ ] **Schritt 2: Syntax prüfen**

```bash
perl -c src/ftp_settings.cgi 2>&1 | grep -v "can't locate"
```

Erwartetes Ergebnis: `src/ftp_settings.cgi syntax OK`

- [ ] **Schritt 3: Commit**

```bash
git add src/ftp_settings.cgi
git commit -m "feat: ftp_settings.cgi — FTP-User-Liste nach allowed_ftp_users() filtern

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 4: `config.cgi` — Admin-Guard

**Files:**
- Modify: `src/config.cgi:9-12`

**Kontext:** `config.cgi` hat aktuell nur `require './lib/core.pl'` und keinen ACL-Import. Modul-Einstellungen (debug_logging) dürfen nur Admins ändern.

- [ ] **Schritt 1: `require './lib/acl.pl'` und Guard einfügen**

In `src/config.cgi` nach:
```perl
require './lib/core.pl';
```

Einfügen:
```perl
require './lib/acl.pl';
```

Und nach:
```perl
&ReadParse(\%in);
```

Einfügen:
```perl
&is_admin() or &error($text{'err_acl_admin_only'} || 'Access denied');
```

- [ ] **Schritt 2: Syntax prüfen**

```bash
perl -c src/config.cgi 2>&1 | grep -v "can't locate"
```

Erwartetes Ergebnis: `src/config.cgi syntax OK`

- [ ] **Schritt 3: Commit**

```bash
git add src/config.cgi
git commit -m "feat: config.cgi — Admin-Guard hinzufügen

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 5: Verifikation + Build

**Files:** keine Änderungen

- [ ] **Schritt 1: Alle neuen Tests ausführen**

```bash
perl t/test_acl_complete.pl
```

Erwartetes Ergebnis: `7/7 ok`

- [ ] **Schritt 2: Bestehende ACL-Tests ausführen**

```bash
perl t/test_acl_roles.pl && perl t/test_acl.pl
```

Erwartetes Ergebnis: alle `ok`

- [ ] **Schritt 3: Standard-Verifikation**

```bash
bash scripts/verify.sh
```

Erwartetes Ergebnis: keine Fehler

- [ ] **Schritt 4: Build**

```bash
bash scripts/build.sh
```

Erwartetes Ergebnis: `==> Built: dist/linuxgsm-webcore-0.1.0.wbm`
