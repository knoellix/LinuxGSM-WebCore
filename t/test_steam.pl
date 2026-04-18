#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 8;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

chdir "$Bin/.." or die "Cannot chdir: $!";

require "$Bin/stubs.pl";
sub error { die "error: $_[0]\n" }

our ($config_directory);
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
    # Create fake steamcmd in tmpdir
    my $fake_steam = "$tmpdir/steamcmd_test1";
    open(my $fh, '>', $fake_steam) or die $!;
    close $fh;
    chmod(0755, $fake_steam);
    local $ENV{PATH} = $tmpdir;
    my $result = detect_steamcmd();
    # With our impl, this should find it via PATH search before standard paths
    ok(defined $result && $result =~ /steamcmd/, 'detect_steamcmd finds steamcmd in PATH');
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

# --- Test 8: install_steamcmd calls apt-get ---
{
    @logged_cmds = ();
    install_steamcmd();
    ok(grep { /apt-get.*install.*steamcmd/ } @logged_cmds, 'install_steamcmd calls apt-get install steamcmd');
}
