#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 6;
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
