#!/usr/bin/env perl
# t/test_mc_profile.pl — .mcprofile.json read/write and LGSM cfg patch
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

use lib "$Bin/..";
chdir "$Bin/.." or die "Cannot chdir to repo root: $!\n";

our ($module_root, $module_config_directory, $config_directory);
require 't/stubs.pl';
$module_root = 'src';
require 'src/lib/mc_loader.pl';
require 'src/lib/mc_profile.pl';

my $tmpdir = tempdir(CLEANUP => 1);

my $profile = build_mc_profile('vanilla', '1.20.4');
ok($profile, 'built profile');

my $json = encode_mc_profile($profile);
like($json, qr/"loader"\s*:\s*"vanilla"/, 'json encodes loader');

my $cfg_in = qq{gamename="Test"\nport="25565"\nserverversion="latest"\nexecutable="./minecraft_server.jar"\npreexecutable="java -Xmx\${javaram}M -jar"\n};
my $cfg_out = patch_lgsm_mc_cfg_content($cfg_in, $profile, $tmpdir);
like($cfg_out, qr/serverversion="1\.20\.4"/, 'sets serverversion');
like($cfg_out, qr/executable="\.\/minecraft_server\.jar"/, 'vanilla keeps minecraft_server.jar');
like($cfg_out, qr/preexecutable=.*JAVA_HOME/, 'sets preexecutable with java_jar');

my $neo = build_mc_profile('neoforge', '1.21.1');
my $neo_out = patch_lgsm_mc_cfg_content($cfg_in, $neo, $tmpdir);
like($neo_out, qr/serverversion="1\.21\.1"/, 'neoforge sets mc version');
like($neo_out, qr/executable="\.\/run\.sh"/, 'neoforge sets run.sh');
like($neo_out, qr/preexecutable=.*mc_start_wrapper\.sh/, 'neoforge uses start wrapper');

my $over = mc_lgsm_cfg_overrides($profile, $tmpdir);
is($over->{'serverversion'}, '1.20.4', 'overrides hash serverversion');
is($over->{'executable'}, './minecraft_server.jar', 'overrides hash executable');

my $wrapper = mc_start_wrapper_content($profile, $tmpdir);
like($wrapper, qr/temurin-21/, 'wrapper references java home');

is(lgsm_instance_cfg_path('/home/u/srv', 'mcserver'),
   '/home/u/srv/lgsm/config-lgsm/mcserver/mcserver.cfg', 'cfg path');

is(mc_eula_file_content(), "eula=true\n", 'eula content');
ok(mc_profile_has_eula_acceptance({ eula_accepted => 1 }), 'eula accepted truthy');
ok(!mc_profile_has_eula_acceptance({ eula_accepted => 0 }), 'eula not accepted');
ok(!mc_profile_has_eula_acceptance({}), 'eula missing');

# Roundtrip write/read
my $prof_path = mc_profile_path($tmpdir);
{
    open(my $fh, '>', $prof_path) or die $!;
    print $fh $json;
    close($fh);
}
my $read_back = read_mc_profile($tmpdir);
is($read_back->{'mc_version'}, '1.20.4', 'read back mc_version');
is($read_back->{'loader'}, 'vanilla', 'read back loader');

subtest 'write_mc_profile direct-write as current user' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $prof = build_mc_profile('neoforge', '1.21.1', { loader_version => '21.1.211' });
    ok($prof, 'built profile for direct write');

    # Current process euid == the passed user's uid -> direct write path (no su).
    my $me = getpwuid($>);
    ok(write_mc_profile($dir, $me, $prof), 'direct write returns ok when euid==user');
    my $rb = read_mc_profile($dir);
    is($rb->{'loader'}, 'neoforge', 'direct-written loader');
    is($rb->{'loader_version'}, '21.1.211', 'direct-written pinned loader version');

    # Empty user -> best-effort direct write (no su).
    my $dir2 = tempdir(CLEANUP => 1);
    ok(write_mc_profile($dir2, '', $prof), 'direct write with empty user');
    ok(-f "$dir2/.mcprofile.json", 'profile file created');
};

