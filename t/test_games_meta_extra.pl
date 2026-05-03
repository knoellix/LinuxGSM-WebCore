#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 12;
use FindBin qw($Bin);
require "$Bin/stubs.pl";
our $module_root;
$module_root = "$Bin/../src";
require "$Bin/../src/lib/games_meta.pl";

# get_game_default_port
is(get_game_default_port('mcserver'),  25565, 'mcserver default port 25565');
is(get_game_default_port('vhserver'),  2456,  'vhserver default port 2456');
is(get_game_default_port('UNKNOWN'),   27015, 'unknown game falls back to 27015');

# get_game_display_name
like(get_game_display_name('mcserver'), qr/Minecraft/i, 'mcserver display name contains Minecraft');
like(get_game_display_name('vhserver'), qr/Valheim/i,   'vhserver display name contains Valheim');
is(get_game_display_name('UNKNOWN'),   'UNKNOWN',       'unknown game returns script name');

# Multi-port games (UE5/Windrose) must declare port/queryport/beaconport.
# Otherwise multiple instances on one host collide silently on the UE5 defaults
# (7777/27015/15000) — the wizard would only set the game port and the worker
# would have nothing else to pass to wine. See steamcmd_control.sh.
my @wf = get_game_fields('windrose');
my %wf_by_key = map { $_->{key} => $_ } @wf;
ok(exists $wf_by_key{'port'},       'windrose has port field');
ok(exists $wf_by_key{'queryport'},  'windrose has queryport field');
ok(exists $wf_by_key{'beaconport'}, 'windrose has beaconport field');
is($wf_by_key{'port'}{'default'},       '7777',  'windrose port default 7777');
is($wf_by_key{'queryport'}{'default'},  '27015', 'windrose queryport default 27015');
is($wf_by_key{'beaconport'}{'default'}, '15000', 'windrose beaconport default 15000');
