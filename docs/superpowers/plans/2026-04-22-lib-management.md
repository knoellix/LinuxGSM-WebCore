# Library Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve missing shared libraries for game servers by downloading the Valve Scout Runtime, scanning binaries via `ldd`, and symlinking found libraries into per-user `.shared_libs/` directories with `LD_LIBRARY_PATH` injected into LGSM config.

**Architecture:** Two independent subsystems: (1) `host_setup.cgi` for one-time host preparation (i386, repos, Scout Runtime ~300 MB, steamcmd symlink); (2) automatic lib resolution triggered after every game install (`libs_pending` status → `resolve_libs.sh` background job → symlinks + LD_LIBRARY_PATH → `installed`). The status flow `lgsm_ready → libs_pending → installed` gates the normal server view until libs are resolved.

**Tech Stack:** Perl (Webmin CGI pattern), Bash workers, `ldd`, `jq`, JSON::PP, Webmin `ui_*` functions, existing `jobs.pl` background job system.

---

## File Structure

| File | Status | Responsibility |
|------|--------|----------------|
| `src/lang/de` | Modify | German strings: host_setup_*, setup_resolve_libs_btn, hint_lib_not_found, hint_scout_missing |
| `src/lang/en` | Modify | English equivalents |
| `src/lib/lib_package_map.json` | Create | `.so` filename → apt package name mapping |
| `src/lib/lib_resolver.pl` | Create | Perl: `get_apt_package_for_lib`, `get_lib_status`, `write_ld_library_path`, `build_runtime_index` |
| `src/scripts/download_scout.sh` | Create | Download Valve Scout Runtime tarball → `/opt/steam-runtime/` + build `lib_index.json` |
| `src/scripts/resolve_libs.sh` | Create | Root: ldd scan → Scout symlinks → apt fallback → chown → write LD_LIBRARY_PATH |
| `src/host_setup.cgi` | Create | Host-setup page: 4 status checks with inline fix buttons |
| `src/manage.cgi` | Modify | Change `install_game` next_status to `libs_pending`; add `resolve_libs` handler; add `libs_pending` setup-phase block |
| `src/index.cgi` | Modify | Add "Host-Vorbereitung" button next to Steam button |
| `t/test_lib_resolver.pl` | Create | TAP tests for lib_resolver.pl functions |

---

## Task 1: Lang-Strings (de + en)

**Files:**
- Modify: `src/lang/de`
- Modify: `src/lang/en`

- [ ] **Step 1: Append German strings to `src/lang/de`**

Append at end of file:

```
host_setup_title=Host-Vorbereitung
host_setup_desc=Einmalige Systemvorbereitung für 32-Bit-Game-Server (Source Engine).
host_setup_btn=Host-Vorbereitung
host_setup_i386_label=i386-Architektur
host_setup_i386_ok=i386-Unterstützung aktiv
host_setup_i386_missing=i386-Architektur nicht konfiguriert
host_setup_i386_fix_btn=i386 aktivieren (dpkg + apt update)
host_setup_repos_label=contrib/non-free Repositories
host_setup_repos_ok=contrib und non-free aktiv
host_setup_repos_missing=contrib und non-free fehlen in sources.list
host_setup_repos_fix_btn=Repositories aktivieren (non-free contrib)
host_setup_scout_label=Steam Scout Runtime
host_setup_scout_ok=Scout Runtime vorhanden (/opt/steam-runtime/lib_index.json)
host_setup_scout_missing=Scout Runtime fehlt (ca. 300 MB)
host_setup_scout_fix_btn=Scout Runtime herunterladen (Hintergrund-Job)
host_setup_symlink_label=SteamCMD-Symlink
host_setup_symlink_ok=Symlink /opt/steam-runtime/steamcmd vorhanden
host_setup_symlink_missing=Symlink /opt/steam-runtime/steamcmd fehlt
host_setup_symlink_fix_btn=Symlink anlegen
host_setup_scout_running=Scout Runtime wird heruntergeladen…
host_setup_scout_done=Download abgeschlossen.
setup_resolve_libs_btn=Libs auflösen
setup_libs_scout_hint=Scout Runtime fehlt — bitte zuerst Host-Vorbereitung durchführen.
hint_lib_not_found=Bibliotheken konnten nicht aufgelöst werden — Scout Runtime prüfen oder fehlende Pakete manuell installieren.
hint_scout_missing=Scout Runtime nicht gefunden unter /opt/steam-runtime/ — bitte Host-Vorbereitung ausführen.
```

- [ ] **Step 2: Append English strings to `src/lang/en`**

Append at end of file:

