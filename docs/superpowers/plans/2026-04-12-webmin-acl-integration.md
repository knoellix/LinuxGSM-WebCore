# Webmin-native ACL Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Webmin's native `get_module_acl()` / `save_module_acl()` / `%access` system replaces the fragile `is_admin()` function and custom owner-file storage.

**Architecture:** A `defaultacl` file defines the permission schema (`can_create`, `can_scan`, `servers`). Webmin's `init_config()` fills `%access` automatically for every CGI request. `acl.pl` reads from `%access` and uses Webmin's `get_module_acl()` / `save_module_acl()` to grant/revoke server access. A new `acl_edit.cgi` integrates into Webmin's built-in user ACL editor.

**Tech Stack:** Perl 5, Webmin API (`init_config`, `get_module_acl`, `save_module_acl`, `foreign_require`, `ui_*`), TAP (pass/fail helpers), `File::Temp`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `src/defaultacl` | **Create** | Permission defaults for all new users |
| `src/lib/acl.pl` | **Rewrite** | ACL checks via `%access`, grant/revoke via Webmin API |
| `src/acl_edit.cgi` | **Create** | Webmin ACL editor UI for this module |
| `src/index.cgi` | **Modify** | Remove debug block, use `%access` for buttons |
| `src/wizard.cgi` | **Modify** | Replace `is_admin()` → `can_create()` |
| `src/scan.cgi` | **Modify** | Replace `is_admin()` → `can_scan()` |
| `src/lang/en` | **Modify** | Add `acl_edit_title`, `acl_can_create`, `acl_can_scan`, `acl_servers`, `acl_servers_all`, `acl_save` |
| `src/lang/de` | **Modify** | Same keys in German |
| `t/stubs.pl` | **Modify** | Add `get_module_acl` + `save_module_acl` stubs |
| `t/test_acl.pl` | **Rewrite** | Tests for new ACL API |

---

## Task 1: `src/defaultacl` + Lang-Strings

**Files:**
- Create: `src/defaultacl`
- Modify: `src/lang/en`
- Modify: `src/lang/de`

- [ ] **Schritt 1: `src/defaultacl` anlegen**

```
can_create=0
can_scan=0
servers=
```

- [ ] **Schritt 2: Neue Strings in `src/lang/en` anhängen**

```
acl_edit_title=Edit Module Permissions
acl_can_create=May create new game servers
acl_can_scan=May scan and assign servers
acl_servers=Assigned servers
acl_servers_all=All servers (*)
acl_save=Save
```

- [ ] **Schritt 3: Neue Strings in `src/lang/de` anhängen**

```
acl_edit_title=Modulrechte bearbeiten
acl_can_create=Darf neue Game-Server erstellen
acl_can_scan=Darf Server scannen und zuweisen
acl_servers=Zugewiesene Server
acl_servers_all=Alle Server (*)
acl_save=Speichern
```

- [ ] **Schritt 4: Commit**

```bash
git add src/defaultacl src/lang/en src/lang/de
git commit -m "feat: add defaultacl and ACL editor lang strings"
```

---

## Task 2: Stubs erweitern

**Files:**
- Modify: `t/stubs.pl`

- [ ] **Schritt 1: `get_module_acl` + `save_module_acl` + `$stub_acl_dir` in `t/stubs.pl` einfügen**

Einfügen VOR der abschließenden `1;` in `t/stubs.pl`:

```perl
# Stub: ACL-Verzeichnis für Tests (von Tests auf tempdir gesetzt)
our $stub_acl_dir = '/tmp/webmin-stub-acl';

# Stub: get_module_acl — liest key=value aus $stub_acl_dir/$module/$user
sub get_module_acl {
    my ($user, $module) = @_;
    my %acl;
    my $file = "$stub_acl_dir/$module/$user";
    return %acl unless defined $file && -f $file;
    open(my $fh, '<', $file) or return %acl;
    while (<$fh>) {
        chomp;
        next if /^\s*#/ || !/=/;
        my ($k, $v) = split(/=/, $_, 2);
        $acl{$k} = $v if defined $k && defined $v;
    }
    close($fh);
    return %acl;
}

# Stub: save_module_acl — schreibt key=value nach $stub_acl_dir/$module/$user
sub save_module_acl {
    my ($acl_ref, $user, $module) = @_;
    my $dir = "$stub_acl_dir/$module";
    mkdir $dir unless -d $dir;
    open(my $fh, '>', "$dir/$user") or return;
    for my $k (sort keys %$acl_ref) {
        print $fh "$k=$acl_ref->{$k}\n";
    }
    close($fh);
}
```

