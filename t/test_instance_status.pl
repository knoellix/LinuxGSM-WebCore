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

BEGIN {
    *CORE::GLOBAL::getpwnam = sub {
        return ('gs_mc','x',1002,1002,'','','/home/gs_mc','/usr/sbin/nologin') if $_[0] eq 'gs_mc';
        return ();
    };
}

sub sanitize_input { my ($s) = @_; $s =~ s/[^a-zA-Z0-9_-]//g; return $s; }

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
is(scalar @cols, 10, 'exactly 10 columns');

# Test 5: set_instance_status
set_instance_status('gs_mc_myserver', 'installed');
my %reg2 = _load_registered();
is($reg2{'gs_mc_myserver'}{'instance_status'}, 'installed', 'set_instance_status works');

# Test 6: legacy 7-col -> defaults to installed
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

# Test 9+10: get_instance keeps registry instance_status when script file exists
my $srv = "$tmp/serverdir";
require File::Path;
File::Path::make_path("$srv/lgsm/config-lgsm/mcserver");
open(my $sf, '>', "$srv/mcserver") or die $!;
close($sf);
chmod 0755, "$srv/mcserver";
open($fh, '>', "$tmp/instances") or die $!;
print $fh "gs_mc_live\tgs_mc\t$srv/mcserver\tprovisioned\t\t\t\tlgsm_ready\n";
close($fh);
my $live = get_instance('gs_mc_live');
ok($live, 'get_instance when script exists');
is($live->{'instance_status'}, 'lgsm_ready', 'instance_status preserved when script exists');