```
host_setup_title=Host Preparation
host_setup_desc=One-time system preparation for 32-bit game servers (Source Engine).
host_setup_btn=Host Preparation
host_setup_i386_label=i386 Architecture
host_setup_i386_ok=i386 support active
host_setup_i386_missing=i386 architecture not configured
host_setup_i386_fix_btn=Enable i386 (dpkg + apt update)
host_setup_repos_label=contrib/non-free Repositories
host_setup_repos_ok=contrib and non-free active
host_setup_repos_missing=contrib and non-free missing from sources.list
host_setup_repos_fix_btn=Enable repositories (non-free contrib)
host_setup_scout_label=Steam Scout Runtime
host_setup_scout_ok=Scout Runtime present (/opt/steam-runtime/lib_index.json)
host_setup_scout_missing=Scout Runtime missing (~300 MB)
host_setup_scout_fix_btn=Download Scout Runtime (background job)
host_setup_symlink_label=SteamCMD Symlink
host_setup_symlink_ok=Symlink /opt/steam-runtime/steamcmd present
host_setup_symlink_missing=Symlink /opt/steam-runtime/steamcmd missing
host_setup_symlink_fix_btn=Create symlink
host_setup_scout_running=Downloading Scout Runtime…
host_setup_scout_done=Download complete.
setup_resolve_libs_btn=Resolve Libraries
setup_libs_scout_hint=Scout Runtime missing — please run Host Preparation first.
hint_lib_not_found=Libraries could not be resolved — check Scout Runtime or install missing packages manually.
hint_scout_missing=Scout Runtime not found at /opt/steam-runtime/ — please run Host Preparation.
```

- [ ] **Step 3: Verify with perl syntax check on lang files (no parse step needed — key=value)**

```bash
grep -c "host_setup_title" src/lang/de src/lang/en
```

Expected output:
```
src/lang/de:1
src/lang/en:1
```

- [ ] **Step 4: Commit**

```bash
git add src/lang/de src/lang/en
git commit -m "feat: add lang strings for lib management and host setup

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 2: lib_package_map.json

**Files:**
- Create: `src/lib/lib_package_map.json`

- [ ] **Step 1: Create the JSON mapping file**

```json
{
  "libgcc_s.so.1":            "lib32gcc-s1",
  "libstdc++.so.6":           "lib32stdc++6",
  "libsdl2-2.0.so.0":        "libsdl2-2.0-0:i386",
  "libcurl.so.4":             "libcurl4:i386",
  "libssl.so.1.0.0":         "libssl1.0.0",
  "libtcmalloc_minimal.so.4": "libgoogle-perftools4:i386",
  "libm.so.6":                "libc6:i386",
  "libdl.so.2":               "libc6:i386",
  "libc.so.6":                "libc6:i386",
  "libpthread.so.0":          "libc6:i386",
  "libz.so.1":                "zlib1g:i386",
  "libbz2.so.1.0":            "libbz2-1.0:i386"
}
```

Write to `src/lib/lib_package_map.json`.

- [ ] **Step 2: Validate JSON**

```bash
perl -e 'use JSON::PP; open(my $f,"<","src/lib/lib_package_map.json"); local $/; my $t=<$f>; close $f; decode_json($t); print "JSON OK\n"'
```

Expected: `JSON OK`

- [ ] **Step 3: Commit**

```bash
git add src/lib/lib_package_map.json
git commit -m "feat: add lib_package_map.json for so-to-apt mapping

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 3: lib_resolver.pl + tests

**Files:**
- Create: `src/lib/lib_resolver.pl`
- Create: `t/test_lib_resolver.pl`

- [ ] **Step 1: Write the failing test**

Create `t/test_lib_resolver.pl`:

```perl
#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 9;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

require "$Bin/stubs.pl";

our ($module_root, $config_directory);
my $tmp = tempdir(CLEANUP => 1);
$config_directory = $tmp;
$module_root = "$Bin/..";

BEGIN {
    *CORE::GLOBAL::getpwnam = sub {
        return ('gs_mc','x',1002,1002,'','','/home/gs_mc','/usr/sbin/nologin') if $_[0] eq 'gs_mc';
        return ();
    };
}

# Stub for validate_config_target — no-op in tests
sub validate_config_target { return 1; }

require "$Bin/../src/lib/lib_resolver.pl";

# --- Test 1+2: get_apt_package_for_lib ---
my $pkg = get_apt_package_for_lib('libgcc_s.so.1');
is($pkg, 'lib32gcc-s1', 'get_apt_package_for_lib returns correct package');

my $undef = get_apt_package_for_lib('libnosuchlib.so.999');
ok(!defined $undef, 'get_apt_package_for_lib returns undef for unknown lib');

# --- Test 3+4+5: get_lib_status ---
my $missing_status = get_lib_status('gs_mc');
is($missing_status, 'missing', 'get_lib_status=missing when dir absent');

mkdir "$tmp/fakehome";
# Override home lookup
{
    no warnings 'redefine';
    # make get_lib_status check tmp dir
}
# Use temp dir as stand-in for /home/gs_mc/.shared_libs
my $shared = "$tmp/.shared_libs";
mkdir $shared;
my $empty_status = _get_lib_status_dir($shared);
is($empty_status, 'empty', 'get_lib_status=empty for empty dir');

open(my $fh, '>', "$shared/libgcc_s.so.1") or die $!;
close($fh);
my $ok_status = _get_lib_status_dir($shared);
is($ok_status, 'ok', 'get_lib_status=ok when symlinks present');

# --- Test 6+7: write_ld_library_path ---
my $server_dir = "$tmp/server";
mkdir "$server_dir";
mkdir "$server_dir/lgsm";
mkdir "$server_dir/lgsm/config-lgsm";
mkdir "$server_dir/lgsm/config-lgsm/mcserver";

write_ld_library_path('gs_mc', 'mcserver', $server_dir, $shared);

my $cfg = "$server_dir/lgsm/config-lgsm/mcserver/mcserver.cfg";
ok(-f $cfg, 'write_ld_library_path creates config file');
open($fh, '<', $cfg) or die $!;
my $content = do { local $/; <$fh> };
close($fh);
like($content, qr/LD_LIBRARY_PATH=/, 'config contains LD_LIBRARY_PATH');
like($content, qr{\Q$shared\E}, 'config contains shared_libs path');

# --- Test 8+9: write_ld_library_path updates existing line ---
open($fh, '>', $cfg) or die $!;
print $fh "port=\"27015\"\nLD_LIBRARY_PATH=\"/old/path:\${LD_LIBRARY_PATH}\"\n";
close($fh);

write_ld_library_path('gs_mc', 'mcserver', $server_dir, $shared);
open($fh, '<', $cfg) or die $!;
$content = do { local $/; <$fh> };
close($fh);
my @ld_lines = grep { /^LD_LIBRARY_PATH=/ } split(/\n/, $content);
is(scalar @ld_lines, 1, 'write_ld_library_path replaces existing LD_LIBRARY_PATH, not appends');
like($content, qr/port=/, 'other config values preserved');
```

- [ ] **Step 2: Run test to verify it fails**

```bash
perl t/test_lib_resolver.pl
```

Expected: Compilation error or `Attempt to require nonexistent module`.

- [ ] **Step 3: Create `src/lib/lib_resolver.pl`**

```perl
# LinuxGSM-WebCore — Lib resolver helper functions
use strict;
use warnings;
use JSON::PP;

our ($module_root);

sub get_apt_package_for_lib {
    my ($libname) = @_;
    (my $lib_dir = __FILE__) =~ s|/[^/]+$||;
    my $map_file = "$lib_dir/lib_package_map.json";
    return undef unless -f $map_file;
    open(my $fh, '<', $map_file) or return undef;
    local $/;
    my $json = <$fh>;
    close($fh);
    my $map = eval { decode_json($json) } or return undef;
    return $map->{$libname};
}

sub get_lib_status {
    my ($unix_user) = @_;
    my @pw = getpwnam($unix_user);
    return 'missing' unless @pw;
    my $home = $pw[7];
    return _get_lib_status_dir("$home/.shared_libs");
}

sub _get_lib_status_dir {
    my ($dir) = @_;
    return 'missing' unless -d $dir;
    opendir(my $dh, $dir) or return 'missing';
    my @files = grep { !/^\./ } readdir($dh);
    closedir($dh);
    return @files ? 'ok' : 'empty';
}

# Write LD_LIBRARY_PATH into LGSM instance config ($script.cfg).
# $shared_libs_dir defaults to /home/$unix_user/.shared_libs if omitted.
sub write_ld_library_path {
    my ($unix_user, $script_name, $server_dir, $shared_libs_dir) = @_;
    my @pw = getpwnam($unix_user);
    my $home = @pw ? $pw[7] : "/home/$unix_user";
    $shared_libs_dir //= "$home/.shared_libs";

    my $cfg_dir  = "$server_dir/lgsm/config-lgsm/$script_name";
    my $cfg_path = "$cfg_dir/$script_name.cfg";

    &validate_config_target($cfg_path);

    my @lines;
    my $found = 0;
    if (-f $cfg_path) {
        open(my $fh, '<', $cfg_path) or return;
        while (<$fh>) {
            chomp;
            if (/^LD_LIBRARY_PATH=/) {
                push @lines, "LD_LIBRARY_PATH=\"$shared_libs_dir:\${LD_LIBRARY_PATH}\"";
                $found = 1;
            } else {
                push @lines, $_;
            }
        }
        close($fh);
    }
    push @lines, "LD_LIBRARY_PATH=\"$shared_libs_dir:\${LD_LIBRARY_PATH}\"" unless $found;

    mkdir $cfg_dir, 0755 unless -d $cfg_dir;
    open(my $fh, '>', $cfg_path) or return;
    print $fh "$_\n" for @lines;
    close($fh);

    chown($pw[2], $pw[3], $cfg_path) if @pw;
}

sub build_runtime_index {
    my $runtime_dir = '/opt/steam-runtime';
    return 0 unless -d $runtime_dir;
    require File::Find;
    my %idx;
    File::Find::find(sub {
        return if -d $_;
        return unless $_ =~ /\.so/;
        my $name = $_;
        $idx{$name} = $File::Find::name;
    }, $runtime_dir);
    open(my $fh, '>', "$runtime_dir/lib_index.json") or return 0;
    print $fh encode_json(\%idx);
    close($fh);
    return 1;
}

1;
```

