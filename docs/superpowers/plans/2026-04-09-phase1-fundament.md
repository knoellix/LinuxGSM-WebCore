# Phase 1 — Fundament: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `core.pl`, `instance.pl` und `index.cgi` vollständig implementieren — das Dashboard zeigt echte LGSM-Instanzen mit Health-Check, Firewall-Status und Start/Stop-Buttons in einer Expand-Zeile.

**Architecture:** Thin Vertical Slice — erst /etc/passwd-Erkennung + Config-Parsing, dann Status + Firewall, zuletzt das Dashboard. Jeder Schritt ist einzeln deploybar. Kein JavaScript, expand via GET-Parameter `?expand=<user>`. Vollständige Spec: `docs/superpowers/specs/2026-04-09-phase1-fundament-design.md`.

**Tech Stack:** Perl 5 (Webmin CGI), `Test::More` für Unit-Tests, Fixtures in `t/fixtures/`.

---

## Dateiübersicht

| Datei | Änderung |
|-------|---------|
| `src/lang/en` | Neue Schlüssel: Spalten-Header, Status-Texte, Firewall, Health-Warnungen |
| `src/lang/de` | Gleiche Schlüssel, deutsche Werte |
| `src/lib/core.pl` | `sanitize_input` absichern + `run_server_action` Whitelist |
| `src/lib/firewall.pl` | Neue Funktion `firewall_status($port)` |
| `src/lib/instance.pl` | `_parse_lgsm_config`, `_check_instance_health`, `_detect_status` absichern, `get_instance` verdrahten |
| `src/index.cgi` | Echte Instanz-Tabelle + Expand-Zeile + Firewall-Buttons |
| `t/stubs.pl` | NEU: Webmin-Stubs für Tests |
| `t/fixtures/common.cfg` | NEU: Mock LGSM common config |
| `t/fixtures/mcserver.cfg` | NEU: Mock LGSM game config |
| `t/test_sanitize.pl` | NEU: Tests für sanitize_input |
| `t/test_run_action.pl` | NEU: Tests für run_server_action |
| `t/test_firewall_status.pl` | NEU: Tests für firewall_status |
| `t/test_config_parse.pl` | NEU: Tests für _parse_lgsm_config |
| `t/test_health_check.pl` | NEU: Tests für _check_instance_health |

---

### Task 1: Sprachdateien erweitern

**Files:**
- Modify: `src/lang/en`
- Modify: `src/lang/de`

- [ ] **Step 1: src/lang/en erweitern**

Füge diese Zeilen am Ende von `src/lang/en` an:

```
index_col_user=User
index_col_game=Game
index_col_port=Port
index_col_status=Status
index_col_health=Health
index_col_details=Details
status_online=online
status_offline=offline
status_unknown=unknown
fw_status_open=open
fw_status_closed=closed
fw_open_btn=Open port
fw_close_btn=Close port
health_warn_shell=Shell should be nologin: usermod -s /usr/sbin/nologin {user}
health_warn_no_script=No LGSM script found -- installation may be incomplete
health_warn_no_config=LGSM config directory missing -- non-standard structure?
detail_port=Port
detail_firewall=Firewall
err_invalid_action=Invalid action.
err_invalid_input=Invalid input.
```

- [ ] **Step 2: src/lang/de erweitern**

Füge diese Zeilen am Ende von `src/lang/de` an:

```
index_col_user=Benutzer
index_col_game=Spiel
index_col_port=Port
index_col_status=Status
index_col_health=Gesundheit
index_col_details=Details
status_online=online
status_offline=offline
status_unknown=unbekannt
fw_status_open=offen
fw_status_closed=geschlossen
fw_open_btn=Port öffnen
fw_close_btn=Port schließen
health_warn_shell=Shell auf nologin setzen: usermod -s /usr/sbin/nologin {user}
health_warn_no_script=Kein LGSM-Script gefunden -- Installation evtl. unvollständig
health_warn_no_config=LGSM-Config-Verzeichnis fehlt -- abweichende Struktur?
detail_port=Port
detail_firewall=Firewall
err_invalid_action=Ungültige Aktion.
err_invalid_input=Ungültige Eingabe.
```

- [ ] **Step 3: Schlüsselanzahl prüfen**

```bash
grep -c "=" src/lang/en src/lang/de
```

Erwartung: Beide Dateien haben dieselbe Anzahl Schlüssel (38 = 18 alt + 20 neu).

- [ ] **Step 4: Commit**

