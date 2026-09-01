#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

require "$Bin/stubs.pl";
our $module_root = "$Bin/../src";

require "$Bin/../src/lib/mc_loader.pl";
require "$Bin/../src/lib/mc_profile.pl";
require "$Bin/../src/lib/jobs.pl";
require "$Bin/../src/lib/mc_mods.pl";
require "$Bin/../src/lib/mc_upgrade.pl";

my $profile = {
    loader         => 'neoforge',
    mc_version     => '26.1.2',
    loader_version => '26.1.2.80',
    lgsm_script    => 'mcserver',
    java_major     => 21,
    java_home      => 'java/21',
};

my @neo26 = qw(26.1.2.80 26.1.2.95 26.1.1.10);
mc_upgrade_set_loader_versions_for_test(@neo26);

subtest 'validate loader target' => sub {
    is(mc_upgrade_validate_loader_target($profile, '26.1.2.95', \@neo26),
        undef, 'accept newer neoforge pin');
    is(mc_upgrade_validate_loader_target($profile, '26.1.2.80', \@neo26),
        'not_newer', 'reject same or older pin');
    is(mc_upgrade_validate_loader_target($profile, '26.1.1.10', \@neo26),
        'invalid_target', 'reject wrong mc line');
    is(mc_upgrade_validate_loader_target($profile, 'nope', \@neo26),
        'invalid_target', 'reject garbage pin');
};

subtest 'upgrade candidates' => sub {
    my @candidates = mc_upgrade_loader_upgrade_candidates($profile, \@neo26);
    is_deeply(\@candidates, ['26.1.2.95'], 'only newer than current pin');
};

