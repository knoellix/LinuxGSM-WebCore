#!/usr/bin/env perl
# t/test_mc_profile.pl — .mcprofile.json read/write and LGSM cfg patch
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

use lib "$Bin/..";
chdir "$Bin/.." or die "Cannot chdir to repo root: $!\n";

chdir "$Bin/.." or die "Cannot chdir to repo root: $!\n";

our $module_root = 'src';
require 't/stubs.pl';
$module_root = 'src';
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
like($neo_out, qr/preexecutable=""/, 'neoforge clears preexecutable');

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

done_testing();