```bash
git add src/lang/en src/lang/de
git commit --author="Christian Möllmann <moellix@knoellix.net>" -m "feat: Sprachdateien — neue Schlüssel für Phase 1"
```

---

### Task 2: Test-Infrastruktur aufsetzen

**Files:**
- Create: `t/stubs.pl`
- Create: `t/fixtures/common.cfg`
- Create: `t/fixtures/mcserver.cfg`

- [ ] **Step 1: t/ Verzeichnis anlegen**

```bash
mkdir -p t/fixtures
```

- [ ] **Step 2: t/stubs.pl schreiben**

```perl
# t/stubs.pl — Webmin-Stubs für Unit-Tests
# Usage: require 't/stubs.pl'; (vor dem require des Moduls)
use strict;
use warnings;

# Webmin package globals
our ($module_root, $current_lang, $config_directory);
our (%text, %config, %gconfig, %in);

$module_root       = 't';
$current_lang      = 'en';
$config_directory  = '/dev/null';

# Stub: read_file — parst key=value Dateien in einen Hash
sub read_file {
    my ($file, $hash_ref) = @_;
    return unless defined $file && -f $file;
    open(my $fh, '<', $file) or return;
    while (<$fh>) {
        chomp;
        next if /^\s*#/ || !/=/;
        my ($k, $v) = split(/=/, $_, 2);
        $hash_ref->{$k} = $v if defined $k && defined $v;
    }
    close($fh);
}

# Stub: system_logged — führt Befehl aus, gibt Exit-Code zurück
sub system_logged {
    return system($_[0]);
}

# error() wird in Tests NICHT als Stub definiert — jedes Test-File
# definiert es selbst (manche wollen es fangen, manche nicht).

1;
```

- [ ] **Step 3: t/fixtures/common.cfg schreiben**

```
# LGSM common config — test fixture
port="27015"
gamename="halflife"
maxplayers="16"
```

- [ ] **Step 4: t/fixtures/mcserver.cfg schreiben**

```
# LGSM mcserver config — overrides common
port="25565"
gamename="mcserver"
```

- [ ] **Step 5: Prüfen**

```bash
perl -e "require 't/stubs.pl'; print 'stubs ok\n';"
```

Erwartung: `stubs ok`

- [ ] **Step 6: Commit**

```bash
git add t/
git commit --author="Christian Möllmann <moellix@knoellix.net>" -m "test: Test-Infrastruktur (stubs, fixtures)"
```

---

### Task 3: core.pl — sanitize_input absichern

**Files:**
- Create: `t/test_sanitize.pl`
- Modify: `src/lib/core.pl`

- [ ] **Step 1: Failing Test schreiben**

```perl
#!/usr/bin/perl
# t/test_sanitize.pl
use strict;
use warnings;
use Test::More tests => 6;

# Webmin-Stubs
our ($module_root, $current_lang, $config_directory);
our (%text, %config, %gconfig);
$module_root = 't'; $current_lang = 'en';

sub read_file { }
sub system_logged { return system($_[0]); }

# error() fangen statt sterben lassen
my $error_called = 0;
my $last_error;
sub error { $error_called = 1; $last_error = $_[0]; die "caught\n"; }

require 'src/lib/core.pl';

# Test 1: gültiger Username bleibt erhalten
is(sanitize_input('mc-survival'), 'mc-survival', 'valid username preserved');

# Test 2: gültiger Username mit Underscore
is(sanitize_input('cs_server'), 'cs_server', 'underscore allowed');

# Test 3: Leerzeichen werden entfernt
is(sanitize_input('mc server'), 'mcserver', 'spaces stripped');

# Test 4: Gefährliche Zeichen entfernt
is(sanitize_input('mc;rm -rf /'), 'mcrmrf', 'dangerous chars stripped');

# Test 5: Leere Eingabe triggert error()
$error_called = 0;
eval { sanitize_input('') };
is($error_called, 1, 'empty string triggers error()');

# Test 6: Eingabe die nach Sanitize leer ist triggert error()
$error_called = 0;
eval { sanitize_input(';;;') };
is($error_called, 1, 'all-special input triggers error()');
```

- [ ] **Step 2: Test ausführen — muss fehlschlagen**

```bash
perl t/test_sanitize.pl
```

Erwartung: Tests 5 und 6 schlagen fehl (current `sanitize_input` ruft kein `error()` bei leerem Ergebnis).

- [ ] **Step 3: sanitize_input in src/lib/core.pl implementieren**

Ersetze die bestehende `sanitize_input`-Sub komplett:

```perl
# Strip dangerous characters from user input.
# Dies() via Webmin &error() if nothing valid remains.
sub sanitize_input {
    my ($input) = @_;
    $input //= '';
    $input =~ s/[^a-zA-Z0-9_\-]//g;
    &error($text{'err_invalid_input'}) unless length $input;
    return $input;
}
```

- [ ] **Step 4: Test ausführen — muss bestehen**

```bash
perl t/test_sanitize.pl
```

Erwartung: `ok 1 - ok 6`, alle 6 Tests grün.

- [ ] **Step 5: Perl-Syntax prüfen**

```bash
perl -c src/lib/core.pl 2>&1
```

Erwartung: `syntax OK`

- [ ] **Step 6: Commit**

```bash
git add src/lib/core.pl t/test_sanitize.pl
git commit --author="Christian Möllmann <moellix@knoellix.net>" -m "feat: sanitize_input — error() bei leerem Ergebnis"
```

---

### Task 4: core.pl — run_server_action Whitelist

**Files:**
- Create: `t/test_run_action.pl`
- Modify: `src/lib/core.pl`

- [ ] **Step 1: Failing Test schreiben**

```perl
#!/usr/bin/perl
# t/test_run_action.pl
use strict;
use warnings;
use Test::More tests => 5;

our ($module_root, $current_lang, $config_directory);
our (%text, %config, %gconfig);
$module_root = 't'; $current_lang = 'en';
%text = (err_invalid_input => 'Invalid input.', err_invalid_action => 'Invalid action.');

sub read_file { }

my $error_called = 0;
my $last_error;
sub error { $error_called = 1; $last_error = $_[0]; die "caught\n"; }

my @logged_commands;
sub system_logged { push @logged_commands, $_[0]; return 0; }

require 'src/lib/core.pl';

# Test 1: 'start' ist eine gültige Aktion
@logged_commands = ();
run_server_action('mc-survival', 'start');
like($logged_commands[0], qr/su -s \/bin\/bash -c "\.\/mc-survival start" mc-survival/, 'start executes correct su command');

# Test 2: 'stop' ist eine gültige Aktion
@logged_commands = ();
run_server_action('mc-survival', 'stop');
like($logged_commands[0], qr/mc-survival stop/, 'stop executes correct command');

# Test 3: 'details' ist eine gültige Aktion
@logged_commands = ();
run_server_action('mc-survival', 'details');
like($logged_commands[0], qr/details/, 'details is valid action');

# Test 4: ungültige Aktion triggert error()
$error_called = 0;
eval { run_server_action('mc-survival', 'rm -rf /') };
is($error_called, 1, 'invalid action triggers error()');

# Test 5: ungültiger User triggert error() (aus sanitize_input)
$error_called = 0;
eval { run_server_action('', 'start') };
is($error_called, 1, 'empty user triggers error()');
```

- [ ] **Step 2: Test ausführen — muss fehlschlagen**

```bash
perl t/test_run_action.pl
```

Erwartung: Test 4 schlägt fehl (kein Whitelist-Check vorhanden).

- [ ] **Step 3: run_server_action in src/lib/core.pl implementieren**

Ersetze die bestehende `run_server_action`-Sub:

```perl
# Run a server action as the game user (never as root).
# $action must be in the whitelist — otherwise Webmin error() is called.
sub run_server_action {
    my ($user, $action) = @_;
    $user   = &sanitize_input($user);
    $action = &sanitize_input($action);

    my %valid_actions = map { $_ => 1 } qw(start stop restart update details);
    &error($text{'err_invalid_action'}) unless $valid_actions{$action};

    return &system_logged("su -s /bin/bash -c \"./$user $action\" $user");
}
```

- [ ] **Step 4: Test ausführen — muss bestehen**

```bash
perl t/test_run_action.pl
```

Erwartung: alle 5 Tests grün.

- [ ] **Step 5: Syntax prüfen**

```bash
perl -c src/lib/core.pl 2>&1
```

Erwartung: `syntax OK`

- [ ] **Step 6: Commit**

```bash
git add src/lib/core.pl t/test_run_action.pl
git commit --author="Christian Möllmann <moellix@knoellix.net>" -m "feat: run_server_action — Whitelist-Validierung"
```

---

### Task 5: firewall.pl — firewall_status() implementieren

**Files:**
- Create: `t/test_firewall_status.pl`
- Modify: `src/lib/firewall.pl`

- [ ] **Step 1: Failing Test schreiben**

