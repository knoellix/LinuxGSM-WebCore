#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 8;
use FindBin qw($Bin);
use File::Temp qw(tempfile);

# Kein require stubs.pl — wir brauchen nur %config und webmin_log
our (%config);

# Stub webmin_log vor dem require — sonst Undefined subroutine
my @webmin_log_calls;
sub webmin_log {
    push @webmin_log_calls, [@_];
}

require "$Bin/../src/lib/logging.pl";

# Helper: capture STDERR via tempfile (scalar-ref redirect not supported on all Perl versions)
sub capture_stderr {
    my ($code) = @_;
    my ($fh, $fname) = tempfile(UNLINK => 1);
    open(my $save, '>&STDERR') or die "Cannot dup STDERR: $!";
    open(STDERR, '>&', $fh)    or die "Cannot redirect STDERR: $!";
    $code->();
    open(STDERR, '>&', $save)  or die "Cannot restore STDERR: $!";
    close $save;
    seek $fh, 0, 0;
    my $out = do { local $/; <$fh> };
    close $fh;
    return $out;
}

# Test 1-2: log_error schreibt [LGSM-ERROR] nach STDERR
{
    my $captured = capture_stderr(sub { log_error("something broke") });
    like($captured, qr/\[LGSM-ERROR\] something broke/, 'log_error writes [LGSM-ERROR] prefix');
    like($captured, qr/\n$/, 'log_error appends newline');
}

# Test 3-4: log_action ruft webmin_log auf
{
    @webmin_log_calls = ();
    log_action('job_started', 'abc123', {instance_id => 'mc_srv', action => 'install_game'});
    is(scalar @webmin_log_calls, 1, 'log_action calls webmin_log once');
    is($webmin_log_calls[0][0], 'job_started', 'log_action: action arg correct');
    is($webmin_log_calls[0][1], 'lgsm',        'log_action: type arg is lgsm');
    is($webmin_log_calls[0][2], 'abc123',       'log_action: object arg correct');
}

# Test 5: log_debug stumm wenn debug_logging=0
{
    $config{debug_logging} = 0;
    my $captured = capture_stderr(sub { log_debug("silent message") });
    is($captured, '', 'log_debug silent when debug_logging=0');
}

# Test 6: log_debug schreibt [LGSM-DEBUG] wenn debug_logging=1
{
    $config{debug_logging} = 1;
    my $captured = capture_stderr(sub { log_debug("verbose detail") });
    like($captured, qr/\[LGSM-DEBUG\] verbose detail/, 'log_debug writes [LGSM-DEBUG] when debug_logging=1');
}
