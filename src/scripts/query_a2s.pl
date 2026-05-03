#!/usr/bin/perl
use strict;
use warnings;

my ($host, $port) = @ARGV;
die "Usage: query_a2s.pl <host> <port>\n" unless $host && $port;

use FindBin qw($Bin);
require "$Bin/../lib/query.pl";

my $result = a2s_query($host, int($port), 2);
unless ($result) {
    print STDERR "A2S query failed: $host:$port\n";
    exit 1;
}
printf '{"players":%d,"max":%d}' . "\n", $result->{players}, $result->{max};
exit 0;
