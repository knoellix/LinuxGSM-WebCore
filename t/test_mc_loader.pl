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

ok(mc_reinstall_uses_loader_chain({ loader => 'neoforge' }), 'reinstall chain for neoforge');
ok(mc_reinstall_uses_loader_chain({ loader => 'fabric' }), 'reinstall chain for fabric');
ok(mc_reinstall_uses_loader_chain({ loader => 'forge' }), 'reinstall chain for forge');
ok(!mc_reinstall_uses_loader_chain({ loader => 'paper' }), 'no loader chain for paper');
ok(!mc_reinstall_uses_loader_chain({ loader => 'vanilla' }), 'no loader chain for vanilla');
ok(!mc_reinstall_uses_loader_chain(undef), 'no loader chain without profile');
ok(!mc_reinstall_uses_loader_chain({}), 'no loader chain without loader');

# Legacy MC 1.x → NeoForge drops the leading 1
is(mc_neoforge_version_prefix('1.21.1'), '21.1', 'neoforge prefix 1.21.1');
is(mc_neoforge_version_prefix('1.20.4'), '20.4', 'neoforge prefix 1.20.4');
# Mojang 26.x (year.drop[.hotfix]) → NeoForge keeps full 3-component MC id
is(mc_neoforge_version_prefix('26.1.2'), '26.1.2', 'neoforge prefix 26.1.2 stays');
is(mc_neoforge_version_prefix('26.1'), '26.1.0', 'neoforge prefix 26.1 pads to 26.1.0');

my @neo = qw(21.0.5-beta 21.1.68 21.1.234 21.2.0-beta 20.4.10);
is(mc_pick_neoforge_version('1.21.1', \@neo), '21.1.234', 'pick latest stable neoforge');
is(mc_pick_neoforge_version('1.20.4', \@neo), '20.4.10', 'pick neoforge for 1.20.4');

# NeoForge 26.x builds are 4-part: {mc_major}.{mc_minor}.{mc_patch}.{build}
my @neo26 = qw(26.1.2.80 26.1.2.95 26.1.2.95-beta 26.1.1.10 26.2.0.1);
is(mc_pick_neoforge_version('26.1.2', \@neo26), '26.1.2.95', 'pick latest stable neoforge for 26.1.2');
my @neo26_filtered = @{ mc_filter_neoforge_versions_for_mc('26.1.2', \@neo26) };
is_deeply(\@neo26_filtered, [ '26.1.2.95', '26.1.2.80' ], 'neoforge 26.x filter newest first');
ok(mc_loader_version_matches_mc('neoforge', '26.1.2', '26.1.2.95'), 'neoforge 26.x pin matches mc');
ok(!mc_loader_version_matches_mc('neoforge', '26.1.2', '26.1.1.10'), 'neoforge 26.x pin wrong mc line');

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

# After wipe/reinstall: disk says mc_ready even if an old job was ok — prefer disk.
is(mc_infer_setup_status(1, ['loader']), 'mc_ready',
    'loader missing after wipe stays mc_ready (not installed)');

my $paper_prof = build_mc_profile('paper', '1.21.1');
my $paper_dir = tempdir(CLEANUP => 1);
mkdir "$paper_dir/serverfiles" or die $!;
ok(!mc_mod_ui_ready($paper_prof, $paper_dir), 'paper mod ui blocked until jar install');

my $neo_prof = build_mc_profile('neoforge', '1.21.1');
my $neo_dir = tempdir(CLEANUP => 1);
mkdir "$neo_dir/serverfiles" or die $!;
ok(!mc_mod_ui_ready($neo_prof, $neo_dir), 'mod ui blocked until java+loader');

$neo_prof->{'java_home'} = mc_java_home_rel($neo_prof->{'java_major'});
system('mkdir', '-p', "$neo_dir/$neo_prof->{'java_home'}/bin") == 0 or die "mkdir: $!";
open(my $jf, '>', "$neo_dir/$neo_prof->{'java_home'}/bin/java") or die $!;
close($jf);
chmod 0755, "$neo_dir/$neo_prof->{'java_home'}/bin/java";
open(my $nf, '>', "$neo_dir/serverfiles/run.sh") or die $!;
close($nf);
ok(mc_mod_ui_ready($neo_prof, $neo_dir), 'mod ui ready when java+loader on disk');

# Stale Java 21 on MC 26.x must pend java even if an old JDK path exists
{
    my $stale = {
        loader      => 'neoforge',
        mc_version  => '26.1.2',
        java_major  => 21,
        java_home   => '.java/temurin-21',
        lgsm_script => 'mcserver',
        mod_dir     => 'mods',
    };
    ok(mc_profile_java_needs_sync($stale), 'stale java 21 on 26.1.2 needs sync');
    my $synced = mc_profile_sync_java_fields($stale);
    is($synced->{'java_major'}, 25, 'sync bumps java_major to 25');
    is($synced->{'java_home'}, '.java/temurin-25', 'sync sets temurin-25 home');
    my $sdir = tempdir(CLEANUP => 1);
    system('mkdir', '-p', "$sdir/.java/temurin-21/bin") == 0 or die $!;
    open(my $sj, '>', "$sdir/.java/temurin-21/bin/java") or die $!;
    close($sj);
    chmod 0755, "$sdir/.java/temurin-21/bin/java";
    my @sp = @{ mc_pending_setup_steps($stale, $sdir) };
    ok(grep({ $_ eq 'java' } @sp), 'pending java when major stale despite old JDK present');
}

done_testing();
