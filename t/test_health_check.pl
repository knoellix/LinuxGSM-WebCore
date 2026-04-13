#!/usr/bin/perl
# t/test_health_check.pl
use strict;
use warnings;
use Test::More tests => 5;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/..";

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

# Test 1: alles ok — leeres Warnings-Array
my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/lgsm"; mkdir "$dir/lgsm/config-lgsm";
open my $fh, '>', "$dir/mc"; close $fh;   # LGSM-Script anlegen
my $w = _check_instance_health('mc', $dir, '/usr/sbin/nologin', "$dir/mc", {});
is(scalar @$w, 0, 'no warnings when setup is correct');

# Test 2: falsche Shell — eine Warnung
my $w2 = _check_instance_health('mc', $dir, '/bin/bash', "$dir/mc", {});
is(scalar @$w2, 1, 'one warning for wrong shell');
like($w2->[0], qr/mc/, 'warning contains username');

# Test 3: fehlendes LGSM-Script — eine Warnung
my $dir2 = tempdir(CLEANUP => 1);
mkdir "$dir2/lgsm"; mkdir "$dir2/lgsm/config-lgsm";
# kein Script angelegt
my $w3 = _check_instance_health('mc', $dir2, '/usr/sbin/nologin', "$dir2/mc", {});
is(scalar @$w3, 1, 'one warning for missing LGSM script');

# Test 4: fehlendes Config-Verzeichnis — eine Warnung
my $dir3 = tempdir(CLEANUP => 1);
open $fh, '>', "$dir3/mc"; close $fh;
# kein lgsm/config-lgsm/
my $w4 = _check_instance_health('mc', $dir3, '/usr/sbin/nologin', "$dir3/mc", {});
is(scalar @$w4, 1, 'one warning for missing config dir');