subtest 'mc_versions_cache path under module_config_directory' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    local $module_config_directory = $tmpdir;
    local $main::module_config_directory = $tmpdir;
    is(mc_versions_cache_path(), "$tmpdir/mc_versions_cache.json", 'cache path uses module_config_directory');
    ok(mc_versions_cache_save({
        fetched_at   => time() - 100_000,  # stale (>24h)
        releases     => [ '1.21.1', '1.20.4' ],
        java_majors  => { '1.21.1' => 21 },
        version_urls => {},
    }), 'stale cache save');
    # Network miss: still use stale cache before static fallback
    local *_mc_fetch_url = sub { return undef; };
    my @vers = mc_list_mc_versions();
    is_deeply(\@vers, [ '1.21.1', '1.20.4' ], 'stale cache used when offline');
    is(resolve_java_major('1.21.1'), 21, 'java from stale cache');
};

subtest 'resolve_java_major unknown defaults version-aware' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    local $module_config_directory = $tmpdir;
    local $main::module_config_directory = $tmpdir;
    local *_mc_fetch_url = sub { return undef; };
    is(resolve_java_major('99.0.0'), 25, 'unknown new-scheme major (>=25) defaults to java 25');
    is(resolve_java_major('2.0.0'), 21, 'unknown pre-25 major defaults to java 21');
};

# Offline/stale: 26.x with no java_majors cache entry must not fall back to 21
subtest 'resolve_java_major offline 26.1.2 defaults to 25' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    local $module_config_directory = $tmpdir;
    local $main::module_config_directory = $tmpdir;
    ok(mc_versions_cache_save({
        fetched_at   => time() - 100_000,  # stale
        releases     => [ '26.1.2', '1.21.1' ],
        java_majors  => {},                 # no entry for 26.1.2
        version_urls => {},
    }), 'stale cache without java_majors');
    local *_mc_fetch_url = sub { return undef; };
    is(resolve_java_major('26.1.2'), 25, 'offline 26.1.2 without java cache → 25 not 21');
    is(resolve_java_major('1.21.1'), 21, 'offline 1.21.1 still defaults to 21 when no compat/cache');
};

subtest 'mc_profile_java_needs_sync / sync_java_fields' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    local $module_config_directory = $tmpdir;
    local $main::module_config_directory = $tmpdir;
    local *_mc_fetch_url = sub { return undef; };
    my $stale = {
        loader => 'neoforge', mc_version => '26.1.2',
        java_major => 21, java_home => '.java/temurin-21',
        lgsm_script => 'mcserver', mod_dir => 'mods',
    };
    ok(mc_profile_java_needs_sync($stale), '26.1.2 with java 21 needs sync');
    my $okp = {
        loader => 'neoforge', mc_version => '26.1.2',
        java_major => 25, java_home => '.java/temurin-25',
        lgsm_script => 'mcserver', mod_dir => 'mods',
    };
    ok(!mc_profile_java_needs_sync($okp), '26.1.2 with java 25 is synced');
    my $synced = mc_profile_sync_java_fields($stale);
    is($synced->{'java_major'}, 25, 'sync sets 25');
    is($synced->{'java_home'}, '.java/temurin-25', 'sync sets home');
    is($stale->{'java_major'}, 21, 'original hash unchanged');
};

# Game-user merge path: write must succeed for live-only MC versions when Mojang
# list/cache is unreachable (static fallback has no 26.x).
subtest 'write_mc_profile allows existing 26.x profile offline' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $cfg = tempdir(CLEANUP => 1);
    local $module_config_directory = $cfg;
    local $main::module_config_directory = $cfg;
    local *_mc_fetch_url = sub { return undef; };
    ok(!grep({ $_ eq '26.1.2' } mc_list_mc_versions()), '26.1.2 not in offline effective list');
    my $prof = {
        loader         => 'neoforge',
        mc_version     => '26.1.2',
        java_major     => 25,
        java_home      => '.java/temurin-25',
        lgsm_script    => 'mcserver',
        mod_dir        => 'mods',
        loader_version => '26.1.2.95',
    };
    is(validate_mc_profile($prof), undef, 'validate accepts structural 26.1.2 profile');
    ok(!build_mc_profile('neoforge', '26.1.2'), 'build_mc_profile still gates create allowlist');
    my $me = getpwuid($>);
    ok(write_mc_profile($dir, $me, $prof), 'write succeeds for 26.1.2 offline');
    my $rb = read_mc_profile($dir);
    is($rb->{'loader_version'}, '26.1.2.95', 'loader_version persisted');
};

done_testing();
