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
is(normalize_mod_env_value('server'), 'server', 'string env server');
is(normalize_mod_env_value('BOTH'), 'both', 'string env both');
is(normalize_mod_env_value('nope'), 'unknown', 'bad string env -> unknown');

is(mod_friendly_name_from_basename('EdivadLib-26.1.2-4.0.1.jar'),
    'EdivadLib', 'friendly strips version pairs');
is(mod_friendly_name_from_basename('EnchantmentDescriptions-neoforge-MC26.1.2-26.1.2.5.jar'),
    'EnchantmentDescriptions', 'friendly strips loader+mc+version');
is(mod_friendly_name_from_basename('enderio-9.0.5-alpha.jar'),
    'enderio', 'friendly strips version and alpha');
is(mod_friendly_name_from_basename('appleskin-neoforge-mc1.21-3.0.6.jar'),
    'appleskin', 'friendly strips neoforge mc version');
is(_mc_mods_display_name({ title => 'Jade', basename => 'jade-1.21.1.jar' }),
    'Jade', 'display prefers real title');
is(_mc_mods_display_name({ title => 'jade-1.21.1.jar', basename => 'jade-1.21.1.jar' }),
    'jade', 'display ignores title that equals jar name');

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
    open my $c, '>', "$sf/EdivadLib-26.1.2-4.0.1.jar" or die $!;
    print $c 'z'; close $c;
    write_mc_mods_index($tmp, {
        'mods/Alpha.jar' => {
            title => 'Alpha Mod', source => 'modrinth',
            modrinth_project => 'abc', env => 'server',
        },
        'mods/EdivadLib-26.1.2-4.0.1.jar' => {
            env => 'both', source => 'modrinth',
        },
    });
    my $profile = { mod_dir => 'mods', loader => 'neoforge', mc_version => '1.21.1' };
    my $list = list_installed_mods($tmp, $profile);
    is(scalar @$list, 3, 'three mods');
    my %by = map { $_->{basename} => $_ } @$list;
    ok($by{'Alpha.jar'}{enabled}, 'alpha enabled');
    ok(!$by{'Beta.jar'}{enabled}, 'beta disabled');
    is($by{'Alpha.jar'}{title}, 'Alpha Mod', 'title from index');
    is($by{'Alpha.jar'}{env}, 'server', 'env from index');
    ok($by{'Alpha.jar'}{has_update_meta}, 'update meta when project known');
    ok(!$by{'Beta.jar'}{has_update_meta}, 'no update meta without index');
    is($by{'Beta.jar'}{env}, 'unknown', 'missing env is unknown');
    is($by{'EdivadLib-26.1.2-4.0.1.jar'}{title}, 'EdivadLib',
        'missing title becomes friendly name');
    is($by{'EdivadLib-26.1.2-4.0.1.jar'}{env}, 'both', 'env both from index');
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