- [ ] **Step 4: Run tests**

```bash
perl t/test_lib_resolver.pl
```

Expected: `ok 1 - ok 9` / all 9 pass.

- [ ] **Step 5: Perl syntax check**

```bash
perl -c src/lib/lib_resolver.pl
```

Expected: `src/lib/lib_resolver.pl syntax OK`

- [ ] **Step 6: Commit**

```bash
git add src/lib/lib_resolver.pl t/test_lib_resolver.pl
git commit -m "feat: add lib_resolver.pl with tests

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 4: download_scout.sh

**Files:**
- Create: `src/scripts/download_scout.sh`

- [ ] **Step 1: Create the script**

```bash
#!/bin/bash
set -euo pipefail

JOB_DIR="$1"

echo $$ > "$JOB_DIR/pid"
exec >> "$JOB_DIR/output" 2>&1

RUNTIME_DIR="/opt/steam-runtime"
TARBALL="com.valvesoftware.SteamRuntime.Sdk-amd64,i386-scout-sysroot.tar.gz"
URL="https://repo.steampowered.com/steamrt-images-scout/snapshots/latest-steam-client-general-availability/${TARBALL}"

echo "=== Creating $RUNTIME_DIR ==="
mkdir -p "$RUNTIME_DIR"
cd "$RUNTIME_DIR"

echo "=== Downloading Scout Runtime (~300 MB) ==="
if ! wget -q --show-progress -O "${TARBALL}.tmp" "$URL"; then
    echo "Download failed."
    echo "failed" > "$JOB_DIR/status"
    exit 1
fi
mv "${TARBALL}.tmp" "$TARBALL"

echo "=== Extracting ==="
if ! tar -xf "$TARBALL"; then
    echo "Extraction failed."
    echo "failed" > "$JOB_DIR/status"
    exit 1
fi
rm -f "$TARBALL"

echo "=== Building lib_index.json ==="
find "$RUNTIME_DIR" -name "*.so*" -not -type d | perl -e '
    use JSON::PP;
    my %idx;
    while (<STDIN>) {
        chomp;
        my $name = (split "/", $_)[-1];
        $idx{$name} //= $_;
    }
    open(my $fh, ">", "/opt/steam-runtime/lib_index.json") or die $!;
    print $fh encode_json(\%idx);
    close($fh);
    print "Indexed " . scalar(keys %idx) . " libraries.\n";
'

echo "=== Scout Runtime ready ==="
echo "ok" > "$JOB_DIR/status"
```

Write to `src/scripts/download_scout.sh`.

- [ ] **Step 2: Syntax check**

```bash
bash -n src/scripts/download_scout.sh
```

Expected: no output (no errors).

- [ ] **Step 3: Make executable**

```bash
chmod +x src/scripts/download_scout.sh
```

- [ ] **Step 4: Commit**

```bash
git add src/scripts/download_scout.sh
git commit -m "feat: add download_scout.sh for Scout Runtime download

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 5: host_setup.cgi

**Files:**
- Create: `src/host_setup.cgi`

The page shows 4 checks as a status table. Fix buttons POST to the same page.
Reuses `check_apt_sources()` and `patch_apt_sources()` from `steam.pl`.

- [ ] **Step 1: Create `src/host_setup.cgi`**

