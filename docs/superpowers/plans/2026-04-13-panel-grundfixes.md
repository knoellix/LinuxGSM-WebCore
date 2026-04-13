# Panel-Grundfixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** UTF-8-Darstellung reparieren, LGSM-Config-Daten korrekt aus config-default lesen, Script-Name-Bug beheben, und manage.cgi um Firewall-Status, Warnungen und Quick-Fix erweitern.

**Architecture:** Geschichteter Config-Parser in `instance.pl` liest config-default als Basis und config-lgsm als Überschreibungen. `run_server_action` bekommt optionalen `$script_name`-Parameter. `manage.cgi` zeigt Firewall, Warnungen und Quick-Fix-Button.

**Tech Stack:** Perl, Webmin CGI (ui_* Funktionen), LGSM-Konfigstruktur (`config-default/`, `config-lgsm/`)

---

## Datei-Struktur

| Datei | Was ändert sich |
|---|---|
| `src/lib/core.pl` | `run_server_action`: optionaler `$script_name`, `cd $home` |
| `src/lib/instance.pl` | `_parse_lgsm_config`: config-default Layer, `_has_user_config` |
| `src/manage.cgi` | Firewall-Sektion, Warnungen, Quick-Fix, UTF-8, script_name-Fix, check_referer entfernen |
| `src/index.cgi` | UTF-8, check_referer entfernen |
| `src/lang/de` | Neue Keys |
| `src/lang/en` | Neue Keys |
| `t/test_config_parser.pl` | Neues Test-File für geschichteten Parser |

---

## Task 1: check_referer entfernen (index.cgi + manage.cgi)

`check_referer()` existiert in dieser Webmin-Version nicht und verursacht 500-Fehler bei jedem POST.

**Files:**
- Modify: `src/index.cgi:19`
- Modify: `src/manage.cgi:20`

- [ ] **Step 1: check_referer aus index.cgi entfernen**

`src/index.cgi` aktuell Zeile 18–19:
```perl
if ($in{'action'} && $in{'user'}) {
    &check_referer(1);
```
Ersetze durch:
```perl
if ($in{'action'} && $in{'user'}) {
```

- [ ] **Step 2: check_referer aus manage.cgi entfernen**

`src/manage.cgi` aktuell Zeile 19–20:
```perl
if ($in{'action'}) {
    &check_referer(1);
```
Ersetze durch:
```perl
if ($in{'action'}) {
```

- [ ] **Step 3: Build ausführen**

```bash
bash scripts/build.sh
```
Erwartete Ausgabe: `==> Build complete.`

- [ ] **Step 4: Commit**

```bash
git add src/index.cgi src/manage.cgi
git commit -m "fix: remove check_referer (not available in this Webmin version)"
```

---

## Task 2: UTF-8-Fix

Webmin liest `$gconfig{'charset'}` um den Content-Type-Header zu setzen. Wir setzen ihn auf `utf-8` bevor `header()` aufgerufen wird.

**Files:**
- Modify: `src/index.cgi`
- Modify: `src/manage.cgi`

- [ ] **Step 1: UTF-8 in index.cgi setzen**

In `src/index.cgi` nach `&init_config();` (Zeile 7) folgende Zeile einfügen:
```perl
our %gconfig;
$gconfig{'charset'} = 'utf-8';
```

Die `our %gconfig;` Zeile gehört direkt nach `&init_config();`, vor dem ersten `require`.

- [ ] **Step 2: UTF-8 in manage.cgi setzen**

In `src/manage.cgi` nach `&init_config();` (Zeile 7) einfügen:
```perl
our %gconfig;
$gconfig{'charset'} = 'utf-8';
```

- [ ] **Step 3: Build ausführen**

```bash
bash scripts/build.sh
```
Erwartete Ausgabe: `==> Build complete.`

- [ ] **Step 4: Commit**

```bash
git add src/index.cgi src/manage.cgi
git commit -m "fix: set utf-8 charset for correct umlaut rendering"
```

---

## Task 3: Tests für geschichteten Config-Parser schreiben

**Files:**
- Create: `t/test_config_parser.pl`

- [ ] **Step 1: Test-File anlegen**

