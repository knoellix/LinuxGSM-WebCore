#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../src/lib";

# Minimal bootstrap: set $module_root for load_games_meta
our $module_root = "$FindBin::Bin/../src";
require "$module_root/lib/games_meta.pl";

my $pz = get_start_ready_config('pzserver');
ok(length($pz->{regex}), 'pzserver has ready regex');
like($pz->{regex}, qr/SERVER STARTED/, 'pz marker mentions SERVER STARTED');
cmp_ok($pz->{secs}, '>=', 60, 'pz timeout sensible');
is($pz->{log}, 'console', 'pz uses console log');

my $none = get_start_ready_config('unknownserverxyz');
is($none->{regex}, '', 'unknown game → no regex');
is($none->{log}, '', 'unknown game → no log');
is($none->{secs}, 0, 'unknown game → no timeout');

done_testing();
