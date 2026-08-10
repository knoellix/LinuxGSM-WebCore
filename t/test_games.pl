#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
chdir "$Bin/.." or die "Cannot chdir to project root: $!";
use File::Temp qw(tempdir);
use File::Copy;

# TAP helpers
sub pass { print "ok - $_[0]\n" }
sub fail { print "not ok - $_[0]\n" }

require 't/stubs.pl';

# Point module_root at a temp dir so cache tests are isolated
our $module_root;
my $tmpdir = tempdir(CLEANUP => 1);
$module_root = $tmpdir;

# Stub error()
sub error { die "error: $_[0]\n" }

require 'src/lib/games.pl';

print "1..8\n";

# 1. _parse_csv parses 3 games correctly
{
    open(my $fh, '<', 't/data/serverlist.csv') or die $!;
    local $/;
    my $csv = <$fh>;
    close $fh;

    my @games = &_parse_csv($csv);
    scalar(@games) == 4
        ? pass('_parse_csv returns 4 entries')
        : fail("_parse_csv returns 4 entries (got " . scalar(@games) . ")");
}

# 2. Games are sorted by name
{
    open(my $fh, '<', 't/data/serverlist.csv') or die $!;
    local $/;
    my $csv = <$fh>;
    close $fh;

    my @games = &_parse_csv($csv);
    my @names = map { $_->{'name'} } @games;
    my @sorted = sort @names;
    "@names" eq "@sorted"
        ? pass('games sorted by name')
        : fail('games sorted by name');
}

# 3. Each entry has required keys
{
    open(my $fh, '<', 't/data/serverlist.csv') or die $!;
    local $/;
    my $csv = <$fh>;
    close $fh;

    my @games = &_parse_csv($csv);
    my $ok = 1;
    for my $g (@games) {
        $ok = 0 unless $g->{'shortname'} && $g->{'name'};
    }
    $ok ? pass('all entries have shortname and name') : fail('all entries have shortname and name');
}

# 4. Cache write + read round-trip
{
    # Copy fixture to cache location
    my $cache = "$tmpdir/data/serverlist.csv";
    mkdir "$tmpdir/data";
    copy('t/data/serverlist.csv', $cache) or die "copy failed: $!";

    my @games = &get_game_list();
    scalar(@games) == 4
        ? pass('get_game_list reads from cache')
        : fail("get_game_list reads from cache (got " . scalar(@games) . ")");
}

# 5. _cache_path returns path inside module_root
{
    my $path = &_cache_path();
    $path =~ m{/data/serverlist\.csv$}
        ? pass('_cache_path correct suffix')
        : fail("_cache_path correct suffix (got $path)");
}

# 6. _cache_path should not warn when module_root is unset
{
    our $module_root_directory;
    local $module_root = undef;
    local $module_root_directory = $tmpdir;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $path = &_cache_path();
    my $ok = (@warnings == 0) && ($path =~ m{^\Q$tmpdir\E/data/serverlist\.csv$});
    $ok
        ? pass('_cache_path falls back without warnings')
        : fail('_cache_path falls back without warnings');
}

# 7. resolve_lgsm_game_script maps shortname to on-disk script
{
    copy('t/data/serverlist.csv', "$tmpdir/data/serverlist.csv") or die "copy failed: $!";
    resolve_lgsm_game_script('pw') eq 'pwserver'
        ? pass('pw shortname resolves to pwserver')
        : fail('pw shortname resolves to pwserver');
}

# 8. resolve_lgsm_game_shortname maps script back to linuxgsm.sh shortname
{
    resolve_lgsm_game_shortname('pwserver') eq 'pw'
        ? pass('pwserver resolves to pw shortname')
        : fail('pwserver resolves to pw shortname');
}