subtest 'filter sort paginate installed mods' => sub {
    my @mods = (
        { basename => 'Zeta.jar',   title => 'Zeta Mod',       enabled => 1 },
        { basename => 'Alpha.jar',  title => 'Alpha Mod',      enabled => 0 },
        { basename => 'Beta.jar',   title => 'Something Beta', enabled => 1 },
        { basename => 'Gamma.jar',  title => 'Gamma',          enabled => 0 },
    );

    my $all = filter_installed_mods(\@mods, {});
    is(scalar @$all, 4, 'filter empty opts returns all');

    my $en = filter_installed_mods(\@mods, { status => 'enabled' });
    is(scalar @$en, 2, 'filter enabled count');
    ok((grep { $_->{basename} eq 'Zeta.jar' } @$en), 'enabled includes Zeta');
    ok(!(grep { $_->{basename} eq 'Alpha.jar' } @$en), 'enabled excludes Alpha');

    my $dis = filter_installed_mods(\@mods, { status => 'disabled' });
    is(scalar @$dis, 2, 'filter disabled count');
    ok((grep { $_->{basename} eq 'Alpha.jar' } @$dis), 'disabled includes Alpha');

    my $by_title = filter_installed_mods(\@mods, { q => 'alpha mod' });
    is(scalar @$by_title, 1, 'filter q matches title');
    is($by_title->[0]{basename}, 'Alpha.jar', 'title match basename');

    my $by_base = filter_installed_mods(\@mods, { q => 'beta.jar' });
    is(scalar @$by_base, 1, 'filter q matches basename');
    is($by_base->[0]{basename}, 'Beta.jar', 'basename match');

    my $combo = filter_installed_mods(\@mods, { q => 'a', status => 'enabled' });
    is(scalar @$combo, 2, 'filter q + enabled');
    ok((grep { $_->{basename} eq 'Beta.jar' } @$combo), 'combo includes Beta');
    ok(!(grep { $_->{basename} eq 'Alpha.jar' } @$combo), 'combo excludes disabled Alpha');

    my $name_asc = sort_installed_mods(\@mods, 'name', 'asc');
    my @names_asc = map { $_->{basename} } @$name_asc;
    is_deeply(\@names_asc, [qw(Alpha.jar Gamma.jar Beta.jar Zeta.jar)], 'sort name asc by title');

    my $name_desc = sort_installed_mods(\@mods, 'name', 'desc');
    my @names_desc = map { $_->{basename} } @$name_desc;
    is_deeply(\@names_desc, [qw(Zeta.jar Beta.jar Gamma.jar Alpha.jar)], 'sort name desc by title');

    my $stat_asc = sort_installed_mods(\@mods, 'status', 'asc');
    ok(!$stat_asc->[0]{enabled}, 'sort status asc disabled first');
    ok($stat_asc->[-1]{enabled}, 'sort status asc enabled last');

    my $stat_desc = sort_installed_mods(\@mods, 'status', 'desc');
    ok($stat_desc->[0]{enabled}, 'sort status desc enabled first');
    ok(!$stat_desc->[-1]{enabled}, 'sort status desc disabled last');

    my ($s1, $t1, $p1) = paginate_installed_mods(\@mods, 1, 2);
    is($t1, 4, 'page1 total');
    is($p1, 2, 'page1 pages');
    is(scalar @$s1, 2, 'page1 slice size');
    is($s1->[0]{basename}, $mods[0]{basename}, 'page1 first item unchanged order');

    my ($s2, $t2, $p2) = paginate_installed_mods(\@mods, 2, 2);
    is(scalar @$s2, 2, 'page2 slice size');

    my ($s3, $t3, $p3) = paginate_installed_mods(\@mods, 3, 2);
    is($p3, 2, 'page3 pages unchanged');
    is(scalar @$s3, 2, 'page3 clamped to last page');

    my ($s_clamp, $t_clamp, $p_clamp) = paginate_installed_mods(\@mods, 99, 2);
    is(scalar @$s_clamp, 2, 'page clamp high returns last page slice');
    is($s_clamp->[0]{basename}, $s2->[0]{basename}, 'clamped page matches page2');

    my ($s_def, $t_def, $p_def) = paginate_installed_mods(\@mods, 1);
    is($t_def, 4, 'default per_page total');
    is($p_def, 1, 'default per_page single page');

    my ($s_empty, $t_empty, $p_empty) = paginate_installed_mods([], 1, 10);
    is($t_empty, 0, 'empty total');
    is($p_empty, 1, 'empty still one page');
    is(scalar @$s_empty, 0, 'empty slice');
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

subtest 'modrinth list compatible versions filters and caps' => sub {
    my $profile = { loader => 'fabric', mc_version => '1.21.1' };
    my $hits = [];
    for my $i (1 .. 35) {
        push @$hits, {
            id   => "v$i",
            name => "Version $i",
            env  => { server => 'required', client => 'unsupported' },
            date_published => "2026-01-$i",
            files => [
                {
                    primary  => 1,
                    filename => "mod-$i.jar",
                    url      => "https://cdn.modrinth.com/data/x/y/mod-$i.jar",
                },
            ],
        };
    }
    # Should be filtered out (client-only env).
    push @$hits, {
        id   => 'client-only',
        env  => { server => 'unsupported', client => 'required' },
        files => [
            {
                primary  => 1,
                filename => 'client.jar',
                url      => 'https://cdn.modrinth.com/data/x/y/client.jar',
            },
        ],
    };

    no warnings 'redefine';
    local *_mc_mods_http_get_json = sub { return $hits; };

    my $list = modrinth_list_compatible_versions('some-project', $profile);
    is(ref($list), 'ARRAY', 'returns arrayref');
    is(scalar @$list, 30, 'caps compatible versions at 30');
    is($list->[0]{version_id}, 'v1', 'keeps API order');
    is($list->[0]{name}, 'Version 1', 'includes version name');
    is($list->[0]{filename}, 'mod-1.jar', 'includes sanitized filename');
    like($list->[0]{download_url}, qr{^https://cdn\.modrinth\.com/}, 'includes download url');
    is($list->[0]{env}, 'server', 'includes normalized env');
};

subtest 'modrinth resolve uses list helper first entry' => sub {
    no warnings 'redefine';
    local *modrinth_list_compatible_versions = sub {
        my ($project_id, $profile) = @_;
        is($project_id, 'abc-123', 'resolve passes project id to list helper');
        is($profile->{mc_version}, '1.21.1', 'resolve forwards profile');
        return [
            { version_id => 'first', filename => 'first.jar', download_url => 'https://cdn.modrinth.com/data/x/y/first.jar', hashes => { sha1 => 'a' }, env => 'server' },
            { version_id => 'second', filename => 'second.jar', download_url => 'https://cdn.modrinth.com/data/x/y/second.jar', hashes => { sha1 => 'b' }, env => 'both' },
        ];
    };

    my $resolved = modrinth_resolve_version_file('abc-123', { loader => 'fabric', mc_version => '1.21.1' });
    is($resolved->{version_id}, 'first', 'resolve picks first compatible version');
    is($resolved->{filename}, 'first.jar', 'resolve returns first compatible filename');
};

subtest 'curseforge list compatible files filters by server pack and download' => sub {
    no warnings 'redefine';
    local *_curseforge_api_headers = sub { return { 'x-api-key' => 'abc' }; };
    local *_mc_mods_http_get_json = sub {
        return {
            data => [
                { id => 1001, fileName => 'ServerPack.jar', isServerPack => 1, hashes => [] },
                { id => 1002, fileName => 'NoDownload.jar', isServerPack => 0, hashes => [] },
                { id => 1003, fileName => 'Good File.jar', isServerPack => 0, hashes => [] },
            ],
        };
    };
    local *curseforge_mod_file_download_url = sub {
        my ($project_id, $file_id) = @_;
        return undef if $file_id == 1002;
        return "https://edge.forgecdn.net/files/1/$file_id/mod.jar";
    };

    my $list = curseforge_list_compatible_files(703224, { loader => 'neoforge', mc_version => '1.21.1' });
    is(ref($list), 'ARRAY', 'returns arrayref');
    is(scalar @$list, 1, 'keeps only downloadable non-server-pack files');
    is($list->[0]{file_id}, 1003, 'keeps expected file id');
    is($list->[0]{filename}, 'GoodFile.jar', 'sanitizes filename');
    is($list->[0]{env}, 'both', 'sets env to both for CF');
};

subtest 'curseforge resolve uses list helper first entry' => sub {
    no warnings 'redefine';
    local *curseforge_list_compatible_files = sub {
        return [
            { file_id => 10, filename => 'one.jar', download_url => 'https://edge.forgecdn.net/files/1/10/one.jar', hashes => {}, env => 'both' },
            { file_id => 11, filename => 'two.jar', download_url => 'https://edge.forgecdn.net/files/1/11/two.jar', hashes => {}, env => 'both' },
        ];
    };
    my $resolved = curseforge_resolve_mod_file('703224', { loader => 'neoforge', mc_version => '1.21.1' });
    is($resolved->{file_id}, 10, 'resolve picks first compatible file');
    is($resolved->{filename}, 'one.jar', 'resolve returns first compatible filename');
};

subtest 'hangar resolve honors requested version_id' => sub {
    no warnings 'redefine';
    local *hangar_list_compatible_versions = sub {
        return [
            {
                version_id   => '2.0.0',
                name         => '2.0.0',
                filename     => 'plugin-2.jar',
                download_url => 'https://hangar.papermc.io/api/v1/projects/Owner/Slug/versions/2.0.0/PAPER/download',
                hashes       => {},
                env          => 'server',
            },
            {
                version_id   => '1.5.1',
                name         => '1.5.1',
                filename     => 'plugin-1.jar',
                download_url => 'https://hangar.papermc.io/api/v1/projects/Owner/Slug/versions/1.5.1/PAPER/download',
                hashes       => {},
                env          => 'server',
            },
        ];
    };

    my $picked = hangar_resolve_plugin_file(
        'Owner', 'Slug',
        { loader => 'paper', mc_version => '1.21.1' },
        '1.5.1',
    );
    is($picked->{version_id}, '1.5.1', 'requested Hangar version id selected');
    is($picked->{filename}, 'plugin-1.jar', 'selected requested Hangar file');

    my $fallback = hangar_resolve_plugin_file(
        'Owner', 'Slug',
        { loader => 'paper', mc_version => '1.21.1' },
        '9.9.9',
    );
    is($fallback->{version_id}, '2.0.0', 'falls back to first compatible version');
};

subtest 'prepare_mod_install_meta pins hangar by version id or name' => sub {
    no warnings 'redefine';
    local *hangar_resolve_plugin_file = sub {
        my ($owner, $slug, $profile, $requested_version_id) = @_;
        is($owner, 'PaperMC', 'owner passed through');
        is($slug, 'FancyPlugin', 'slug passed through');
        is($profile->{loader}, 'paper', 'profile loader passed through');
        if (($requested_version_id // '') eq 'release-1.4.0') {
            return {
                version_id   => 'release-1.4.0',
                filename     => 'fancy-1.4.0.jar',
                download_url => 'https://hangar.papermc.io/api/v1/projects/PaperMC/FancyPlugin/versions/release-1.4.0/PAPER/download',
                hashes       => {},
                env          => 'server',
            };
        }
        if (($requested_version_id // '') eq '1.4.0') {
            return {
                version_id   => 'release-1.4.0',
                filename     => 'fancy-1.4.0.jar',
                download_url => 'https://hangar.papermc.io/api/v1/projects/PaperMC/FancyPlugin/versions/release-1.4.0/PAPER/download',
                hashes       => {},
                env          => 'server',
            };
        }
        return {
            version_id   => 'latest',
            filename     => 'fancy-latest.jar',
            download_url => 'https://hangar.papermc.io/api/v1/projects/PaperMC/FancyPlugin/versions/latest/PAPER/download',
            hashes       => {},
            env          => 'server',
        };
    };

    my ($ok_a, $meta_a, $err_a) = prepare_mod_install_meta(
        'hangar',
        {
            hangar_owner => 'PaperMC',
            hangar_slug  => 'FancyPlugin',
            version_id   => 'release-1.4.0',
            title        => 'Fancy Plugin',
        },
        { loader => 'paper', mc_version => '1.21.1', mod_dir => 'plugins' },
        '/tmp/test-server-a',
    );
    ok($ok_a, 'prepare meta with explicit hangar version id') or diag($err_a // 'unknown');
    is($meta_a->{version_id}, 'release-1.4.0', 'meta keeps explicit pinned version');
    is($meta_a->{filename}, 'fancy-1.4.0.jar', 'meta uses pinned file');

    my ($ok_b, $meta_b, $err_b) = prepare_mod_install_meta(
        'hangar',
        {
            hangar_owner => 'PaperMC',
            hangar_slug  => 'FancyPlugin',
            version_id   => '1.4.0',
            title        => 'Fancy Plugin',
        },
        { loader => 'paper', mc_version => '1.21.1', mod_dir => 'plugins' },
        '/tmp/test-server-b',
    );
    ok($ok_b, 'prepare meta with hangar version name pin') or diag($err_b // 'unknown');
    is($meta_b->{version_id}, 'release-1.4.0', 'meta resolves requested version name');
};

subtest 'prepare_mod_install_meta allows replace when force_replace set' => sub {
    no warnings 'redefine';
    local *modrinth_resolve_version_file = sub {
        return {
            version_id   => 'ver-new',
            filename     => 'jade-1.21.1.jar',
            download_url => 'https://cdn.modrinth.com/data/jade/jade-1.21.1.jar',
            hashes       => {},
            env          => 'server',
        };
    };

    my $tmp = tempdir(CLEANUP => 1);
    my $sf = "$tmp/serverfiles/mods";
    require File::Path;
    File::Path::make_path($sf);
    open my $fh, '>', "$sf/jade-1.21.1.jar" or die $!;
    print $fh 'old'; close $fh;
    write_mc_mods_index($tmp, {
        'mods/jade-1.21.1.jar' => {
            source => 'modrinth', modrinth_project => 'jade', modrinth_version => 'ver-old',
        },
    });

    my ($blocked, $meta_blocked, $err_blocked) = prepare_mod_install_meta(
        'modrinth',
        { project_id => 'jade', title => 'Jade' },
        { loader => 'fabric', mc_version => '1.21.1', mod_dir => 'mods' },
        $tmp,
    );
    ok(!$blocked, 'fresh install blocked when mod already present');
    is($err_blocked, 'file_exists', 'duplicate reason is file_exists');

    my ($ok, $meta, $err) = prepare_mod_install_meta(
        'modrinth',
        { project_id => 'jade', title => 'Jade' },
        { loader => 'fabric', mc_version => '1.21.1', mod_dir => 'mods' },
        $tmp,
        { force_replace => 1 },
    );
    ok($ok, 'force_replace skips already_present check') or diag($err // 'unknown');
    is($meta->{filename}, 'jade-1.21.1.jar', 'replace keeps resolved filename');
    is($meta->{version_id}, 'ver-new', 'replace keeps pinned version');
};

# mods.cgi calls modpack_* helpers — must load mc_modpack.pl (500 if omitted)
# mods.cgi start/stop jobs call log_action — must load logging.pl (500 if omitted)
{
    open my $fh, '<', "$Bin/../src/mods.cgi" or die $!;
    local $/;
    my $src = <$fh>;
    close $fh;
    like($src, qr/require\s+['\"]\.\/lib\/mc_modpack\.pl['\"]/,
        'mods.cgi requires mc_modpack.pl');
    like($src, qr/require\s+['\"]\.\/lib\/logging\.pl['\"]/,
        'mods.cgi requires logging.pl');
    like($src, qr/ReadParseMime/, 'mods.cgi supports multipart upload');
    like($src, qr/ui_form_start\('mods\.cgi',\s*'form-data'\)/,
        'mods.cgi has browser upload form');
    like($src, qr/sync_monitor_job_pointers/,
        'mods.cgi syncs monitor restart jobs into UI');
    like($src, qr/monitor_last_restart/,
        'mods.cgi shows last auto-restart like manage');
    like($src, qr/monitor_disable/,
        'mods.cgi can disable monitoring');
}

done_testing();
