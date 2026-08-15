#!/usr/bin/env perl
# t/test_mc_compat.pl — Minecraft compatibility matrix lookup
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use JSON::PP qw(decode_json);

use lib "$Bin/..";
chdir "$Bin/.." or die "Cannot chdir to repo root: $!\n";

our ($module_root, $module_config_directory, $config_directory);
require 't/stubs.pl';
$module_root = 'src';
require 'src/lib/games.pl';
require 'src/lib/mc_loader.pl';
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
is(validate_mc_profile({ loader => 'bad' }), 'missing mc_version', 'invalid profile missing version');
is(validate_mc_profile({ loader => 'nope', mc_version => '1.21.1' }), 'unknown loader', 'unknown loader');

subtest 'mojang manifest parse releases only' => sub {
    open(my $fh, '<', 't/fixtures/mc/version_manifest_v2.json') or die $!;
    local $/;
    my $raw = <$fh>;
    close($fh);
    my $manifest = decode_json($raw);
    my @ids = mc_parse_mojang_release_ids($manifest);
    is_deeply(\@ids, [ '26.1.2', '1.21.1', '1.20.4' ], 'release ids exclude snapshots');
    my $urls = mc_parse_mojang_version_urls($manifest);
    is($urls->{'1.21.1'}, 'https://example.test/versions/1.21.1.json', 'version url map');
};

subtest 'resolve_java_major from cache' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    local $module_config_directory = $tmpdir;
    local $main::module_config_directory = $tmpdir;
    ok(mc_versions_cache_save({
        fetched_at  => time(),
        releases    => [ '26.1.2', '1.21.1' ],
        java_majors => { '1.21.1' => 21, '26.1.2' => 25 },
        version_urls => {},
    }), 'cache save ok');
    my $loaded = mc_versions_cache_load();
    ok(ref($loaded) eq 'HASH', 'cache load ok');
    is($loaded->{'java_majors'}{'26.1.2'}, 25, 'cache stores java major');
    is(resolve_java_major('26.1.2'), 25, 'resolve_java_major prefers cache');
};

subtest 'offline empty fetch falls back to mc_compat' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    local $module_config_directory = $tmpdir;
    local $main::module_config_directory = $tmpdir;
    # No cache file; mock network miss
    local *_mc_fetch_url = sub { return undef; };
    my @vers = mc_list_mc_versions();
    ok(scalar(@vers) > 0, 'offline list non-empty');
    ok((grep { $_ eq '1.21.1' } @vers), 'offline includes compat fallback 1.21.1');
    is(resolve_java_major('1.20.1'), 17, 'offline java from compat');
    ok(build_mc_profile('paper', '1.21.1'), 'offline build uses compat versions');
};

subtest 'live mocked list allows version outside static compat' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    local $module_config_directory = $tmpdir;
    local $main::module_config_directory = $tmpdir;
    open(my $mfh, '<', 't/fixtures/mc/version_manifest_v2.json') or die $!;
    local $/;
    my $manifest_raw = <$mfh>;
    close($mfh);
    open(my $vfh, '<', 't/fixtures/mc/version_1.21.1.json') or die $!;
    my $ver_raw = <$vfh>;
    close($vfh);
    local *_mc_fetch_url = sub {
        my ($url) = @_;
        return $manifest_raw if $url =~ /version_manifest_v2\.json/;
        return $ver_raw if $url =~ /1\.21\.1\.json/;
        return undef;
    };
    my @ids = mc_fetch_mojang_release_ids();
    is_deeply(\@ids, [ '26.1.2', '1.21.1', '1.20.4' ], 'fetch release ids from mocked manifest');
    my @list = mc_list_mc_versions();
    ok((grep { $_ eq '26.1.2' } @list), 'effective list includes live 26.1.2');
    ok(build_mc_profile('neoforge', '26.1.2'), 'build_mc_profile allows live-only version');
    is(mc_fetch_java_major_for_mc('1.21.1'), 21, 'fetch java major from version json');
};