- [ ] **Schritt 2: Commit**

```bash
git add t/stubs.pl
git commit -m "test: add get_module_acl / save_module_acl stubs"
```

---

## Task 3: Fehlschlagende Tests schreiben

**Files:**
- Rewrite: `t/test_acl.pl`

- [ ] **Schritt 1: `t/test_acl.pl` komplett ersetzen**

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

# Temp-Verzeichnis für ACL-Dateien
our $stub_acl_dir = tempdir(CLEANUP => 1);
our $module_name  = 'linuxgsm-webcore';

# %access wird von init_config() befüllt — hier manuell gesetzt
our %access;

# list_instances() wird in list_managed_instances() genutzt
sub list_instances {
    return (
        { user => 'mc-test',  game => 'Minecraft',         port => 25565 },
        { user => 'tf2-test', game => 'Team Fortress 2',   port => 27015 },
    );
}

require 'src/lib/acl.pl';

print "1..11\n";

# 1. can_create: false by default
{
    %access = ();
    !&can_create()
        ? pass('can_create false by default')
        : fail('can_create false by default');
}

# 2. can_create: true when set
{
    %access = (can_create => 1);
    &can_create()
        ? pass('can_create true when set')
        : fail('can_create true when set');
}

# 3. can_scan: false by default
{
    %access = ();
    !&can_scan()
        ? pass('can_scan false by default')
        : fail('can_scan false by default');
}

# 4. can_scan: true when set
{
    %access = (can_scan => 1);
    &can_scan()
        ? pass('can_scan true when set')
        : fail('can_scan true when set');
}

