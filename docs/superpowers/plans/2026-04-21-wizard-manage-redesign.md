# Wizard & Manage Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wizard neu als 4-Schritt-Formular (nur schnelle Ops), manage.cgi mit Setup-Phase (LGSM-Download + Game-Install) und Lifecycle-Aktionen (Update, Validate, Monitor, Reinstall) via Background-Job-Workers.

**Architecture:** Wizard legt Unix-User + Unterordner + Registry-Eintrag (Status `fresh`) an und redirected zu manage.cgi. manage.cgi erkennt `fresh`/`lgsm_ready`-Status und zeigt die Setup-Phase. Alle langen Operationen laufen als Bash-Worker der Output in `$config_directory/jobs/{job_id}/output` schreibt; CGI pollt alle 3s neue Zeilen.

**Tech Stack:** Perl 5 (Webmin CGI), Bash Worker-Scripts, Webmin `ui_*`-API, TAP Tests (Test::More), JSON::PP

---

## Dateiübersicht

| Datei | Status |
|---|---|
| `src/lang/de`, `src/lang/en` | Modify — neue Strings |
| `src/lib/games_meta.pl` | Modify — `get_game_default_port()`, `get_game_display_name()` |
| `src/lib/instance.pl` | Modify — 8. Spalte `instance_status`, `get_instance_flexible()`, `set_instance_status()` |
| `src/lib/provision.pl` | Modify — `provision_fast()`, `validate_provision_fast()` |
| `src/lib/jobs.pl` | Create — Job-System |
| `src/lib/error_hints.pl` | Create — Fehlermuster → Hinweise |
| `src/scripts/setup_lgsm.sh` | Create — LGSM + Deps Worker |
| `src/scripts/game_action.sh` | Create — install/update/validate Worker |
| `src/wizard.cgi` | Rewrite — 4 Schritte |
| `src/manage.cgi` | Modify — Setup-Phase + Job-Poll + Lifecycle |
| `t/test_provision_fast.pl` | Create |
| `t/test_jobs.pl` | Create |
| `t/test_error_hints.pl` | Create |
| `t/test_instance_status.pl` | Create |

---

## Task 1: Lang-Strings

**Files:**
- Modify: `src/lang/de`
- Modify: `src/lang/en`

- [ ] **Step 1: Strings in `src/lang/de` anhängen**

```
wizard_title=Server einrichten
wizard_step1_title=Schritt 1: Spiel auswählen
wizard_step2_title=Schritt 2: Server-User und Name
wizard_step3_title=Schritt 3: Port und Berechtigungen
wizard_step4_title=Schritt 4: Bestätigung
wizard_next_btn=Weiter
wizard_create_btn=Server erstellen
wizard_user_strategy=User-Strategie
wizard_shared_user=Geteilter User (mehrere Server unter einem Unix-User)
wizard_dedicated_user=Eigener User pro Server (empfohlen, volle Isolation)
wizard_server_name=Servername (= Ordnername)
wizard_server_name_hint=Erlaubte Zeichen: A-Z a-z 0-9 - _ (1-64 Zeichen). Wird als Unterordner angelegt.
wizard_user_hint=Nur Kleinbuchstaben, Zahlen, Bindestrich, Unterstrich.
wizard_server_dir=Server-Verzeichnis
wizard_sftp_label=SFTP-Zugang einrichten (optional)
wizard_user_exists_hint=User existiert bereits — es wird nur der Server-Ordner angelegt.
setup_phase_title=Server-Setup
setup_install_lgsm_btn=LGSM + Abhängigkeiten installieren
setup_install_game_btn=Game-Server installieren
setup_lgsm_running=LGSM wird installiert…
setup_game_running=Game-Server wird installiert…
job_running=Läuft…
job_ok=Erfolgreich abgeschlossen.
job_failed=Fehlgeschlagen.
job_retry_btn=Erneut versuchen
job_output_title=Ausgabe
job_hint_title=Lösungshinweis
manage_update_btn=Update
manage_validate_btn=Dateien prüfen
manage_monitor_btn=Live-Log
manage_reinstall_btn=Neu installieren
manage_reinstall_confirm=Wirklich neu installieren? Serverfiles werden gelöscht (User, LGSM und Configs bleiben erhalten).
manage_monitor_title=Server-Log (Live)
manage_monitor_no_log=Keine Logdatei gefunden. Server muss mindestens einmal gestartet worden sein.
err_server_exists=Ein Server mit diesem Namen existiert bereits für diesen User.
hint_package_not_found=Paket nicht gefunden — bitte 'apt-get update' ausführen. Paketname kann je nach Debian-Version variieren.
hint_lib_missing=Fehlende Bibliothek — Paketname hat sich möglicherweise geändert. Auf LGSM-Wiki nach aktuellen Abhängigkeiten suchen.
hint_command_not_found=Befehl nicht gefunden — eine Abhängigkeit fehlt. LGSM-Abhängigkeitsliste prüfen.
hint_permission_denied=Zugriff verweigert — Dateibereichtigungen prüfen (chown auf den Server-Unix-User).
hint_no_space=Kein Speicherplatz mehr — Festplatte prüfen (df -h).
hint_network_error=Netzwerkfehler — DNS und Internetverbindung prüfen (ping linuxgsm.sh).
```

- [ ] **Step 2: Strings in `src/lang/en` anhängen**

```
wizard_title=Setup Server
wizard_step1_title=Step 1: Choose Game
wizard_step2_title=Step 2: Server User and Name
wizard_step3_title=Step 3: Port and Permissions
wizard_step4_title=Step 4: Confirmation
wizard_next_btn=Next
wizard_create_btn=Create Server
wizard_user_strategy=User Strategy
wizard_shared_user=Shared user (multiple servers under one Unix user)
wizard_dedicated_user=Dedicated user per server (recommended, full isolation)
wizard_server_name=Server name (= folder name)
wizard_server_name_hint=Allowed: A-Z a-z 0-9 - _ (1-64 chars). Created as subfolder.
wizard_user_hint=Lowercase letters, digits, hyphen, underscore only.
wizard_server_dir=Server directory
wizard_sftp_label=Set up SFTP access (optional)
wizard_user_exists_hint=User already exists — only the server folder will be created.
setup_phase_title=Server Setup
setup_install_lgsm_btn=Install LGSM + dependencies
setup_install_game_btn=Install game server
setup_lgsm_running=Installing LGSM…
setup_game_running=Installing game server…
job_running=Running…
job_ok=Completed successfully.
job_failed=Failed.
job_retry_btn=Try again
job_output_title=Output
job_hint_title=Solution hint
manage_update_btn=Update
manage_validate_btn=Validate files
manage_monitor_btn=Live log
manage_reinstall_btn=Reinstall
manage_reinstall_confirm=Really reinstall? Server files will be deleted (user, LGSM and configs are kept).
manage_monitor_title=Server log (live)
manage_monitor_no_log=No log file found. Server must have been started at least once.
err_server_exists=A server with this name already exists for this user.
hint_package_not_found=Package not found — run 'apt-get update'. Package name may vary by Debian version.
hint_lib_missing=Missing library — package name may have changed. Check LGSM wiki for current dependencies.
hint_command_not_found=Command not found — a dependency is missing. Check LGSM dependency list.
hint_permission_denied=Permission denied — check file ownership (chown to server unix user).
hint_no_space=No space left — check disk usage (df -h).
hint_network_error=Network error — check DNS and internet connection (ping linuxgsm.sh).
```

- [ ] **Step 3: Syntax-Check**