```perl
#!/usr/bin/perl
# t/test_firewall_status.pl
use strict;
use warnings;
use Test::More tests => 4;

sub error { die "error: $_[0]\n"; }
sub system_logged { return system($_[0]); }

# Mock has_ufw und ufw-Output
my $mock_ufw    = 0;  # 1 = ufw vorhanden, 0 = nur iptables
my $mock_ufw_output = '';

require 'src/lib/firewall.pl';

# Überschreibe has_ufw für Tests
no warnings 'redefine';
*has_ufw = sub { return $mock_ufw; };

# Helper: mock das ufw-Kommando via lokale Überschreibung
# (firewall_status nutzt intern _ufw_status_output)
# Überschreibe _ufw_status_output
*_ufw_status_output = sub { return $mock_ufw_output; };
use warnings 'redefine';

# Test 1: ufw, Port offen (TCP)
$mock_ufw = 1;
$mock_ufw_output = "Status: active\n25565/tcp                  ALLOW IN    Anywhere\n";
is(firewall_status(25565), 1, 'ufw: open tcp port detected');

# Test 2: ufw, Port geschlossen
$mock_ufw = 1;
$mock_ufw_output = "Status: active\n";
is(firewall_status(25565), 0, 'ufw: closed port returns 0');

# Test 3: ufw, Port als range "25565 ALLOW"
$mock_ufw = 1;
$mock_ufw_output = "Status: active\n25565                      ALLOW IN    Anywhere\n";
is(firewall_status(25565), 1, 'ufw: plain port number detected');

# Test 4: kein ufw — immer 0 zurückgeben (iptables nicht testbar ohne root)
$mock_ufw = 0;
is(firewall_status(25565), 0, 'no ufw: returns 0 (iptables not checked in test)');
```

- [ ] **Step 2: Test ausführen — muss fehlschlagen**

```bash
perl t/test_firewall_status.pl
```

Erwartung: Fehler weil `firewall_status` und `_ufw_status_output` nicht existieren.

- [ ] **Step 3: firewall_status() in src/lib/firewall.pl implementieren**

Füge diese Funktionen in `src/lib/firewall.pl` ein (vor dem abschließenden `1;`):

```perl
# Internal: return ufw status output (split out for testability)
sub _ufw_status_output {
    return `ufw status 2>/dev/null`;
}

# Check if a port is open in the firewall.
# Returns 1 if open, 0 if closed or unknown.
sub firewall_status {
    my ($port) = @_;
    $port = int($port);
    if (&has_ufw()) {
        my $out = &_ufw_status_output();
        return 1 if $out =~ /^$port\b[^\n]*ALLOW/m;
        return 1 if $out =~ /^$port\/(?:tcp|udp)\b[^\n]*ALLOW/m;
        return 0;
    } else {
        # iptables: try to check rule (requires root)
        my $rc = system("iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null");
        return $rc == 0 ? 1 : 0;
    }
}
```

- [ ] **Step 4: Test ausführen — muss bestehen**

```bash
perl t/test_firewall_status.pl
```

Erwartung: alle 4 Tests grün.

- [ ] **Step 5: Syntax prüfen**

```bash
perl -c src/lib/firewall.pl 2>&1
```

Erwartung: `syntax OK`

- [ ] **Step 6: Commit**

```bash
git add src/lib/firewall.pl t/test_firewall_status.pl
git commit --author="Christian Möllmann <moellix@knoellix.net>" -m "feat: firewall_status() — ufw/iptables Port-Check"
```

---

### Task 6: instance.pl — _parse_lgsm_config implementieren

**Files:**
- Create: `t/test_config_parse.pl`
- Modify: `src/lib/instance.pl`

- [ ] **Step 1: Failing Test schreiben**

