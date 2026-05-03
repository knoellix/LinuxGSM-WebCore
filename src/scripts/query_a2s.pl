#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);

require "$Bin/../lib/query.pl";

my ($host, $port) = @ARGV;
die "Usage: query_a2s.pl <host> <port>\n" unless $host && $port;
die "Invalid port: $port\n" unless $port =~ /^\d+$/ && $port > 0 && $port < 65536;

my $result = a2s_query($host, int($port), 2);
unless ($result) {
    print STDERR "A2S query failed: $host:$port\n";
    exit 1;
}
printf '{"players":%d,"max":%d}' . "\n", $result->{players}, $result->{max};
exit 0;
