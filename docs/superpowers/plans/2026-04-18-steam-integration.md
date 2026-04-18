# Steam-Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Steam-Account-Verwaltung, interaktiver Guard-Web-Flow und spielespezifische Steam-Pflicht-Login-Integration in das LinuxGSM-WebCore Webmin-Modul einbauen.

**Architecture:** Neue Library `src/lib/steam.pl` kapselt alle Steam-Logik (Systemprüfung, Account-Vault, Session-Management). Eine neue `src/steam_settings.cgi` bietet die Admin-Oberfläche. Wizard und Manage-Seite werden erweitert. Das Passwort wird niemals persistiert — nur einmalig via chmod-600-Temp-Datei an einen Hintergrundprozess übergeben.

**Tech Stack:** Perl 5 (strict/warnings), Webmin ui_* API, Bash (steam_login_worker.sh), steamcmd, FIFO für IPC, TAP-Tests mit Test::More

---

## Dateistruktur

| Datei | Status | Zweck |
|---|---|---|
| `src/lib/steam.pl` | NEU | System-Detection, Account-Vault, Session-Functions |
| `src/scripts/steam_login_worker.sh` | NEU | Hintergrundprozess für steamcmd + Guard-Flow |
| `src/steam_settings.cgi` | NEU | Admin-UI: System-Status, Accounts, Login-Flow |
| `t/test_steam.pl` | NEU | Unit-Tests für steam.pl |
| `src/lang/de` | ÄNDERN | Neue Steam-Strings |
| `src/lang/en` | ÄNDERN | Neue Steam-Strings |
| `src/lib/games_meta.json` | ÄNDERN | `steam_required` Flag pro Spiel |
| `src/lib/games_meta.pl` | ÄNDERN | Neue Funktion `game_requires_steam()` |
| `src/lib/instance.pl` | ÄNDERN | 7. TSV-Spalte `steam_account` |
| `src/index.cgi` | ÄNDERN | Steam-Button für Admins |
| `src/wizard.cgi` | ÄNDERN | Steam-Account-Schritt in Step 2 |
| `src/manage.cgi` | ÄNDERN | Steam-Abschnitt auf Instanz-Seite |

---

## Task 1: Lang-Strings

**Files:**
- Modify: `src/lang/de`
- Modify: `src/lang/en`

- [ ] **Step 1: Steam-Strings in `src/lang/de` einfügen**

Am Ende der Datei `src/lang/de` anfügen:

```
steam_title=Steam-Einstellungen
steam_btn=Steam-Einstellungen
steam_system_title=System
steam_cmd_ok=SteamCMD gefunden
steam_cmd_missing=SteamCMD nicht installiert
steam_install_btn=SteamCMD installieren
steam_repos_ok=Repositories korrekt konfiguriert
steam_repos_fix_btn=Repos aktivieren (non-free contrib)
steam_cdrom_warn=CD-ROM-Eintrag in sources.list aktiv
steam_cdrom_fix_btn=CD-ROM-Eintrag deaktivieren
steam_installed_ok=Installation abgeschlossen
steam_accounts_title=Steam-Accounts
steam_add_account=Account hinzufügen
steam_username=Steam-Benutzername
steam_display_name=Anzeigename
steam_password_hint=Passwort (wird nicht gespeichert)
steam_login_start_btn=Login starten
steam_status_ok=Token aktiv
steam_status_expired=Token abgelaufen
steam_status_pending=Einrichtung ausstehend
steam_remove_btn=Entfernen
steam_relogin_btn=Re-Login auslösen
steam_no_accounts=Keine Steam-Accounts konfiguriert.
steam_login_title=Steam-Login läuft
steam_login_connecting=Verbinde mit Steam...
steam_guard_prompt=Steam Guard Code eingeben (5 Zeichen):
steam_guard_submit=Code bestätigen
steam_login_ok=Login erfolgreich — Token gespeichert.
steam_login_failed=Login fehlgeschlagen. Bitte prüfe Benutzername und Passwort.
steam_login_timeout=Zeitüberschreitung beim Login.
steam_required_wizard=Steam-Account (dieses Spiel erfordert einen Steam-Login)
steam_account_label=Steam-Account
steam_no_steam_accounts=Kein Steam-Account vorhanden — bitte zuerst einen Account einrichten.
steam_manage_section=Steam
steam_manage_account=Account
steam_manage_status=Token-Status
steam_manage_no_account=Kein Account zugewiesen
steam_col_username=Steam-Username
steam_col_display=Anzeigename
steam_col_status=Status
steam_col_actions=Aktionen
steam_account_saved=Steam-Account gespeichert.
steam_account_removed=Account entfernt.
```

- [ ] **Step 2: Steam-Strings in `src/lang/en` einfügen**

Am Ende der Datei `src/lang/en` anfügen:

```
steam_title=Steam Settings
steam_btn=Steam Settings
steam_system_title=System
steam_cmd_ok=SteamCMD found
steam_cmd_missing=SteamCMD not installed
steam_install_btn=Install SteamCMD
steam_repos_ok=Repositories correctly configured
steam_repos_fix_btn=Enable repositories (non-free contrib)
steam_cdrom_warn=CD-ROM entry active in sources.list
steam_cdrom_fix_btn=Disable CD-ROM entry
steam_installed_ok=Installation complete
steam_accounts_title=Steam Accounts
steam_add_account=Add account
steam_username=Steam username
steam_display_name=Display name
steam_password_hint=Password (not stored)
steam_login_start_btn=Start login
steam_status_ok=Token active
steam_status_expired=Token expired
steam_status_pending=Setup pending
steam_remove_btn=Remove
steam_relogin_btn=Trigger re-login
steam_no_accounts=No Steam accounts configured.
steam_login_title=Steam login in progress
steam_login_connecting=Connecting to Steam...
steam_guard_prompt=Enter Steam Guard code (5 characters):
steam_guard_submit=Confirm code
steam_login_ok=Login successful — token saved.
steam_login_failed=Login failed. Please check username and password.
steam_login_timeout=Login timed out.
steam_required_wizard=Steam account (this game requires a Steam login)
steam_account_label=Steam account
steam_no_steam_accounts=No Steam account available — please set one up first.
steam_manage_section=Steam
steam_manage_account=Account
steam_manage_status=Token status
steam_manage_no_account=No account assigned
steam_col_username=Steam username
steam_col_display=Display name
steam_col_status=Status
steam_col_actions=Actions
steam_account_saved=Steam account saved.
steam_account_removed=Account removed.
```

- [ ] **Step 3: Syntaxcheck und Commit**

```bash
perl -c src/lib/core.pl && bash scripts/verify.sh
git add src/lang/de src/lang/en
git commit -m "feat: add Steam lang strings (de/en)

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 2: `src/lib/steam.pl` — System-Detection-Funktionen

**Files:**
- Create: `src/lib/steam.pl`
- Create: `t/test_steam.pl`

- [ ] **Step 1: Test schreiben (failing)**

Erstelle `t/test_steam.pl`:

```perl
#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 8;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

