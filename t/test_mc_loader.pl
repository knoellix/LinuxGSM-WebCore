#!/usr/bin/env perl
# t/test_mc_loader.pl — mod loader version resolution (no network)
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
require 'src/lib/mc_loader.pl';
require 'src/lib/mc_profile.pl';

ok(mc_loader_is_modded('fabric'), 'fabric is modded');
ok(mc_loader_is_modded('neoforge'), 'neoforge is modded');
ok(!mc_loader_is_modded('vanilla'), 'vanilla not modded');

is(mc_neoforge_version_prefix('1.21.1'), '21.1', 'neoforge prefix 1.21.1');
is(mc_neoforge_version_prefix('1.20.4'), '20.4', 'neoforge prefix 1.20.4');

my @neo = qw(21.0.5-beta 21.1.68 21.1.234 21.2.0-beta 20.4.10);
is(mc_pick_neoforge_version('1.21.1', \@neo), '21.1.234', 'pick latest stable neoforge');
is(mc_pick_neoforge_version('1.20.4', \@neo), '20.4.10', 'pick neoforge for 1.20.4');

my @forge_keys = mc_forge_promo_key_candidates('1.21.1');
is_deeply(\@forge_keys, ['1.21.1-recommended', '1.21.1-latest', '1.21-recommended', '1.21-latest'], 'forge promo keys');

is(
    mc_forge_installer_url('1.21.1', '52.1.0'),
    'https://maven.minecraftforge.net/net/minecraftforge/forge/1.21.1-52.1.0/forge-1.21.1-52.1.0-installer.jar',
    'forge installer url',
);
is(
    mc_neoforge_installer_url('21.1.234'),
    'https://maven.neoforged.net/releases/net/neoforged/neoforge/21.1.234/neoforge-21.1.234-installer.jar',
    'neoforge installer url',
);

my $fabric_loaders = [
    { loader => { version => '0.19.3', stable => 1 } },
    { loader => { version => '0.19.2', stable => 0 } },
];
is(mc_fabric_pick_loader_version($fabric_loaders), '0.19.3', 'fabric stable loader');
is(mc_fabric_pick_loader_version($fabric_loaders, '0.19.2'), '0.19.2', 'fabric pinned loader');
is(mc_fabric_pick_loader_version($fabric_loaders, '9.9.9'), undef, 'fabric invalid pin');

my @neo_filtered = @{ mc_filter_neoforge_versions_for_mc('1.21.1', \@neo) };
is($neo_filtered[0], '21.1.234', 'neoforge list newest first');
ok(grep { $_ eq '21.1.68' } @neo_filtered, 'neoforge list includes older build');

my @forge_maven = qw(1.21.1-52.0.0 1.21.1-52.1.0 1.20.4-49.0.0);
my @forge_filtered = @{ mc_filter_forge_versions_for_mc('1.21.1', \@forge_maven) };
is_deeply(\@forge_filtered, [ '52.1.0', '52.0.0' ], 'forge versions for mc');

is(mc_sanitize_loader_version_pin('neoforge', '21.1.68'), '21.1.68', 'sanitize neoforge pin');
is(mc_sanitize_loader_version_pin('neoforge', 'auto'), undef, 'sanitize auto');
is(mc_sanitize_loader_version_pin('forge', '52.1.0'), '52.1.0', 'sanitize forge pin');

my $prof_pinned = build_mc_profile('neoforge', '1.21.1', { loader_version => '21.1.68' });
is($prof_pinned->{'loader_version'}, '21.1.68', 'profile stores pinned loader version');

my $fabric_installers = [
    { url => 'https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.1.1/fabric-installer-1.1.1.jar', stable => 1 },
];
is(
    mc_fabric_pick_installer_url($fabric_installers),
    'https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.1.1/fabric-installer-1.1.1.jar',
    'fabric installer url',
);

is(mc_loader_version_matches_mc('neoforge', '1.21.1', '21.1.68'), 1, 'neoforge pin matches mc');
is(mc_loader_version_matches_mc('neoforge', '1.21.1', '20.4.10'), 0, 'neoforge pin wrong mc line');

my $prof = build_mc_profile('neoforge', '1.21.1');
my $tmpdir = tempdir(CLEANUP => 1);
my @pending = @{ mc_pending_setup_steps($prof, $tmpdir) };
ok(grep { $_ eq 'java' } @pending, 'pending java when missing');
ok(grep { $_ eq 'loader' } @pending, 'pending loader when missing');

is(mc_infer_setup_status(0, ['java', 'loader']), 'fresh', 'fresh when lgsm missing');
is(mc_infer_setup_status(1, ['java', 'loader']), 'lgsm_ready', 'lgsm_ready after setup');
is(mc_infer_setup_status(1, ['loader']), 'mc_ready', 'mc_ready when java done');
is(mc_infer_setup_status(1, []), 'installed', 'installed when nothing pending');
is(mc_pick_setup_status('fresh', 'lgsm_ready'), 'lgsm_ready', 'pick higher setup rank');

my $paper_prof = build_mc_profile('paper', '1.21.1');
my $paper_dir = tempdir(CLEANUP => 1);
mkdir "$paper_dir/serverfiles" or die $!;
ok(!mc_mod_ui_ready($paper_prof, $paper_dir), 'paper mod ui blocked until jar install');

my $neo_prof = build_mc_profile('neoforge', '1.21.1');
my $neo_dir = tempdir(CLEANUP => 1);
mkdir "$neo_dir/serverfiles" or die $!;
ok(!mc_mod_ui_ready($neo_prof, $neo_dir), 'mod ui blocked until java+loader');

$neo_prof->{'java_home'} = '.java';
system('mkdir', '-p', "$neo_dir/.java/bin") == 0 or die "mkdir: $!";
open(my $jf, '>', "$neo_dir/.java/bin/java") or die $!;
close($jf);
chmod 0755, "$neo_dir/.java/bin/java";
open(my $nf, '>', "$neo_dir/serverfiles/run.sh") or die $!;
close($nf);
ok(mc_mod_ui_ready($neo_prof, $neo_dir), 'mod ui ready when java+loader on disk');

done_testing();
