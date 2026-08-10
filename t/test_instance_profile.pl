#!/usr/bin/env perl
# t/test_instance_profile.pl — modular profile → LGSM cfg overrides
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

use lib "$Bin/..";
chdir "$Bin/.." or die "Cannot chdir to repo root: $!\n";

our $module_root = 'src';
require 't/stubs.pl';
$module_root = 'src';
require 'src/lib/mc_profile.pl';
require 'src/lib/instance_profile.pl';

my $tmpdir = tempdir(CLEANUP => 1);
my $profile = build_mc_profile('paper', '1.21.1');
ok($profile, 'built profile');

open(my $fh, '>', "$tmpdir/.mcprofile.json") or die $!;
print $fh encode_mc_profile($profile);
close($fh);

my $over = get_instance_profile_cfg_overrides('pmcserver', $tmpdir);
is($over->{'serverversion'}, '1.21.1', 'mc profile overrides serverversion');
is($over->{'executable'}, './paperclip.jar', 'paper executable from matrix');

my $cfg_in = qq{serverversion="latest"\nexecutable="./minecraft_server.jar"\n};
my $cfg_out = apply_instance_profile_to_cfg_content($cfg_in, 'pmcserver', $tmpdir);
like($cfg_out, qr/serverversion="1\.21\.1"/, 'apply patches content');
like($cfg_out, qr/executable="\.\/paperclip\.jar"/, 'apply patches executable');

my $empty = get_instance_profile_cfg_overrides('vhserver', $tmpdir);
ok(!keys %$empty, 'non-mc game returns empty overrides');

done_testing();
