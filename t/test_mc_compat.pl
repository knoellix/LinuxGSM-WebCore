#!/usr/bin/env perl
# t/test_mc_compat.pl — Minecraft compatibility matrix lookup
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

use lib "$Bin/..";
chdir "$Bin/.." or die "Cannot chdir to repo root: $!\n";

chdir "$Bin/.." or die "Cannot chdir to repo root: $!\n";

our $module_root = 'src';
require 't/stubs.pl';
$module_root = 'src';
require 'src/lib/games.pl';
require 'src/lib/mc_profile.pl';

ok(is_minecraft_game('mc'), 'mc shortname is minecraft');
ok(is_minecraft_game('mcserver'), 'mcserver is minecraft');
ok(is_minecraft_game('pmc'), 'pmc shortname is minecraft');
ok(is_minecraft_game('mc-paper'), 'mc-paper is minecraft');
ok(!is_minecraft_game('mcb'), 'mcb bedrock excluded');
ok(!is_minecraft_game('vhserver'), 'vhserver is not minecraft');

is(mc_loader_from_game('mc'), 'vanilla', 'mc shortname -> vanilla');
is(mc_loader_from_game('pmc'), 'paper', 'pmc shortname -> paper');
is(mc_loader_from_game('mc-paper'), 'paper', 'game to loader paper');
is(mc_loader_from_game('mc-fabric'), 'fabric', 'game to loader fabric');

is(resolve_java_major('1.20.1'), 17, '1.20.1 -> Java 17');
is(resolve_java_major('1.21.1'), 21, '1.21.1 -> Java 21');
is(resolve_java_major('1.16.5'), 8,  '1.16.5 -> Java 8');

ok(mc_loader_phase1_ready('vanilla'), 'vanilla phase 1');
ok(mc_loader_phase1_ready('paper'),   'paper phase 1');
ok(!mc_loader_phase1_ready('fabric'), 'fabric phase 2');

my $profile = build_mc_profile('paper', '1.21.1');
ok($profile, 'build profile');
is($profile->{'lgsm_script'}, 'pmcserver', 'lgsm script paper');
is($profile->{'mod_dir'}, 'plugins', 'mod dir plugins');
is($profile->{'java_major'}, 21, 'java major');
is($profile->{'java_home'}, '.java/temurin-21', 'java home rel');

is(validate_mc_profile($profile), undef, 'valid profile');
is(validate_mc_profile({ loader => 'bad' }), 'missing mc_version', 'invalid profile');

done_testing();