subtest 'mc_compat_local merges versions and map keys' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    local $module_config_directory = $tmpdir;
    local $main::module_config_directory = $tmpdir;
    local $config_directory = $tmpdir;
    local $main::config_directory = $tmpdir;
    # No live/cache java — local versions override base bundled policy
    local *_mc_fetch_url = sub { return undef; };
    open(my $fh, '>', "$tmpdir/mc_compat_local.json") or die $!;
    print {$fh} <<'JSON';
{
  "versions": {
    "1.21.1": { "java_major": 25, "min_java": 25, "max_java": 25 },
    "99.0.0": { "java_major": 25 }
  },
  "game_to_loader": {
    "mc-custom": "fabric"
  },
  "loaders": {
    "paper": { "phase": 1, "label_en": "Paper (local)" },
    "customloader": {
      "lgsm_script": "mcserver",
      "mod_dir": "mods",
      "label_de": "Custom",
      "label_en": "Custom",
      "phase": 1
    }
  },
  "java_mod_excluded": ["mcb", "mcbserver", "extra-excluded"]
}
JSON
    close($fh);
    _reset_mc_compat_cache();

    is(resolve_java_major('1.21.1'), 25, 'local versions override java_major for known id');
    is(resolve_java_major('99.0.0'), 25, 'local versions can add new id');
    is(mc_loader_from_game('mc-custom'), 'fabric', 'local game_to_loader extends map');
    is(mc_loader_from_game('mc'), 'vanilla', 'base game_to_loader still present');
    my $paper = mc_loader_config('paper');
    ok(ref($paper) eq 'HASH', 'paper loader still loaded');
    is($paper->{'label_en'}, 'Paper (local)', 'local loaders shallow-merge fields');
    is($paper->{'lgsm_script'}, 'pmcserver', 'base loader fields preserved on merge');
    ok(mc_loader_config('customloader'), 'local can add new loader');
    ok(_mc_java_mod_excluded('extra-excluded'), 'local java_mod_excluded replaces list');
    ok(_mc_java_mod_excluded('mcb'), 'local java_mod_excluded still has mcb');
};

subtest 'mc_compat_local mc_versions is offline fallback only' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    local $module_config_directory = $tmpdir;
    local $main::module_config_directory = $tmpdir;
    local $config_directory = $tmpdir;
    local $main::config_directory = $tmpdir;
    open(my $fh, '>', "$tmpdir/mc_compat_local.json") or die $!;
    print {$fh} <<'JSON';
{
  "mc_versions": [ "1.21.1", "99.9.9" ],
  "versions": {
    "99.9.9": { "java_major": 25 }
  }
}
JSON
    close($fh);
    _reset_mc_compat_cache();

    # Offline: local non-empty mc_versions becomes the fallback list
    {
        local *_mc_fetch_url = sub { return undef; };
        my @offline = mc_list_mc_versions();
        is_deeply(\@offline, [ '1.21.1', '99.9.9' ],
            'offline uses local mc_versions as fallback list');
        ok(build_mc_profile('paper', '99.9.9'), 'offline build allows local-only fallback version');
    }

    # Live still preferred over local fallback pins
    {
        open(my $mfh, '<', 't/fixtures/mc/version_manifest_v2.json') or die $!;
        local $/;
        my $manifest_raw = <$mfh>;
        close($mfh);
        local *_mc_fetch_url = sub {
            my ($url) = @_;
            return $manifest_raw if $url =~ /version_manifest_v2\.json/;
            return undef;
        };
        my @live = mc_list_mc_versions();
        ok((grep { $_ eq '26.1.2' } @live), 'live list preferred over local mc_versions pin');
        ok(!(grep { $_ eq '99.9.9' } @live), 'local mc_versions does not replace live list');
    }
};

subtest 'mc_compat_local prefers module_config_directory path' => sub {
    my $modcfg = tempdir(CLEANUP => 1);
    my $cfg    = tempdir(CLEANUP => 1);
    local $module_config_directory = $modcfg;
    local $main::module_config_directory = $modcfg;
    local $config_directory = $cfg;
    local $main::config_directory = $cfg;
    local *_mc_fetch_url = sub { return undef; };

    open(my $fh1, '>', "$modcfg/mc_compat_local.json") or die $!;
    print {$fh1} '{"versions":{"1.20.1":{"java_major":99}}}' . "\n";
    close($fh1);
    open(my $fh2, '>', "$cfg/mc_compat_local.json") or die $!;
    print {$fh2} '{"versions":{"1.20.1":{"java_major":11}}}' . "\n";
    close($fh2);
    _reset_mc_compat_cache();
    is(resolve_java_major('1.20.1'), 99, 'module_config_directory local wins over config_directory');

    unlink "$modcfg/mc_compat_local.json";
    _reset_mc_compat_cache();
    is(resolve_java_major('1.20.1'), 11, 'falls back to config_directory/mc_compat_local.json');
};

done_testing();
