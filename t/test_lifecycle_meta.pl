#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
our $module_root = "$FindBin::Bin/../src";
require "$module_root/lib/games_meta.pl";

my $pz = get_lifecycle_config('pzserver');
ok(length($pz->{regex}), 'pz ready regex');
cmp_ok($pz->{stall_secs}, '==', 120, 'pz stall warn default/meta');
cmp_ok($pz->{stall_fail_secs}, '==', 300, 'pz stall fail');
ok(@{ $pz->{start_phases} } >= 2, 'pz has start phases');
ok((grep { $_->{id} eq 'ready' } @{ $pz->{start_phases} }), 'pz ready phase');

my $mc = get_lifecycle_config('mcserver');
like($mc->{regex}, qr/Done/, 'mc ready Done');
ok((grep { $_->{id} eq 'preparing' } @{ $mc->{start_phases} }), 'mc preparing phase');

my $mc_var = get_lifecycle_config('mc-neoforge');
like($mc_var->{regex}, qr/Done/, 'mc-neoforge inherits from mcserver variants');

my $wr = get_lifecycle_config('windrose');
like($wr->{regex}, qr/GenlandiaMulty/, 'windrose ready GenlandiaMulty');
is($wr->{log}, 'live_log', 'windrose uses live_log');
ok(length($wr->{live_log_path} // ''), 'windrose live_log_path set');

my $pw = get_lifecycle_config('pwserver');
like($pw->{regex}, qr/Running Palworld dedicated server on/, 'palworld ready line');
is($pw->{log}, 'console', 'palworld uses console log');

my $none = get_lifecycle_config('unknownserverxyz');
is($none->{regex}, '', 'unknown → empty regex');
cmp_ok($none->{stall_secs}, '==', 120, 'unknown still gets stall defaults');

# Workshop tier mapper (pure; no INI/disk)
my $t0 = workshop_start_scale_tier(0);
cmp_ok($t0->{ready_secs}, '==', 900, 'workshop tier 0–9 ready');
cmp_ok($t0->{stall_secs}, '==', 120, 'workshop tier 0–9 stall warn');
cmp_ok($t0->{stall_fail_secs}, '==', 300, 'workshop tier 0–9 stall fail');

my $t25 = workshop_start_scale_tier(25);
cmp_ok($t25->{ready_secs}, '==', 1200, 'workshop 25 items → ready 1200');
cmp_ok($t25->{stall_secs}, '==', 180, 'workshop 25 stall warn 180');
cmp_ok($t25->{stall_fail_secs}, '==', 420, 'workshop 25 stall fail 420');

my $t40 = workshop_start_scale_tier(40);
cmp_ok($t40->{ready_secs}, '==', 1500, 'workshop 40 → ready 1500');

my $t60 = workshop_start_scale_tier(60);
cmp_ok($t60->{ready_secs}, '==', 1800, 'workshop ≥50 → ready 1800');
cmp_ok($t60->{stall_secs}, '==', 300, 'workshop ≥50 stall warn');
cmp_ok($t60->{stall_fail_secs}, '==', 600, 'workshop ≥50 stall fail');

is(get_workshop_start_scale('mcserver', 'nobody', '/tmp'), undef,
    'non-workshop game → undef scale');

done_testing();
