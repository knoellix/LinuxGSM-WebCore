#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);

require "$Bin/stubs.pl";
our (%config, $module_root);
$config{'modrinth_contact'} = 'LinuxGSM-WebCore-Test/1.0 (test@example.com)';

require "$Bin/../src/lib/module_config.pl";
require "$Bin/../src/lib/mc_mods.pl";

sub _read_json_fixture {
    my ($name) = @_;
    open my $fh, '<', "$Bin/fixtures/mc_mods/$name" or die "fixture $name: $!";
    local $/;
    my $raw = <$fh>;
    close $fh;
    require JSON::PP;
    return JSON::PP::decode_json($raw);
}

# --- normalize_mod_dependency_type ---

is(normalize_mod_dependency_type('required'), 'required', 'modrinth required');
is(normalize_mod_dependency_type('OPTIONAL'), 'optional', 'modrinth optional case');
is(normalize_mod_dependency_type('embedded'), 'embedded', 'modrinth embedded');
is(normalize_mod_dependency_type('incompatible'), 'incompatible', 'modrinth incompatible');
is(normalize_mod_dependency_type(3), 'required', 'cf required');
is(normalize_mod_dependency_type(2), 'optional', 'cf optional');
is(normalize_mod_dependency_type(1), 'embedded', 'cf embedded library');
is(normalize_mod_dependency_type(5), 'incompatible', 'cf incompatible');
is(normalize_mod_dependency_type('nope'), 'unknown', 'unknown type');

ok(mod_dependency_type_installable('required'), 'required installable');
ok(mod_dependency_type_installable('optional'), 'optional installable');
ok(!mod_dependency_type_installable('embedded'), 'embedded not installable');
ok(!mod_dependency_type_installable('incompatible'), 'incompatible not installable');

# --- modrinth_version_dependencies ---

{
    my $v = _read_json_fixture('modrinth_version_with_dep.json');
    my $deps = modrinth_version_dependencies($v);
    ok(ref($deps) eq 'ARRAY', 'modrinth deps array');
    is(scalar @$deps, 2, 'modrinth skips embedded/incompatible');
    is($deps->[0]{'project_id'}, 'balm', 'balm required');
    is($deps->[0]{'dependency_type'}, 'required', 'balm type');
    is($deps->[0]{'source'}, 'modrinth', 'modrinth source');
    is($deps->[1]{'project_id'}, 'cloth-config', 'optional dep kept');
    is($deps->[1]{'dependency_type'}, 'optional', 'optional type');
    is($deps->[1]{'version_id'}, 'v123', 'optional version pin');
}

is(scalar @{ modrinth_version_dependencies({}) }, 0, 'empty version');
is(scalar @{ modrinth_version_dependencies({ dependencies => [] }) }, 0, 'empty deps');

# --- curseforge_file_dependencies ---

{
    my $f = _read_json_fixture('curseforge_file_with_dep.json');
    my $deps = curseforge_file_dependencies($f);
    ok(ref($deps) eq 'ARRAY', 'cf deps array');
    is(scalar @$deps, 2, 'cf skips embedded/incompatible');
    is($deps->[0]{'project_id'}, '531761', 'cf required modId');
    is($deps->[0]{'dependency_type'}, 'required', 'cf required type');
    is($deps->[0]{'source'}, 'curseforge', 'cf source');
    is($deps->[1]{'project_id'}, '999001', 'cf optional modId');
    is($deps->[1]{'dependency_type'}, 'optional', 'cf optional type');
}

# --- mod_index_has_project + mod_dependency_status ---