# 5. allowed_servers: returns ('*') for wildcard
{
    %access = (servers => '*');
    my @s = &allowed_servers();
    ($s[0] // '') eq '*'
        ? pass('allowed_servers returns wildcard')
        : fail("allowed_servers returns wildcard (got: @s)");
}

# 6. allowed_servers: parses space-separated list
{
    %access = (servers => 'mc-test tf2-test');
    my @s = &allowed_servers();
    (scalar(@s) == 2 && $s[0] eq 'mc-test' && $s[1] eq 'tf2-test')
        ? pass('allowed_servers parses list')
        : fail("allowed_servers parses list (got: @s)");
}

# 7. user_can_manage: wildcard grants access to any server
{
    %access = (servers => '*');
    &user_can_manage('any-server')
        ? pass('user_can_manage true with wildcard')
        : fail('user_can_manage true with wildcard');
}

# 8. user_can_manage: listed server granted
{
    %access = (servers => 'mc-test');
    &user_can_manage('mc-test')
        ? pass('user_can_manage true for listed server')
        : fail('user_can_manage true for listed server');
}

# 9. user_can_manage: unlisted server denied
{
    %access = (servers => 'mc-test');
    !&user_can_manage('tf2-test')
        ? pass('user_can_manage false for unlisted server')
        : fail('user_can_manage false for unlisted server');
}

# 10. list_managed_instances: filters by servers
{
    %access = (servers => 'mc-test');
    my @inst = &list_managed_instances();
    (scalar(@inst) == 1 && $inst[0]{'user'} eq 'mc-test')
        ? pass('list_managed_instances filters correctly')
        : fail("list_managed_instances filters correctly (got " . scalar(@inst) . ")");
}

# 11. grant_server_access: schreibt Server in ACL, keine Duplikate
{
    &grant_server_access('alice', 'mc-test');
    &grant_server_access('alice', 'mc-test');  # zweites Mal → kein Duplikat
    my %acl = &get_module_acl('alice', 'linuxgsm-webcore');
    my @servers = split /\s+/, ($acl{'servers'} // '');
    my $count = scalar grep { $_ eq 'mc-test' } @servers;
    $count == 1
        ? pass('grant_server_access writes once, no duplicate')
        : fail("grant_server_access writes once, no duplicate (count=$count)");
}
```

- [ ] **Schritt 2: Tests ausführen — müssen fehlschlagen**

```bash
perl t/test_acl.pl
```

Erwartetes Ergebnis: `not ok` für Tests die `can_create`, `can_scan`, `allowed_servers` etc. nutzen, weil `acl.pl` die Funktionen noch nicht hat.

- [ ] **Schritt 3: Commit**

```bash
git add t/test_acl.pl
git commit -m "test: rewrite test_acl.pl for new %access-based API"
```

---

## Task 4: `src/lib/acl.pl` neu schreiben

**Files:**
- Rewrite: `src/lib/acl.pl`

- [ ] **Schritt 1: `src/lib/acl.pl` komplett ersetzen**

```perl
# LinuxGSM-WebCore - ACL-Verwaltung via Webmin-Modul-ACL-System
#
# %access wird von Webmins init_config() automatisch befüllt aus:
#   /etc/webmin/<module_name>/<webmin_user>  (oder defaultacl als Fallback)
#
# Felder:
#   can_create  0/1   Darf Wizard/neue Server anlegen
#   can_scan    0/1   Darf Scan-Seite aufrufen
#   servers     '*' oder Leerzeichen-getrennte Unix-Usernamen
use strict;
use warnings;

our (%access, $module_name);

# Returns 1 if current Webmin user may create new game servers.
sub can_create { return $access{'can_create'} ? 1 : 0 }

# Returns 1 if current Webmin user may run the scanner.
sub can_scan { return $access{'can_scan'} ? 1 : 0 }

# Returns list of Unix usernames the current user may manage.
# Returns the single-element list ('*') for unrestricted access.
sub allowed_servers {
    my $s = $access{'servers'} // '';
    $s =~ s/^\s+|\s+$//g;
    return ('*') if $s eq '*';
    return grep { /\S/ } split /\s+/, $s;
}

# Returns 1 if the current user may manage the given Unix game user.
sub user_can_manage {
    my ($game_user) = @_;
    my @allowed = allowed_servers();
    return 1 if grep { $_ eq '*' } @allowed;
    return scalar grep { $_ eq $game_user } @allowed;
}

# Returns all instances the current user may manage.
# Admins (servers=*) get the full unfiltered list.
sub list_managed_instances {
    my @all = &list_instances();
    return @all if grep { $_ eq '*' } (allowed_servers());
    return grep { user_can_manage($_->{'user'}) } @all;
}

# Grants $webmin_user access to $game_user by appending to their servers list.
# No-op if already has access (including wildcard). Called by wizard after install.
sub grant_server_access {
    my ($webmin_user, $game_user) = @_;
    my %acl = get_module_acl($webmin_user, $module_name);
    my @servers = grep { /\S/ } split /\s+/, ($acl{'servers'} // '');
    return if grep { $_ eq $game_user || $_ eq '*' } @servers;
    push @servers, $game_user;
    $acl{'servers'} = join(' ', @servers);
    save_module_acl(\%acl, $webmin_user, $module_name);
}

# Returns sorted list of Webmin usernames that have access to $game_user.
sub get_server_owners {
    my ($game_user) = @_;
    my @owners;
    eval {
        foreign_require('acl', 'acl-lib.pl');
        for my $u (acl::list_users()) {
            next unless ref($u) eq 'HASH';
            my %acl = get_module_acl($u->{'name'}, $module_name);
            my @s = grep { /\S/ } split /\s+/, ($acl{'servers'} // '');
            push @owners, $u->{'name'} if grep { $_ eq $game_user || $_ eq '*' } @s;
        }
    };
    return sort @owners;
}

# Returns a sorted list of all Webmin usernames.
sub list_webmin_users {
    my @names;
    eval {
        foreign_require('acl', 'acl-lib.pl');
        @names = map { $_->{'name'} } acl::list_users();
    };
    return sort @names;
}

1;
```

- [ ] **Schritt 2: Tests ausführen — müssen jetzt grün sein**

```bash
perl t/test_acl.pl
```

Erwartetes Ergebnis: `1..11` mit allen `ok`.

- [ ] **Schritt 3: Commit**

```bash
git add src/lib/acl.pl
git commit -m "feat: rewrite acl.pl — Webmin-native %access + get/save_module_acl"
```

---

## Task 5: `src/acl_edit.cgi` erstellen

Webmin ruft diese Datei auf, wenn ein Admin in "Webmin-Benutzer → User → LinuxGSM" klickt.

**Files:**
- Create: `src/acl_edit.cgi`

- [ ] **Schritt 1: `src/acl_edit.cgi` anlegen**

```perl
#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/acl.pl';
require './lib/instance.pl';

our (%text, %in, %access, $module_name);
&ReadParse(\%in);

# Nur User mit can_create dürfen ACLs anderer User bearbeiten
&can_create() or &error($text{'err_access_denied'});

my $edit_user = &sanitize_input($in{'user'} // '');
$edit_user or &error($text{'err_invalid_input'});

if ($ENV{REQUEST_METHOD} eq 'POST') {
    &check_referer(1);

    my %acl;
    $acl{'can_create'} = $in{'can_create'} ? 1 : 0;
    $acl{'can_scan'}   = $in{'can_scan'}   ? 1 : 0;

    if ($in{'servers_all'}) {
        $acl{'servers'} = '*';
    } else {
        # ReadParse liefert bei mehreren gleichen Feldern ein Array-Ref
        my @sel = ref($in{'servers'}) eq 'ARRAY' ? @{$in{'servers'}}
                : defined($in{'servers'})         ? ($in{'servers'})
                :                                   ();
        # Nur gültige Unix-Usernamen durchlassen
        @sel = grep { /^\w[\w-]*$/ } @sel;
        $acl{'servers'} = join(' ', @sel);
    }

    save_module_acl(\%acl, $edit_user, $module_name);
    &redirect("../acl/edit_user.cgi?user=" . &urlize($edit_user));
}

# GET: Formular mit aktuellem ACL des Users anzeigen
&header($text{'acl_edit_title'}, '');

my %cur      = get_module_acl($edit_user, $module_name);
my @instances = &list_instances();
my $srv_val  = $cur{'servers'} // '';
my $all_chk  = $srv_val eq '*' ? 1 : 0;
my %srv_on   = map { $_ => 1 } split /\s+/, $srv_val;

print &ui_form_start('acl_edit.cgi', 'post');
print &ui_hidden('user', &html_escape($edit_user));
print &ui_table_start($text{'acl_edit_title'}, undef, 2);

print &ui_table_row($text{'acl_can_create'},
    &ui_checkbox('can_create', '1', '', $cur{'can_create'} ? 1 : 0));

print &ui_table_row($text{'acl_can_scan'},
    &ui_checkbox('can_scan', '1', '', $cur{'can_scan'} ? 1 : 0));

my $srv_html = &ui_checkbox('servers_all', '1', $text{'acl_servers_all'}, $all_chk) . '<br>';
for my $inst (@instances) {
    my $u = $inst->{'user'};
    $srv_html .= &ui_checkbox('servers', $u,
        &html_escape($u) . ' (' . &html_escape($inst->{'game'}) . ')',
        $srv_on{$u} ? 1 : 0) . '<br>';
}

print &ui_table_row($text{'acl_servers'}, $srv_html);
print &ui_table_end();
print &ui_submit($text{'acl_save'});
print &ui_form_end();
&footer('', '');
```

- [ ] **Schritt 2: Commit**

```bash
git add src/acl_edit.cgi
git commit -m "feat: add acl_edit.cgi — Webmin ACL editor integration"
```

---

## Task 6: `src/index.cgi` aktualisieren

**Files:**
- Modify: `src/index.cgi`

- [ ] **Schritt 1: Debug-Block entfernen und `%access` deklarieren**

Den kompletten Debug-Block (von `# DEBUG:` bis `}`) entfernen und `%access` zur `our`-Deklaration hinzufügen:

```perl
our (%text, %config, %in, %access);
```

- [ ] **Schritt 2: Admin-Buttons auf `%access` umstellen**

```perl
# Vorher:
if (&is_admin()) {

# Nachher:
if ($access{'can_create'} || $access{'can_scan'}) {
```

Und die einzelnen Buttons absichern:

```perl
if ($access{'can_create'} || $access{'can_scan'}) {
    if ($access{'can_create'}) {
        print &ui_form_start('wizard.cgi', 'get');
        print &ui_submit($text{'index_btn_new_server'});
        print &ui_form_end();
    }
    if ($access{'can_scan'}) {
        print &ui_form_start('scan.cgi', 'get');
        print &ui_submit($text{'index_btn_scan'});
        print &ui_form_end();
    }
}
```

- [ ] **Schritt 3: `list_instances()` → `list_managed_instances()` bleibt** (bereits geändert)

- [ ] **Schritt 4: Commit**

```bash
git add src/index.cgi
git commit -m "feat: index.cgi — use %access for admin buttons, remove debug block"
```

---

## Task 7: `src/wizard.cgi` aktualisieren

**Files:**
- Modify: `src/wizard.cgi`

- [ ] **Schritt 1: `our %access` zur Deklaration hinzufügen**

```perl
our (%text, %in, %access);
```

- [ ] **Schritt 2: `is_admin()` → `can_create()` ersetzen**

```perl
# Vorher:
&is_admin() or &error($text{'err_access_denied'});

# Nachher:
&can_create() or &error($text{'err_access_denied'});
```

- [ ] **Schritt 3: Nach Installation `grant_server_access` aufrufen**

Im Step-3-POST-Block, nach `set_owner()` (diese Zeile entfernen) und nach `provision_server()`:

```perl
# Vorher (entfernen):
&set_owner($username, $webmin_user) if $webmin_user;

# Nachher:
&grant_server_access($webmin_user, $username) if $webmin_user;
```

- [ ] **Schritt 4: Commit**

```bash
git add src/wizard.cgi
git commit -m "feat: wizard.cgi — use can_create() and grant_server_access()"
```

---

## Task 8: `src/scan.cgi` aktualisieren

**Files:**
- Modify: `src/scan.cgi`

- [ ] **Schritt 1: `our %access` zur Deklaration hinzufügen**

```perl
our (%text, %in, %access);
```

- [ ] **Schritt 2: `is_admin()` → `can_scan()` ersetzen** (beide Stellen)

```perl
# Vorher (GET und POST):
&is_admin() or &error($text{'err_access_denied'});

# Nachher:
&can_scan() or &error($text{'err_access_denied'});
```

- [ ] **Schritt 3: `set_owner()` → `grant_server_access()` ersetzen**

```perl
# Vorher:
&set_owner($game_user, $webmin_user);

# Nachher:
&grant_server_access($webmin_user, $game_user);
```

- [ ] **Schritt 4: Owner-Anzeige auf `get_server_owners()` umstellen**

```perl
# Vorher:
my $owner = &get_owner($user);
my $owner_cell = defined($owner) ? ...

# Nachher:
my @owners = &get_server_owners($user);
my $owner_cell = @owners
    ? join(', ', map { &html_escape($_) } @owners)
    : "<i>$text{'scan_unowned'}</i>";
```

- [ ] **Schritt 5: Im POST-Block Validierung anpassen**

```perl
# Vorher:
&get_instance($game_user) or &error($text{'err_not_found'});
my %valid = map { $_ => 1 } &list_webmin_users();
$valid{$webmin_user} or &error($text{'err_invalid_input'});
&set_owner($game_user, $webmin_user);

# Nachher:
&get_instance($game_user) or &error($text{'err_not_found'});
my %valid = map { $_ => 1 } &list_webmin_users();
$valid{$webmin_user} or &error($text{'err_invalid_input'});
&grant_server_access($webmin_user, $game_user);
```

- [ ] **Schritt 6: Commit**

```bash
git add src/scan.cgi
git commit -m "feat: scan.cgi — use can_scan(), get_server_owners(), grant_server_access()"
```

---

## Task 9: Build + Gesamttest

- [ ] **Schritt 1: Alle Tests einzeln ausführen**

```bash
perl t/test_acl.pl
perl t/test_games.pl
```

Erwartetes Ergebnis: alle `ok`

- [ ] **Schritt 2: Vollständigen Build ausführen**

```bash
bash scripts/build.sh
```

Erwartetes Ergebnis:
```
==> Running tests...
[alle Tests grün]
==> Built: dist/linuxgsm-webcore-0.1.0.wbm
==> Build complete.
```

- [ ] **Schritt 3: `.wbm` auf Webmin-Server hochladen und installieren**

In Webmin: Webmin → Webmin-Konfiguration → Webmin-Module → Aus Datei installieren → `dist/linuxgsm-webcore-0.1.0.wbm`

- [ ] **Schritt 4: Einmalig Rechte setzen**

Webmin → Webmin-Benutzer → eigener User → LinuxGSM → Rechte bearbeiten:
- `can_create` ☑
- `can_scan` ☑
- Alle Server: ☑ (oder `*`)

- [ ] **Schritt 5: Verifikation**

1. Index-Seite: "Neuen Server erstellen" + "Server scannen" Buttons sichtbar
2. Zweiten Webmin-User anlegen, einen Server zuweisen → User sieht nur seinen Server
3. Wizard durchlaufen: Server wird angelegt + Zugriff automatisch gewährt
4. `acl_edit.cgi` öffnen: Checkboxliste korrekt, Speichern funktioniert

---

## Nicht im Scope dieses Plans

- Migration alter Owner-Dateien aus `/etc/webmin/linuxgsm-webcore/<game_user>` (kein Produktivbestand)
- Feinrechte pro Server (start/stop/update einzeln)
- SFTP-Passwort-Reset UI (separater Task)