subtest 'loader plan' => sub {
    my ($ok, $plan, $err) = mc_upgrade_loader_plan($profile, '26.1.2.95', \@neo26);
    ok($ok, 'plan ok') or diag($err // 'unknown');
    is($plan->{'mode'}, 'loader', 'loader mode');
    is($plan->{'target_loader_version'}, '26.1.2.95', 'target pin');
    is($plan->{'mc_version'}, '26.1.2', 'mc version kept');
};

subtest 'preflight offline and jobs' => sub {
    my $pf_ok = mc_upgrade_preflight(
        { user => 'testuser' },
        $profile,
        '/tmp/server',
        { mode => 'loader', target_loader_version => '26.1.2.95' },
        { runtime_status => 'offline', instance_id => 'testuser' },
    );
    ok($pf_ok->{'ok'}, 'preflight ok when offline') or diag($pf_ok->{'err'} // '');

    my $pf_online = mc_upgrade_preflight(
        {},
        $profile,
        '/tmp/server',
        { mode => 'loader', target_loader_version => '26.1.2.95' },
        { runtime_status => 'online' },
    );
    ok(!$pf_online->{'ok'}, 'preflight rejects online server');
    is($pf_online->{'err'}, 'server_must_be_stopped', 'online error token');
};

subtest 'write_upgrade_job_plan' => sub {
    require File::Temp;
    my $tmpdir = File::Temp::tempdir(CLEANUP => 1);
    ok(write_upgrade_job_plan($tmpdir, { mode => 'loader', target_loader_version => '26.1.2.95' }),
        'plan written');
    ok(-f "$tmpdir/upgrade_plan.json", 'upgrade_plan.json exists');
};

mc_upgrade_clear_loader_versions_for_test();

my $profile_mc = {
    loader         => 'neoforge',
    mc_version     => '1.20.4',
    loader_version => '20.4.10',
    java_major     => 21,
    java_home      => '.java/temurin-21',
    lgsm_script    => 'mcserver',
    mod_dir        => 'mods',
};

subtest 'MC version upgrade candidates and validation' => sub {
    mc_upgrade_set_mc_versions_for_test(
        qw(1.16.5 1.20.4 1.20.6 1.21.1 26.1.2)
    );
    my @candidates = mc_upgrade_mc_upgrade_candidates($profile_mc);
    ok(grep { $_ eq '1.21.1' } @candidates, '1.21.1 is upgrade candidate from 1.20.4');
    ok(!grep { $_ eq '1.20.4' } @candidates, 'current mc not listed');
    ok(!grep { $_ eq '1.16.5' } @candidates, 'downgrade not listed');

    is(mc_upgrade_validate_mc_target($profile_mc, '1.21.1'), undef, '1.21.1 valid target');
    is(mc_upgrade_validate_mc_target($profile_mc, '1.20.4'), 'same_version', 'same version rejected');
    is(mc_upgrade_validate_mc_target($profile_mc, '1.16.5'), 'not_newer', 'downgrade rejected');
    mc_upgrade_clear_mc_versions_for_test();
};

subtest 'MC plan detects Java major change' => sub {
    my $profile_old = {
        loader      => 'neoforge',
        mc_version  => '1.16.5',
        java_major  => 8,
        java_home   => '.java/temurin-8',
        lgsm_script => 'mcserver',
        mod_dir     => 'mods',
    };
    mc_upgrade_set_mc_versions_for_test(qw(1.16.5 1.20.4 1.21.1));
    my ($ok, $plan, $err) = mc_upgrade_mc_plan($profile_old, '1.20.4');
    ok($ok, 'mc plan with java bump') or diag($err // 'unknown');
    is($plan->{'target_java_major'}, 21, 'target java 21');
    ok($plan->{'needs_java'}, 'needs java when major changes 8->21');
    mc_upgrade_clear_mc_versions_for_test();

    mc_upgrade_set_mc_versions_for_test(qw(1.20.4 1.21.1));
    my ($ok2, $plan2) = mc_upgrade_mc_plan($profile_mc, '1.21.1');
    ok($ok2, 'mc plan for 1.21.1');
    ok(!$plan2->{'needs_java'}, 'no java step when major stays 21');
    mc_upgrade_clear_mc_versions_for_test();
};

subtest 'MC preflight' => sub {
    mc_upgrade_set_mc_versions_for_test(qw(1.20.4 1.21.1));
    my $pf = mc_upgrade_preflight(
        {}, $profile_mc, '/tmp/srv',
        { mode => 'mc', target_mc_version => '1.21.1' },
        { runtime_status => 'offline', instance_id => 'u1' },
    );
    ok($pf->{'ok'}, 'mc preflight offline ok');
    mc_upgrade_clear_mc_versions_for_test();
};

subtest 'mod compat report for MC upgrade' => sub {
    no warnings 'redefine';
    local *list_installed_mods = sub {
        return [
            {
                source           => 'modrinth',
                project_id       => 'balm',
                title            => 'Balm',
                basename         => 'balm.jar',
                has_update_meta  => 1,
                enabled          => 1,
            },
            {
                source           => 'modrinth',
                project_id       => 'farming-for-blockheads',
                title            => 'Farming',
                basename         => 'farming.jar',
                has_update_meta  => 1,
                enabled          => 1,
            },
            {
                source           => 'modrinth',
                project_id       => 'manual-mod',
                basename         => 'manual.jar',
                has_update_meta  => 0,
                enabled          => 1,
            },
        ];
    };
    mc_upgrade_set_mod_compat_for_test('modrinth', 'balm', 1);
    mc_upgrade_set_mod_compat_for_test('modrinth', 'farming-for-blockheads', 0);

    my $report = mc_upgrade_mod_compat_report('/tmp/srv', $profile_mc, '1.21.1');
    is($report->{'target_mc_version'}, '1.21.1', 'target mc in report');
    is($report->{'total'}, 2, 'two indexed mods');
    is(scalar @{ $report->{'compatible'} // [] }, 1, 'one compatible');
    is(scalar @{ $report->{'incompatible'} // [] }, 1, 'one incompatible');
    is($report->{'incompatible'}[0]{'project_id'}, 'farming-for-blockheads', 'farming incompatible');

    mc_upgrade_clear_mod_compat_for_test();
};

mc_upgrade_clear_loader_versions_for_test();
done_testing();