```perl
#!/usr/bin/perl
# t/test_config_parse.pl
use strict;
use warnings;
use Test::More tests => 6;
use File::Temp qw(tempdir);

sub sanitize_input { my ($s) = @_; $s =~ s/[^a-zA-Z0-9_-]//g; return $s; }
sub error { die "error: $_[0]\n"; }
sub system_logged { return 0; }
sub firewall_status { return 0; }

require 'src/lib/instance.pl';

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/lgsm";
mkdir "$dir/lgsm/config-lgsm";
mkdir "$dir/lgsm/config-lgsm/mcserver";

# common.cfg schreiben
open my $fh, '>', "$dir/lgsm/config-lgsm/common.cfg" or die;
print $fh "# common settings\n";
print $fh "port=\"27015\"\n";
print $fh "gamename=\"halflife\"\n";
print $fh "maxplayers='16'\n";
close $fh;

# game-specific cfg (überschreibt common)
open $fh, '>', "$dir/lgsm/config-lgsm/mcserver/mcserver.cfg" or die;
print $fh "port=\"25565\"\n";
print $fh "gamename=\"mcserver\"\n";
close $fh;

my %cfg = _parse_lgsm_config($dir, 'mcserver');

# Test 1: game-specific port überschreibt common
is($cfg{port}, '25565', 'game config overrides common port');

# Test 2: game-specific gamename überschreibt common
is($cfg{gamename}, 'mcserver', 'game config overrides common gamename');

# Test 3: value aus common.cfg (maxplayers nicht in game cfg)
is($cfg{maxplayers}, '16', 'value from common.cfg preserved');

# Test 4: Kommentarzeilen werden ignoriert
ok(!exists $cfg{'# common settings'}, 'comment lines ignored');

# Test 5: kein common.cfg — nur game cfg
my $dir2 = tempdir(CLEANUP => 1);
mkdir "$dir2/lgsm"; mkdir "$dir2/lgsm/config-lgsm"; mkdir "$dir2/lgsm/config-lgsm/cs";
open $fh, '>', "$dir2/lgsm/config-lgsm/cs/cs.cfg" or die;
print $fh "port=\"27015\"\n";
close $fh;
my %cfg2 = _parse_lgsm_config($dir2, 'cs');
is($cfg2{port}, '27015', 'works without common.cfg');

# Test 6: kein config dir — leerer Hash zurück
my $dir3 = tempdir(CLEANUP => 1);
my %cfg3 = _parse_lgsm_config($dir3, 'unknown');
is(scalar keys %cfg3, 0, 'missing config dir returns empty hash');
```

- [ ] **Step 2: Test ausführen — muss fehlschlagen**

```bash
perl t/test_config_parse.pl
```

Erwartung: Fehler weil `_parse_lgsm_config` noch nicht existiert (skeleton hat `_detect_game`/`_detect_port`).

- [ ] **Step 3: _parse_lgsm_config in src/lib/instance.pl implementieren**

Ersetze `_detect_game` und `_detect_port` (beide TODO-Stubs) durch:

```perl
# Parse LGSM config files for a game user.
# Reads common.cfg first, then game-specific <user>.cfg (overrides common).
# Returns a flat hash of all key=value pairs found.
sub _parse_lgsm_config {
    my ($home, $user) = @_;
    my %cfg;
    for my $path (
        "$home/lgsm/config-lgsm/common.cfg",
        "$home/lgsm/config-lgsm/$user/$user.cfg",
    ) {
        next unless -f $path;
        open(my $fh, '<', $path) or next;
        while (<$fh>) {
            chomp;
            next if /^\s*#/;                          # Kommentare überspringen
            next unless /=/;
            if (/^\s*(\w+)\s*=\s*["']?([^"'\n]+?)["']?\s*$/) {
                $cfg{$1} = $2;
            }
        }
        close($fh);
    }
    return %cfg;
}
```

- [ ] **Step 4: Test ausführen — muss bestehen**

```bash
perl t/test_config_parse.pl
```

Erwartung: alle 6 Tests grün.

- [ ] **Step 5: Syntax prüfen**

```bash
perl -c src/lib/instance.pl 2>&1
```

Erwartung: `syntax OK`

- [ ] **Step 6: Commit**

```bash
git add src/lib/instance.pl t/test_config_parse.pl
git commit --author="Christian Möllmann <moellix@knoellix.net>" -m "feat: _parse_lgsm_config — LGSM-Config-Parsing (common + game-specific)"
```

---

### Task 7: instance.pl — _check_instance_health implementieren

**Files:**
- Create: `t/test_health_check.pl`
- Modify: `src/lib/instance.pl`

- [ ] **Step 1: Failing Test schreiben**