```perl
#!/usr/bin/perl
# t/test_config_parser.pl
use strict;
use warnings;
use Test::More tests => 6;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/..";

sub sanitize_input { my ($s) = @_; $s =~ s/[^a-zA-Z0-9_-]//g; return $s; }
sub error          { die "error: $_[0]\n" }
sub system_logged  { return 0 }
sub firewall_status { return 0 }

our %text = ();

require 'src/lib/instance.pl';

# Test-Verzeichnis-Struktur:
# $dir/
#   lgsm/
#     config-default/
#       _default.cfg          (port=25565, defaultgame=Minecraft)
#       pwserver.cfg          (gamename=Palworld, port=8211)
#     config-lgsm/
#       common.cfg            (port=9999)   <- überschreibt default

# Test 1: Nur config-default vorhanden -> _has_user_config = 0
{
    my $dir = tempdir(CLEANUP => 1);
    mkdir "$dir/lgsm";
    mkdir "$dir/lgsm/config-default";
    open(my $fh, '>', "$dir/lgsm/config-default/_default.cfg") or die $!;
    print $fh "port=\"25565\"\n";
    print $fh "gamename=\"Minecraft\"\n";
    close($fh);

    my %cfg = _parse_lgsm_config($dir, 'mcserver');
    is($cfg{port},             '25565',    'default port read');
    is($cfg{gamename},         'Minecraft','default gamename read');
    is($cfg{_has_user_config}, 0,          'no user config -> flag is 0');
}

# Test 2: config-lgsm/common.cfg überschreibt default
{
    my $dir = tempdir(CLEANUP => 1);
    mkdir "$dir/lgsm";
    mkdir "$dir/lgsm/config-default";
    mkdir "$dir/lgsm/config-lgsm";

    open(my $fh, '>', "$dir/lgsm/config-default/_default.cfg") or die $!;
    print $fh "port=\"25565\"\n";
    print $fh "gamename=\"Minecraft\"\n";
    close($fh);

    open($fh, '>', "$dir/lgsm/config-lgsm/common.cfg") or die $!;
    print $fh "port=\"9999\"\n";
    close($fh);

    my %cfg = _parse_lgsm_config($dir, 'mcserver');
    is($cfg{port},             '9999', 'common.cfg overrides default port');
    is($cfg{gamename},         'Minecraft', 'gamename still from default');
    is($cfg{_has_user_config}, 1,     'common.cfg exists -> flag is 1');
}
```

- [ ] **Step 2: Test ausführen — muss fehlschlagen**

```bash
perl t/test_config_parser.pl
```
Erwartete Ausgabe: Tests schlagen fehl da `_parse_lgsm_config` noch kein config-default liest.

---

## Task 4: Geschichteten Config-Parser implementieren

**Files:**
- Modify: `src/lib/instance.pl:184-207`

- [ ] **Step 1: `_parse_lgsm_config` ersetzen**

In `src/lib/instance.pl` die aktuelle `_parse_lgsm_config`-Funktion (Zeilen 184–207) vollständig ersetzen:

```perl
# Parse LGSM config files using a layered approach.
# Read order (lowest -> highest priority):
#   1. lgsm/config-default/_default.cfg
#   2. lgsm/config-default/$scriptname.cfg
#   3. lgsm/config-lgsm/common.cfg
#   4. lgsm/config-lgsm/$scriptname/$scriptname.cfg
#
# Returns a hash of all parsed values plus:
#   _has_user_config => 1  if any file from layer 3 or 4 exists and is non-empty
#   _has_user_config => 0  if data comes only from config-default
sub _parse_lgsm_config {
    my ($script_dir, $scriptname) = @_;
    my %cfg;

    my @layers = (
        "$script_dir/lgsm/config-default/_default.cfg",
        "$script_dir/lgsm/config-default/$scriptname.cfg",
        "$script_dir/lgsm/config-lgsm/common.cfg",
        "$script_dir/lgsm/config-lgsm/$scriptname/$scriptname.cfg",
    );

    my $has_user_config = 0;

    for my $i (0 .. $#layers) {
        my $path = $layers[$i];
        next unless -f $path;
        open(my $fh, '<', $path) or next;
        my $has_content = 0;
        while (<$fh>) {
            chomp;
            next if /^\s*#/;
            next if /^\s*$/;
            if (/^\s*(\w+)\s*=\s*["']?([^"'\n]+?)["']?\s*$/) {
                $cfg{$1} = $2;
                $has_content = 1;
            }
        }
        close($fh);
        # Layers 3 and 4 (index 2 and 3) are user configs
        $has_user_config = 1 if $i >= 2 && $has_content;
    }

    $cfg{_has_user_config} = $has_user_config;
    return %cfg;
}
```

- [ ] **Step 2: Tests ausführen — müssen grün sein**

```bash
perl t/test_config_parser.pl
```
Erwartete Ausgabe:
```
ok 1 - default port read
ok 2 - default gamename read
ok 3 - no user config -> flag is 0
ok 4 - common.cfg overrides default port
ok 5 - gamename still from default
ok 6 - common.cfg exists -> flag is 1
```

- [ ] **Step 3: Vollständigen Build ausführen**

```bash
bash scripts/build.sh
```
Erwartete Ausgabe: `==> Build complete.`

- [ ] **Step 4: Commit**

