#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

chdir "$Bin/.." or die "Cannot chdir to repo root: $!\n";

my $file = 'src/integrations.cgi';
open(my $fh, '<', $file) or die "Cannot open $file: $!";
my @lines = <$fh>;
close($fh);

my @redirects;
for (my $i = 0; $i < @lines; $i++) {
    next unless $lines[$i] =~ /&redirect\(/;
    push @redirects, $i;
}

ok(scalar(@redirects) > 0, 'integrations.cgi contains redirects');

for my $idx (@redirects) {
    my $has_exit = 0;
    for my $lookahead (1 .. 4) {
        my $j = $idx + $lookahead;
        last if $j > $#lines;
        if ($lines[$j] =~ /^\s*exit\s*;/) {
            $has_exit = 1;
            last;
        }
        last if $lines[$j] =~ /elsif\s*\(|^\s*}/;
    }
    ok($has_exit, "redirect at line " . ($idx + 1) . " is followed by exit");
}

done_testing();
