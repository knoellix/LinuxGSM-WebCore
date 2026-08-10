#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use File::Temp qw(tempdir);
use FindBin qw($Bin);

require "$Bin/stubs.pl";
our (%config, $module_root);
$config{'modrinth_contact'} = 'LinuxGSM-WebCore-Test/1.0 (test@example.com)';

require "$Bin/../src/lib/module_config.pl";
require "$Bin/../src/lib/mc_profile.pl";
require "$Bin/../src/lib/mc_loader.pl";
require "$Bin/../src/lib/mc_mods.pl";
require "$Bin/../src/lib/mc_modpack.pl";

my $fixture_json = do {
    open my $fh, '<', "$Bin/fixtures/modpack/modrinth.index.json" or die $!;
    local $/; <$fh>
};

subtest 'parse modrinth index json' => sub {
    my $idx = parse_modrinth_index_json($fixture_json);
    ok($idx, 'parses fixture');
    is($idx->{'dependencies'}{'minecraft'}, '1.21.1', 'mc version in deps');
};

subtest 'validate against profile' => sub {
    my $pack = {
        loader     => 'neoforge',
        mc_version => '1.21.1',
        files      => [{ env => 'server' }],
    };
    my $profile = build_mc_profile('neoforge', '1.21.1');
    my $v = validate_modpack_against_profile($pack, $profile);
    ok($v->{ok}, 'matching profile ok');

    $pack->{loader} = 'forge';
    $v = validate_modpack_against_profile($pack, $profile);
    ok(!$v->{ok}, 'loader mismatch fails');
    ok(grep { $_ eq 'loader_mismatch' } @{ $v->{errors} }, 'loader_mismatch error');
};

subtest 'server import filter' => sub {
    my $pack = parse_modrinth_index_json($fixture_json);
    $pack = {
        files => [
            { env => 'server' },
            { env => 'client' },
            { env => 'both' },
        ],
    };
    my ($files, $skipped) = modpack_files_for_server_import($pack);
    is(scalar @$files, 2, 'server + both kept');
    is($skipped, 1, 'one client skipped');
};

SKIP: {
    skip 'unzip not available', 2 unless system('command -v unzip >/dev/null 2>&1') == 0;
    my $tmpdir = tempdir(CLEANUP => 1);
    my $mrpack = "$tmpdir/test.mrpack";
    system('zip', '-j', '-q', $mrpack, "$Bin/fixtures/modpack/modrinth.index.json") == 0
        or skip 'zip command failed', 2;
    is(detect_modpack_format($mrpack), 'modrinth', 'detect mrpack');
    my $parsed = parse_modrinth_mrpack($mrpack);
    ok($parsed, 'parse mrpack file');
    is($parsed->{loader}, 'neoforge', 'loader from mrpack');
};