```perl
#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/acl.pl';
require './lib/steam.pl';
require './lib/jobs.pl';

our (%text, %in, $module_root, $config_directory);
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

&can_scan() or &error($text{'err_access_denied'});

if ($ENV{REQUEST_METHOD} eq 'POST') {
    my $action = $in{'action'} // '';
    $action =~ s/[^a-z_]//g;

    if ($action eq 'add_i386') {
        system('dpkg --add-architecture i386 && apt-get update -qq');
        &redirect('host_setup.cgi');

    } elsif ($action eq 'fix_repos') {
        &patch_apt_sources('/etc/apt/sources.list');
        system('apt-get update -qq');
        &redirect('host_setup.cgi');

    } elsif ($action eq 'fix_symlink') {
        system('ln -sf /usr/games/steamcmd /opt/steam-runtime/steamcmd') if -f '/usr/games/steamcmd';
        &redirect('host_setup.cgi');

    } elsif ($action eq 'download_scout') {
        my $job_id = &create_job();
        my $worker = "$module_root/scripts/download_scout.sh";
        my $job_dir = "$config_directory/jobs/$job_id";
        system("nohup bash \Q$worker\E \Q$job_dir\E >/dev/null 2>&1 &");
        &redirect("host_setup.cgi?action=poll_scout&job=" . &html_escape($job_id));
    }
}

my $get_action = $in{'action'} // '';
$get_action =~ s/[^a-z_]//g;

if ($get_action eq 'poll_scout') {
    my $job_id = $in{'job'} // '';
    $job_id =~ s/[^0-9a-f]//g;
    $job_id = substr($job_id, 0, 16);

    my $status = &get_job_status($job_id) // 'unknown';
    my $offset = int($in{'offset'} || 0);
    my ($out, $new_len) = &get_job_output($job_id, $offset);

    &header($text{'host_setup_title'}, '');
    print "<h3>" . &html_escape($text{'host_setup_scout_label'}) . "</h3>\n";

    if ($status eq 'running') {
        my $poll_url = "host_setup.cgi?action=poll_scout&job=" . &html_escape($job_id) . "&offset=$new_len";
        print "<meta http-equiv=\"refresh\" content=\"3;url=$poll_url\">\n";
        print "<p>" . &html_escape($text{'host_setup_scout_running'}) . "</p>\n";
    } elsif ($status eq 'ok') {
        print "<p style='color:green'>" . &html_escape($text{'host_setup_scout_done'}) . "</p>\n";
        print "<p><a href='host_setup.cgi'>&larr; Zur&uuml;ck</a></p>\n";
    } else {
        print "<p style='color:red'>" . &html_escape($text{'job_failed'}) . "</p>\n";
        print "<p><a href='host_setup.cgi'>&larr; Zur&uuml;ck</a></p>\n";
    }
    print "<pre style='background:#111;color:#eee;padding:8px;overflow:auto'>" . &html_escape($out) . "</pre>\n" if $out;
    &footer('', '');
    exit;
}

# --- Checks ---
my $i386_ok   = (qx(dpkg --print-foreign-architectures 2>/dev/null) =~ /\bi386\b/) ? 1 : 0;
my $apt_info  = &check_apt_sources('/etc/apt/sources.list');
my $repos_ok  = ($apt_info->{'non_free'} && $apt_info->{'contrib'}) ? 1 : 0;
my $scout_ok  = -f '/opt/steam-runtime/lib_index.json' ? 1 : 0;
my $symlink_ok = (-l '/opt/steam-runtime/steamcmd' &&
                  readlink('/opt/steam-runtime/steamcmd') eq '/usr/games/steamcmd') ? 1 : 0;

sub _check_row {
    my ($label_ok, $label_bad, $is_ok, $fix_action, $fix_btn_text) = @_;
    my $status_html = $is_ok
        ? "<span style='color:green'>&#x2705; " . &html_escape($label_ok) . "</span>"
        : "<span style='color:red'>&#x274C; " . &html_escape($label_bad) . "</span>";
    my $fix_html = '';
    unless ($is_ok) {
        $fix_html = &ui_form_start('host_setup.cgi', 'post')
            . &ui_hidden('action', $fix_action)
            . &ui_submit($fix_btn_text, undef, undef, undef, 'btn-primary')
            . &ui_form_end();
    }
    return [$status_html, $fix_html];
}

&header($text{'host_setup_title'}, '');
print "<h3>" . &html_escape($text{'host_setup_title'}) . "</h3>\n";
print "<p>" . &html_escape($text{'host_setup_desc'}) . "</p>\n";

my @rows = (
    _check_row($text{'host_setup_i386_ok'},    $text{'host_setup_i386_missing'},   $i386_ok,    'add_i386',       $text{'host_setup_i386_fix_btn'}),
    _check_row($text{'host_setup_repos_ok'},   $text{'host_setup_repos_missing'},  $repos_ok,   'fix_repos',      $text{'host_setup_repos_fix_btn'}),
    _check_row($text{'host_setup_scout_ok'},   $text{'host_setup_scout_missing'},  $scout_ok,   'download_scout', $text{'host_setup_scout_fix_btn'}),
    _check_row($text{'host_setup_symlink_ok'}, $text{'host_setup_symlink_missing'},$symlink_ok, 'fix_symlink',    $text{'host_setup_symlink_fix_btn'}),
);

my @labels = (
    $text{'host_setup_i386_label'},
    $text{'host_setup_repos_label'},
    $text{'host_setup_scout_label'},
    $text{'host_setup_symlink_label'},
);

print &ui_columns_start([$text{'index_col_status'}, '', ''], undef, 0);
for my $i (0 .. $#rows) {
    print &ui_columns_row([
        &html_escape($labels[$i]),
        $rows[$i][0],
        $rows[$i][1],
    ], ['', '', '']);
}
print &ui_columns_end();

&footer('', '');
```

- [ ] **Step 2: Perl syntax check**

```bash
perl -c src/host_setup.cgi
```

Expected: `src/host_setup.cgi syntax OK`

- [ ] **Step 3: Commit**

