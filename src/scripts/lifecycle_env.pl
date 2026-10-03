#!/usr/bin/env perl
# Dump start/stop lifecycle meta as KEY=value for bash eval.
# Usage: perl lifecycle_env.pl <script_name> [unix_user] [server_dir]
# Prints: READY_LOG, READY_REGEX, READY_SECS, STALL_SECS, STALL_FAIL_SECS,
#         STOP_GRACE, STOP_FORCE, LIVE_LOG_REL,
#         START_PHASE_N=id|match, STOP_PHASE_N=id|match
# When mod_support=workshop: WORKSHOP_STALL_PAUSE=1; with unix_user+server_dir,
# also WORKSHOP_ITEMS / WORKSHOP_PENDING and ready/stall overrides from scale tier.
# Values are single-quoted for safe bash eval (phases contain | and regexes contain *).
use strict;
use warnings;
use FindBin qw($Bin);

our $module_root = "$Bin/..";
require "$Bin/../lib/games_meta.pl";

my $script = $ARGV[0] // '';
if ($script eq '') {
    print STDERR "Usage: lifecycle_env.pl <script_name> [unix_user] [server_dir]\n";
    exit 2;
}

my $unix_user  = $ARGV[1] // '';
my $server_dir = $ARGV[2] // '';

my $c = get_lifecycle_config($script);

sub _bash_kv {
    my ($k, $v) = @_;
    $v //= '';
    $v =~ s/'/'\\''/g;
    printf "%s='%s'\n", $k, $v;
}

_bash_kv('READY_LOG',   $c->{log} // '');
_bash_kv('READY_REGEX', $c->{regex} // '');
_bash_kv('READY_SECS',  int($c->{secs} || 900));
_bash_kv('STALL_SECS',  int($c->{stall_secs} // 0));
_bash_kv('STALL_FAIL_SECS', int($c->{stall_fail_secs} // 0));
_bash_kv('STOP_GRACE',  int($c->{stop_grace_secs} // 0));
_bash_kv('STOP_FORCE',  int($c->{stop_force_secs} // 0));
_bash_kv('LIVE_LOG_REL', $c->{live_log_path} // '');

my $i = 0;
for my $p (@{ $c->{start_phases} // [] }) {
    _bash_kv("START_PHASE_$i", ($p->{id} // '') . '|' . ($p->{match} // ''));
    $i++;
}
$i = 0;
for my $p (@{ $c->{stop_phases} // [] }) {
    _bash_kv("STOP_PHASE_$i", ($p->{id} // '') . '|' . ($p->{match} // ''));
    $i++;
}

if (get_game_mod_support($script) eq 'workshop') {
    _bash_kv('WORKSHOP_STALL_PAUSE', 1);
    if (length($unix_user) && length($server_dir)) {
        my $scale = get_workshop_start_scale($script, $unix_user, $server_dir);
        if (ref($scale) eq 'HASH') {
            _bash_kv('WORKSHOP_ITEMS',   int($scale->{items} // 0));
            _bash_kv('WORKSHOP_PENDING', int($scale->{pending} // 0));
            _bash_kv('READY_SECS',       int($scale->{ready_secs} // 900));
            _bash_kv('STALL_SECS',       int($scale->{stall_secs} // 120));
            _bash_kv('STALL_FAIL_SECS',  int($scale->{stall_fail_secs} // 300));
        }
    }
}

exit 0;