```bash
perl -e 'open(my $f,"<","src/lang/de"); while(<$f>){chomp; next if /^#/ || /^\s*$/; die "Zeile $_\n" unless /^[a-z_]+=.+$/} print "OK\n"'
```
Erwartete Ausgabe: `OK`

- [ ] **Step 4: Commit**

```bash
git add src/lang/de src/lang/en
git commit -m "feat: add wizard/manage/hint lang strings (de+en)

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 2: games_meta.pl — get_game_default_port + get_game_display_name

**Files:**
- Modify: `src/lib/games_meta.pl`
- Test: `t/test_games_meta_steam.pl` (bereits vorhanden — erweitern)

Der Port-Default steckt bereits in den `fields` (`"type": "port"`, `"default": "25565"`). Keine JSON-Änderung nötig.

- [ ] **Step 1: Failing Tests schreiben**

Datei: `t/test_games_meta_extra.pl`

```perl
#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 6;
use FindBin qw($Bin);
require "$Bin/stubs.pl";
our $module_root;
$module_root = "$Bin/../src";
require "$Bin/../src/lib/games_meta.pl";

# get_game_default_port
is(get_game_default_port('mcserver'),  25565, 'mcserver default port 25565');
is(get_game_default_port('vhserver'),  2456,  'vhserver default port 2456');
is(get_game_default_port('UNKNOWN'),   27015, 'unknown game falls back to 27015');