subtest 'modpack search empty query' => sub {
    my $r = mc_modpack_search('', { loader => 'neoforge', mc_version => '1.21.1' });
    ok(ref($r) eq 'HASH', 'returns hash');
    is(scalar @{ $r->{results} // [] }, 0, 'empty query');
};

subtest 'modpack search query variants' => sub {
    my @v = mc_modpack_search_query_variants('ATM10');
    ok(grep { $_ eq 'All the Mods 10' } @v, 'expands ATM10');
    my @slugs = mc_modpack_guess_curseforge_slugs('All the Mods 10');
    is($slugs[0], 'all-the-mods-10', 'guesses CF slug');
    ok(mc_modpack_query_likely_curseforge_only('ATM10'), 'ATM flagged CF-only');
    @slugs = mc_modpack_guess_curseforge_slugs('ATM10 Sky');
    ok(grep { $_ eq 'all-the-mods-10-sky' } @slugs, 'ATM10 Sky guesses sky slug');
    my @sky_v = mc_modpack_search_query_variants('ATM10 Sky');
    ok(grep { /To the Sky/i } @sky_v, 'ATM10 Sky expands to full title');
    @slugs = mc_modpack_guess_curseforge_slugs('ATM10');
    ok(grep { $_ eq 'all-the-mods-10-sky' } @slugs, 'ATM10 also offers sky slug');
};

subtest 'curseforge modpack file pick' => sub {
    my $profile = build_mc_profile('neoforge', '1.21.1');
    my $file = {
        id           => 8091114,
        fileName     => 'All the Mods 10-7.0.zip',
        isServerPack => 0,
        gameVersions => ['1.21.1'],
        modLoaders   => [ { id => 6, name => 'NeoForge' } ],
    };
    ok(_curseforge_file_matches_profile($file, '1.21.1', 6), 'CF file matches neoforge 1.21.1');
    my $server = { %$file, isServerPack => 1, id => 8091115 };
    ok(_curseforge_file_matches_profile($server, '1.21.1', 6), 'server pack matches profile metadata');
    my $meta = _curseforge_pick_modpack_file_meta($profile, [$file]);
    is($meta->{file_id}, 8091114, 'meta pick file id');
    my @hit = _modpack_hit_from_curseforge_mod({
        id => 925200, name => 'All the Mods 10 - ATM10', summary => 'test',
        downloadCount => 100, latestFiles => [$file],
    }, $profile);
    is(scalar @hit, 1, 'CF search hit without download-url roundtrip');
    is($hit[0]->{project_id}, 925200, 'hit project id');
    is(_curseforge_fetch_modpack_file_meta(undef, $profile), undef, 'fetch meta needs project id');
    is(curseforge_extract_download_url('https://edge.forgecdn.net/files/1/2/pack.zip'),
        'https://edge.forgecdn.net/files/1/2/pack.zip', 'CF download-url string data');
    is(curseforge_extract_download_url({ downloadUrl => 'https://edge.forgecdn.net/x.zip' }),
        'https://edge.forgecdn.net/x.zip', 'CF download-url hash data');
    is(curseforge_build_forgecdn_url(616555, 5623665, 'SmoothFont_1.21.zip'),
        'https://edge.forgecdn.net/files/6165/5623665/SmoothFont_1.21.zip',
        'forgecdn URL from meta fileName when downloadUrl null');
    is(curseforge_forgecdn_path_id(335423), 3354, 'forgecdn path id');
    like(mc_modpack_error_message('version_mismatch', {
        pack_mc => '1.20.1', instance_mc => '1.21.1',
    }, { mc_version => '1.21.1', loader => 'neoforge' }),
        qr/1\.20\.1.*1\.21\.1/, 'version mismatch message mentions versions');
};

subtest 'curseforge search compatibility filter' => sub {
    my $profile = build_mc_profile('neoforge', '1.21.1');
    my $atm10 = {
        id => 925200, name => 'All the Mods 10', summary => 'ATM10',
        downloadCount => 1000,
        latestFiles => [ {
            id => 8091114, fileName => 'ATM10-1.0.zip', isServerPack => 0,
            gameVersions => ['1.21.1', 'NeoForge'],
            modLoaders   => [ { id => 6, name => 'NeoForge' } ],
        } ],
    };
    my $atm9 = {
        id => 715572, name => 'All the Mods 9', summary => 'ATM9',
        downloadCount => 2000,
        latestFiles => [ {
            id => 5000001, fileName => 'ATM9-2.0.zip', isServerPack => 0,
            gameVersions => ['1.20.1', 'Forge'],
            modLoaders   => [ { id => 1, name => 'Forge' } ],
        } ],
    };
    my $c10 = curseforge_mod_compat_info($atm10, $profile);
    ok($c10->{compatible}, 'ATM10 marked compatible for neoforge 1.21.1');
    is($c10->{mc}, '1.21.1', 'ATM10 display mc');
    like($c10->{loader}, qr/neoforge/i, 'ATM10 display loader');

    my $c9 = curseforge_mod_compat_info($atm9, $profile);
    ok(!$c9->{compatible}, 'ATM9 marked incompatible for neoforge 1.21.1');
    is($c9->{mc}, '1.20.1', 'ATM9 display mc reflects its own version');

    # No version metadata => stay compatible (avoid false negatives).
    my $unknown = {
        id => 1, name => 'Unknown Pack', summary => '', downloadCount => 5,
        latestFiles => [ { id => 9, fileName => 'x.zip', isServerPack => 0 } ],
    };
    ok(curseforge_mod_compat_info($unknown, $profile)->{compatible},
        'pack without version info stays visible');

    my @hit9 = _modpack_hit_from_curseforge_mod($atm9, $profile);
    is($hit9[0]->{compatible}, 0, 'hit carries compatible=0 for ATM9');
    is($hit9[0]->{pack_mc}, '1.20.1', 'hit carries pack_mc');
};

subtest 'loader id from modpack name' => sub {
    is(mc_loader_id_from_name('NeoForge'), 'neoforge', 'neoforge name maps');
    is(mc_loader_id_from_name('Forge'), 'forge', 'forge name maps');
    is(mc_loader_id_from_name('Fabric'), 'fabric', 'fabric name maps');
    is(mc_loader_id_from_name('Quilt'), 'quilt', 'quilt recognised');
    is(mc_loader_id_from_name('bogus'), undef, 'unknown loader undef');
};

subtest 'open modpack search hit extraction' => sub {
    my $cf = _modpack_open_hit_from_curseforge_mod({
        id => 925200, name => 'All the Mods 10', summary => 'ATM10',
        downloadCount => 500,
        latestFiles => [ {
            id => 8091114, fileName => 'ATM10-1.0.zip', isServerPack => 0,
            gameVersions => ['1.21.1', 'NeoForge'],
            modLoaders   => [ { id => 6, name => 'NeoForge' } ],
        } ],
    });
    is($cf->{loader}, 'neoforge', 'CF open hit loader');
    is($cf->{pack_mc}, '1.21.1', 'CF open hit mc');
    is($cf->{file_id}, 8091114, 'CF open hit file id');

    # Forge/1.20.1 pack still resolvable (no profile filter in open search).
    my $cf9 = _modpack_open_hit_from_curseforge_mod({
        id => 715572, name => 'All the Mods 9', summary => '',
        downloadCount => 900,
        latestFiles => [ {
            id => 5000001, fileName => 'ATM9.zip', isServerPack => 0,
            gameVersions => ['1.20.1', 'Forge'],
            modLoaders   => [ { id => 1, name => 'Forge' } ],
        } ],
    });
    is($cf9->{loader}, 'forge', 'ATM9 open hit forge');
    is($cf9->{pack_mc}, '1.20.1', 'ATM9 open hit mc');

    my $mr = _modpack_open_hit_from_modrinth({
        project_id => 'abcd1234', slug => 'cool-pack', title => 'Cool Pack',
        description => 'x', downloads => 42,
        versions => ['1.20.1', '1.21', '1.21.1'],
        categories => ['fabric', 'adventure'],
    });
    is($mr->{loader}, 'fabric', 'modrinth open hit loader');
    is($mr->{pack_mc}, '1.21.1', 'modrinth open hit picks highest mc');
    is($mr->{project_id}, 'abcd1234', 'modrinth open hit project id');

    # No supported loader -> no hit.
    my $none = _modpack_open_hit_from_modrinth({
        project_id => 'x', title => 'y', versions => ['1.21.1'],
        categories => ['datapack'],
    });
    ok(!defined $none, 'modrinth hit without loader dropped');
};

subtest 'atomic pack meta write' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $path = "$tmpdir/pack_meta.json";
    ok(_modpack_atomic_write_json($path, '{"ok":1}'), 'writes json file');
    ok(-f $path, 'target exists');
    open my $fh, '<', $path or die $!;
    local $/; my $raw = <$fh>; close $fh;
    is($raw, '{"ok":1}', 'content matches');
    chmod 0444, $path;
    ok(_modpack_atomic_write_json($path, '{"ok":2}'), 'replaces read-only file in writable dir');
    open $fh, '<', $path or die $!;
    local $/; $raw = <$fh>; close $fh;
    is($raw, '{"ok":2}', 'updated content');
};

subtest 'curseforge manifest server import' => sub {
    my $manifest = parse_curseforge_manifest_json(<<'JSON');
{"manifestType":"minecraftModpack","manifestVersion":1,"name":"Test","version":"1","files":[{"projectID":123,"fileID":456,"required":true}],"overrides":"overrides","minecraft":{"version":"1.21.1","modLoaders":[{"id":"neoforge-21","primary":true}]}}
JSON
    ok($manifest, 'parses CF manifest fixture');
    my $pack = {
        format => 'curseforge',
        files  => [
            map {
                +{
                    project_id => $_->{'projectID'},
                    file_id    => $_->{'fileID'},
                    required   => 1,
                    env        => 'server',
                }
            } @{ $manifest->{'files'} // [] },
        ],
    };
    local $config{'curseforge_api_key'} = 'test-key';
    my ($ok, $deferred) = curseforge_deferred_pack_files($pack);
    ok($ok, 'deferred CF files ok');
    my ($files, $skipped) = modpack_files_for_server_import({
        format => 'curseforge',
        files  => $deferred,
    });
    is(scalar @$files, 1, 'CF deferred mods kept for server import');
    is($skipped, 0, 'no client skips');
};

subtest 'deferred curseforge pack files' => sub {
    my $pack = {
        format => 'curseforge',
        files  => [
            { project_id => 123, file_id => 456, required => 1, env => 'unknown' },
            { project_id => 789, file_id => 1011, required => 0, env => 'unknown' },
        ],
    };
    local $config{'curseforge_api_key'} = 'test-key';
    my ($ok, $files, $err) = curseforge_deferred_pack_files($pack);
    ok($ok, 'deferred CF pack files ok');
    is(scalar @$files, 2, 'deferred CF file count');
    is($files->[0]->{project_id}, 123, 'deferred project id');
    is($files->[0]->{file_id}, 456, 'deferred file id');
    is(scalar @{ $files->[0]->{downloads} // [] }, 0, 'deferred downloads empty');
    is($files->[0]->{path}, 'mods/mod-123-456.jar', 'deferred placeholder path');
    ($ok, my $none, $err) = curseforge_deferred_pack_files({ format => 'curseforge', files => [] });
    ok(!$ok && $err eq 'no_server_mods', 'deferred empty manifest');
};

subtest 'curseforge resolve pack files' => sub {
    local $config{'curseforge_api_key'} = 'test-key';
    my $calls = 0;
    no warnings 'redefine';
    local *curseforge_fetch_file_record = sub {
        my ($pid, $fid) = @_;
        $calls++;
        return {
            url  => "https://edge.forgecdn.net/files/$pid/$fid/mod.jar",
            meta => {
                fileName => "resolved-$pid-$fid.jar",
                hashes   => [{ value => ('a' x 40), algo => 1 }],
            },
            err => undef,
        };
    };
    my @progress;
    my ($ok, $files, $err) = curseforge_resolve_pack_files({
        format => 'curseforge',
        files  => [
            { project_id => 616555, file_id => 5623665, required => 1, env => 'server' },
        ],
    }, throttle_sec => 0, progress_cb => sub { push @progress, [@_] });
    ok($ok, 'resolve pack files ok');
    is($err, undef, 'no resolve error');
    is(scalar @$files, 1, 'one resolved entry');
    is($files->[0]->{path}, 'mods/resolved-616555-5623665.jar', 'resolved path from API meta');
    is($files->[0]->{downloads}[0], 'https://edge.forgecdn.net/files/616555/5623665/mod.jar', 'CDN url stored');
    is($calls, 1, 'one API record fetch per mod');
    is(scalar @progress, 1, 'progress callback on last mod');
    is($progress[0][0], 1, 'progress done count');
};

subtest 'curseforge resolve checkpoint resume' => sub {
    local $config{'curseforge_api_key'} = 'test-key';
    my $tmpdir = tempdir(CLEANUP => 1);
    my $job_dir = "$tmpdir/job";
    mkdir $job_dir, 0755 or die $!;
    my $calls = 0;
    no warnings 'redefine';
    local *curseforge_fetch_file_record = sub {
        my ($pid, $fid) = @_;
        $calls++;
        return {
            url  => "https://edge.forgecdn.net/files/$pid/$fid/mod.jar",
            meta => {
                fileName => "resolved-$pid-$fid.jar",
                hashes   => [{ value => ('b' x 40), algo => 1 }],
            },
            err => undef,
        };
    };
    my @pack_files = (
        { project_id => 1, file_id => 10, env => 'server' },
        { project_id => 2, file_id => 20, env => 'server' },
        { project_id => 3, file_id => 30, env => 'server' },
    );
    my @partial = (
        {
            path => 'mods/resolved-1-10.jar',
            downloads => ['https://edge.forgecdn.net/files/1/10/mod.jar'],
            hashes => { sha1 => ('b' x 40) },
            project_id => 1, file_id => 10, source => 'curseforge', env => 'server',
        },
        undef,
        undef,
    );
    modpack_write_cf_resolve_checkpoint($job_dir, \@partial, scalar @pack_files, undef);
    my ($ok, $files, $err) = curseforge_resolve_pack_files({
        format => 'curseforge',
        files  => [@pack_files],
    }, checkpoint_job => $job_dir, throttle_sec => 0);
    ok($ok, 'checkpoint resume ok');
    is($err, undef, 'no error');
    is($calls, 2, 'only unresolved mods hit API');
    is(scalar @$files, 3, 'three resolved entries');
    ok(_modpack_entry_has_download($files->[0]), 'first from checkpoint');
    ok(_modpack_entry_has_download($files->[1]), 'second resolved');
    ok(_modpack_entry_has_download($files->[2]), 'third resolved');
};

subtest 'cf resolve checkpoint merge pads short arrays' => sub {
    my $total = 5;
    my $cp = {
        total    => $total,
        resolved => [
            {
                path      => 'mods/a.jar',
                downloads => ['https://example/a.jar'],
            },
        ],
    };
    my @merged = modpack_cf_resolve_merge_checkpoint($cp, $total);
    is(scalar @merged, $total, 'padded to total');
    ok(_modpack_entry_has_download($merged[0]), 'first entry kept');
    ok(!defined $merged[1], 'second slot empty');
    is(modpack_cf_resolve_done_count(\@merged), 1, 'done count');
};

subtest 'curseforge rate limit error message' => sub {
    my %text = (
        mc_modpack_curseforge_rate_limited =>
            'Rate limit at mod $1 (project $2, file $3).',
    );
    my $msg = mc_modpack_error_message('curseforge_rate_limited', {
        mod_num    => 91,
        project_id => '12345',
        file_id    => '67890',
    }, {}, \%text);
    like($msg, qr/Rate limit at mod 91/, 'rate limit message includes mod number');
    like($msg, qr/12345/, 'includes project id');
};

subtest 'curseforge cdn bulk info and cdn rate limit message' => sub {
    is(modpack_cf_cdn_bulk_threshold(), 90, 'default bulk threshold');
    ok(!modpack_is_cf_bulk_pack_meta({ format => 'curseforge', files => [ (1) x 50 ] }),
        'small cf pack not bulk');
    ok(modpack_is_cf_bulk_pack_meta({ format => 'curseforge', files => [ (1) x 100 ] }),
        'large cf pack is bulk');
    my %text = (
        mc_modpack_cf_bulk_install_info => 'Bulk pack $1 mods hint.',
        mc_modpack_curseforge_cdn_rate_limited =>
            'CDN limit mod $1 file $2 total $3.',
    );
    is(modpack_cf_bulk_install_info_message(324, \%text),
        'Bulk pack 324 mods hint.', 'bulk install info');
    my $cdn = mc_modpack_error_message('curseforge_cdn_rate_limited', {
        mod_num  => 95,
        basename => 'SmoothFont.zip',
        total    => 324,
    }, {}, \%text);
    like($cdn, qr/CDN limit mod 95/, 'cdn rate limit message');
};

subtest 'curseforge auto-resume helpers' => sub {
    local $ENV{WEBCORE_CF_COOLDOWN_SEC} = 900;
    local $ENV{WEBCORE_CF_AUTO_RESUME_EXTRA_SEC} = 30;
    is(modpack_cf_auto_resume_wait_sec(), 930, 'auto-resume wait ~15.5 min');
    local $config{modpack_cf_auto_resume} = '0';
    ok(!modpack_cf_auto_resume_enabled(), 'disabled by default');
    local $config{modpack_cf_auto_resume} = '1';
    ok(modpack_cf_auto_resume_enabled(), 'enabled when config=1');
};

subtest 'cf rate limit cooldown sleep' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $job_dir = "$tmpdir/job";
    mkdir $job_dir, 0755 or die $!;
    modpack_write_cf_resolve_checkpoint($job_dir, [], 1, undef, {
        last_rate_limit_at => time() - 1000,
        last_fail_index    => 0,
    });
    is(modpack_cf_apply_rate_limit_cooldown($job_dir), 0, 'no wait when cooldown elapsed');
    local $ENV{WEBCORE_CF_COOLDOWN_SEC} = 2;
    modpack_write_cf_resolve_checkpoint($job_dir, [], 1, undef, {
        last_rate_limit_at => time() - 1,
        last_fail_index    => 0,
    });
    my $slept = modpack_cf_apply_rate_limit_cooldown($job_dir);
    ok($slept >= 0 && $slept <= 2, 'short cooldown waits remaining seconds');
};

subtest 'modpack install progress scan' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $job_dir = "$tmpdir/job";
    my $server_dir = "$tmpdir/server";
    mkdir $job_dir, 0755 or die $!;
    mkdir $server_dir, 0755 or die $!;
    mkdir "$server_dir/serverfiles", 0755 or die $!;
    mkdir "$server_dir/serverfiles/mods", 0755 or die $!;
    my $jar = "$server_dir/serverfiles/mods/already.jar";
    open my $bf, '>', $jar or die $!;
    print $bf 'ok-content';
    close $bf;
    my $sha1 = `sha1sum '$jar' 2>/dev/null`;
    skip 'sha1sum unavailable', 7 unless $sha1 =~ /^([0-9a-f]{40})/i;
    $sha1 = $1;
    open my $fh, '>', "$job_dir/pack_meta.json" or die $!;
    print $fh encode_json({
        mod_dir    => 'mods',
        server_dir => $server_dir,
        files      => [
            { path => 'mods/already.jar', hashes => { sha1 => $sha1 } },
            { path => 'mods/missing.jar',  hashes => {} },
        ],
    });
    close $fh;

    my $prog = modpack_install_progress($job_dir, $server_dir);
    ok($prog, 'progress hash');
    is($prog->{total}, 2, 'total mods');
    is($prog->{installed}, 1, 'one mod on disk');
    is($prog->{missing}, 1, 'one missing');
    is($prog->{resume_index}, 1, 'resume at second mod');
    my $meta = decode_json(do { open my $m, '<', "$job_dir/pack_meta.json"; local $/; <$m> });
    ok(modpack_entry_installed($meta->{files}[0], $jar), 'installed check with sha1');
    ok(!modpack_entry_installed($meta->{files}[1], "$server_dir/serverfiles/mods/missing.jar"),
        'missing mod not installed');
};

subtest 'modpack progress via mc_mods_index placeholder path' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $job_dir = "$tmpdir/job";
    my $server_dir = "$tmpdir/server";
    mkdir $job_dir, 0755 or die $!;
    mkdir $server_dir, 0755 or die $!;
    mkdir "$server_dir/serverfiles", 0755 or die $!;
    mkdir "$server_dir/serverfiles/mods", 0755 or die $!;
    my $real = 'sound-physics-remastered-fabric-1.21.1-1.4.2.jar';
    open my $bf, '>', "$server_dir/serverfiles/mods/$real" or die $!;
    print $bf 'cf-mod-bytes';
    close $bf;
    open my $if, '>', "$server_dir/.mc_mods_index.json" or die $!;
    print $if encode_json({
        "mods/$real" => {
            source     => 'curseforge',
            project_id => 616555,
            file_id    => 5623665,
            env        => 'server',
        },
    });
    close $if;
    open my $fh, '>', "$job_dir/pack_meta.json" or die $!;
    print $fh encode_json({
        mod_dir    => 'mods',
        server_dir => $server_dir,
        files      => [
            { path => 'mods/mod-616555-5623665.jar', project_id => 616555, file_id => 5623665 },
            { path => 'mods/missing.jar' },
        ],
    });
    close $fh;

    my $prog = modpack_install_progress($job_dir, $server_dir);
    ok($prog, 'progress with index lookup');
    is($prog->{installed}, 1, 'indexed mod counts as installed');
    is($prog->{missing}, 1, 'second mod still missing');
    is($prog->{resume_index}, 1, 'resume at missing mod');
    my ($ok, $dest, $base) = modpack_mod_installed_for_index($job_dir, $server_dir, 0);
    ok($ok, 'mod 0 installed via index');
    like($dest, qr/\Q$real\E\z/, 'resolved real dest path');
    is($base, $real, 'resolved display basename');
};

subtest 'modpack bootstrap matches disk via CF cache sha1' => sub {
    local $config{'curseforge_api_key'} = 'test-key';
    my $tmpdir = tempdir(CLEANUP => 1);
    my $job_dir = "$tmpdir/job";
    my $server_dir = "$tmpdir/server";
    mkdir $job_dir, 0755 or die $!;
    mkdir $server_dir, 0755 or die $!;
    mkdir "$server_dir/serverfiles", 0755 or die $!;
    mkdir "$server_dir/serverfiles/mods", 0755 or die $!;
    my $real = 'sound-physics-remastered-neoforge-1.21.1-1.5.1.jar';
    my $sha1 = 'a' x 40;
    open my $bf, '>', "$server_dir/serverfiles/mods/$real" or die $!;
    print $bf 'cf-mod-bytes';
    close $bf;
    no warnings 'redefine';
    local *curseforge_fetch_file_record = sub {
        return {
            url  => 'https://edge.forgecdn.net/files/535489/7032247/mod.jar',
            meta => {
                fileName => $real,
                hashes   => [{ value => $sha1, algo => 1 }],
            },
        };
    };
    local *_modpack_file_sha1 = sub {
        my ($path) = @_;
        return $sha1 if $path =~ /\Q$real\E/;
        return undef;
    };
    open my $fh, '>', "$job_dir/pack_meta.json" or die $!;
    print $fh encode_json({
        mod_dir    => 'mods',
        server_dir => $server_dir,
        format     => 'curseforge',
        files      => [
            { path => 'mods/mod-535489-7032247.jar', project_id => 535489, file_id => 7032247 },
        ],
    });
    close $fh;
    ok(modpack_bootstrap_installed_from_disk($job_dir, $server_dir, undef), 'bootstrap ok');
    my $prog = modpack_install_progress($job_dir, $server_dir);
    ok($prog, 'progress after bootstrap');
    is($prog->{installed}, 1, 'placeholder meta counts installed mod on disk');
};

subtest 'modpack install progress light uses state file' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $job_dir = "$tmpdir/job";
    my $server_dir = "$tmpdir/server";
    mkdir $job_dir, 0755 or die $!;
    mkdir $server_dir, 0755 or die $!;
    open my $fh, '>', "$job_dir/pack_meta.json" or die $!;
    print $fh encode_json({
        mod_dir    => 'mods',
        server_dir => $server_dir,
        files      => [
            { path => 'mods/a.jar' },
            { path => 'mods/b.jar' },
        ],
    });
    close $fh;
    ok(modpack_write_install_state($job_dir, {
        total         => 2,
        installed     => 1,
        missing       => 1,
        resume_index  => 1,
        last_basename => 'a.jar',
        completed     => { 0 => 'a.jar' },
    }), 'write install state');
    my $light = modpack_install_progress_light($job_dir, $server_dir);
    ok($light, 'light progress');
    is($light->{installed}, 1, 'from state file');
    is($light->{resume_index}, 1, 'resume from state');
};