```bash
git add src/lib/instance.pl t/test_config_parser.pl
git commit -m "feat: layered LGSM config parser with _has_user_config flag"
```

---

## Task 5: run_server_action reparieren

**Files:**
- Modify: `src/lib/core.pl`
- Modify: `src/manage.cgi`

- [ ] **Step 1: `run_server_action` in core.pl aktualisieren**

Aktuelle Funktion in `src/lib/core.pl` (Zeilen 24–35):
```perl
sub run_server_action {
    my ($user, $action) = @_;
    $user   = &sanitize_input($user);
    $action = &sanitize_input($action);

    my %valid_actions = map { $_ => 1 } qw(start stop restart update details);
    &error($text{'err_invalid_action'}) unless $valid_actions{$action};

    return &system_logged("su -s /bin/bash -c \"./$user $action\" $user");
}
```

Ersetzen durch:
```perl
# Run a server action as the game user (never as root).
# $action must be in the whitelist.
# $script_name is optional: defaults to $user (standard LGSM convention).
sub run_server_action {
    my ($user, $action, $script_name) = @_;
    $user        = &sanitize_input($user);
    $action      = &sanitize_input($action);
    $script_name = defined $script_name ? &sanitize_input($script_name) : $user;

    my %valid_actions = map { $_ => 1 } qw(start stop restart update details);
    &error($text{'err_invalid_action'}) unless $valid_actions{$action};

    my @pw = getpwnam($user) or &error($text{'err_not_found'});
    my $home = $pw[7];

    return &system_logged(
        "su -s /bin/bash -c \"cd \Q$home\E && ./$script_name $action\" $user"
    );
}
```

- [ ] **Step 2: manage.cgi — script_name übergeben**

In `src/manage.cgi` Zeile 22 aktuell:
```perl
    &run_server_action($unix_user, $action);
```
Ersetzen durch:
```perl
    my $script_name = (split('/', $inst->{'script'}))[-1];
    &run_server_action($unix_user, $action, $script_name);
```

- [ ] **Step 3: Build ausführen**

```bash
bash scripts/build.sh
```
Erwartete Ausgabe: `==> Build complete.`

- [ ] **Step 4: Commit**

```bash
git add src/lib/core.pl src/manage.cgi
git commit -m "fix: run_server_action uses script basename and cd to home dir"
```

---

## Task 6: Neue Lang-Strings

**Files:**
- Modify: `src/lang/de`
- Modify: `src/lang/en`

- [ ] **Step 1: Deutsche Strings ergänzen**

An das Ende von `src/lang/de` anhängen:
```
manage_script=Script-Pfad
manage_fw_status=Firewall
manage_fix_config_warn=Konfiguration aus LGSM-Defaults — bitte eigene Config anlegen.
manage_fix_config_btn=Quick Fix: Config anlegen
```

- [ ] **Step 2: Englische Strings ergänzen**

An das Ende von `src/lang/en` anhängen:
```
manage_script=Script path
manage_fw_status=Firewall
manage_fix_config_warn=Configuration from LGSM defaults -- please create a custom config.
manage_fix_config_btn=Quick Fix: Create config
```

- [ ] **Step 3: Build ausführen**

```bash
bash scripts/build.sh
```
Erwartete Ausgabe: `==> Build complete.`

- [ ] **Step 4: Commit**

```bash
git add src/lang/de src/lang/en
git commit -m "i18n: add manage panel lang strings for firewall and quick-fix"
```

---

## Task 7: manage.cgi Panel-Erweiterungen

Firewall-Sektion, Warnungen (inkl. config-Warnung + Quick-Fix) und Script-Pfad zur Info-Tabelle.

**Files:**
- Modify: `src/manage.cgi`

- [ ] **Step 1: manage.cgi komplett ersetzen**

`src/manage.cgi` vollständig ersetzen mit:

```perl
#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

our (%gconfig, %text, %config, %in);
$gconfig{'charset'} = 'utf-8';

require './lib/core.pl';
require './lib/instance.pl';
require './lib/firewall.pl';
require './lib/acl.pl';

&ReadParse(\%in);

my $instance_id = &sanitize_input($in{'instance_id'} || $in{'user'} || '');
my $inst        = &get_instance($instance_id) or &error($text{'err_not_found'});
my $unix_user   = $inst->{'user'};
my $script_name = (split('/', $inst->{'script'}))[-1];

if ($in{'action'}) {
    my $action = &sanitize_input($in{'action'});

    if ($action eq 'fw_open' || $action eq 'fw_close') {
        my $port = int($inst->{'port'});
        if ($action eq 'fw_open') {
            &firewall_open_port($port, 'tcp');
            &firewall_open_port($port, 'udp');
        } else {
            &firewall_close_port($port, 'tcp');
            &firewall_close_port($port, 'udp');
        }
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id));
    }

    if ($action eq 'fix_config') {
        my $script_dir = $inst->{'script'};
        $script_dir =~ s|/[^/]+$||;
        my $config_file = "$script_dir/lgsm/config-lgsm/common.cfg";
        my $safe_port   = int($inst->{'port'});
        my $safe_game   = $inst->{'game'};
        $safe_game =~ s/[^a-zA-Z0-9 _-]//g;

        open(my $fh, '>', $config_file) or &error("Cannot write config: $!");
        print $fh "port=\"$safe_port\"\n";
        print $fh "gamename=\"$safe_game\"\n";
        close($fh);

        my @pw = getpwnam($unix_user);
        chown($pw[2], $pw[3], $config_file) if @pw;

        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id));
    }

    if (grep { $action eq $_ } qw(start stop restart update)) {
        &run_server_action($unix_user, $action, $script_name);
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id));
    }

    &error($text{'err_invalid_action'});
}

my $safe_id = &html_escape($instance_id);
&header("$text{'manage_title'}: $safe_id", '');

# --- Server-Info ---
print &ui_table_start($text{'manage_title'}, "width=100%", 2);
print &ui_table_row($text{'manage_game'},   &html_escape($inst->{'game'}));
print &ui_table_row($text{'manage_port'},   int($inst->{'port'}));
print &ui_table_row($text{'manage_status'}, &html_escape($inst->{'status'}));
print &ui_table_row($text{'manage_script'}, &html_escape($inst->{'script'}));
print &ui_table_end();

# --- Firewall ---
my $fw_open   = $inst->{'fw_open'};
my $fw_icon   = $fw_open
    ? "\x{2705} $text{fw_status_open}"
    : "\x{274C} $text{fw_status_closed}";
my $fw_action = $fw_open ? 'fw_close' : 'fw_open';
my $fw_btn    = $fw_open ? $text{fw_close_btn} : $text{fw_open_btn};

print &ui_table_start($text{'manage_fw_status'}, "width=100%", 2);
print &ui_table_row($text{'manage_fw_status'}, $fw_icon);
print &ui_table_end();

print &ui_form_start('manage.cgi', 'post');
print &ui_hidden('instance_id', $safe_id);
print &ui_hidden('action',      $fw_action);
print &ui_submit($fw_btn);
print &ui_form_end();

# --- Steuerungs-Buttons ---
print "<p>\n";
foreach my $action (qw(start stop restart update)) {
    print &ui_form_start('manage.cgi', 'post');
    print &ui_hidden('instance_id', $safe_id);
    print &ui_hidden('action',      $action);
    print &ui_submit($text{"manage_$action"});
    print &ui_form_end();
    print " ";
}
print "</p>\n";

# --- Warnungen ---
my @warnings  = @{$inst->{'warnings'}};

# Config-Warnung: wenn Daten nur aus Defaults kommen
my $script_dir = $inst->{'script'};
$script_dir =~ s|/[^/]+$||;
my %cfg = _parse_lgsm_config($script_dir, $script_name);
if (!$cfg{_has_user_config}) {
    push @warnings, $text{'manage_fix_config_warn'};
}

if (@warnings) {
    print "<p><b>\x{26A0}\x{FE0F} $text{health_warn_header}</b></p>\n";
    print "<ul>\n";
    for my $w (@warnings) {
        print "<li>" . &html_escape($w) . "</li>\n";
    }
    print "</ul>\n";
}

# Quick-Fix-Button (nur wenn keine User-Config)
if (!$cfg{_has_user_config}) {
    print &ui_form_start('manage.cgi', 'post');
    print &ui_hidden('instance_id', $safe_id);
    print &ui_hidden('action',      'fix_config');
    print &ui_submit($text{'manage_fix_config_btn'});
    print &ui_form_end();
}

&footer('index.cgi', $text{'index_title'});
```

- [ ] **Step 2: Build ausführen**

```bash
bash scripts/build.sh
```
Erwartete Ausgabe: `==> Build complete.`

- [ ] **Step 3: Commit**

```bash
git add src/manage.cgi
git commit -m "feat: manage.cgi panel with firewall, warnings and quick-fix config button"
```

---

## Verifikation (nach Installation)

1. **UTF-8**: "Port öffnen"-Button zeigt kein "Ã–ffnen" mehr
2. **Daten**: Spiel + Port aus `config-default` werden angezeigt (nicht mehr "unknown"/0)
3. **Quick Fix**: Bei Server ohne `config-lgsm/common.cfg` erscheint Warnung + Button; nach Klick existiert die Datei und Warnung verschwindet
4. **Start/Stop**: Buttons führen `./pwserver start` aus (nicht `./kekks start`)
5. **Firewall**: Status und Button erscheinen korrekt im Panel