```bash
git add src/host_setup.cgi
git commit -m "feat: add host_setup.cgi for Scout Runtime and system checks

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 6: resolve_libs.sh

**Files:**
- Create: `src/scripts/resolve_libs.sh`

Runs as **root** (launched via `nohup` from manage.cgi which runs as root).

- [ ] **Step 1: Create `src/scripts/resolve_libs.sh`**

```bash
#!/bin/bash
set -euo pipefail

JOB_DIR="$1"
UNIX_USER="$2"
SERVER_DIR="$3"
GAME_SCRIPT="$4"

echo $$ > "$JOB_DIR/pid"
exec >> "$JOB_DIR/output" 2>&1

INDEX="/opt/steam-runtime/lib_index.json"
SHARED_LIBS="/home/$UNIX_USER/.shared_libs"
SERVERFILES="$SERVER_DIR/serverfiles"

# Step 1: Require Scout Runtime
if [ ! -f "$INDEX" ]; then
    echo "ERROR: $INDEX not found. Run Host Setup first."
    echo "hint_scout_missing" > "$JOB_DIR/error_hint"
    echo "failed" > "$JOB_DIR/status"
    exit 1
fi

# Step 2: Create .shared_libs dir (owned by root temporarily)
mkdir -p "$SHARED_LIBS"

# Step 3-5: ldd scan on all executables and .so files in serverfiles/
echo "=== Scanning binaries in $SERVERFILES/ ==="

# Track missing libs to avoid duplicate lookups
declare -A CHECKED

