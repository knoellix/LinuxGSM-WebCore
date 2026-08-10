#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 22;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

chdir "$Bin/.." or die "Cannot chdir: $!";

require "$Bin/stubs.pl";
sub error { die "error: $_[0]\n" }
sub log_error {}
sub log_debug {}

our ($config_directory, $module_root);
my $tmpdir = tempdir(CLEANUP => 1);
$config_directory = $tmpdir;

# Stub system_logged to capture calls
my @logged_cmds;
{
    no warnings qw(redefine once);
    *main::system_logged = sub { push @logged_cmds, $_[0]; return 0; };
}

require "$Bin/../src/lib/steam.pl";

# --- Test 1: detect_steamcmd returns PATH result when in PATH ---
{
    # Must be named exactly "steamcmd" — detect_steamcmd looks for $dir/steamcmd.
    my $fake_steam = "$tmpdir/steamcmd";
    open(my $fh, '>', $fake_steam) or die $!;
    close $fh;
    chmod(0755, $fake_steam);
    # Isolate from host PATH and standard install locations.
    local $ENV{PATH} = $tmpdir;
    my $result = detect_steamcmd();
    is($result, $fake_steam, 'detect_steamcmd finds steamcmd in PATH');
    unlink $fake_steam;
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

# --- Test 3: check_apt_repos detects missing non_free ---
{
    my $sources = "$tmpdir/sources.list";
    open(my $fh, '>', $sources) or die $!;
    print $fh "deb http://deb.debian.org/debian bookworm main\n";
    close $fh;
    my $result = check_apt_repos($sources);
    is($result->{'non_free'}, 0, 'check_apt_repos: non_free=0 when missing');
}

# --- Test 4: check_apt_repos detects non_free ---
{
    my $sources = "$tmpdir/sources.list";
    open(my $fh, '>', $sources) or die $!;
    print $fh "deb http://deb.debian.org/debian bookworm main contrib non-free\n";
    close $fh;
    my $result = check_apt_repos($sources);
    is($result->{'non_free'}, 1, 'check_apt_repos: non_free=1 when present');
}

# --- Test 5: check_apt_repos detects contrib ---
{
    my $sources = "$tmpdir/sources.list";
    open(my $fh, '>', $sources) or die $!;
    print $fh "deb http://deb.debian.org/debian bookworm main contrib non-free\n";
    close $fh;
    my $result = check_apt_repos($sources);
    is($result->{'contrib'}, 1, 'check_apt_repos: contrib=1 when present');
}

# --- Test 6: check_apt_repos detects active cdrom line ---
{
    my $sources = "$tmpdir/sources.list";
    open(my $fh, '>', $sources) or die $!;
    print $fh "deb cdrom:[Debian GNU]/ bookworm main\n";
    close $fh;
    my $result = check_apt_repos($sources);
    is($result->{'cdrom_active'}, 1, 'check_apt_repos: cdrom_active=1 for uncommented cdrom line');
}

# --- Test 7: patch_apt_sources comments out cdrom ---
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

# --- Test 8: install_steamcmd delegates apt to module_bootstrap_deps.sh ---
{
    @logged_cmds = ();
    install_steamcmd();
    ok(
        (grep { /module_bootstrap_deps\.sh/ && /steamcmd/ } @logged_cmds),
        'install_steamcmd calls module_bootstrap_deps.sh steamcmd'
    );
    ok(
        !(grep { /\bapt-get\b/ } @logged_cmds),
        'install_steamcmd does not call apt-get directly'
    );
}

# --- Test 9: load_steam_accounts returns arrayref ---
{
    my $result = load_steam_accounts();
    is(ref $result, 'ARRAY', 'load_steam_accounts returns arrayref');
}

# --- Test 10: load_steam_accounts returns empty list when no file ---
{
    my $result = load_steam_accounts();
    is(scalar @$result, 0, 'load_steam_accounts returns empty list when no file');
}

# --- Test 11: add_steam_account writes TSV entry ---
{
    add_steam_account('testuser', 'Test User');
    my $accounts = load_steam_accounts();
    is(scalar @$accounts, 1, 'add_steam_account: one entry written');
}

# --- Test 12: add_steam_account: username correct ---
{
    my $accounts = load_steam_accounts();
    is($accounts->[0]{'username'}, 'testuser', 'add_steam_account: username correct');
}

# --- Test 13: add_steam_account: display_name correct ---
{
    my $accounts = load_steam_accounts();
    is($accounts->[0]{'display_name'}, 'Test User', 'add_steam_account: display_name correct');
}

# --- Test 14: add_steam_account: status is guard_pending ---
{
    my $accounts = load_steam_accounts();
    is($accounts->[0]{'status'}, 'guard_pending', 'add_steam_account: status is guard_pending');
}

# --- Test 15: get_steam_account_status returns correct status ---
{
    my $status = get_steam_account_status('testuser');
    is($status, 'guard_pending', 'get_steam_account_status returns guard_pending');
}

# --- Test 16: update_steam_account_status changes status ---
{
    update_steam_account_status('testuser', 'ok');
    my $status = get_steam_account_status('testuser');
    is($status, 'ok', 'update_steam_account_status: status changed to ok');
}

# --- Test 17: remove_steam_account removes entry ---
{
    add_steam_account('user2', 'User Two');
    remove_steam_account('testuser');
    my $accounts = load_steam_accounts();
    is(scalar @$accounts, 1, 'remove_steam_account: removes correct entry');
}

# --- Test 18: remaining entry is correct ---
{
    my $accounts = load_steam_accounts();
    is($accounts->[0]{'username'}, 'user2', 'remove_steam_account: remaining entry correct');
    remove_steam_account('user2');
}

# --- Test 19: login_session_dispatch_verified detects worker status ---
{
    my ($token, $dir) = create_login_session();
    mkdir "$dir" unless -d $dir;
    open(my $sf, '>', "$dir/status") or die $!;
    print $sf "connecting\n";
    close $sf;
    ok(login_session_dispatch_verified($token), 'login_session_dispatch_verified: true when status exists');
    cleanup_session($token);
}

# --- Test 20: start_login_session returns token when worker starts ---
{
    $module_root = $tmpdir;
    mkdir "$tmpdir/scripts" unless -d "$tmpdir/scripts";
    my $worker = "$tmpdir/scripts/steam_login_worker.sh";
    open(my $wf, '>', $worker) or die $!;
    print $wf "#!/bin/bash\n";
    print $wf 'echo connecting > "$1/status"' . "\n";
    print $wf 'rm -f "$3"' . "\n";
    close $wf;
    chmod(0755, $worker);
    {
        no warnings 'redefine';
        *main::_steam_background_exec = sub {
            my ($cmd) = @_;
            if ($cmd =~ /steam_login_worker\.sh/) {
                my ($sd) = $cmd =~ /nohup '[^']+' '([^']+)'/;
                if ($sd) {
                    open(my $sf, '>', "$sd/status") or return 1;
                    print $sf "connecting\n";
                    close $sf;
                }
                return 0;
            }
            return 1;
        };
    }
    my $tok = start_login_session('loginuser', 'secret');
    ok(defined $tok && $tok =~ /^[0-9a-f]{32}$/, 'start_login_session returns token when worker starts');
    cleanup_session($tok) if $tok;
}

# --- Test 21: start_login_session returns undef when worker missing ---
{
    my $worker = "$tmpdir/scripts/steam_login_worker.sh";
    unlink $worker if -f $worker;
    is(start_login_session('failuser', 'secret'), undef, 'start_login_session returns undef when worker missing');
}