```perl
#!/usr/bin/perl
# t/test_health_check.pl
use strict;
use warnings;
use Test::More tests => 5;
use File::Temp qw(tempdir);

sub sanitize_input { my ($s) = @_; $s =~ s/[^a-zA-Z0-9_-]//g; return $s; }
sub error { die "error: $_[0]\n"; }
sub system_logged { return 0; }
sub firewall_status { return 0; }

our %text = (
    health_warn_shell    => 'Shell should be nologin: usermod -s /usr/sbin/nologin {user}',
    health_warn_no_script => 'No LGSM script found -- installation may be incomplete',
    health_warn_no_config => 'LGSM config directory missing -- non-standard structure?',
);

require 'src/lib/instance.pl';

# Test 1: alles ok — leere Warnung
my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/lgsm"; mkdir "$dir/lgsm/config-lgsm";
open my $fh, '>', "$dir/mc"; close $fh;   # LGSM-Script anlegen
my $w = _check_instance_health('mc', $dir, '/usr/sbin/nologin', {});
is(scalar @$w, 0, 'no warnings when setup is correct');

# Test 2: falsche Shell
my $w2 = _check_instance_health('mc', $dir, '/bin/bash', {});
is(scalar @$w2, 1, 'one warning for wrong shell');
like($w2->[0], qr/mc/, 'warning mentions username');

# Test 3: fehlendes LGSM-Script
my $dir2 = tempdir(CLEANUP => 1);
mkdir "$dir2/lgsm"; mkdir "$dir2/lgsm/config-lgsm";
# kein Script angelegt
my $w3 = _check_instance_health('mc', $dir2, '/usr/sbin/nologin', {});
is(scalar @$w3, 1, 'one warning for missing LGSM script');

# Test 4: fehlendes Config-Verzeichnis
my $dir3 = tempdir(CLEANUP => 1);
open $fh, '>', "$dir3/mc"; close $fh;
# kein lgsm/config-lgsm/
my $w4 = _check_instance_health('mc', $dir3, '/usr/sbin/nologin', {});
is(scalar @$w4, 1, 'one warning for missing config dir');
```

- [ ] **Step 2: Test ausführen — muss fehlschlagen**

```bash
perl t/test_health_check.pl
```

Erwartung: Fehler weil `_check_instance_health` nicht existiert.

- [ ] **Step 3: _check_instance_health in src/lib/instance.pl implementieren**

Füge nach `_parse_lgsm_config` ein:

```perl
# Check instance health — returns arrayref of warning strings (empty = ok).
# $shell is the user's login shell from /etc/passwd.
sub _check_instance_health {
    my ($user, $home, $shell, $cfg_ref) = @_;
    my @warnings;

    if ($shell ne '/usr/sbin/nologin') {
        my $msg = $text{health_warn_shell};
        $msg =~ s/\{user\}/$user/g;
        push @warnings, $msg;
    }

    unless (-f "$home/$user") {
        push @warnings, $text{health_warn_no_script};
    }

    unless (-d "$home/lgsm/config-lgsm") {
        push @warnings, $text{health_warn_no_config};
    }

    return \@warnings;
}
```

- [ ] **Step 4: Test ausführen — muss bestehen**

```bash
perl t/test_health_check.pl
```

Erwartung: alle 5 Tests grün.

- [ ] **Step 5: Syntax prüfen**

```bash
perl -c src/lib/instance.pl 2>&1
```

Erwartung: `syntax OK`

- [ ] **Step 6: Commit**

```bash
git add src/lib/instance.pl t/test_health_check.pl
git commit --author="Christian Möllmann <moellix@knoellix.net>" -m "feat: _check_instance_health — Health-Check mit Shell/Script/Config-Prüfung"
```

---

### Task 8: instance.pl — _detect_status absichern und get_instance verdrahten

**Files:**
- Modify: `src/lib/instance.pl`

- [ ] **Step 1: _detect_status in src/lib/instance.pl ersetzen**

Ersetze die bestehende `_detect_status`-Sub:

```perl
# Detect whether a game server instance is running.
# Calls the LGSM 'details' command as the game user.
# Returns 'online', 'offline', or 'unknown' (on error).
sub _detect_status {
    my ($home, $user) = @_;
    my $out = `su -s /bin/bash -c "./$user details" $user 2>/dev/null`;
    return 'unknown' unless defined $out && length $out;
    return $out =~ /Online/ ? 'online' : 'offline';
}
```

- [ ] **Step 2: get_instance in src/lib/instance.pl vollständig verdrahten**

Ersetze die bestehende `get_instance`-Sub:

```perl
# Return instance details for a specific user, or undef if not a valid LGSM instance.
sub get_instance {
    my ($user) = @_;
    $user = &sanitize_input($user);
    my @pw = getpwnam($user) or return undef;
    my $home  = $pw[7];
    my $shell = $pw[8];
    return undef unless -f "$home/$user";

    my %cfg     = _parse_lgsm_config($home, $user);
    my $status  = _detect_status($home, $user);
    my $port    = $cfg{port} // 0;
    my $fw_open = &firewall_status($port);
    my $warns   = _check_instance_health($user, $home, $shell, \%cfg);

    return {
        user     => $user,
        home     => $home,
        game     => $cfg{gamename} // 'unknown',
        port     => $port,
        status   => $status,
        fw_open  => $fw_open,
        warnings => $warns,
    };
}
```