_resolve_lib() {
    local libname="$1"
    local depth="${2:-0}"
    [ "$depth" -ge 5 ] && return
    [ -n "${CHECKED[$libname]+set}" ] && return
    CHECKED[$libname]=1

    # Check if already linked
    if [ -L "$SHARED_LIBS/$libname" ]; then
        return
    fi

    # Try Scout Runtime index
    local runtime_path
    runtime_path=$(jq -r --arg lib "$libname" '.[$lib] // empty' "$INDEX" 2>/dev/null)
    if [ -n "$runtime_path" ] && [ -f "$runtime_path" ]; then
        echo "  [Scout] $libname -> $runtime_path"
        # Path-traversal guard: target must be under /opt/steam-runtime/
        if [[ "$runtime_path" != /opt/steam-runtime/* ]]; then
            echo "  SKIP: suspicious path $runtime_path"
            echo "$libname" >> "$JOB_DIR/lib_errors"
            return
        fi
        ln -sf "$runtime_path" "$SHARED_LIBS/$libname"
        # Recurse: resolve deps of the new symlink target (max depth 5)
        ldd "$runtime_path" 2>/dev/null | grep "not found" | awk '{print $1}' | while read -r dep; do
            _resolve_lib "$dep" $(( depth + 1 ))
        done
        return
    fi

    # Try apt package map
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    MAP="$SCRIPT_DIR/../lib/lib_package_map.json"
    local pkg
    pkg=$(jq -r --arg lib "$libname" '.[$lib] // empty' "$MAP" 2>/dev/null)
    if [ -n "$pkg" ]; then
        echo "  [apt] $libname -> package $pkg"
        if apt-get install -y "$pkg" -qq 2>/dev/null; then
            echo "  Installed $pkg"
        else
            echo "  apt install failed for $pkg"
            echo "$libname" >> "$JOB_DIR/lib_errors"
        fi
        return
    fi

    echo "  NOT FOUND: $libname"
    echo "$libname" >> "$JOB_DIR/lib_errors"
}

# Find binaries and scan each
find "$SERVERFILES" -type f \( -executable -o -name "*.so*" \) 2>/dev/null | while read -r binary; do
    ldd "$binary" 2>/dev/null | grep "not found" | awk '{print $1}' | while read -r libname; do
        _resolve_lib "$libname"
    done
done

# Step 6: Fix ownership of all symlinks
if ls "$SHARED_LIBS"/* 2>/dev/null 1>&2; then
    chown -h "$UNIX_USER:$UNIX_USER" "$SHARED_LIBS"/* 2>/dev/null || true
fi
chown "$UNIX_USER:$UNIX_USER" "$SHARED_LIBS"

# Step 7: Write LD_LIBRARY_PATH into LGSM instance config
if [ -d "$SHARED_LIBS" ] && ls "$SHARED_LIBS"/* 2>/dev/null 1>&2; then
    SCRIPT_CFG="$SERVER_DIR/lgsm/config-lgsm/$GAME_SCRIPT/$GAME_SCRIPT.cfg"
    mkdir -p "$(dirname "$SCRIPT_CFG")"
    if grep -q "^LD_LIBRARY_PATH=" "$SCRIPT_CFG" 2>/dev/null; then
        sed -i "s|^LD_LIBRARY_PATH=.*|LD_LIBRARY_PATH=\"$SHARED_LIBS:\${LD_LIBRARY_PATH}\"|" "$SCRIPT_CFG"
    else
        echo "LD_LIBRARY_PATH=\"$SHARED_LIBS:\${LD_LIBRARY_PATH}\"" >> "$SCRIPT_CFG"
    fi
    chown "$UNIX_USER:$UNIX_USER" "$SCRIPT_CFG" 2>/dev/null || true
    echo "=== LD_LIBRARY_PATH set in $SCRIPT_CFG ==="
fi

# Step 8: Final status
if [ -f "$JOB_DIR/lib_errors" ] && [ -s "$JOB_DIR/lib_errors" ]; then
    echo "=== Some libraries could not be resolved: ==="
    cat "$JOB_DIR/lib_errors"
    echo "hint_lib_not_found" > "$JOB_DIR/error_hint"
    echo "failed" > "$JOB_DIR/status"
    exit 1
fi

echo "=== Library resolution complete ==="
echo "ok" > "$JOB_DIR/status"
```

- [ ] **Step 2: Bash syntax check**

```bash
bash -n src/scripts/resolve_libs.sh
```

Expected: no output.

- [ ] **Step 3: Make executable**

```bash
chmod +x src/scripts/resolve_libs.sh
```

- [ ] **Step 4: Smoke test (no-root, Scout Runtime absent — expects correct error path)**

```bash
tmpjob=$(mktemp -d)
bash src/scripts/resolve_libs.sh "$tmpjob" "$(whoami)" /tmp/nonexistent mcserver 2>/dev/null || true
cat "$tmpjob/status"
cat "$tmpjob/error_hint"
rm -rf "$tmpjob"
```

Expected output:
```
failed
hint_scout_missing
```

- [ ] **Step 5: Commit**

```bash
git add src/scripts/resolve_libs.sh
git commit -m "feat: add resolve_libs.sh for ldd-based library resolution

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 7: manage.cgi — libs_pending flow

**Files:**
- Modify: `src/manage.cgi`

Three changes:
1. `install_game` handler: change `next_status=installed` → `next_status=libs_pending`
2. Add `resolve_libs` POST action handler (after `install_game` block)
3. Add `libs_pending` branch in setup-phase render (after `lgsm_ready` block, before `&footer`)

- [ ] **Step 1: Change `install_game` next_status**

Find in `src/manage.cgi` (line ~366):
```perl
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=poll_job&job=" . &html_escape($job_id) . "&next_status=installed");
    }
    elsif ($action eq 'update') {
```

Replace with:
```perl
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=poll_job&job=" . &html_escape($job_id) . "&next_status=libs_pending");
    }
    elsif ($action eq 'update') {
```

- [ ] **Step 2: Add `resolve_libs` handler after `install_game` block**

Find in `src/manage.cgi`:
```perl
    elsif ($action eq 'update') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
```

Insert before it:
```perl
    elsif ($action eq 'resolve_libs') {
        my $reg = &get_registered_instance($instance_id) or &error($text{'err_not_found'});
        my $script_path = $reg->{'script'} // '';
        my $script_name = (split('/', $script_path))[-1] // '';
        (my $server_dir = $script_path) =~ s|/[^/]+$||;
        $script_name =~ s/[^a-zA-Z0-9_-]//g;

        our ($config_directory, $module_root);
        my $job_id = &create_job();
        my $worker = "$module_root/scripts/resolve_libs.sh";
        &system_logged("nohup bash \Q$worker\E \Q$config_directory/jobs/$job_id\E \Q$unix_user\E \Q$server_dir\E \Q$script_name\E >/dev/null 2>&1 &");
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=poll_job&job=" . &html_escape($job_id) . "&next_status=installed");
    }
    elsif ($action eq 'update') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
```

- [ ] **Step 3: Add `libs_pending` setup-phase render block**

Find in `src/manage.cgi` (line ~518):
```perl
    } elsif ($istatus eq 'lgsm_ready') {
        print "<p style='color:green'>&#x2705; LGSM installiert.</p>\n";
        print &ui_form_start('manage.cgi', 'post');
        print &ui_hidden('instance_id', &html_escape($instance_id));
        print &ui_hidden('action', 'install_game');
        print &ui_submit($text{'setup_install_game_btn'}, undef, undef, undef, 'btn-primary');
        print &ui_form_end();
    }
```

Replace with:
```perl
    } elsif ($istatus eq 'lgsm_ready') {
        print "<p style='color:green'>&#x2705; LGSM installiert.</p>\n";
        print &ui_form_start('manage.cgi', 'post');
        print &ui_hidden('instance_id', &html_escape($instance_id));
        print &ui_hidden('action', 'install_game');
        print &ui_submit($text{'setup_install_game_btn'}, undef, undef, undef, 'btn-primary');
        print &ui_form_end();
    } elsif ($istatus eq 'libs_pending') {
        print "<p style='color:green'>&#x2705; LGSM installiert.</p>\n";
        print "<p style='color:green'>&#x2705; Game-Server installiert.</p>\n";
        if (-f '/opt/steam-runtime/lib_index.json') {
            print &ui_form_start('manage.cgi', 'post');
            print &ui_hidden('instance_id', &html_escape($instance_id));
            print &ui_hidden('action', 'resolve_libs');
            print &ui_submit($text{'setup_resolve_libs_btn'}, undef, undef, undef, 'btn-primary');
            print &ui_form_end();
        } else {
            print "<p style='color:orange'>" . &html_escape($text{'setup_libs_scout_hint'})
                . " <a href='host_setup.cgi'>" . &html_escape($text{'host_setup_title'}) . "</a></p>\n";
        }
    }
```

- [ ] **Step 4: Perl syntax check**

```bash
perl -c src/manage.cgi
```

Expected: `src/manage.cgi syntax OK`

- [ ] **Step 5: Run verify script**

```bash
bash scripts/verify.sh
```

Expected: all checks pass.

- [ ] **Step 6: Commit**

```bash
git add src/manage.cgi
git commit -m "feat: add libs_pending flow in manage.cgi (resolve_libs handler + setup phase)

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 8: index.cgi — host_setup button

**Files:**
- Modify: `src/index.cgi`

Add a "Host-Vorbereitung" button next to the Steam button in the admin tools block.

- [ ] **Step 1: Add host_setup button**

Find in `src/index.cgi`:
```perl
    print &ui_form_start('steam_settings.cgi', 'get');
    print &ui_submit($text{'steam_btn'}, undef, undef, undef, 'btn-default');
    print &ui_form_end();
```

Replace with:
```perl
    print &ui_form_start('steam_settings.cgi', 'get');
    print &ui_submit($text{'steam_btn'}, undef, undef, undef, 'btn-default');
    print &ui_form_end();

    print &ui_form_start('host_setup.cgi', 'get');
    print &ui_submit($text{'host_setup_btn'}, undef, undef, undef, 'btn-default');
    print &ui_form_end();
```

- [ ] **Step 2: Perl syntax check**

```bash
perl -c src/index.cgi
```

Expected: `src/index.cgi syntax OK`

- [ ] **Step 3: Commit**

```bash
git add src/index.cgi
git commit -m "feat: add Host Preparation button to index.cgi

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 9: Full Verification + Build

- [ ] **Step 1: Run full verification**

```bash
bash scripts/verify-full.sh
```

Expected: all checks green, no failures.

- [ ] **Step 2: Run critical regression tests**

```bash
perl t/test_security_guards.pl
perl t/test_provisioning_flow.pl
perl t/test_lib_resolver.pl
perl t/test_instance_status.pl
```

Expected: all TAP tests pass.

- [ ] **Step 3: Build .wbm**

```bash
bash scripts/build.sh
```

Expected: `dist/linuxgsm-webcore-*.wbm` created without errors.

- [ ] **Step 4: Commit if verify.sh made any auto-fixes (otherwise skip)**

```bash
git status
# Only commit if there are unstaged changes from verify.sh
```

---

## Self-Review

### Spec Coverage

| Spec Requirement | Task |
|-----------------|------|
| host_setup.cgi — 4 checks (i386, repos, Scout, symlink) | Task 5 |
| download_scout.sh background job | Task 4 |
| `libs_pending` status in flow | Task 7 (manage.cgi next_status change) |
| resolve_libs.sh — ldd scan + symlinks + apt fallback | Task 6 |
| lib_index.json path-traversal guard | Task 6 (runtime_path guard) |
| Recursion depth limit 5 | Task 6 (_resolve_lib depth param) |
| LD_LIBRARY_PATH in LGSM config | Task 6 (sed in-place) |
| chown -h for symlinks | Task 6 |
| lib_package_map.json whitelist | Task 2 |
| lib_resolver.pl Perl helpers | Task 3 |
| manage.cgi libs_pending setup block | Task 7 |
| manage.cgi resolve_libs action | Task 7 |
| Scout Runtime missing → link to host_setup | Task 7 |
| index.cgi host_setup button | Task 8 |
| Lang strings de + en | Task 1 |
| Security: no user-input in shell commands (all from registry) | Tasks 6, 7: $UNIX_USER from registry, shell-escaped with \Q\E |
| Symlinks only point to /opt/steam-runtime/ | Task 6 (path guard check) |

### No Placeholders Check
All steps contain concrete code. ✅

### Type Consistency
- `write_ld_library_path($unix_user, $script_name, $server_dir, $shared_libs_dir)` — defined in Task 3, tested with same signature ✅
- `get_lib_status($unix_user)` / `_get_lib_status_dir($dir)` — used consistently ✅
- `get_apt_package_for_lib($libname)` — consistent ✅
- `create_job()`, `get_job_status()`, `get_job_output()` — from existing `jobs.pl` ✅
- `can_scan()` — from existing `acl.pl` ✅
