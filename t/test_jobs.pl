#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 10;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

require "$Bin/stubs.pl";
our $config_directory;
my $tmp = tempdir(CLEANUP => 1);
$config_directory = $tmp;

require "$Bin/../src/lib/jobs.pl";

# Test 1: create_job returns 16-char hex ID
my $job_id = create_job();
like($job_id, qr/^[0-9a-f]{16}$/, 'job_id is 16 hex chars');

# Test 2: job dir created
ok(-d "$tmp/jobs/$job_id", 'job directory created');

# Test 3: status file created with 'running'
ok(-f "$tmp/jobs/$job_id/status", 'status file created');

# Test 4: get_job_status returns 'running'
is(get_job_status($job_id), 'running', 'initial status is running');

# Test 5: get_job_output returns empty at offset 0
my ($out, $len) = get_job_output($job_id, 0);
is($out, '', 'initial output empty');

# Test 6: initial length is 0
is($len, 0, 'initial length 0');

# Test 7+8: append output and read with offset
open(my $fh, '>>', "$tmp/jobs/$job_id/output") or die $!;
print $fh "line1\nline2\n";
close($fh);
my ($new_out, $new_len) = get_job_output($job_id, 0);
is($new_out, "line1\nline2\n", 'full output read from offset 0');
my ($delta, $delta_len) = get_job_output($job_id, 6);
is($delta, "line2\n", 'delta read from offset 6');

# Test 9: get_job_error_hint returns empty when no file
is(get_job_error_hint($job_id), '', 'no error_hint file returns empty');

# Test 10: get_job_status returns undef for unknown job
is(get_job_status('nonexistent1234567'), undef, 'unknown job returns undef status');