subtest 'modpack ensure dir idempotent' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $dir = "$tmpdir/upload";
    ok(_modpack_ensure_dir($dir, 0755), 'creates upload dir');
    ok(-d $dir, 'upload dir exists');
    ok(_modpack_ensure_dir($dir, 0755), 'existing upload dir ok');
};

subtest 'adopt profile from modpack meta' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $job_dir = "$tmpdir/job";
    my $server_dir = "$tmpdir/server";
    mkdir $job_dir, 0755 or die $!;
    mkdir $server_dir, 0755 or die $!;

    # Provisional profile: right loader, but no pinned loader version.
    my $prov = build_mc_profile('neoforge', '1.21.1');
    $prov->{'eula_accepted'} = 1;
    open my $pf, '>', "$server_dir/.mcprofile.json" or die $!;
    print $pf encode_mc_profile($prov);
    close $pf;

    my $captured;
    no warnings 'redefine';
    local *write_mc_profile = sub {
        my ($sd, $user, $profile) = @_;
        $captured = $profile;
        return 1;
    };

    my $write_meta = sub {
        my ($extra) = @_;
        open my $fh, '>', "$job_dir/pack_meta.json" or die $!;
        print $fh encode_json({
            format     => 'curseforge',
            server_dir => $server_dir,
            files      => [{ path => 'mods/a.jar' }],
            pack_file  => "$job_dir/pack.zip",
            %{ $extra || {} },
        });
        close $fh;
    };

    # No adopt flag -> no-op, no profile write.
    $write_meta->({});
    my ($ok, $code) = modpack_adopt_profile_from_meta($job_dir, $server_dir, 'gameuser');
    ok($ok, 'no-adopt returns ok');
    is($code, 'not_adopt', 'not adopt when flag missing');
    ok(!defined $captured, 'profile not written without adopt flag');

    # Adopt with pinned loader version -> profile rewritten with the pin.
    $write_meta->({
        adopt_profile       => 1,
        pack_loader         => 'neoforge',
        pack_mc_version     => '1.21.1',
        pack_loader_version => '21.1.211',
    });
    ($ok, $code, my $detail) = modpack_adopt_profile_from_meta($job_dir, $server_dir, 'gameuser');
    ok($ok, 'adopt returns ok');
    is($code, 'adopted', 'adopted when flag + pinned version differ');
    ok($captured, 'profile captured');
    is($captured->{'loader'}, 'neoforge', 'loader from pack');
    is($captured->{'mc_version'}, '1.21.1', 'mc from pack');
    is($captured->{'loader_version'}, '21.1.211', 'pinned loader version adopted');
    is($captured->{'eula_accepted'}, 1, 'eula preserved');

    # Second adopt with identical values -> unchanged (idempotent).
    $captured = undef;
    open my $pf2, '>', "$server_dir/.mcprofile.json" or die $!;
    print $pf2 encode_mc_profile($detail ? build_mc_profile('neoforge', '1.21.1', { loader_version => '21.1.211' }) : $prov);
    close $pf2;
    ($ok, $code) = modpack_adopt_profile_from_meta($job_dir, $server_dir, 'gameuser');
    ok($ok, 'second adopt ok');
    is($code, 'unchanged', 'no rewrite when already pinned');
};

