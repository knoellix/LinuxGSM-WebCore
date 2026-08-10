#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 3;
use FindBin qw($Bin);

require "$Bin/stubs.pl";
require "$Bin/../src/lib/instance.pl";

is(instance_memory_display_gb(''), '', 'empty user → no display');
is(instance_memory_display_gb('not_a_user'), '', 'invalid user → no display');

my $kb = instance_memory_rss_kb($ENV{USER} // 'root');
ok($kb >= 0, 'instance_memory_rss_kb returns non-negative for current user');