subtest 'mod_index_has_project and dependency status' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $profile = { loader => 'neoforge', mc_version => '1.21.1', mod_dir => 'mods' };
    my $sf = "$tmp/serverfiles/mods";
    make_path($sf);

    ok(!mod_index_has_project($tmp, 'modrinth', 'balm', $profile),
        'balm not in empty index');

    write_mc_mods_index($tmp, {
        'mods/balm-1.21.1.jar' => {
            source           => 'modrinth',
            modrinth_project => 'balm',
            modrinth_version => 'ver-balm',
        },
    });
    open my $fh, '>', "$sf/balm-1.21.1.jar" or die $!;
    print $fh 'balm'; close $fh;

    ok(mod_index_has_project($tmp, 'modrinth', 'balm', $profile),
        'balm found in index with jar on disk');

    unlink "$sf/balm-1.21.1.jar";
    ok(!mod_index_has_project($tmp, 'modrinth', 'balm', $profile),
        'stale index entry without jar is not satisfied');

    open my $fh2, '>', "$sf/balm-1.21.1.jar" or die $!;
    print $fh2 'balm'; close $fh2;

    my $ver = _read_json_fixture('modrinth_version_with_dep.json');
    my $deps = modrinth_version_dependencies($ver);

    my $empty_status = mod_dependency_status($tmp, $profile, [
        { project_id => 'balm', dependency_type => 'required', source => 'modrinth' },
    ]);
    is(scalar @{ $empty_status->{'satisfied'} // [] }, 1, 'balm satisfied when indexed');
    is(scalar @{ $empty_status->{'missing'} // [] }, 0, 'no missing when balm present');

    my $tmp2 = tempdir(CLEANUP => 1);
    my $farming_status = mod_dependency_status($tmp2, $profile, $deps);
    is(scalar @{ $farming_status->{'missing'} // [] }, 1, 'balm missing on empty server');
    is($farming_status->{'missing'}[0]{'project_id'}, 'balm', 'missing dep is balm');
    is(scalar @{ $farming_status->{'optional'} // [] }, 1, 'cloth-config optional');
    is($farming_status->{'optional'}[0]{'project_id'}, 'cloth-config', 'optional project');
};

# --- build_mod_install_plan ---

subtest 'build_mod_install_plan resolves missing required deps' => sub {
    no warnings 'redefine';
    my $ver = _read_json_fixture('modrinth_version_with_dep.json');

    local *modrinth_resolve_version_file = sub {
        my ($pid) = @_;
        if ($pid eq 'balm') {
            return {
                version_id   => 'balm-ver',
                filename     => 'balm-1.21.1.jar',
                download_url => 'https://cdn.modrinth.com/data/balm/versions/y/balm.jar',
                hashes       => { sha1 => 'b' x 40 },
                env          => 'server',
            };
        }
        return {
            version_id   => 'abc123',
            filename     => 'farming.jar',
            download_url => 'https://cdn.modrinth.com/data/x/versions/y/farming.jar',
            hashes       => { sha1 => 'a' x 40 },
            env          => 'server',
        };
    };
    local *_modrinth_version_deps_by_id = sub {
        return modrinth_version_dependencies($ver);
    };

    my $tmp = tempdir(CLEANUP => 1);
    my $profile = { loader => 'neoforge', mc_version => '1.21.1', mod_dir => 'mods' };

    my ($ok, $plan, $err) = build_mod_install_plan(
        'modrinth',
        { project_id => 'farming-for-blockheads', title => 'Farming' },
        $profile,
        $tmp,
        { install_deps => 1 },
    );
    ok($ok, 'plan built with install_deps') or diag($err // 'unknown');
    ok(ref($plan) eq 'HASH', 'plan hash');
    is($plan->{'primary'}{'filename'}, 'farming.jar', 'primary farming');
    is(scalar @{ $plan->{'dependencies'} // [] }, 1, 'one dependency resolved');
    is($plan->{'dependencies'}[0]{'project_id'}, 'balm', 'dependency is balm');
    is($plan->{'dependencies'}[0]{'filename'}, 'balm-1.21.1.jar', 'balm filename');
    is(scalar @{ $plan->{'status'}{'missing'} // [] }, 1, 'status still lists missing before install');
};

subtest 'build_mod_install_plan deps_too_many' => sub {
    no warnings 'redefine';
    local *modrinth_resolve_version_file = sub {
        return {
            version_id   => 'main-ver',
            filename     => 'main.jar',
            download_url => 'https://cdn.modrinth.com/data/main/main.jar',
            hashes       => {},
            env          => 'server',
        };
    };
    local *_modrinth_version_deps_by_id = sub {
        my @deps;
        for my $i (1 .. 6) {
            push @deps, {
                project_id      => "dep$i",
                dependency_type => 'required',
                source          => 'modrinth',
            };
        }
        return \@deps;
    };

    my $tmp = tempdir(CLEANUP => 1);
    my ($ok, $plan, $err) = build_mod_install_plan(
        'modrinth',
        { project_id => 'main-mod', title => 'Main' },
        { loader => 'fabric', mc_version => '1.21.1', mod_dir => 'mods' },
        $tmp,
        { install_deps => 1 },
    );
    ok(!$ok, 'plan rejected when too many deps');
    is($err, 'deps_too_many', 'deps_too_many error');
};

subtest 'write_mod_install_plan_job_meta writes plan files' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $primary = {
        source       => 'modrinth',
        project_id   => 'farming-for-blockheads',
        filename     => 'farming.jar',
        download_url => 'https://cdn.modrinth.com/data/x/farming.jar',
        mod_dir      => 'mods',
        title        => 'Farming',
    };
    my $dep = {
        source       => 'modrinth',
        project_id   => 'balm',
        filename     => 'balm.jar',
        download_url => 'https://cdn.modrinth.com/data/balm/balm.jar',
        mod_dir      => 'mods',
        title        => 'Balm',
    };
    ok(write_mod_install_plan_job_meta($tmpdir, {
        primary      => $primary,
        dependencies => [$dep],
    }), 'plan meta written');
    ok(-f "$tmpdir/mod_install_plan.json", 'mod_install_plan.json exists');
    ok(-f "$tmpdir/mod_meta.json", 'mod_meta.json exists');
    ok(-f "$tmpdir/dep_meta_0.json", 'dep_meta_0.json exists');

    open my $pfh, '<', "$tmpdir/mod_install_plan.json" or die $!;
    local $/; my $raw = <$pfh>; close $pfh;
    require JSON::PP;
    my $plan = JSON::PP::decode_json($raw);
    is(scalar @{ $plan->{'install_order'} // [] }, 2, 'install order primary + dep');
    is($plan->{'install_order'}[0], 'dep_meta_0.json', 'deps first');
    is($plan->{'install_order'}[1], 'mod_meta.json', 'primary last');
};

done_testing;
