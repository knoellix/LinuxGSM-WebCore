#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

require "$Bin/stubs.pl";
require "$Bin/../src/lib/server_log.pl";

my $root = tempdir(CLEANUP => 1);
my $logs = "$root/serverfiles/logs";
system('mkdir', '-p', $logs) == 0 or die "mkdir: $!";

open(my $lf, '>', "$logs/latest.log") or die $!;
print {$lf} "LINE_LATEST\n" x 20;
close($lf);

open(my $df, '>', "$logs/debug.log") or die $!;
print {$df} "LINE_DEBUG\n";
close($df);

open(my $old, '>', "$logs/2026-08-01-1.log") or die $!;
print {$old} "OLD_PLAIN\n";
close($old);

my $gz_plain = "$logs/2026-08-02-1.log";
open(my $gf, '>', $gz_plain) or die $!;
print {$gf} "GZIPPED_CONTENT_OK\n" x 5;
close($gf);
system('gzip', '-f', '--', $gz_plain) == 0 or die "gzip failed: $?";
ok(-f "$gz_plain.gz", 'rotated log compressed');

my $list = server_log_list_dir($logs);
is(scalar(@$list), 4, 'lists 4 log files');
is($list->[0]{name}, 'latest.log', 'latest first');
is($list->[1]{name}, 'debug.log', 'debug second');

my @cands = server_log_candidates(
    server_dir  => $root,
    script_name => 'mcserver',
    source      => 'lgsm',
    minecraft   => 1,
);
ok(grep { $_ eq "$logs/latest.log" } @cands, 'candidates include latest.log');
ok(grep { /\.log\.gz$/ } @cands, 'candidates include gzipped rotation');

my $picked = server_log_resolve_pick('2026-08-02-1.log.gz', \@cands);
is($picked, "$gz_plain.gz", 'resolve pick by basename');

my $tail = server_log_read_tail($picked, 8192);
ok(defined $tail, 'read gzipped log');
like($tail, qr/GZIPPED_CONTENT_OK/, 'decompressed content readable');
ok(!server_log_looks_binary($tail), 'decompressed text not binary');

my $bad = server_log_resolve_pick('../etc/passwd', \@cands);
is($bad, '', 'path traversal rejected');

my $raw_gz = do {
    open(my $fh, '<:raw', "$gz_plain.gz") or die $!;
    local $/;
    <$fh>;
};
ok(server_log_looks_binary($raw_gz), 'raw gzip bytes look binary');

done_testing();