chdir "$Bin/.." or die "Cannot chdir: $!";

require 't/stubs.pl';
sub error { die "error: $_[0]\n" }

our ($config_directory);
my $tmpdir = tempdir(CLEANUP => 1);
$config_directory = $tmpdir;

# Stub system_logged to capture calls
my @logged_cmds;
no warnings 'redefine';
*main::system_logged = sub { push @logged_cmds, $_[0]; return 0; };
use warnings 'redefine';

require 'src/lib/steam.pl';

# --- Test 1: detect_steamcmd returns undef when not in PATH ---
{
    # Mock which to fail: override PATH to empty dir
    local $ENV{PATH} = $tmpdir;
    my $result = detect_steamcmd();
    ok(!defined $result || $result eq '', 'detect_steamcmd returns undef/empty when steamcmd absent');
}

# --- Test 2: detect_steamcmd returns path when file exists ---
{
    my $fake_steam = "$tmpdir/steamcmd";
    open(my $fh, '>', $fake_steam) or die $!;
    close $fh;
    chmod(0755, $fake_steam);
    local $ENV{PATH} = $tmpdir;
    my $result = detect_steamcmd();
    ok(defined $result && length $result, 'detect_steamcmd returns path when steamcmd exists');
    unlink $fake_steam;
}

# --- Test 3: check_apt_repos detects missing non-free ---
{
    my $sources = "$tmpdir/sources.list";
    open(my $fh, '>', $sources) or die $!;
    print $fh "deb http://deb.debian.org/debian bookworm main\n";
    close $fh;
    my $result = check_apt_repos($sources);
    is($result->{'non_free'}, 0, 'check_apt_repos: non_free=0 when missing');
}

# --- Test 4: check_apt_repos detects non-free contrib ---
{
    my $sources = "$tmpdir/sources.list";
    open(my $fh, '>', $sources) or die $!;
    print $fh "deb http://deb.debian.org/debian bookworm main contrib non-free\n";
    close $fh;
    my $result = check_apt_repos($sources);
    is($result->{'non_free'}, 1, 'check_apt_repos: non_free=1 when present');
    is($result->{'contrib'},  1, 'check_apt_repos: contrib=1 when present');
}

# --- Test 5: check_apt_repos detects active cdrom line ---
{
    my $sources = "$tmpdir/sources.list";
    open(my $fh, '>', $sources) or die $!;
    print $fh "deb cdrom:[Debian GNU]/ bookworm main\n";
    close $fh;
    my $result = check_apt_repos($sources);
    is($result->{'cdrom_active'}, 1, 'check_apt_repos: cdrom_active=1 for uncommented cdrom line');
}

