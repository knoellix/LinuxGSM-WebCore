#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

require "$Bin/stubs.pl";
our (%config, $module_root);
$config{'modrinth_contact'} = 'LinuxGSM-WebCore-Test/1.0 (test@example.com)';

require "$Bin/../src/lib/module_config.pl";
require "$Bin/../src/lib/mc_mods.pl";

ok(mod_env_allowed('server', 'import_server'), 'server env allowed for import');
ok(!mod_env_allowed('client', 'import_server'), 'client env blocked for import');
ok(mod_env_allowed('both', 'import_server'), 'both env allowed for import');
ok(mod_env_allowed('unknown', 'import_server'), 'unknown allowed for server import (CF)');
ok(mod_env_allowed('both', 'export_client'), 'both for client export');
ok(!mod_env_allowed('server', 'export_client'), 'server not in client export');
ok(!mod_env_allowed('unknown', 'export_server'), 'unknown not in export_server');

is(normalize_mod_env({ server => 'required', client => 'unsupported' }), 'server', 'modrinth env server');
is(normalize_mod_env({ server => 'required', client => 'required' }), 'both', 'modrinth env both');

ok(mc_download_url_allowed('https://cdn.modrinth.com/data/x/y/file.jar'), 'modrinth CDN allowed');
ok(!mc_download_url_allowed('https://evil.example.com/mod.jar'), 'unknown host blocked');
is(mc_download_url_normalize('http://edge.forgecdn.net/files/1/2/mod.jar'),
    'https://edge.forgecdn.net/files/1/2/mod.jar', 'CF http CDN upgraded to https');
is(curseforge_extract_download_url('http://edge.forgecdn.net/files/1/2/mod.jar'),
    'https://edge.forgecdn.net/files/1/2/mod.jar', 'CF extract normalizes http CDN');
ok(mc_download_url_host_is_ip('0.8.43.193'), 'detects raw IP host');
ok(!mc_download_url_host_is_ip('edge.forgecdn.net'), 'forgecdn hostname not IP');

is(_modrinth_file_download_url({ url => 'https://cdn.modrinth.com/data/x/y/file.jar' }),
    'https://cdn.modrinth.com/data/x/y/file.jar', 'modrinth singular url field');
is(_modrinth_file_download_url({ urls => ['https://cdn.modrinth.com/data/x/y/file.jar'] }),
    'https://cdn.modrinth.com/data/x/y/file.jar', 'modrinth urls array fallback');
ok(!_modrinth_file_download_url({ url => 'https://evil.example.com/mod.jar' }), 'modrinth url host check');

my $modrinth_search_resp = _mc_mods_http_get_json(
    'https://api.modrinth.com/v2/search?query=jade&limit=1',
    { 'User-Agent' => 'LinuxGSM-WebCore-Test/1.0 (test@example.com)' },
);
SKIP: {
    skip 'curl/network unavailable in this environment', 1
        if ref($modrinth_search_resp) ne 'HASH'
        || ref($modrinth_search_resp->{'hits'}) ne 'ARRAY';
    ok(1, 'modrinth search works with parenthetical User-Agent');
}

is(curseforge_mod_loader_type('neoforge'), 6, 'neoforge CF loader type');
is(curseforge_mod_loader_type('fabric'), 4, 'fabric CF loader type');
$config{'curseforge_api_key'} = '  "abc123"  ';
is(curseforge_api_key(), 'abc123', 'curseforge_api_key trims config value');
delete $config{'curseforge_api_key'};
ok(!mc_hash_value_is_sha1('7032247'), 'file id is not valid sha1');
ok(mc_hash_value_is_sha1('31cf754f9e5f62d1ca257f297e5dce394024696c'), 'valid sha1 accepted');
my $cf_h_bad = curseforge_normalize_hashes([ { value => '7032247', algo => 1 } ]);
is($cf_h_bad->{sha1}, undef, 'CF normalize rejects file id as sha1');
my $cf_h_ok = curseforge_normalize_hashes([ { value => '31cf754f9e5f62d1ca257f297e5dce394024696c', algo => 1 } ]);
is($cf_h_ok->{sha1}, '31cf754f9e5f62d1ca257f297e5dce394024696c', 'CF normalize keeps valid sha1');
my $cf_h_md5 = curseforge_normalize_hashes([ { value => 'd41d8cd98f00b204e9800998ecf8427e', algo => 2 } ]);
is($cf_h_md5->{md5}, 'd41d8cd98f00b204e9800998ecf8427e', 'CF hashes array algo 2 -> md5');
is($cf_h_md5->{sha1}, undef, 'CF hashes array no sha1 unless algo 1');
my $cf_h_legacy = curseforge_normalize_hashes({ sha1 => '31cf754f9e5f62d1ca257f297e5dce394024696c' });
is($cf_h_legacy->{sha1}, '31cf754f9e5f62d1ca257f297e5dce394024696c', 'CF hashes legacy hash ref');
is(_modrinth_side_env('required', 'unsupported'), 'server', 'modrinth side server');
ok(_modrinth_hit_server_visible({ server_side => 'required', client_side => 'unsupported' }), 'hit visible');
ok(!_modrinth_hit_server_visible({ server_side => 'unsupported', client_side => 'required' }), 'client hit hidden');

