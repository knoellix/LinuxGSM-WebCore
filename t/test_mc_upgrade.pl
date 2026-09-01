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
done_testing();