# --- Test 6: patch_apt_sources comments out cdrom ---
{
    my $sources = "$tmpdir/sources.list";
    open(my $fh, '>', $sources) or die $!;
    print $fh "deb cdrom:[Debian GNU]/ bookworm main\n";
    print $fh "deb http://deb.debian.org/debian bookworm main\n";
    close $fh;
    patch_apt_sources($sources);
    open($fh, '<', $sources) or die $!;
    my $content = do { local $/; <$fh> };
    close $fh;
    like($content, qr/^# deb cdrom:/m, 'patch_apt_sources: cdrom line commented out');
}

# --- Test 7: patch_apt_sources adds non-free contrib ---
{
    my $sources = "$tmpdir/sources.list";
    open(my $fh, '>', $sources) or die $!;
    print $fh "deb http://deb.debian.org/debian bookworm main\n";
    close $fh;
    patch_apt_sources($sources);
    open($fh, '<', $sources) or die $!;
    my $content = do { local $/; <$fh> };
    close $fh;
    like($content, qr/non-free/, 'patch_apt_sources: adds non-free to deb line');
}

# --- Test 8: install_steamcmd calls apt-get ---
{
    @logged_cmds = ();
    install_steamcmd();
    ok(grep { /apt-get.*install.*steamcmd/ } @logged_cmds, 'install_steamcmd calls apt-get install steamcmd');
}
```

- [ ] **Step 2: Test ausführen — muss fehlschlagen**

```bash
perl t/test_steam.pl 2>&1 | head -5
```
Erwartet: `Can't locate src/lib/steam.pl` oder ähnlich.

- [ ] **Step 3: `src/lib/steam.pl` mit System-Funktionen erstellen**

```perl
# LinuxGSM-WebCore - Steam integration library
#
# Account vault: $config_directory/steam_accounts.tsv
#   steam_username<TAB>display_name<TAB>status
#   status in: ok | guard_pending | token_expired
#
# Passwords are NEVER stored.
use strict;
use warnings;

our ($config_directory, $module_root);

# ---------------------------------------------------------------------------
# System detection
# ---------------------------------------------------------------------------

# Return steamcmd path (e.g. /usr/games/steamcmd) or undef if not installed.
sub detect_steamcmd {
    for my $candidate (qw(/usr/games/steamcmd /usr/bin/steamcmd)) {
        return $candidate if -x $candidate;
    }
    my $from_path = `which steamcmd 2>/dev/null`;
    chomp $from_path;
    return $from_path if length $from_path && -x $from_path;
    return undef;
}

# Check /etc/apt/sources.list (or $path for testing).
# Returns hashref: { non_free => 0/1, contrib => 0/1, cdrom_active => 0/1 }
sub check_apt_repos {
    my ($path) = @_;
    $path //= '/etc/apt/sources.list';
    my %result = (non_free => 0, contrib => 0, cdrom_active => 0);
    return \%result unless -f $path;
    open(my $fh, '<', $path) or return \%result;
    while (<$fh>) {
        next if /^\s*#/;
        $result{'non_free'}    = 1 if /\bnon-free\b/;
        $result{'contrib'}     = 1 if /\bcontrib\b/;
        $result{'cdrom_active'} = 1 if /^\s*deb\s+cdrom:/;
    }
    close($fh);
    return \%result;
}

# Patch /etc/apt/sources.list (or $path for testing):
# 1. Comment out cdrom: lines
# 2. Add non-free contrib to deb http:// lines that lack them
sub patch_apt_sources {
    my ($path) = @_;
    $path //= '/etc/apt/sources.list';
    # Safety: only allow exact canonical path in production
    return unless $path eq '/etc/apt/sources.list' || $path =~ m|^/tmp/|;
    open(my $fh, '<', $path) or return;
    my @lines = <$fh>;
    close($fh);

    my @out;
    for my $line (@lines) {
        # Comment out cdrom lines
        if ($line =~ /^\s*deb\s+cdrom:/) {
            $line = "# $line";
        }
        # Add non-free contrib to http/https deb lines
        elsif ($line =~ /^\s*deb\s+https?:\/\// && $line !~ /\bnon-free\b/) {
            chomp $line;
            $line .= " contrib non-free\n";
        }
        push @out, $line;
    }
    open($fh, '>', $path) or return;
    print $fh $_ for @out;
    close($fh);
}

# Install steamcmd via apt-get.
sub install_steamcmd {
    &system_logged('apt-get install -y steamcmd 2>&1');
}

1;
```

- [ ] **Step 4: Test ausführen — muss grün sein**

```bash
perl t/test_steam.pl
```
Erwartet: `ok 1` bis `ok 8`.

- [ ] **Step 5: Commit**

```bash
git add src/lib/steam.pl t/test_steam.pl
git commit -m "feat: add steam.pl system-detection functions + tests

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 3: `src/lib/steam.pl` — Account-Vault-Funktionen

**Files:**
- Modify: `src/lib/steam.pl`
- Modify: `t/test_steam.pl`

- [ ] **Step 1: Tests für Vault-Funktionen in `t/test_steam.pl` hinzufügen**

Am Ende von `t/test_steam.pl` (vor dem letzten `1;` bzw. nach dem letzten Test) die Plan-Zahl erhöhen auf `tests => 18` und folgende Tests anfügen:

```perl
# --- Test 9: load_steam_accounts returns empty list when file absent ---
{
    my $result = load_steam_accounts();
    is(ref $result, 'ARRAY', 'load_steam_accounts returns arrayref');
    is(scalar @$result, 0, 'load_steam_accounts returns empty list when no file');
}

# --- Test 10: add_steam_account writes TSV entry ---
{
    add_steam_account('testuser', 'Test User');
    my $accounts = load_steam_accounts();
    is(scalar @$accounts, 1, 'add_steam_account: one entry written');
    is($accounts->[0]{'username'},     'testuser',      'add_steam_account: username correct');
    is($accounts->[0]{'display_name'}, 'Test User',     'add_steam_account: display_name correct');
    is($accounts->[0]{'status'},       'guard_pending', 'add_steam_account: status is guard_pending');
}

# --- Test 11: get_steam_account_status returns correct status ---
{
    my $status = get_steam_account_status('testuser');
    is($status, 'guard_pending', 'get_steam_account_status returns guard_pending');
}

# --- Test 12: remove_steam_account removes entry ---
{
    add_steam_account('user2', 'User Two');
    remove_steam_account('testuser');
    my $accounts = load_steam_accounts();
    is(scalar @$accounts, 1, 'remove_steam_account: removes correct entry');
    is($accounts->[0]{'username'}, 'user2', 'remove_steam_account: remaining entry correct');
    remove_steam_account('user2');
}
```

- [ ] **Step 2: Test ausführen — neue Tests schlagen fehl**

```bash
perl t/test_steam.pl 2>&1 | grep -E "^(ok|not ok)"
```
Erwartet: Tests 1-8 grün, Tests 9-18 rot (Funktionen fehlen noch).

- [ ] **Step 3: Vault-Funktionen in `src/lib/steam.pl` einfügen**

Nach der Zeile `sub install_steamcmd { ... }` in `src/lib/steam.pl` einfügen:

```perl
# ---------------------------------------------------------------------------
# Account vault — $config_directory/steam_accounts.tsv
# ---------------------------------------------------------------------------

sub _accounts_file {
    our $config_directory;
    return "$config_directory/steam_accounts.tsv";
}

# Return arrayref of account hashrefs: { username, display_name, status }
sub load_steam_accounts {
    my $file = _accounts_file();
    return [] unless -f $file;
    open(my $fh, '<:encoding(UTF-8)', $file) or return [];
    my @accounts;
    while (<$fh>) {
        chomp;
        next if /^\s*#/ || !length;
        my ($username, $display_name, $status) = split(/\t/, $_, 3);
        next unless defined $username && $username =~ /\S/;
        push @accounts, {
            username     => $username,
            display_name => $display_name // '',
            status       => $status       // 'guard_pending',
        };
    }
    close($fh);
    return \@accounts;
}

sub _save_steam_accounts {
    my ($accounts_ref) = @_;
    my $file = _accounts_file();
    open(my $fh, '>:encoding(UTF-8)', $file) or return;
    for my $acc (@$accounts_ref) {
        print $fh join("\t", $acc->{'username'}, $acc->{'display_name'} // '', $acc->{'status'} // 'guard_pending') . "\n";
    }
    close($fh);
    chmod(0600, $file);
}

# Add new account with status=guard_pending. No-op if username already exists.
sub add_steam_account {
    my ($username, $display_name) = @_;
    my $accounts = load_steam_accounts();
    return if grep { $_->{'username'} eq $username } @$accounts;
    push @$accounts, { username => $username, display_name => $display_name // '', status => 'guard_pending' };
    _save_steam_accounts($accounts);
}

# Remove account by username.
sub remove_steam_account {
    my ($username) = @_;
    my $accounts = load_steam_accounts();
    $accounts = [grep { $_->{'username'} ne $username } @$accounts];
    _save_steam_accounts($accounts);
}

# Return status string for given username, or undef if not found.
sub get_steam_account_status {
    my ($username) = @_;
    my $accounts = load_steam_accounts();
    for my $acc (@$accounts) {
        return $acc->{'status'} if $acc->{'username'} eq $username;
    }
    return undef;
}

# Update status for a given username.
sub update_steam_account_status {
    my ($username, $new_status) = @_;
    my $accounts = load_steam_accounts();
    for my $acc (@$accounts) {
        if ($acc->{'username'} eq $username) {
            $acc->{'status'} = $new_status;
            last;
        }
    }
    _save_steam_accounts($accounts);
}
```

- [ ] **Step 4: Test ausführen — alle 18 Tests grün**

```bash
perl t/test_steam.pl
```
Erwartet: `1..18` alle `ok`.

- [ ] **Step 5: Commit**

```bash
git add src/lib/steam.pl t/test_steam.pl
git commit -m "feat: add steam.pl account vault functions + tests

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 4: Login-Session-Funktionen + Worker-Script

**Files:**
- Modify: `src/lib/steam.pl`
- Create: `src/scripts/steam_login_worker.sh`

- [ ] **Step 1: Worker-Script erstellen**

Erstelle `src/scripts/steam_login_worker.sh`:

```bash
#!/bin/bash
# steam_login_worker.sh SESSION_DIR USERNAME PASS_FILE
# Manages a steamcmd login session via FIFO.
# Writes status to $SESSION_DIR/status:
#   connecting | guard_required | ok | failed | timeout
set -e

SESSION_DIR="$1"
USERNAME="$2"
PASS_FILE="$3"

if [ -z "$SESSION_DIR" ] || [ -z "$USERNAME" ] || [ -z "$PASS_FILE" ]; then
    echo "Usage: $0 SESSION_DIR USERNAME PASS_FILE" >&2
    exit 1
fi

# Read and immediately delete the password temp file
PASSWORD=$(cat "$PASS_FILE")
rm -f "$PASS_FILE"

echo "connecting" > "$SESSION_DIR/status"

# Create FIFO for steamcmd stdin
mkfifo "$SESSION_DIR/steam_in"

# Start steamcmd reading from FIFO, writing output to file
steamcmd < "$SESSION_DIR/steam_in" > "$SESSION_DIR/steam_out" 2>&1 &
STEAM_PID=$!
echo $STEAM_PID > "$SESSION_DIR/pid"

# Send login command in background (FIFO write blocks until steamcmd reads)
(
    printf "+login %s %s\n+quit\n" "$USERNAME" "$PASSWORD"
) > "$SESSION_DIR/steam_in" &

START=$(date +%s)

while kill -0 $STEAM_PID 2>/dev/null; do
    NOW=$(date +%s)

    # Timeout after 300 seconds
    if [ $((NOW - START)) -gt 300 ]; then
        echo "timeout" > "$SESSION_DIR/status"
        kill "$STEAM_PID" 2>/dev/null
        exit 1
    fi

    # Check for Steam Guard prompt
    if grep -q "Steam Guard" "$SESSION_DIR/steam_out" 2>/dev/null; then
        echo "guard_required" > "$SESSION_DIR/status"

        # Wait for CGI to write the guard code
        while [ ! -f "$SESSION_DIR/guard_code" ]; do
            sleep 1
            NOW=$(date +%s)
            if [ $((NOW - START)) -gt 300 ]; then
                echo "timeout" > "$SESSION_DIR/status"
                kill "$STEAM_PID" 2>/dev/null
                exit 1
            fi
        done

        # Send guard code followed by quit
        (
            cat "$SESSION_DIR/guard_code"
            printf "\n+quit\n"
        ) > "$SESSION_DIR/steam_in"
        rm -f "$SESSION_DIR/guard_code"
        echo "connecting" > "$SESSION_DIR/status"
    fi

    sleep 1
done

# Evaluate outcome
if grep -qE "Login.*OK|Logged in OK" "$SESSION_DIR/steam_out" 2>/dev/null; then
    echo "ok" > "$SESSION_DIR/status"
else
    echo "failed" > "$SESSION_DIR/status"
fi
```

- [ ] **Step 2: Worker-Script ausführbar machen**

```bash
chmod +x src/scripts/steam_login_worker.sh
```

- [ ] **Step 3: Session-Funktionen in `src/lib/steam.pl` anfügen**

Nach `sub update_steam_account_status { ... }` einfügen:

```perl
# ---------------------------------------------------------------------------
# Login session management
# ---------------------------------------------------------------------------

sub _sessions_dir {
    our $config_directory;
    return "$config_directory/steam_sessions";
}

# Generate a cryptographically random 32-char hex token.
sub _generate_session_token {
    open(my $fh, '<', '/dev/urandom') or die "Cannot open /dev/urandom: $!";
    my $raw;
    read($fh, $raw, 16) or die "Cannot read /dev/urandom";
    close($fh);
    return unpack('H*', $raw);
}

# Create a session directory and return ($token, $session_dir).
sub create_login_session {
    my $base = _sessions_dir();
    mkdir $base, 0700 unless -d $base;
    my $token       = _generate_session_token();
    my $session_dir = "$base/$token";
    mkdir $session_dir, 0700 or die "Cannot create session dir: $!";
    return ($token, $session_dir);
}

# Read status from session dir. Returns undef if session does not exist.
sub read_session_status {
    my ($token) = @_;
    my $status_file = _sessions_dir() . "/$token/status";
    return undef unless -f $status_file;
    open(my $fh, '<', $status_file) or return undef;
    my $status = <$fh>;
    close($fh);
    chomp $status if defined $status;
    return $status;
}

# Read steamcmd output log from session dir.
sub read_session_output {
    my ($token) = @_;
    my $out_file = _sessions_dir() . "/$token/steam_out";
    return '' unless -f $out_file;
    open(my $fh, '<', $out_file) or return '';
    local $/;
    my $content = <$fh>;
    close($fh);
    return $content // '';
}

# Write guard code to session dir.
sub submit_guard_code {
    my ($token, $code) = @_;
    $code =~ s/[^A-Z0-9]//g;
    my $code_file = _sessions_dir() . "/$token/guard_code";
    open(my $fh, '>', $code_file) or die "Cannot write guard code: $!";
    print $fh "$code\n";
    close($fh);
}

# Delete session directory (cleanup after ok/failed/timeout).
sub cleanup_session {
    my ($token) = @_;
    my $session_dir = _sessions_dir() . "/$token";
    return unless -d $session_dir;
    for my $file (glob("$session_dir/*")) {
        unlink $file;
    }
    rmdir $session_dir;
}

# Start login worker in background.
# $password is written to a chmod-600 temp file, worker deletes it immediately.
# Returns $token.
sub start_login_session {
    my ($username, $password) = @_;
    our $module_root;

    my ($token, $session_dir) = create_login_session();

    # Write password to temp file with strict permissions
    my $pass_file = "$session_dir/pass_tmp";
    open(my $fh, '>', $pass_file) or die "Cannot write pass_tmp: $!";
    print $fh $password;
    close($fh);
    chmod(0600, $pass_file);

    my $worker = "$module_root/scripts/steam_login_worker.sh";
    # Use list form via shell to avoid shell injection; quote all args
    my $cmd = "nohup " . quotemeta($worker) . " " . quotemeta($session_dir) . " " . quotemeta($username) . " " . quotemeta($pass_file) . " </dev/null >/dev/null 2>&1 &";
    system($cmd);

    return $token;
}
```

- [ ] **Step 4: Syntax-Check**

```bash
perl -c src/lib/steam.pl 2>&1
```
Erwartet: `src/lib/steam.pl syntax OK`

- [ ] **Step 5: Commit**

```bash
git add src/lib/steam.pl src/scripts/steam_login_worker.sh
git commit -m "feat: add steam login session functions + worker script

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 5: `src/steam_settings.cgi`

**Files:**
- Create: `src/steam_settings.cgi`

- [ ] **Step 1: `src/steam_settings.cgi` erstellen**

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

our (%text, %in);
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

&can_scan() or &error($text{'err_access_denied'});

# --- POST handlers ---
if ($ENV{REQUEST_METHOD} eq 'POST') {
    my $action = $in{'action'} // '';
    $action =~ s/[^a-z_]//g;

    if ($action eq 'patch_repos') {
        &patch_apt_sources('/etc/apt/sources.list');
        &redirect('steam_settings.cgi');

    } elsif ($action eq 'install_steamcmd') {
        &install_steamcmd();
        &redirect('steam_settings.cgi');

    } elsif ($action eq 'add_account') {
        my $username     = $in{'steam_username'} // '';
        my $display_name = $in{'steam_display_name'} // '';
        my $password     = $in{'steam_password'} // '';

        # Strict format: Steam usernames are alphanumeric + underscore/hyphen, 1-64 chars
        $username =~ s/[^a-zA-Z0-9_\-]//g;
        $username = substr($username, 0, 64);
        $display_name =~ s/[\t\n\r]//g;
        $display_name = substr($display_name, 0, 80);

        $username or &error($text{'err_invalid_input'});
        $password or &error($text{'err_invalid_input'});

        &add_steam_account($username, $display_name);
        my $token = &start_login_session($username, $password);
        &redirect("steam_settings.cgi?action=poll&session=" . &html_escape($token) . "&username=" . &html_escape($username));

    } elsif ($action eq 'remove_account') {
        my $username = $in{'steam_username'} // '';
        $username =~ s/[^a-zA-Z0-9_\-]//g;
        $username or &error($text{'err_invalid_input'});
        &remove_steam_account($username);
        &redirect('steam_settings.cgi');

    } elsif ($action eq 'submit_guard') {
        my $token    = $in{'session'} // '';
        my $username = $in{'username'} // '';
        my $code     = $in{'guard_code'} // '';
        $token    =~ s/[^a-f0-9]//g;
        $username =~ s/[^a-zA-Z0-9_\-]//g;
        $code     =~ s/[^A-Z0-9]//g;
        $code = substr(uc($code), 0, 5);
        $token    or &error($text{'err_invalid_input'});
        $code     or &error($text{'err_invalid_input'});
        &submit_guard_code($token, $code);
        &redirect("steam_settings.cgi?action=poll&session=" . &html_escape($token) . "&username=" . &html_escape($username));

    } elsif ($action eq 'relogin') {
        # Re-login with stored username, one-time password from form
        my $username = $in{'steam_username'} // '';
        my $password = $in{'steam_password'} // '';
        $username =~ s/[^a-zA-Z0-9_\-]//g;
        $username or &error($text{'err_invalid_input'});
        $password or &error($text{'err_invalid_input'});
        &update_steam_account_status($username, 'guard_pending');
        my $token = &start_login_session($username, $password);
        &redirect("steam_settings.cgi?action=poll&session=" . &html_escape($token) . "&username=" . &html_escape($username));
    }
}

# --- GET: poll page ---
if (($in{'action'} // '') eq 'poll') {
    my $token    = $in{'session'} // '';
    my $username = $in{'username'} // '';
    $token    =~ s/[^a-f0-9]//g;
    $username =~ s/[^a-zA-Z0-9_\-]//g;

    &header($text{'steam_login_title'}, '');

    my $status = &read_session_status($token) // 'connecting';

    if ($status eq 'ok') {
        &update_steam_account_status($username, 'ok');
        &cleanup_session($token);
        print "<div class='alert alert-success'>$text{'steam_login_ok'}</div>\n";
        print "<p><a href='steam_settings.cgi'>$text{'steam_title'}</a></p>\n";

    } elsif ($status eq 'failed') {
        &update_steam_account_status($username, 'token_expired');
        &cleanup_session($token);
        print "<div class='alert alert-danger'>$text{'steam_login_failed'}</div>\n";
        print "<p><a href='steam_settings.cgi'>$text{'steam_title'}</a></p>\n";

    } elsif ($status eq 'timeout') {
        &update_steam_account_status($username, 'token_expired');
        &cleanup_session($token);
        print "<div class='alert alert-warning'>$text{'steam_login_timeout'}</div>\n";
        print "<p><a href='steam_settings.cgi'>$text{'steam_title'}</a></p>\n";

    } elsif ($status eq 'guard_required') {
        # Show guard code input form + auto-refresh fallback
        print "<p>$text{'steam_guard_prompt'}</p>\n";
        print &ui_form_start('steam_settings.cgi', 'post');
        print &ui_hidden('action',   'submit_guard');
        print &ui_hidden('session',  &html_escape($token));
        print &ui_hidden('username', &html_escape($username));
        print &ui_table_start('', undef, 2);
        print &ui_table_row($text{'steam_guard_prompt'},
            &ui_textbox('guard_code', '', 8));
        print &ui_table_end();
        print &ui_submit($text{'steam_guard_submit'}, undef, undef, undef, 'btn-primary');
        print &ui_form_end();

    } else {
        # Still connecting — auto-refresh
        print "<meta http-equiv='refresh' content='3'>\n";
        print "<p>$text{'steam_login_connecting'}</p>\n";
    }

    &footer('', '');
    exit;
}

# --- GET: main page ---
&header($text{'steam_title'}, '');

# === Section 1: System ===
print "<h3>" . &html_escape($text{'steam_system_title'}) . "</h3>\n";

my $steamcmd_path = &detect_steamcmd();
my $repos         = &check_apt_repos('/etc/apt/sources.list');

print &ui_table_start('', undef, 2);

# SteamCMD status row
if ($steamcmd_path) {
    print &ui_table_row($text{'steam_cmd_ok'}, &html_escape($steamcmd_path));
} else {
    my $install_form = &ui_form_start('steam_settings.cgi', 'post');
    $install_form .= &ui_hidden('action', 'install_steamcmd');
    $install_form .= &ui_submit($text{'steam_install_btn'}, undef, undef, undef, 'btn-primary');
    $install_form .= &ui_form_end();
    print &ui_table_row($text{'steam_cmd_missing'}, $install_form);
}

# Repos status row
if ($repos->{'non_free'} && $repos->{'contrib'} && !$repos->{'cdrom_active'}) {
    print &ui_table_row($text{'steam_repos_ok'}, '&#x2705;');
} else {
    my $warn = '';
    $warn .= "<li>$text{'steam_cdrom_warn'}</li>" if $repos->{'cdrom_active'};
    $warn .= "<li>$text{'steam_repos_fix_btn'}</li>" unless $repos->{'non_free'} && $repos->{'contrib'};
    my $fix_form = &ui_form_start('steam_settings.cgi', 'post');
    $fix_form .= &ui_hidden('action', 'patch_repos');
    $fix_form .= &ui_submit($text{'steam_repos_fix_btn'}, undef, undef, undef, 'btn-default');
    $fix_form .= &ui_form_end();
    print &ui_table_row("<ul>$warn</ul>", $fix_form);
}

print &ui_table_end();

# === Section 2: Account Vault ===
print "<h3>" . &html_escape($text{'steam_accounts_title'}) . "</h3>\n";

my $accounts = &load_steam_accounts();
if (@$accounts) {
    my @rows;
    for my $acc (@$accounts) {
        my $uname   = &html_escape($acc->{'username'});
        my $dname   = &html_escape($acc->{'display_name'});
        my $status  = $acc->{'status'} // 'guard_pending';
        my $status_label = &html_escape($text{"steam_status_$status"} // $status);

        my $actions = '';
        # Re-login form (shown for expired or pending)
        if ($status ne 'ok') {
            $actions .= &ui_form_start('steam_settings.cgi', 'post');
            $actions .= &ui_hidden('action', 'relogin');
            $actions .= &ui_hidden('steam_username', $uname);
            $actions .= &ui_table_start('', undef, 2);
            $actions .= &ui_table_row($text{'steam_password_hint'},
                &ui_password('steam_password', '', 20));
            $actions .= &ui_table_end();
            $actions .= &ui_submit($text{'steam_relogin_btn'}, undef, undef, undef, 'btn-default');
            $actions .= &ui_form_end();
        }
        # Remove form
        $actions .= &ui_form_start('steam_settings.cgi', 'post');
        $actions .= &ui_hidden('action', 'remove_account');
        $actions .= &ui_hidden('steam_username', $uname);
        $actions .= &ui_submit($text{'steam_remove_btn'}, undef, undef, undef, 'btn-danger');
        $actions .= &ui_form_end();

        push @rows, [$uname, $dname, $status_label, $actions];
    }
    print &ui_columns_table(
        [$text{'steam_col_username'}, $text{'steam_col_display'}, $text{'steam_col_status'}, $text{'steam_col_actions'}],
        '100%',
        \@rows,
    );
} else {
    print "<p><i>" . &html_escape($text{'steam_no_accounts'}) . "</i></p>\n";
}

# Add account form
print "<h4>" . &html_escape($text{'steam_add_account'}) . "</h4>\n";
print &ui_form_start('steam_settings.cgi', 'post');
print &ui_hidden('action', 'add_account');
print &ui_table_start('', undef, 2);
print &ui_table_row($text{'steam_display_name'},
    &ui_textbox('steam_display_name', '', 30));
print &ui_table_row($text{'steam_username'},
    &ui_textbox('steam_username', '', 30));
print &ui_table_row($text{'steam_password_hint'},
    &ui_password('steam_password', '', 30));
print &ui_table_end();
print &ui_submit($text{'steam_login_start_btn'}, undef, undef, undef, 'btn-primary');
print &ui_form_end();

&footer('index.cgi', $text{'index_title'});
```

- [ ] **Step 2: Syntax-Check**

```bash
perl -c src/steam_settings.cgi 2>&1
```
Erwartet: `src/steam_settings.cgi syntax OK`

- [ ] **Step 3: verify.sh ausführen**

```bash
bash scripts/verify.sh
```
Erwartet: alle Tests grün.

- [ ] **Step 4: Commit**

```bash
git add src/steam_settings.cgi
git commit -m "feat: add steam_settings.cgi with system-setup, account vault, login flow

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 6: games_meta.json + games_meta.pl

**Files:**
- Modify: `src/lib/games_meta.json`
- Modify: `src/lib/games_meta.pl`
- Modify: `t/test_games_meta.pl`

- [ ] **Step 1: Test für `game_requires_steam()` in `t/test_games_meta.pl` hinzufügen**

Plan-Zahl auf `tests => 11` erhöhen und am Ende anfügen:

```perl
# --- Test 10: game_requires_steam returns 1 for steam-required games ---
write_base_json(<<'JSON');
{
  "csgoserver": {"name":"CS:GO","steam_required":true,"fields":[]},
  "mcserver":   {"name":"Minecraft","steam_required":false,"fields":[]}
}
JSON
&_reset_meta_cache();
is(&game_requires_steam('csgoserver'), 1, 'game_requires_steam returns 1 for csgoserver');

# --- Test 11: game_requires_steam returns 0 for non-steam games ---
&_reset_meta_cache();
is(&game_requires_steam('mcserver'), 0, 'game_requires_steam returns 0 for mcserver');
```

- [ ] **Step 2: Test ausführen — Tests 10-11 schlagen fehl**

```bash
perl t/test_games_meta.pl 2>&1 | grep -E "^(ok|not ok)"
```
Erwartet: Tests 1-9 grün, 10-11 rot.

- [ ] **Step 3: `game_requires_steam()` in `src/lib/games_meta.pl` einfügen**

Nach `sub get_game_display_name { ... }` einfügen:

```perl
# Return 1 if the given script name requires a Steam login, 0 otherwise.
sub game_requires_steam {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key  = _resolve_meta_key($script_name);
    return ($meta{$key}{'steam_required'} ? 1 : 0);
}
```

- [ ] **Step 4: `steam_required` in `src/lib/games_meta.json` eintragen**

Zu den drei Steam-pflichtigen Einträgen `"steam_required": true` hinzufügen, bei den anderen `"steam_required": false`:

Für `csgoserver`:
```json
"csgoserver": {
    "name": "Counter-Strike: Global Offensive",
    "steam_required": true,
    "fields": [ ... ]
}
```
Für `rustserver`:
```json
"rustserver": {
    "name": "Rust",
    "steam_required": true,
    "fields": [ ... ]
}
```
Für `armaserver`:
```json
"armaserver": {
    "name": "Arma 3",
    "steam_required": true,
    "fields": [ ... ]
}
```
Für `mcserver`, `vhserver`, `pwserver`, `mc-paper`, `mc-forge`, `mc-neoforge`, `mc-fabric`:
```json
"steam_required": false
```

- [ ] **Step 5: Alle Tests ausführen**

```bash
perl t/test_games_meta.pl && bash scripts/verify.sh
```
Erwartet: alle Tests grün.

- [ ] **Step 6: Commit**

```bash
git add src/lib/games_meta.json src/lib/games_meta.pl t/test_games_meta.pl
git commit -m "feat: add steam_required flag to games_meta + game_requires_steam()

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 7: `src/lib/instance.pl` — 7. TSV-Spalte `steam_account`

**Files:**
- Modify: `src/lib/instance.pl`
- Modify: `t/test_instance.pl`

- [ ] **Step 1: Test für `steam_account`-Spalte in `t/test_instance.pl` hinzufügen**

Den bestehenden Test-Plan um 2 erhöhen und am Ende einfügen:

```perl
# --- steam_account column: register + reload ---
{
    my $tmpdir = tempdir(CLEANUP => 1);
    local $config_directory = $tmpdir;

    register_instance('csgoserver', 'csgouser', '/home/csgouser/csgoserver', {
        source        => 'manual',
        sftp_user     => '',
        owners        => '',
        steam_account => 'mysteamuser',
    });

    my $reg = get_registered_instance('csgoserver');
    is($reg->{'steam_account'}, 'mysteamuser', 'register_instance: steam_account saved');

    # Reload from file to verify persistence
    my %reloaded = _load_registered();
    is($reloaded{'csgoserver'}{'steam_account'}, 'mysteamuser', '_load_registered: steam_account persisted in TSV');
}
```

- [ ] **Step 2: Test ausführen — neue Tests schlagen fehl**

```bash
perl t/test_instance.pl 2>&1 | tail -5
```

- [ ] **Step 3: `_load_registered()` — split-Limit auf 7 erhöhen**

In `src/lib/instance.pl`, Zeile mit `my @cols = split(/\t/, $_, 6)` ändern auf:

```perl
my @cols = split(/\t/, $_, 7);
($id, $user, $script, $source, $sftp_user) = @cols;
$source    ||= 'manual';
$sftp_user ||= '';
$owners       = $cols[5] // '';
my $steam_acc = $cols[6] // '';
```

Und `$reg{$id}` erweitern:
```perl
$reg{$id} = {
    user          => $user,
    script        => $script,
    source        => $source,
    sftp_user     => $sftp_user,
    owners        => $owners,
    steam_account => $steam_acc,
} if defined $id && $id =~ /\S/ && defined $user && defined $script;
```

- [ ] **Step 4: `_save_registered()` — 7. Spalte schreiben**

Die `print $fh`-Zeile ändern auf:

```perl
my $steam = $reg_ref->{$id}{'steam_account'} // '';
print $fh join("\t", $id, $u, $s, $src, $ftp, $own, $steam) . "\n";
```

- [ ] **Step 5: `register_instance()` — `steam_account` aus opts lesen**

In `register_instance()` das `$reg{$id}`-Assignment erweitern:

```perl
$reg{$id} = {
    user          => $user,
    script        => $script_path,
    source        => $opts{'source'} || ($reg{$id}{'source'} // 'manual'),
    sftp_user     => defined $opts{'sftp_user'}     ? $opts{'sftp_user'}     : ($reg{$id}{'sftp_user'}     // ''),
    owners        => defined $opts{'owners'}        ? $opts{'owners'}        : ($reg{$id}{'owners'}        // ''),
    steam_account => defined $opts{'steam_account'} ? $opts{'steam_account'} : ($reg{$id}{'steam_account'} // ''),
};
```

- [ ] **Step 6: `list_instances()` — `steam_account` propagieren**

Im registrierten-Block (nach `$inst->{'owners'} = ...`) hinzufügen:
```perl
$inst->{'steam_account'} = $meta->{'steam_account'} // '';
```

Im auto-detect-Block hinzufügen:
```perl
$inst->{'steam_account'} = '';
```

- [ ] **Step 7: `get_instance()` — `steam_account` im Return-Hash**

In `get_instance()` das Return-Hash erweitern:
```perl
return {
    id            => $id,
    user          => $user,
    home          => $home,
    script        => $script_path,
    game          => $cfg{gamename} // 'unknown',
    port          => $port,
    status        => $status,
    fw_open       => $fw_open,
    warnings      => $warns,
    steam_account => do {
        my %reg = _load_registered();
        $reg{$id}{'steam_account'} // '';
    },
};
```

- [ ] **Step 8: Tests ausführen**

```bash
perl t/test_instance.pl && bash scripts/verify.sh
```
Erwartet: alle Tests grün.

- [ ] **Step 9: Commit**

```bash
git add src/lib/instance.pl t/test_instance.pl
git commit -m "feat: add steam_account as 7th TSV column in instance registry

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 8: index.cgi + wizard.cgi + manage.cgi

**Files:**
- Modify: `src/index.cgi`
- Modify: `src/wizard.cgi`
- Modify: `src/manage.cgi`

- [ ] **Step 1: Steam-Button in `src/index.cgi` einfügen**

Nach dem Block `if (&can_scan()) { ... }` in `src/index.cgi` den bestehenden FTP-Button-Block suchen:

```perl
    print &ui_form_start('ftp_settings.cgi', 'get');
    print &ui_submit($text{'index_btn_ftp'});
    print &ui_form_end();
```

Darunter einfügen:

```perl
    print &ui_form_start('steam_settings.cgi', 'get');
    print &ui_submit($text{'steam_btn'}, undef, undef, undef, 'btn-default');
    print &ui_form_end();
```

Außerdem oben in `src/index.cgi` nach den bestehenden `require`-Zeilen hinzufügen:
```perl
require './lib/games_meta.pl';
require './lib/steam.pl';
```

Lang-String `index_btn_ftp` bleibt unverändert. Neuer String `steam_btn` wurde in Task 1 hinzugefügt.

- [ ] **Step 2: `src/wizard.cgi` — Steam-Account in Step 2**

In `wizard.cgi` oben nach den bestehenden `require`-Zeilen einfügen:
```perl
require './lib/games_meta.pl';
require './lib/steam.pl';
```

In `_step2_form()` den Anfang der Funktion ändern:

```perl
sub _step2_form {
    my ($game, $username, $port, $sftp) = @_;
    print "<h3>$text{'wizard_step2'}</h3>\n";
    my @users = &list_webmin_users();
    my @opts  = map { [$_, $_] } @users;

    print &ui_form_start('wizard.cgi', 'post');
    print &ui_hidden('step',     '3');
    print &ui_hidden('game',     &html_escape($game));
    print &ui_hidden('username', &html_escape($username));
    print &ui_hidden('port',     $port);
    print &ui_hidden('sftp',     $sftp);
    print &ui_table_start('', undef, 2);
    print &ui_table_row($text{'wizard_owner'},
        &ui_select('webmin_user', '', \@opts));
    print &ui_table_row('',
        "<small>$text{'wizard_owner_note'}</small>");

    # Steam account selection if game requires it
    if (&game_requires_steam($game)) {
        my $accounts = &load_steam_accounts();
        my @ok_accounts = grep { ($_->{'status'} // '') eq 'ok' } @$accounts;
        if (@ok_accounts) {
            my @steam_opts = (['', '---'], map { [$_->{'username'}, "$_->{'display_name'} ($_->{'username'})"] } @ok_accounts);
            print &ui_table_row($text{'steam_required_wizard'},
                &ui_select('steam_account', '', \@steam_opts));
        } else {
            print &ui_table_row($text{'steam_required_wizard'},
                "<span class='label label-warning'>" . &html_escape($text{'steam_no_steam_accounts'}) . "</span> " .
                "<a href='steam_settings.cgi' target='_blank'>$text{'steam_add_account'}</a>");
        }
    }

    print &ui_table_end();
    print &ui_submit($text{'wizard_install'});
    print &ui_form_end();
}
```

In `_step3_form()` den `steam_account`-Wert als hidden übergeben und in der Summary anzeigen:

```perl
sub _step3_form {
    my ($game, $username, $port, $sftp, $webmin_user) = @_;
    my $steam_account = $in{'steam_account'} // '';
    $steam_account =~ s/[^a-zA-Z0-9_\-]//g;

    print "<h3>$text{'wizard_step3'}</h3>\n";
    print "<h4>$text{'wizard_summary'}</h4>\n";

    print &ui_table_start('', undef, 2);
    print &ui_table_row($text{'wizard_game'},     &html_escape($game));
    print &ui_table_row($text{'wizard_username'}, &html_escape($username));
    print &ui_table_row($text{'wizard_port'},     $port);
    print &ui_table_row($text{'wizard_sftp'},     $sftp ? 'ja' : 'nein');
    print &ui_table_row($text{'wizard_owner'},    &html_escape($webmin_user));
    if (&game_requires_steam($game) && $steam_account) {
        print &ui_table_row($text{'steam_account_label'}, &html_escape($steam_account));
    }
    print &ui_table_end();

    print &ui_form_start('wizard.cgi', 'post');
    print &ui_hidden('step',          '3');
    print &ui_hidden('game',          &html_escape($game));
    print &ui_hidden('username',      &html_escape($username));
    print &ui_hidden('port',          $port);
    print &ui_hidden('sftp',          $sftp);
    print &ui_hidden('webmin_user',   &html_escape($webmin_user));
    print &ui_hidden('steam_account', &html_escape($steam_account));
    print &ui_submit($text{'wizard_install'});
    print &ui_form_end();
}
```

Im Step-3-POST-Handler (nach `&register_instance(...)`) `steam_account` übergeben. Den bestehenden `register_instance`-Aufruf suchen:

```perl
&register_instance($username, $username, "$home/$username", {
    source => 'provisioned',
```

Ändern auf:

```perl
my $steam_acc = $in{'steam_account'} // '';
$steam_acc =~ s/[^a-zA-Z0-9_\-]//g;
&register_instance($username, $username, "$home/$username", {
    source        => 'provisioned',
    steam_account => $steam_acc,
```

- [ ] **Step 3: `src/manage.cgi` — Steam-Abschnitt**

In `manage.cgi` oben die `require`-Zeilen erweitern:
```perl
require './lib/games_meta.pl';
require './lib/steam.pl';
```

Im Render-Teil von manage.cgi (nach der Warnings-Anzeige, vor `&footer`) den Steam-Block einfügen. An der Stelle wo `$script_name_for_cfg` definiert ist (nach `$inst`-Laden), den Steam-Block hinzufügen:

```perl
# Steam section (only for games that require Steam login)
if (&game_requires_steam($inst->{'game'} // '')) {
    my $steam_acc    = $inst->{'steam_account'} // '';
    my $steam_status = $steam_acc ? (&get_steam_account_status($steam_acc) // 'token_expired') : '';
    my $status_label = $steam_status ? &html_escape($text{"steam_status_$steam_status"} // $steam_status) : '';

    print "<h3>" . &html_escape($text{'steam_manage_section'}) . "</h3>\n";
    print &ui_table_start('', undef, 2);
    if ($steam_acc) {
        print &ui_table_row($text{'steam_manage_account'}, &html_escape($steam_acc));
        print &ui_table_row($text{'steam_manage_status'},  $status_label);
    } else {
        print &ui_table_row($text{'steam_manage_account'},
            "<i>" . &html_escape($text{'steam_manage_no_account'}) . "</i>");
    }
    print &ui_table_end();

    # Re-login button: redirect to steam_settings with relogin flow
    if ($steam_acc) {
        print &ui_form_start('steam_settings.cgi', 'get');
        print &ui_hidden('action',   'relogin_form');
        print &ui_hidden('steam_username', &html_escape($steam_acc));
        print &ui_submit($text{'steam_relogin_btn'}, undef, undef, undef, 'btn-default');
        print &ui_form_end();
    }
}
```

In `steam_settings.cgi` im GET-Handler vor dem Haupt-Rendering den `relogin_form`-Zweig ergänzen (nach dem poll-Block):

```perl
# GET: relogin form (redirected from manage.cgi)
if (($in{'action'} // '') eq 'relogin_form') {
    my $username = $in{'steam_username'} // '';
    $username =~ s/[^a-zA-Z0-9_\-]//g;
    &header($text{'steam_title'}, '');
    print "<h3>" . &html_escape($text{'steam_relogin_btn'}) . ": " . &html_escape($username) . "</h3>\n";
    print &ui_form_start('steam_settings.cgi', 'post');
    print &ui_hidden('action', 'relogin');
    print &ui_hidden('steam_username', &html_escape($username));
    print &ui_table_start('', undef, 2);
    print &ui_table_row($text{'steam_password_hint'},
        &ui_password('steam_password', '', 30));
    print &ui_table_end();
    print &ui_submit($text{'steam_login_start_btn'}, undef, undef, undef, 'btn-primary');
    print &ui_form_end();
    &footer('steam_settings.cgi', $text{'steam_title'});
    exit;
}
```

- [ ] **Step 4: Syntax-Checks**

```bash
perl -c src/index.cgi 2>&1
perl -c src/wizard.cgi 2>&1
perl -c src/manage.cgi 2>&1
perl -c src/steam_settings.cgi 2>&1
```
Alle müssen `syntax OK` ausgeben.

- [ ] **Step 5: Vollständige Verifikation**

```bash
bash scripts/verify.sh
```
Erwartet: alle Tests grün.

- [ ] **Step 6: Build**

```bash
bash scripts/build.sh
```
Erwartet: `dist/linuxgsm-webcore-0.1.0.wbm` erzeugt.

- [ ] **Step 7: Commit**

```bash
git add src/index.cgi src/wizard.cgi src/manage.cgi src/steam_settings.cgi
git commit -m "feat: integrate Steam into index, wizard and manage pages

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Selbst-Review

**Spec-Coverage:**
- ✅ SteamCMD-Erkennung + Install-Button (Task 2, Task 5)
- ✅ Repos patchen — Debian 13 (Task 2, Task 5)
- ✅ Account-Vault TSV (Task 3, Task 5)
- ✅ Passwort nie gespeichert, nur via chmod-600-Temp-Datei (Task 4)
- ✅ Worker-Script mit FIFO + Guard-Flow (Task 4)
- ✅ Poll-Page mit auto-refresh (Task 5)
- ✅ `steam_required` in games_meta (Task 6)
- ✅ `game_requires_steam()` (Task 6)
- ✅ 7. TSV-Spalte in instance.pl (Task 7)
- ✅ Steam-Button auf index.cgi (Task 8)
- ✅ Steam-Account-Schritt im Wizard (Task 8)
- ✅ Steam-Abschnitt in manage.cgi (Task 8)
- ✅ Re-Login Flow (Task 5 + Task 8)

**Sicherheits-Checkliste:**
- ✅ Passwort nie persistiert
- ✅ Session-Token 32 Hex via /dev/urandom
- ✅ Session-Dir chmod 700
- ✅ Steam-Username-Regex `[^a-zA-Z0-9_\-]` in allen Handlers
- ✅ Guard-Code-Regex `[^A-Z0-9]` + Länge 5
- ✅ html_escape() für alle dynamischen Ausgaben
- ✅ sources.list-Pfad nur `/etc/apt/sources.list` in Production
