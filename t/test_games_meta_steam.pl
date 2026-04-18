#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 8;
use File::Temp qw(tempdir);
use JSON::PP;

# Bootstrap
use FindBin qw($Bin);
require "$Bin/stubs.pl";

# Point module_root at src/ so the real games_meta.json is loaded
our ($module_root, $config_directory);
$module_root      = "$Bin/../src";
$config_directory = '/dev/null';

require "$Bin/../src/lib/games_meta.pl";

# Test 1: csgoserver requires steam
ok(game_requires_steam('csgoserver'), 'csgoserver requires steam');

# Test 2: mcserver does not require steam
ok(!game_requires_steam('mcserver'), 'mcserver does not require steam');

# Test 3: vhserver (Valheim) requires steam
ok(game_requires_steam('vhserver'), 'vhserver requires steam');

# Test 4: unknown game returns false (safe default)
ok(!game_requires_steam('unknowngameXYZ'), 'unknown game returns false');

# Test 5: rustserver requires steam
ok(game_requires_steam('rustserver'), 'rustserver requires steam');

# Test 6: factorioserver does not require steam
ok(!game_requires_steam('factorioserver'), 'factorioserver does not require steam');

# Test 7: pwserver (Palworld) requires steam
ok(game_requires_steam('pwserver'), 'pwserver requires steam');

# Test 8: projectzomboidserver does not require steam
ok(!game_requires_steam('projectzomboidserver'), 'projectzomboidserver does not require steam');