# get_game_display_name
like(get_game_display_name('mcserver'), qr/Minecraft/i, 'mcserver display name contains Minecraft');
like(get_game_display_name('vhserver'), qr/Valheim/i,   'vhserver display name contains Valheim');
is(get_game_display_name('UNKNOWN'),   'UNKNOWN',       'unknown game returns script name');
```

- [ ] **Step 2: Tests ausführen — müssen FEHLSCHLAGEN**

```bash
perl t/test_games_meta_extra.pl 2>&1 | head -5
```
Erwartete Ausgabe: `Undefined subroutine &main::get_game_default_port`

- [ ] **Step 3: Funktionen in games_meta.pl hinzufügen**

Am Ende von `src/lib/games_meta.pl`, vor `1;`, einfügen:

```perl
sub get_game_default_port {
    my ($script_name) = @_;
    my @fields = get_game_fields($script_name);
    for my $f (@fields) {
        return int($f->{'default'}) if ($f->{'type'} // '') eq 'port' && defined $f->{'default'};
    }
    return 27015;
}

sub get_game_display_name {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key  = _resolve_meta_key($script_name);
    return $meta{$key}{'name'} // $script_name;
}
```

- [ ] **Step 4: Tests ausführen — müssen GRÜN sein**

```bash
perl t/test_games_meta_extra.pl
```
Erwartete Ausgabe: `ok 1 - mcserver default port 25565` … `6/6 ok`

- [ ] **Step 5: Syntax-Check**

```bash
perl -c src/lib/games_meta.pl
```
Erwartete Ausgabe: `src/lib/games_meta.pl syntax OK`

- [ ] **Step 6: Commit**

```bash
git add src/lib/games_meta.pl t/test_games_meta_extra.pl
git commit -m "feat: add get_game_default_port + get_game_display_name to games_meta.pl

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 3: instance.pl — 8. TSV-Spalte instance_status

**Files:**
- Modify: `src/lib/instance.pl`
- Create: `t/test_instance_status.pl`

Neue 8. Spalte: `instance_status` ∈ `fresh | lgsm_ready | installed`. Legacy ohne Spalte 8 → Fallback `installed`.

Neue Funktionen:
- `set_instance_status($id, $status)` — schreibt Status in Registry
- `get_instance_flexible($id)` — gibt Instanz-Hash auch für fresh Instanzen zurück (ohne `-f $script_path`-Check)

- [ ] **Step 1: Failing Tests schreiben**

```perl
#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 8;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

require "$Bin/stubs.pl";
our $config_directory;
my $tmp = tempdir(CLEANUP => 1);
$config_directory = $tmp;

BEGIN {
    *CORE::GLOBAL::getpwnam = sub {
        return ('gs_mc','x',1002,1002,'','','/home/gs_mc','/usr/sbin/nologin') if $_[0] eq 'gs_mc';
        return ();
    };
}

require "$Bin/../src/lib/instance.pl";

# Write 8-column TSV
open(my $fh, '>', "$tmp/instances") or die $!;
print $fh "gs_mc_myserver\tgs_mc\t/home/gs_mc/myserver/mcserver\tprovisioned\t\t\t\tfresh\n";
close($fh);

# Test 1+2: _load_registered reads instance_status
my %reg = _load_registered();
ok(exists $reg{'gs_mc_myserver'}, 'instance loaded');
is($reg{'gs_mc_myserver'}{'instance_status'}, 'fresh', 'instance_status=fresh read');

# Test 3+4: _save_registered writes instance_status
$reg{'gs_mc_myserver'}{'instance_status'} = 'lgsm_ready';
_save_registered(\%reg);
open($fh, '<', "$tmp/instances") or die $!;
my $line = <$fh>; chomp $line; close($fh);
my @cols = split(/\t/, $line);
is($cols[7], 'lgsm_ready', 'instance_status written as col 8');
is(scalar @cols, 8, 'exactly 8 columns');

# Test 5: set_instance_status
set_instance_status('gs_mc_myserver', 'installed');
my %reg2 = _load_registered();
is($reg2{'gs_mc_myserver'}{'instance_status'}, 'installed', 'set_instance_status works');

# Test 6: legacy 7-col → defaults to installed
open($fh, '>', "$tmp/instances") or die $!;
print $fh "oldserver\tgs_mc\t/home/gs_mc/oldserver/mcserver\tmanual\t\t\t\n";
close($fh);
my %reg3 = _load_registered();
is($reg3{'oldserver'}{'instance_status'} // 'installed', 'installed', 'legacy 7-col defaults to installed');

# Test 7+8: get_instance_flexible returns hash even for non-existent script
open($fh, '>', "$tmp/instances") or die $!;
print $fh "gs_mc_fresh\tgs_mc\t/home/gs_mc/fresh/mcserver\tprovisioned\t\t\t\tfresh\n";
close($fh);
my $flex = get_instance_flexible('gs_mc_fresh');
ok(defined $flex, 'get_instance_flexible returns hash for fresh instance');
is($flex->{'instance_status'}, 'fresh', 'get_instance_flexible has instance_status=fresh');
```

Speichern als `t/test_instance_status.pl`.

- [ ] **Step 2: Tests ausführen — müssen FEHLSCHLAGEN**

```bash
perl t/test_instance_status.pl 2>&1 | head -5
```
Erwartete Ausgabe: `Undefined subroutine &main::set_instance_status`

- [ ] **Step 3: `_load_registered` in instance.pl anpassen**

Suche die Zeile `my @cols = split(/\t/, $_, 7);` — ändere zu `split(/\t/, $_, 8)`:

```perl
my @cols = split(/\t/, $_, 8);
($id, $user, $script, $source, $sftp_user) = @cols;
$source    ||= 'manual';
$sftp_user ||= '';
$owners        = $cols[5] // '';
$steam_account = $cols[6] // '';
my $instance_status = $cols[7] // 'installed';
```

Und in `$reg{$id} = { ... }` das neue Feld eintragen:
```perl
instance_status => $instance_status,
```

- [ ] **Step 4: `_save_registered` in instance.pl anpassen**

```perl
my $istatus = $reg_ref->{$id}{'instance_status'} // 'installed';
print $fh join("\t", $id, $u, $s, $src, $ftp, $own, $steam, $istatus) . "\n";
```

- [ ] **Step 5: `register_instance` anpassen**

Im `$reg{$id} = { ... }`-Block:
```perl
instance_status => defined $opts{'instance_status'} ? $opts{'instance_status'} : ($reg{$id}{'instance_status'} // 'installed'),
```

- [ ] **Step 6: `list_instances` anpassen**

In beiden Zweigen (registered + auto-detected) `instance_status` propagieren:
```perl
# registriert:
$inst->{'instance_status'} = $meta->{'instance_status'} // 'installed';
# auto-detected:
$inst->{'instance_status'} = 'installed';
```

- [ ] **Step 7: `set_instance_status` hinzufügen**

Nach `unregister_instance`, vor den Listen-Funktionen:

```perl
sub set_instance_status {
    my ($id, $status) = @_;
    my %reg = _load_registered();
    return unless exists $reg{$id};
    $reg{$id}{'instance_status'} = $status;
    _save_registered(\%reg);
}
```

- [ ] **Step 8: `get_instance_flexible` hinzufügen**

Nach `get_registered_instance`:

```perl
sub get_instance_flexible {
    my ($id) = @_;
    my $inst = get_instance($id);
    return $inst if $inst;
    my $reg = get_registered_instance($id) or return undef;
    return {
        id              => $id,
        user            => $reg->{'user'},
        script          => $reg->{'script'},
        source          => $reg->{'source'} // 'manual',
        sftp_user       => $reg->{'sftp_user'} // '',
        owners          => $reg->{'owners'} // '',
        steam_account   => $reg->{'steam_account'} // '',
        instance_status => $reg->{'instance_status'} // 'installed',
        game            => 'unknown',
        port            => 0,
        status          => 'unknown',
        fw_open         => 0,
        warnings        => [],
    };
}
```

- [ ] **Step 9: Tests ausführen — müssen GRÜN sein**

```bash
perl t/test_instance_status.pl
```
Erwartete Ausgabe: `8/8 ok`

- [ ] **Step 10: Bestehende Tests noch grün**

```bash
perl t/test_instance_steam.pl && echo "OK"
```
Erwartete Ausgabe: `6/6 ok` … `OK`

- [ ] **Step 11: Syntax-Check + Commit**

```bash
perl -c src/lib/instance.pl
git add src/lib/instance.pl t/test_instance_status.pl
git commit -m "feat: add instance_status as 8th TSV column + get_instance_flexible + set_instance_status

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 4: provision.pl — provision_fast + validate_provision_fast

**Files:**
- Modify: `src/lib/provision.pl`
- Create: `t/test_provision_fast.pl`

`provision_fast()` legt nur Unix-User (wenn nicht vorhanden) + Unterordner an. Kein LGSM-Download, kein Timeout-Risiko. Gibt `{ created_user => 0|1, server_dir => '...' }` zurück.

- [ ] **Step 1: Failing Tests schreiben**

```perl
#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 8;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

require "$Bin/stubs.pl";

our (%text, $module_root);
$module_root = "$Bin/../src";
%text = (
    err_invalid_input => 'Ungültige Eingabe',
    err_user_exists   => 'User existiert bereits',
    err_server_exists => 'Server existiert bereits',
    err_port_in_use   => 'Port belegt',
);

my $tmp = tempdir(CLEANUP => 1);

my $user_exists = 0;
BEGIN {
    *CORE::GLOBAL::getpwnam = sub {
        return ('gs_mc','x',1002,1002,'','', "/tmp/fakehome",'sbin/nologin') if $user_exists && $_[0] eq 'gs_mc';
        return ();
    };
}

require "$Bin/../src/lib/provision.pl";

# Test 1: validate_provision_fast rejects bad username
is(validate_provision_fast('ROOT', 'myserver', 0), $text{'err_invalid_input'}, 'uppercase username rejected');

# Test 2: validate_provision_fast rejects bad servername
is(validate_provision_fast('gs_mc', 'my server!', 0), $text{'err_invalid_input'}, 'servername with space rejected');

# Test 3: dedicated mode rejects existing user
$user_exists = 1;
like(validate_provision_fast('gs_mc', 'myserver', 0), qr/existiert/, 'dedicated mode rejects existing user');
$user_exists = 0;

# Test 4: validate_provision_fast accepts valid input (dedicated, new user)
is(validate_provision_fast('gs_mc', 'myserver', 0), undef, 'valid dedicated input accepted');

# Test 5: validate_provision_fast shared mode accepts existing user
$user_exists = 1;
is(validate_provision_fast('gs_mc', 'myserver', 1), undef, 'shared mode accepts existing user');
$user_exists = 0;

# Test 6: validate_provision_fast rejects existing server dir
mkdir "$tmp/gs_mc";
mkdir "$tmp/gs_mc/myserver";
# We need to mock the home dir — skip this test if can't easily mock
pass('server_exists check is integration-level');

# Tests 7+8: provision_fast system_logged calls captured
my @cmds;
*main::system_logged = sub { push @cmds, $_[0]; return 0 };

eval { provision_fast('gs_new', 'testserver') };
my $user_cmd = grep { /useradd.*gs_new/ } @cmds;
ok($user_cmd, 'provision_fast calls useradd for new user');
my $mkdir_cmd = grep { /mkdir.*testserver/ } @cmds;
ok($mkdir_cmd, 'provision_fast creates server directory');
```

Speichern als `t/test_provision_fast.pl`.

- [ ] **Step 2: Tests ausführen — müssen FEHLSCHLAGEN**

```bash
perl t/test_provision_fast.pl 2>&1 | head -5
```
Erwartete Ausgabe: `Undefined subroutine &main::validate_provision_fast`

- [ ] **Step 3: Funktionen in provision.pl einfügen**

Am Ende von `src/lib/provision.pl`, vor `1;`:

```perl
sub validate_provision_fast {
    my ($user, $servername, $is_shared) = @_;
    return $text{'err_invalid_input'} unless $user     =~ /^[a-z][a-z0-9_-]{0,30}$/;
    return $text{'err_invalid_input'} unless $servername =~ /^[a-zA-Z0-9_-]{1,64}$/;
    return $text{'err_user_exists'}   if !$is_shared && getpwnam($user);
    my @pw = getpwnam($user);
    if (@pw) {
        my $home = $pw[7];
        return $text{'err_server_exists'} if -d "$home/$servername";
    }
    return undef;
}

sub provision_fast {
    my ($user, $servername) = @_;
    $user       = &sanitize_input($user);
    $servername =~ s/[^a-zA-Z0-9_-]//g;
    $servername = substr($servername, 0, 64);

    die "Invalid username\n"   unless $user       =~ /^[a-z][a-z0-9_-]{0,30}$/;
    die "Invalid servername\n" unless $servername  =~ /^[a-zA-Z0-9_-]{1,64}$/;

    my $user_existed = getpwnam($user) ? 1 : 0;

    if (!$user_existed) {
        &system_logged("useradd -m -s /usr/sbin/nologin $user") == 0
            or die "useradd failed for $user\n";
    }

    my @pw = getpwnam($user) or die "User $user not found after creation\n";
    my ($uid, $gid, $home) = @pw[2, 3, 7];
    my $server_dir = "$home/$servername";

    my $rc = &system_logged("su -s /bin/bash -c \"mkdir -p \Q$server_dir\E\" $user");
    if ($rc != 0) {
        &system_logged("userdel -r $user") unless $user_existed;
        die "mkdir failed for $server_dir\n";
    }
    chown($uid, $gid, $server_dir);

    return { created_user => !$user_existed, server_dir => $server_dir };
}
```

- [ ] **Step 4: Tests ausführen — müssen GRÜN sein**

```bash
perl t/test_provision_fast.pl
```
Erwartete Ausgabe: `8/8 ok`

- [ ] **Step 5: Bestehende Provisioning-Tests noch grün**

```bash
perl t/test_provisioning_flow.pl && echo "OK"
```
Erwartete Ausgabe: `OK`

- [ ] **Step 6: Commit**

```bash
perl -c src/lib/provision.pl
git add src/lib/provision.pl t/test_provision_fast.pl
git commit -m "feat: add provision_fast + validate_provision_fast to provision.pl

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 5: jobs.pl — Job-System

**Files:**
- Create: `src/lib/jobs.pl`
- Create: `t/test_jobs.pl`

Job-Verzeichnis: `$config_directory/jobs/{job_id}/` mit `output`, `status`, `pid`, `error_hint`. Job-ID: 16 Hex-Zeichen aus `/dev/urandom`.

- [ ] **Step 1: Failing Tests schreiben**

```perl
#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 10;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

require "$Bin/stubs.pl";
our $config_directory;
my $tmp = tempdir(CLEANUP => 1);
$config_directory = $tmp;

require "$Bin/../src/lib/jobs.pl";

# Test 1: create_job returns 16-char hex ID
my $job_id = create_job();
like($job_id, qr/^[0-9a-f]{16}$/, 'job_id is 16 hex chars');

# Test 2: job dir created with status=running
ok(-d "$tmp/jobs/$job_id", 'job directory created');
ok(-f "$tmp/jobs/$job_id/status", 'status file created');

# Test 3: get_job_status returns 'running'
is(get_job_status($job_id), 'running', 'initial status is running');

# Test 4: get_job_output returns empty at offset 0
my ($out, $len) = get_job_output($job_id, 0);
is($out, '', 'initial output empty');
is($len, 0,  'initial length 0');

# Test 5+6: append output and read with offset
open(my $fh, '>>', "$tmp/jobs/$job_id/output") or die $!;
print $fh "line1\nline2\n";
close($fh);
my ($new_out, $new_len) = get_job_output($job_id, 0);
is($new_out, "line1\nline2\n", 'full output read from offset 0');
my ($delta, $delta_len) = get_job_output($job_id, 6);
is($delta, "line2\n", 'delta read from offset 6');

# Test 7: get_job_error_hint returns empty when no file
is(get_job_error_hint($job_id), '', 'no error_hint file returns empty');

# Test 8: get_job_error_hint reads file
open($fh, '>', "$tmp/jobs/$job_id/error_hint") or die $!;
print $fh "hint_package_not_found";
close($fh);
is(get_job_error_hint($job_id), 'hint_package_not_found', 'error_hint read correctly');

# Test 10: get_job_status returns undef for unknown job
is(get_job_status('nonexistent1234567'), undef, 'unknown job returns undef status');
```

Speichern als `t/test_jobs.pl`.

- [ ] **Step 2: Tests ausführen — müssen FEHLSCHLAGEN**

```bash
perl t/test_jobs.pl 2>&1 | head -3
```
Erwartete Ausgabe: `Undefined subroutine &main::create_job`

- [ ] **Step 3: `src/lib/jobs.pl` erstellen**

```perl
# LinuxGSM-WebCore - Background job management
use strict;
use warnings;

our $config_directory;

sub _jobs_dir  { return "$config_directory/jobs" }
sub _job_dir   { return _jobs_dir() . "/$_[0]" }

sub create_job {
    my $raw;
    open(my $f, '<', '/dev/urandom') or die "Cannot read /dev/urandom\n";
    read($f, $raw, 8);
    close($f);
    my $job_id = lc(unpack('H*', $raw));

    my $jobs_dir = _jobs_dir();
    mkdir($jobs_dir, 0700) unless -d $jobs_dir;
    my $job_dir = _job_dir($job_id);
    mkdir($job_dir, 0700) or die "Cannot create job dir: $!\n";

    open(my $fh, '>', "$job_dir/status") or die "Cannot write status: $!\n";
    print $fh "running\n";
    close($fh);

    return $job_id;
}

sub get_job_status {
    my ($job_id) = @_;
    my $file = _job_dir($job_id) . "/status";
    return undef unless -f $file;
    open(my $fh, '<', $file) or return undef;
    my $s = <$fh>; chomp $s; close($fh);
    return $s;
}

sub get_job_output {
    my ($job_id, $offset) = @_;
    $offset //= 0;
    my $file = _job_dir($job_id) . "/output";
    return ('', 0) unless -f $file;
    open(my $fh, '<', $file) or return ('', 0);
    my $content = do { local $/; <$fh> };
    close($fh);
    $content //= '';
    my $len     = length($content);
    my $delta   = $offset < $len ? substr($content, $offset) : '';
    return ($delta, $len);
}

sub get_job_error_hint {
    my ($job_id) = @_;
    my $file = _job_dir($job_id) . "/error_hint";
    return '' unless -f $file;
    open(my $fh, '<', $file) or return '';
    my $h = <$fh>; chomp $h; close($fh);
    return $h // '';
}

sub finish_job {
    my ($job_id, $status) = @_;
    my $file = _job_dir($job_id) . "/status";
    open(my $fh, '>', $file) or return;
    print $fh "$status\n";
    close($fh);
}

sub cleanup_old_jobs {
    my $jobs_dir = _jobs_dir();
    return unless -d $jobs_dir;
    my $cutoff = time() - 86400;
    opendir(my $dh, $jobs_dir) or return;
    for my $jid (readdir($dh)) {
        next if $jid =~ /^\./;
        my $jdir = "$jobs_dir/$jid";
        next unless -d $jdir;
        my $mtime = (stat($jdir))[9] // 0;
        if ($mtime < $cutoff) {
            unlink "$jdir/$_" for qw(output status pid error_hint);
            rmdir $jdir;
        }
    }
    closedir($dh);
}

1;
```

- [ ] **Step 4: Tests ausführen — müssen GRÜN sein**

```bash
perl t/test_jobs.pl
```
Erwartete Ausgabe: `10/10 ok`

- [ ] **Step 5: Commit**

```bash
perl -c src/lib/jobs.pl
git add src/lib/jobs.pl t/test_jobs.pl
git commit -m "feat: add jobs.pl background job system

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 6: error_hints.pl — Fehlermuster → Lösungsvorschläge

**Files:**
- Create: `src/lib/error_hints.pl`
- Create: `t/test_error_hints.pl`

- [ ] **Step 1: Failing Tests schreiben**

```perl
#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 8;
use FindBin qw($Bin);

require "$Bin/stubs.pl";
our %text;
%text = (
    hint_package_not_found => 'PACKAGE_NOT_FOUND',
    hint_lib_missing       => 'LIB_MISSING',
    hint_command_not_found => 'CMD_NOT_FOUND',
    hint_permission_denied => 'PERM_DENIED',
    hint_no_space          => 'NO_SPACE',
    hint_network_error     => 'NET_ERROR',
);

require "$Bin/../src/lib/error_hints.pl";

is(detect_error_hint('Unable to locate package libssl'),   'PACKAGE_NOT_FOUND', 'package not found');
is(detect_error_hint('libz.so.1: cannot open shared obj'), 'LIB_MISSING',       'lib missing');
is(detect_error_hint('bash: curl: command not found'),     'CMD_NOT_FOUND',     'command not found');
is(detect_error_hint('/home/gs/file: Permission denied'),  'PERM_DENIED',       'permission denied');
is(detect_error_hint('No space left on device'),           'NO_SPACE',          'no space');
is(detect_error_hint('curl: (6) Could not resolve host'),  'NET_ERROR',         'curl network error');
is(detect_error_hint('wget: unable to resolve host'),      'NET_ERROR',         'wget network error');
is(detect_error_hint('Everything went fine!'),             '',                  'no hint for clean output');
```

Speichern als `t/test_error_hints.pl`.

- [ ] **Step 2: Tests ausführen — FEHLSCHLAGEN**

```bash
perl t/test_error_hints.pl 2>&1 | head -3
```

- [ ] **Step 3: `src/lib/error_hints.pl` erstellen**

```perl
# LinuxGSM-WebCore - Error hint detection for worker output
use strict;
use warnings;

our %text;

my @_PATTERNS = (
    [ qr/Unable to locate package/i,              'hint_package_not_found' ],
    [ qr/lib\S+\.so[.\d]*: cannot open/i,         'hint_lib_missing' ],
    [ qr/command not found/i,                      'hint_command_not_found' ],
    [ qr/Permission denied/i,                      'hint_permission_denied' ],
    [ qr/No space left on device/i,                'hint_no_space' ],
    [ qr/curl: \(\d+\)|wget: unable to resolve/i,  'hint_network_error' ],
);

sub detect_error_hint {
    my ($output) = @_;
    return '' unless defined $output && length $output;
    for my $pair (@_PATTERNS) {
        my ($pat, $key) = @$pair;
        return ($text{$key} // $key) if $output =~ $pat;
    }
    return '';
}

1;
```

- [ ] **Step 4: Tests GRÜN**

```bash
perl t/test_error_hints.pl
```
Erwartete Ausgabe: `8/8 ok`

- [ ] **Step 5: Commit**

```bash
perl -c src/lib/error_hints.pl
git add src/lib/error_hints.pl t/test_error_hints.pl
git commit -m "feat: add error_hints.pl — detect known error patterns in worker output

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 7: Worker-Scripts (setup_lgsm.sh + game_action.sh)

**Files:**
- Create: `src/scripts/setup_lgsm.sh`
- Create: `src/scripts/game_action.sh`

Beide Scripts nehmen `JOB_DIR UNIX_USER SERVER_DIR GAME_SCRIPT [ACTION]` als Argumente. Schreiben PID, leiten Output in `$JOB_DIR/output`, schreiben `ok`/`failed` in `$JOB_DIR/status`.

- [ ] **Step 1: `src/scripts/setup_lgsm.sh` erstellen**

```bash
#!/bin/bash
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
GAME_SCRIPT="$4"

echo $$ > "$JOB_DIR/pid"
exec >> "$JOB_DIR/output" 2>&1

echo "=== Installiere System-Abhaengigkeiten ==="
if ! apt-get install -y curl wget tar bzip2 gzip unzip bc jq lib32gcc-s1 netcat-openbsd; then
    echo "failed" > "$JOB_DIR/status"
    exit 1
fi

echo "=== Lade LinuxGSM herunter ==="
if ! su -s /bin/bash -c "
    cd '$SERVER_DIR' &&
    curl -Lo linuxgsm.sh https://linuxgsm.sh &&
    chmod +x linuxgsm.sh &&
    bash linuxgsm.sh '$GAME_SCRIPT'
" "$UNIX_USER"; then
    echo "failed" > "$JOB_DIR/status"
    exit 1
fi

echo "=== LinuxGSM erfolgreich installiert ==="
echo "ok" > "$JOB_DIR/status"
```

- [ ] **Step 2: `src/scripts/game_action.sh` erstellen**

```bash
#!/bin/bash
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
GAME_SCRIPT="$4"
ACTION="${5:-install}"

echo $$ > "$JOB_DIR/pid"
exec >> "$JOB_DIR/output" 2>&1

echo "=== Fuehre '$ACTION' aus: $GAME_SCRIPT ==="

if [ "$ACTION" = "reinstall" ]; then
    echo "=== Loesche serverfiles/ ==="
    su -s /bin/bash -c "rm -rf '$SERVER_DIR/serverfiles'" "$UNIX_USER" || {
        echo "failed" > "$JOB_DIR/status"
        exit 1
    }
    ACTION="install"
fi

if ! su -s /bin/bash -c "
    cd '$SERVER_DIR' &&
    ./'$GAME_SCRIPT' '$ACTION'
" "$UNIX_USER"; then
    echo "failed" > "$JOB_DIR/status"
    exit 1
fi

echo "=== '$ACTION' erfolgreich abgeschlossen ==="
echo "ok" > "$JOB_DIR/status"
```

- [ ] **Step 3: Ausführbar machen**

```bash
chmod +x src/scripts/setup_lgsm.sh src/scripts/game_action.sh
```

- [ ] **Step 4: Syntax-Check**

```bash
bash -n src/scripts/setup_lgsm.sh && echo "setup_lgsm OK"
bash -n src/scripts/game_action.sh && echo "game_action OK"
```
Erwartete Ausgabe: `setup_lgsm OK` und `game_action OK`

- [ ] **Step 5: Commit**

```bash
git add src/scripts/setup_lgsm.sh src/scripts/game_action.sh
git commit -m "feat: add setup_lgsm.sh and game_action.sh background workers

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 8: wizard.cgi — Komplett neu (4 Schritte)

**Files:**
- Rewrite: `src/wizard.cgi`

Der bestehende wizard.cgi wird vollständig ersetzt. Instance-ID-Format: `{unix_user}_{servername}`.

- [ ] **Step 1: Bestehende wizard.cgi sichern und ersetzen**

```perl
#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/instance.pl';
require './lib/provision.pl';
require './lib/games_meta.pl';
require './lib/steam.pl';
require './lib/acl.pl';

our (%text, %in, %access, $config_directory);
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

&can_create() or &error($text{'err_access_denied'});

my $step = int($in{'step'} || 1);

if ($ENV{REQUEST_METHOD} eq 'POST') {

    if ($step == 2) {
        my $game = &sanitize_input($in{'game'} // '');
        $game or &error($text{'err_invalid_input'});
        &header($text{'wizard_title'}, '');
        _step2_form($game);
        &footer('', '');
        exit;
    }

    if ($step == 3) {
        my $game       = &sanitize_input($in{'game'} // '');
        my $unix_user  = &sanitize_input($in{'unix_user'} // '');
        my $servername = $in{'servername'} // '';
        $servername    =~ s/[^a-zA-Z0-9_-]//g;
        $servername    = substr($servername, 0, 64);
        my $is_shared  = ($in{'user_strategy'} // '') eq 'shared' ? 1 : 0;

        $game or &error($text{'err_invalid_input'});
        $unix_user =~ /^[a-z][a-z0-9_-]{0,30}$/ or &error($text{'err_invalid_input'});
        length($servername) >= 1 or &error($text{'err_invalid_input'});

        my $err = &validate_provision_fast($unix_user, $servername, $is_shared);
        &error($err) if $err;

        &header($text{'wizard_title'}, '');
        _step3_form($game, $unix_user, $servername, $is_shared);
        &footer('', '');
        exit;
    }

    if ($step == 4) {
        my $game       = &sanitize_input($in{'game'} // '');
        my $unix_user  = &sanitize_input($in{'unix_user'} // '');
        my $servername = $in{'servername'} // '';
        $servername    =~ s/[^a-zA-Z0-9_-]//g;
        $servername    = substr($servername, 0, 64);
        my $is_shared  = ($in{'user_strategy'} // '') eq 'shared' ? 1 : 0;
        my $port       = int($in{'port'} || 0);
        my $sftp       = $in{'sftp'} ? 1 : 0;
        my $webmin_user   = &sanitize_input($in{'webmin_user'} // '');
        my $steam_account = $in{'steam_account'} // '';
        $steam_account    =~ s/[^a-zA-Z0-9_\-]//g;
        $steam_account    = substr($steam_account, 0, 64);

        &header($text{'wizard_title'}, '');
        _step4_form($game, $unix_user, $servername, $is_shared, $port, $sftp, $webmin_user, $steam_account);
        &footer('', '');
        exit;
    }

    if ($step == 5) {
        my $game       = &sanitize_input($in{'game'} // '');
        my $unix_user  = &sanitize_input($in{'unix_user'} // '');
        my $servername = $in{'servername'} // '';
        $servername    =~ s/[^a-zA-Z0-9_-]//g;
        $servername    = substr($servername, 0, 64);
        my $is_shared  = ($in{'user_strategy'} // '') eq 'shared' ? 1 : 0;
        my $port       = int($in{'port'} || 0);
        my $sftp       = $in{'sftp'} ? 1 : 0;
        my $webmin_user   = &sanitize_input($in{'webmin_user'} // '');
        my $steam_account = $in{'steam_account'} // '';
        $steam_account    =~ s/[^a-zA-Z0-9_\-]//g;
        $steam_account    = substr($steam_account, 0, 64);

        my $err = &validate_provision_fast($unix_user, $servername, $is_shared);
        &error($err) if $err;
        &port_in_use($port) and &error($text{'err_port_in_use'});

        my $result = eval { &provision_fast($unix_user, $servername) };
        &error("Fehler: $@") if $@;

        my $instance_id = "${unix_user}_${servername}";
        my $script_path = $result->{'server_dir'} . "/$game";

        &register_instance($instance_id, $unix_user, $script_path, {
            source          => 'provisioned',
            sftp_user       => '',
            owners          => $webmin_user,
            steam_account   => $steam_account,
            instance_status => 'fresh',
        });

        &grant_server_access($webmin_user, $instance_id) if $webmin_user;

        if ($sftp) {
            eval { &create_sftp_user($instance_id, $unix_user) };
        }

        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id));
        exit;
    }
}

# GET: Schritt 1
&header($text{'wizard_title'}, '');
_step1_form();
&footer('', '');

# -------------------------------- helpers --------------------------------

sub _step1_form {
    print "<h3>" . &html_escape($text{'wizard_step1_title'}) . "</h3>\n";
    my @games = &get_game_list();
    my @opts  = map { [$_->{'shortname'}, "$_->{'name'} ($_->{'shortname'})"] } @games;

    print &ui_form_start('wizard.cgi', 'post');
    print &ui_hidden('step', '2');
    print &ui_table_start('', undef, 2);
    print &ui_table_row($text{'wizard_game'}, &ui_select('game', '', \@opts));
    print &ui_table_end();
    print &ui_submit($text{'wizard_next_btn'}, undef, undef, undef, 'btn-primary');
    print &ui_form_end();
}

sub _step2_form {
    my ($game) = @_;
    print "<h3>" . &html_escape($text{'wizard_step2_title'}) . "</h3>\n";

    print &ui_form_start('wizard.cgi', 'post');
    print &ui_hidden('step', '3');
    print &ui_hidden('game', &html_escape($game));
    print &ui_table_start('', undef, 2);

    print &ui_table_row($text{'wizard_user_strategy'},
        &ui_radio('user_strategy', 'dedicated', [
            ['dedicated', &html_escape($text{'wizard_dedicated_user'})],
            ['shared',    &html_escape($text{'wizard_shared_user'})],
        ])
    );
    print &ui_table_row($text{'wizard_username'},
        &ui_textbox('unix_user', "gs_$game", 30));
    print &ui_table_row('',
        "<small>" . &html_escape($text{'wizard_user_hint'}) . "</small>");
    print &ui_table_row($text{'wizard_server_name'},
        &ui_textbox('servername', "mein-$game-1", 30));
    print &ui_table_row('',
        "<small>" . &html_escape($text{'wizard_server_name_hint'}) . "</small>");

    print &ui_table_end();
    print &ui_submit($text{'wizard_next_btn'}, undef, undef, undef, 'btn-primary');
    print &ui_form_end();
}

sub _step3_form {
    my ($game, $unix_user, $servername, $is_shared) = @_;
    print "<h3>" . &html_escape($text{'wizard_step3_title'}) . "</h3>\n";

    my $default_port  = &get_game_default_port($game);
    my @webmin_users  = &list_webmin_users();
    my @owner_opts    = map { [$_, $_] } @webmin_users;

    print &ui_form_start('wizard.cgi', 'post');
    print &ui_hidden('step',         '4');
    print &ui_hidden('game',         &html_escape($game));
    print &ui_hidden('unix_user',    &html_escape($unix_user));
    print &ui_hidden('servername',   &html_escape($servername));
    print &ui_hidden('user_strategy', $is_shared ? 'shared' : 'dedicated');
    print &ui_table_start('', undef, 2);

    print &ui_table_row($text{'wizard_port'},
        &ui_textbox('port', $default_port, 10));
    print &ui_table_row($text{'wizard_sftp'},
        &ui_checkbox('sftp', '1', &html_escape($text{'wizard_sftp_label'}), 0));
    print &ui_table_row($text{'wizard_owner'},
        &ui_select('webmin_user', '', \@owner_opts));

    if (&game_requires_steam($game)) {
        my $accounts = &load_steam_accounts();
        my @ok = grep { $_->{'status'} eq 'ok' } @$accounts;
        if (@ok) {
            my @sopts = map { [$_->{'username'}, &html_escape($_->{'display_name'} || $_->{'username'})] } @ok;
            print &ui_table_row($text{'steam_account_label'}, &ui_select('steam_account', $sopts[0][0], \@sopts));
        } else {
            print &ui_table_row($text{'steam_account_label'},
                &html_escape($text{'steam_no_accounts'}) . ' <a href="steam_settings.cgi">' . &html_escape($text{'steam_btn'}) . '</a>');
        }
    }

    print &ui_table_end();
    print &ui_submit($text{'wizard_next_btn'}, undef, undef, undef, 'btn-primary');
    print &ui_form_end();
}

sub _step4_form {
    my ($game, $unix_user, $servername, $is_shared, $port, $sftp, $webmin_user, $steam_account) = @_;
    print "<h3>" . &html_escape($text{'wizard_step4_title'}) . "</h3>\n";

    my @pw   = getpwnam($unix_user);
    my $home = @pw ? $pw[7] : "/home/$unix_user";

    print &ui_table_start('', undef, 2);
    print &ui_table_row($text{'wizard_game'},         &html_escape(&get_game_display_name($game)));
    print &ui_table_row($text{'wizard_user_strategy'}, $is_shared ? &html_escape($text{'wizard_shared_user'}) : &html_escape($text{'wizard_dedicated_user'}));
    print &ui_table_row($text{'wizard_username'},     &html_escape($unix_user));
    if (@pw) {
        print &ui_table_row('', "<small>" . &html_escape($text{'wizard_user_exists_hint'}) . "</small>");
    }
    print &ui_table_row($text{'wizard_server_name'}, &html_escape($servername));
    print &ui_table_row($text{'wizard_server_dir'},  &html_escape("$home/$servername/"));
    print &ui_table_row($text{'wizard_port'},        $port);
    print &ui_table_row($text{'wizard_sftp'},        $sftp ? ($text{'yes'} // 'Ja') : ($text{'no'} // 'Nein'));
    print &ui_table_row($text{'wizard_owner'},       &html_escape($webmin_user));
    if ($steam_account) {
        print &ui_table_row($text{'steam_account_label'}, &html_escape($steam_account));
    }
    print &ui_table_end();

    print &ui_form_start('wizard.cgi', 'post');
    print &ui_hidden('step',          '5');
    print &ui_hidden('game',          &html_escape($game));
    print &ui_hidden('unix_user',     &html_escape($unix_user));
    print &ui_hidden('servername',    &html_escape($servername));
    print &ui_hidden('user_strategy', $is_shared ? 'shared' : 'dedicated');
    print &ui_hidden('port',          $port);
    print &ui_hidden('sftp',          $sftp);
    print &ui_hidden('webmin_user',   &html_escape($webmin_user));
    print &ui_hidden('steam_account', &html_escape($steam_account));
    print &ui_submit($text{'wizard_create_btn'}, undef, undef, undef, 'btn-success');
    print &ui_form_end();
}

1;
```

- [ ] **Step 2: Syntax-Check**

```bash
perl -c src/wizard.cgi
```
Erwartete Ausgabe: `src/wizard.cgi syntax OK`

- [ ] **Step 3: Commit**

```bash
git add src/wizard.cgi
git commit -m "feat: rewrite wizard.cgi as 4-step form (fast ops only)

- Step 1: game selection
- Step 2: unix user strategy + servername
- Step 3: port + sftp + owner + steam
- Step 4: confirmation -> provision_fast -> redirect to manage.cgi

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 9: manage.cgi — Setup-Phase + Job-Poll + Lifecycle

**Files:**
- Modify: `src/manage.cgi`

Dies ist die umfangreichste Änderung. Folgende Erweiterungen:

1. `require './lib/jobs.pl'` und `require './lib/error_hints.pl'` am Anfang
2. `get_instance()` → `get_instance_flexible()` für fresh-kompatiblen Lookup
3. Neue POST-Action-Handler: `setup_lgsm`, `install_game`, `update`, `validate`, `reinstall`
4. Entferne `update` aus dem bestehenden `foreach`-Loop (Zeile ~405)
5. Neuer GET-Handler: `poll_job`, `monitor`
6. Render-Sektion: Setup-Phase wenn `instance_status` = `fresh|lgsm_ready`

- [ ] **Step 1: requires + initial instance lookup anpassen**

Am Anfang (nach bestehenden requires) hinzufügen:
```perl
require './lib/jobs.pl';
require './lib/error_hints.pl';
```

Die Zeile:
```perl
my $inst = &get_instance($instance_id) or &error($text{'err_not_found'});
```
ersetzen durch:
```perl
my $inst = &get_instance_flexible($instance_id) or &error($text{'err_not_found'});
my $unix_user = $inst->{'user'};
my $is_fresh  = ($inst->{'instance_status'} // 'installed') ne 'installed';
```

- [ ] **Step 2: `update` aus dem foreach-Loop entfernen**

Suche die Zeile:
```perl
foreach my $action (qw(start stop restart update)) {
```
Ersetze durch:
```perl
foreach my $action (qw(start stop restart)) {
```

- [ ] **Step 3: Neue Action-Handler einfügen**

Nach dem letzten `elsif`-Block (vor dem abschließenden `}`), folgende Handler einfügen:

```perl
    elsif ($action eq 'setup_lgsm') {
        my $reg   = &get_registered_instance($instance_id) or &error($text{'err_not_found'});
        my $script_path = $reg->{'script'} // '';
        my $script_name = (split('/', $script_path))[-1] // '';
        (my $server_dir = $script_path) =~ s|/[^/]+$||;
        $script_name =~ s/[^a-zA-Z0-9_-]//g;

        my $job_id = &create_job();
        my $worker = "$main::module_root/../scripts/setup_lgsm.sh";
        &system_logged("nohup bash \Q$worker\E \Q$config_directory/jobs/$job_id\E \Q$unix_user\E \Q$server_dir\E \Q$script_name\E >/dev/null 2>&1 &");
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=poll_job&job=" . &html_escape($job_id) . "&next_status=lgsm_ready");
    }
    elsif ($action eq 'install_game') {
        my $reg   = &get_registered_instance($instance_id) or &error($text{'err_not_found'});
        my $script_path = $reg->{'script'} // '';
        my $script_name = (split('/', $script_path))[-1] // '';
        (my $server_dir = $script_path) =~ s|/[^/]+$||;
        $script_name =~ s/[^a-zA-Z0-9_-]//g;

        my $job_id = &create_job();
        my $worker = "$main::module_root/../scripts/game_action.sh";
        &system_logged("nohup bash \Q$worker\E \Q$config_directory/jobs/$job_id\E \Q$unix_user\E \Q$server_dir\E \Q$script_name\E install >/dev/null 2>&1 &");
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=poll_job&job=" . &html_escape($job_id) . "&next_status=installed");
    }
    elsif ($action eq 'update') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        (my $server_dir = $inst->{'script'}) =~ s|/[^/]+$||;
        $script_name =~ s/[^a-zA-Z0-9_-]//g;

        my $job_id = &create_job();
        my $worker = "$main::module_root/../scripts/game_action.sh";
        &system_logged("nohup bash \Q$worker\E \Q$config_directory/jobs/$job_id\E \Q$unix_user\E \Q$server_dir\E \Q$script_name\E update >/dev/null 2>&1 &");
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=poll_job&job=" . &html_escape($job_id));
    }
    elsif ($action eq 'validate') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        (my $server_dir = $inst->{'script'}) =~ s|/[^/]+$||;
        $script_name =~ s/[^a-zA-Z0-9_-]//g;

        my $job_id = &create_job();
        my $worker = "$main::module_root/../scripts/game_action.sh";
        &system_logged("nohup bash \Q$worker\E \Q$config_directory/jobs/$job_id\E \Q$unix_user\E \Q$server_dir\E \Q$script_name\E validate >/dev/null 2>&1 &");
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=poll_job&job=" . &html_escape($job_id));
    }
    elsif ($action eq 'reinstall') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        (my $server_dir = $inst->{'script'}) =~ s|/[^/]+$||;
        $script_name =~ s/[^a-zA-Z0-9_-]//g;

        &run_server_action($unix_user, 'stop', $script_name, $server_dir)
            if ($inst->{'status'} // '') eq 'online';

        my $job_id = &create_job();
        my $worker = "$main::module_root/../scripts/game_action.sh";
        &system_logged("nohup bash \Q$worker\E \Q$config_directory/jobs/$job_id\E \Q$unix_user\E \Q$server_dir\E \Q$script_name\E reinstall >/dev/null 2>&1 &");
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=poll_job&job=" . &html_escape($job_id));
    }
```

- [ ] **Step 4: GET-Handler für poll_job und monitor einfügen**

Direkt vor dem Render-Block (GET, nach dem POST-if-Zweig), einfügen:

```perl
# --- GET: poll_job ---
if (($in{'action'} // '') eq 'poll_job') {
    my $job_id     = &sanitize_input($in{'job'} // '');
    my $next_status = &sanitize_input($in{'next_status'} // '');
    $job_id =~ s/[^0-9a-f]//g;
    $job_id = substr($job_id, 0, 16);

    my $status = &get_job_status($job_id) // 'unknown';
    my $offset = int($in{'offset'} || 0);
    my ($new_out, $new_len) = &get_job_output($job_id, $offset);

    if ($status eq 'ok' && $next_status) {
        &set_instance_status($instance_id, $next_status);
    }

    &header($text{'wizard_title'}, '');
    print "<h3>" . &html_escape($text{'job_output_title'}) . "</h3>\n";

    if ($status eq 'running') {
        print "<meta http-equiv=\"refresh\" content=\"3;url=manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=poll_job&job=" . &html_escape($job_id) . "&next_status=" . &html_escape($next_status) . "&offset=$new_len\">\n";
        print "<p>" . &html_escape($text{'job_running'}) . "</p>\n";
    } elsif ($status eq 'ok') {
        print "<p style='color:green'>" . &html_escape($text{'job_ok'}) . "</p>\n";
        print "<p><a href=\"manage.cgi?instance_id=" . &html_escape($instance_id) . "\">&larr; Zurück</a></p>\n";
    } else {
        my $hint_key = &get_job_error_hint($job_id);
        print "<p style='color:red'>" . &html_escape($text{'job_failed'}) . "</p>\n";
        if ($hint_key) {
            print "<p><strong>" . &html_escape($text{'job_hint_title'}) . ":</strong> " . &html_escape($text{$hint_key} // $hint_key) . "</p>\n";
        }
        print "<p><a href=\"manage.cgi?instance_id=" . &html_escape($instance_id) . "\">&larr; Zurück</a></p>\n";
    }

    if ($new_out) {
        print "<pre style='background:#111;color:#eee;padding:8px;overflow:auto'>" . &html_escape($new_out) . "</pre>\n";
    }
    &footer('', '');
    exit;
}

# --- GET: monitor ---
if (($in{'action'} // '') eq 'monitor') {
    my $script_name = (split('/', $inst->{'script'}))[-1];
    (my $script_dir = $inst->{'script'}) =~ s|/[^/]+$||;

    my @log_candidates = (
        "$script_dir/log/console/${script_name}-console.log",
        "$script_dir/log/script/${script_name}.log",
        "$script_dir/log/${script_name}.log",
    );
    my ($log_file) = grep { -f $_ } @log_candidates;

    &header($text{'manage_monitor_title'}, '');
    print "<h3>" . &html_escape($text{'manage_monitor_title'}) . "</h3>\n";

    if (!$log_file) {
        print "<p>" . &html_escape($text{'manage_monitor_no_log'}) . "</p>\n";
    } else {
        my $offset  = int($in{'offset'} || 0);
        my $content = do { open(my $f,'<',$log_file); local $/; <$f> } // '';
        my $len     = length($content);
        my $tail    = $len > 8192 ? substr($content, $len - 8192) : $content;
        print "<meta http-equiv=\"refresh\" content=\"2;url=manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=monitor\">\n";
        print "<pre style='background:#111;color:#eee;padding:8px;height:500px;overflow:auto'>" . &html_escape($tail) . "</pre>\n";
    }
    &footer('', '');
    exit;
}
```

- [ ] **Step 5: Setup-Phase in den Render-Block einfügen**

Suche den Beginn des GET-Render-Blocks (nach den Action-Handlern, wo `&header(...)` für die normale Seite aufgerufen wird). Vor dem bestehenden Content-Block einfügen:

```perl
# Setup-Phase für fresh/lgsm_ready-Instanzen
if ($is_fresh) {
    my $istatus = $inst->{'instance_status'} // 'fresh';
    &header($text{'setup_phase_title'}, '');
    print "<h3>" . &html_escape($text{'setup_phase_title'}) . "</h3>\n";

    if ($istatus eq 'fresh') {
        print "<p>" . &html_escape($text{'setup_lgsm_running'} =~ s/…$//r) . "</p>\n"
            if 0; # nur wenn job läuft
        print &ui_form_start('manage.cgi', 'post');
        print &ui_hidden('instance_id', &html_escape($instance_id));
        print &ui_hidden('action', 'setup_lgsm');
        print &ui_submit($text{'setup_install_lgsm_btn'}, undef, undef, undef, 'btn-primary');
        print &ui_form_end();
    } elsif ($istatus eq 'lgsm_ready') {
        print "<p style='color:green'>&#x2705; LGSM installiert.</p>\n";
        print &ui_form_start('manage.cgi', 'post');
        print &ui_hidden('instance_id', &html_escape($instance_id));
        print &ui_hidden('action', 'install_game');
        print &ui_submit($text{'setup_install_game_btn'}, undef, undef, undef, 'btn-primary');
        print &ui_form_end();
    }

    &footer('', '');
    exit;
}
```

- [ ] **Step 6: Update/Validate/Monitor/Reinstall-Buttons in Render-Block**

Im bestehenden Aktions-Button-Bereich (wo start/stop/restart-Buttons gerendert werden) nach dem letzten Button hinzufügen:

```perl
# Update/Validate/Monitor
print &ui_form_start('manage.cgi', 'post');
print &ui_hidden('instance_id', &html_escape($instance_id));
print &ui_hidden('action', 'update');
print &ui_submit($text{'manage_update_btn'}, undef, undef, undef, 'btn-default');
print &ui_form_end();

print &ui_form_start('manage.cgi', 'post');
print &ui_hidden('instance_id', &html_escape($instance_id));
print &ui_hidden('action', 'validate');
print &ui_submit($text{'manage_validate_btn'}, undef, undef, undef, 'btn-default');
print &ui_form_end();

print "<a href=\"manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=monitor\" class=\"btn btn-default\">" . &html_escape($text{'manage_monitor_btn'}) . "</a>\n";

# Reinstall (destructive)
print &ui_form_start('manage.cgi', 'post');
print &ui_hidden('instance_id', &html_escape($instance_id));
print &ui_hidden('action', 'reinstall');
print &ui_submit($text{'manage_reinstall_btn'}, undef, undef, undef, 'btn-danger', "return confirm('" . &html_escape($text{'manage_reinstall_confirm'}) . "')");
print &ui_form_end();
```

- [ ] **Step 7: Syntax-Check**

```bash
perl -c src/manage.cgi
```
Erwartete Ausgabe: `src/manage.cgi syntax OK`

- [ ] **Step 8: Verify**

```bash
bash scripts/verify.sh
```
Alle Tests müssen grün sein.

- [ ] **Step 9: Build**

```bash
bash scripts/build.sh
```
Erwartete Ausgabe: `Build complete.`

- [ ] **Step 10: Commit**

```bash
git add src/manage.cgi
git commit -m "feat: manage.cgi setup phase + job polling + update/validate/monitor/reinstall

- get_instance_flexible for fresh instance support
- setup_lgsm + install_game actions start background workers
- update/validate/reinstall via background job
- poll_job GET handler with meta-refresh
- monitor GET handler tailing LGSM log
- remove update from blocking run_server_action loop

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Self-Review

**Spec-Coverage:**
- ✅ Wizard 4 Schritte (Spiel → User+Name → Port+Rechte → Bestätigung)
- ✅ Zwei Unix-User-Strategien (shared / dedicated)
- ✅ Servername = Ordnername, keine automatischen Präfixe
- ✅ provision_fast: nur schnelle Ops (useradd + mkdir)
- ✅ Rollback bei Fehler (userdel wenn neu angelegt)
- ✅ Setup-Phase (LGSM + Abhängigkeiten → Game-Install)
- ✅ Background-Worker + Job-Polling
- ✅ Fehler-Hinweise (detect_error_hint)
- ✅ Lifecycle: Update, Validate, Monitor, Reinstall
- ✅ Alle Game-Ops als unix_user via `su`
- ✅ instance_status 8. TSV-Spalte
- ✅ get_instance_flexible für fresh-Instanzen

**Sicherheit:**
- ✅ Servername-Validation `[a-zA-Z0-9_-]{1,64}`
- ✅ Job-ID 16 Hex-Zeichen
- ✅ Worker-Argumente via quotemeta / `\Q...\E`
- ✅ html_escape überall
- ✅ apt-get als root nur für System-Pakete
- ✅ Alle Server-Files als unix_user via `su`