subtest 'validate_modpack_import_path symlink hardening' => sub {
    plan tests => 5;
    my $tmp = tempdir(CLEANUP => 1);
    die 'tempdir failed' unless defined $tmp && $tmp ne '';
    my $home = "$tmp/home/guser";
    my $server = "$home/mcserver";
    require File::Path;
    File::Path::make_path($server) or die "make_path $server: $!";
    my $pack = "$server/inside.mrpack";
    open my $pf, '>', $pack or die $!;
    print $pf 'x';
    close $pf;
    my $outside = "$tmp/outside-secret.mrpack";
    open my $of, '>', $outside or die $!;
    print $of 'secret';
    close $of;

    my ($ok, $resolved, $err) = validate_modpack_import_path($pack, 'guser', $server);
    ok($ok, 'pack inside server_dir accepted');
    is($resolved, $pack, 'resolved path returned');

    symlink($outside, "$server/escape.mrpack") or die "symlink: $!";
    ($ok, $resolved, $err) = validate_modpack_import_path("$server/escape.mrpack", 'guser', $server);
    ok(!$ok, 'symlink escape rejected');
    is($err, 'outside', 'outside error code');

    ($ok, $resolved, $err) = validate_modpack_import_path("$server/../outside-secret.mrpack", 'guser', $server);
    ok(!$ok && $err eq 'invalid', '.. in path rejected');
};

done_testing();