- [ ] **Step 3: list_instances in src/lib/instance.pl prüfen**

Die bestehende `list_instances`-Implementierung ruft bereits `&get_instance($user)` auf. Prüfe ob sie korrekt ist:

```bash
grep -A 15 'sub list_instances' src/lib/instance.pl
```

Erwartung: filtert auf `$shell eq '/usr/sbin/nologin'` UND `-f "$home/$user"`. Falls nicht vorhanden, ersetze `list_instances` durch:

```perl
# Return list of all LGSM game server instances found in /etc/passwd.
sub list_instances {
    my @instances;
    open(my $fh, '<', '/etc/passwd') or return ();
    while (<$fh>) {
        chomp;
        my ($user, undef, undef, undef, undef, $home, $shell) = split(':', $_);
        next unless defined $shell && $shell eq '/usr/sbin/nologin';
        next unless defined $home && -f "$home/$user";
        my $inst = &get_instance($user);
        push @instances, $inst if $inst;
    }
    close($fh);
    return @instances;
}
```

- [ ] **Step 4: Syntax prüfen**

```bash
perl -c src/lib/instance.pl 2>&1
```

Erwartung: `syntax OK`

- [ ] **Step 5: Commit**

```bash
git add src/lib/instance.pl
git commit --author="Christian Möllmann <moellix@knoellix.net>" -m "feat: get_instance vollständig — Config, Status, Firewall, Health verdrahtet"
```

---

### Task 9: index.cgi — Dashboard vollständig implementieren

**Files:**
- Modify: `src/index.cgi`

- [ ] **Step 1: src/index.cgi vollständig ersetzen**

```perl
#!/usr/bin/perl
use strict;
use warnings;

require './lib/core.pl';
require './lib/instance.pl';
require './lib/firewall.pl';

our (%text, %config, %in);
&ReadParse(\%in);

# Firewall-Aktionen verarbeiten (vor Header, da redirect möglich)
if ($in{'action'} && $in{'user'}) {
    &error_if_root();
    my $action = &sanitize_input($in{'action'});
    my $user   = &sanitize_input($in{'user'});
    my $inst   = &get_instance($user) or &error($text{'err_not_found'});
    my $port   = int($inst->{'port'});

    if ($action eq 'fw_open') {
        &firewall_open_port($port, 'tcp');
        &firewall_open_port($port, 'udp');
    } elsif ($action eq 'fw_close') {
        &firewall_close_port($port, 'tcp');
        &firewall_close_port($port, 'udp');
    }
    &redirect("index.cgi?expand=$user");
}

&header($text{'index_title'}, '');
print "<p>$text{'index_desc'}</p>\n";

my @instances = &list_instances();

if (!@instances) {
    print "<p>$text{'index_no_instances'}</p>\n";
} else {
    my $expand = $in{'expand'} ? &sanitize_input($in{'expand'}) : '';

    print "<table class='ui_table'>\n";
    print "<tr>";
    for my $col (qw(index_col_user index_col_game index_col_port index_col_status index_col_health index_col_details)) {
        print "<th>$text{$col}</th>";
    }
    print "</tr>\n";

    foreach my $inst (@instances) {
        my $user      = $inst->{'user'};
        my $status    = $inst->{'status'};
        my $warnings  = $inst->{'warnings'};
        my $expanding = ($expand eq $user);

        my $status_color = $status eq 'online'  ? 'green'
                         : $status eq 'offline' ? 'red'
                         :                        'gray';
        my $status_text = $text{"status_$status"} // $status;
        my $health_icon = @$warnings
            ? "&#9888; (" . scalar(@$warnings) . ")"
            : "&#10003;";
        my $toggle_url  = $expanding
            ? "index.cgi"
            : "index.cgi?expand=$user";
        my $toggle_char = $expanding ? "&#9650;" : "&#9660;";

        print "<tr>";
        print "<td>$user</td>";
        print "<td>$inst->{'game'}</td>";
        print "<td>$inst->{'port'}</td>";
        print "<td style='color:$status_color'>$status_text</td>";
        print "<td>$health_icon</td>";
        print "<td><a href='$toggle_url'>$toggle_char</a></td>";
        print "</tr>\n";

        if ($expanding) {
            my $port    = $inst->{'port'};
            my $fw_open = $inst->{'fw_open'};
            my $fw_icon = $fw_open
                ? "&#10003; $text{fw_status_open}"
                : "&#10007; $text{fw_status_closed}";
            my $fw_action = $fw_open ? 'fw_close' : 'fw_open';
            my $fw_btn    = $fw_open ? $text{fw_close_btn} : $text{fw_open_btn};

            print "<tr><td colspan='6' style='padding:8px;background:#f9f9f9'>\n";
            print "<table>\n";
            print "<tr><td><b>$text{detail_port}</b></td><td>$port</td></tr>\n";
            print "<tr><td><b>$text{detail_firewall}</b></td><td>$fw_icon &nbsp;";
            print "<form method='post' action='index.cgi' style='display:inline'>";
            print "<input type='hidden' name='action' value='$fw_action'>";
            print "<input type='hidden' name='user' value='$user'>";
            print "<input type='hidden' name='expand' value='$user'>";
            print "<input type='submit' value=\"$fw_btn\">";
            print "</form></td></tr>\n";
            print "</table>\n";

            print "<p>";
            foreach my $action (qw(start stop restart update)) {
                print "<form method='post' action='manage.cgi' style='display:inline;margin-right:4px'>";
                print "<input type='hidden' name='user' value='$user'>";
                print "<input type='hidden' name='action' value='$action'>";
                print "<input type='submit' value=\"$text{'manage_$action'}\">";
                print "</form>";
            }
            print "</p>\n";

            if (@$warnings) {
                print "<p><b>&#9888; Warnungen:</b></p><ul>\n";
                for my $w (@$warnings) {
                    my $safe_w = $w;
                    $safe_w =~ s/&/&amp;/g;
                    $safe_w =~ s/</&lt;/g;
                    print "<li>$safe_w</li>\n";
                }
                print "</ul>\n";
            }

            print "</td></tr>\n";
        }
    }
    print "</table>\n";
}

&footer('', '');
```