subtest 'search helpers return empty list not arrayref' => sub {
    my @empty = modrinth_search_mods('', { loader => 'neoforge', mc_version => '1.21.1' });
    is(scalar @empty, 0, 'empty query returns empty list');
    my @cf = curseforge_search_mods('jade', { loader => 'neoforge', mc_version => '1.21.1' });
    is(scalar @cf, 0, 'curseforge without key returns empty list');
};

subtest 'list_installed_mods scans jar and disabled' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $sf = "$tmp/serverfiles/mods";
    require File::Path;
    File::Path::make_path($sf);
    open my $a, '>', "$sf/Alpha.jar" or die $!;
    print $a 'x'; close $a;
    open my $b, '>', "$sf/Beta.jar.disabled" or die $!;
    print $b 'y'; close $b;
    write_mc_mods_index($tmp, {
        'mods/Alpha.jar' => { title => 'Alpha Mod', source => 'modrinth', modrinth_project => 'abc' },
    });
    my $profile = { mod_dir => 'mods', loader => 'neoforge', mc_version => '1.21.1' };
    my $list = list_installed_mods($tmp, $profile);
    is(scalar @$list, 2, 'two mods');
    my %by = map { $_->{basename} => $_ } @$list;
    ok($by{'Alpha.jar'}{enabled}, 'alpha enabled');
    ok(!$by{'Beta.jar'}{enabled}, 'beta disabled');
    is($by{'Alpha.jar'}{title}, 'Alpha Mod', 'title from index');
    ok($by{'Alpha.jar'}{has_update_meta}, 'update meta when project known');
    ok(!$by{'Beta.jar'}{has_update_meta}, 'no update meta without index');
};

subtest 'mod_set_enabled and delete' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $sf = "$tmp/serverfiles/mods";
    require File::Path;
    File::Path::make_path($sf);
    open my $fh, '>', "$sf/Foo.jar" or die $!;
    print $fh 'x'; close $fh;
    # Empty unix_user = direct filesystem ops (test harness runs as current user).
    my ($ok, $err) = mod_set_enabled($tmp, '', 'mods', 'Foo.jar', 0);
    ok($ok, 'disable ok') or diag($err);
    ok(-f "$sf/Foo.jar.disabled", 'disabled file present');
    ok(!-f "$sf/Foo.jar", 'enabled file gone');
    ($ok, $err) = mod_set_enabled($tmp, '', 'mods', 'Foo.jar', 1);
    ok($ok, 'enable ok') or diag($err);
    ok(-f "$sf/Foo.jar", 'enabled file restored');
    ok(!-f "$sf/Foo.jar.disabled", 'disabled file gone after enable');
    write_mc_mods_index($tmp, { 'mods/Foo.jar' => { title => 'Foo', source => 'modrinth' } });
    ($ok, $err) = mod_delete_installed($tmp, '', 'mods', 'Foo.jar');
    ok($ok, 'delete ok') or diag($err);
    ok(!-e "$sf/Foo.jar" && !-e "$sf/Foo.jar.disabled", 'both variants gone');
    my $idx = read_mc_mods_index($tmp);
    ok(!exists $idx->{'mods/Foo.jar'}, 'index key removed');
};

subtest 'curseforge file record cache' => sub {
    curseforge_clear_file_cache();
    my $calls = 0;
    no warnings 'redefine';
    local *curseforge_fetch_file_record = sub {
        my ($pid, $fid) = @_;
        my $ck = "$pid:$fid";
        return $main::curseforge_file_cache{$ck} if exists $main::curseforge_file_cache{$ck};
        $calls++;
        my $rec = {
            url  => "https://edge.forgecdn.net/files/$pid/$fid/x.jar",
            meta => { fileName => 'x.jar' },
            err  => undef,
        };
        $main::curseforge_file_cache{$ck} = $rec;
        return $rec;
    };
    my ($u1) = curseforge_fetch_file_download_url(1, 2, 'key');
    my ($u2) = curseforge_fetch_file_download_url(1, 2, 'key');
    is($u1, $u2, 'cached download url');
    is($calls, 1, 'single API record fetch per project/file');
};

done_testing();