- [ ] **Step 2: Perl-Syntax prüfen**

```bash
perl -c src/index.cgi 2>&1
```

Erwartung: `syntax OK`

- [ ] **Step 3: Commit**

```bash
git add src/index.cgi
git commit --author="Christian Möllmann <moellix@knoellix.net>" -m "feat: index.cgi — Dashboard mit Instanz-Tabelle, Expand-Zeile, Firewall-Buttons"
```

- [ ] **Step 4: Alle Unit-Tests ausführen**

```bash
perl t/test_sanitize.pl && \
perl t/test_run_action.pl && \
perl t/test_firewall_status.pl && \
perl t/test_config_parse.pl && \
perl t/test_health_check.pl
```

Erwartung: alle Tests grün (kein Fehler, kein FAIL).

- [ ] **Step 5: Integrations-Checkliste für Debian-Server**

Auf dem Debian-Server deployen (`cp -r src/* /usr/share/webmin/linuxgsm-webcore/`) und prüfen:

```
[ ] index.cgi lädt ohne 500-Fehler
[ ] Tabelle zeigt vorhandene LGSM-Instanzen
[ ] Status (online/offline) wird korrekt angezeigt
[ ] Klick auf ▼ öffnet Expand-Zeile
[ ] Firewall-Status wird korrekt angezeigt
[ ] Port öffnen/schließen funktioniert
[ ] Health-Warnungen erscheinen wenn Shell falsch gesetzt
[ ] Start/Stop-Buttons leiten korrekt zu manage.cgi weiter
[ ] Keine Instanz: "Keine Game-Server-Instanzen gefunden." wird angezeigt
```

---

## Self-Review

**Spec-Abdeckung:**
- ✅ `core.pl` — sanitize_input, error_if_root, run_server_action (Tasks 3+4)
- ✅ `firewall.pl` — firewall_status() (Task 5)
- ✅ `instance.pl` — _parse_lgsm_config, _check_instance_health, _detect_status, get_instance, list_instances (Tasks 6+7+8)
- ✅ `index.cgi` — Tabelle, Expand, Firewall-Buttons, Health-Warnungen (Task 9)
- ✅ Sprachdateien — alle neuen Schlüssel (Task 1)
- ✅ Test-Infrastruktur (Task 2)

**Sicherheits-Invarianten geprüft:**
- ✅ `sanitize_input` ruft `error()` bei leerem Ergebnis — kein leerer String in Shell-Befehle
- ✅ `run_server_action` validiert gegen Whitelist
- ✅ `index.cgi` ruft `error_if_root()` vor Firewall-Aktionen
- ✅ Warning-Texte werden HTML-escaped in index.cgi
- ✅ `get_instance` übergibt `$shell` explizit an `_check_instance_health` (testbar ohne getpwnam-Mock)
