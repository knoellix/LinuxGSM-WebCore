#!/usr/bin/perl
use strict;
use warnings;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/..";
chdir "$Bin/.." or die "Cannot chdir: $!";

print "1..8\n";
sub pass { print "ok - $_[0]\n" }
sub fail { print "not ok - $_[0]\n" }

my $tmp = tempdir(CLEANUP => 1);

require './src/lib/monitor.pl';

# 1. read_monitor_state returns defaults for missing file
{
    my $s = read_monitor_state($tmp, 'testinst');
    ($s->{status} eq 'running' && $s->{restart_count} == 0)
        ? pass('read_monitor_state: defaults for missing state file')
        : fail("read_monitor_state: wrong defaults: status=$s->{status} count=$s->{restart_count}");
}

# 2. write then read round-trip
{
    write_monitor_state($tmp, 'testinst', { status => 'failed', restart_count => 5, window_start => 1000 });
    my $s = read_monitor_state($tmp, 'testinst');
    ($s->{status} eq 'failed' && $s->{restart_count} == 5)
        ? pass('write/read monitor state round-trip')
        : fail("write/read round-trip failed: status=$s->{status} count=$s->{restart_count}");
}

# 3. set_monitor_paused writes paused
{
    set_monitor_paused($tmp, 'inst2');
    my $s = read_monitor_state($tmp, 'inst2');
    $s->{status} eq 'paused'
        ? pass('set_monitor_paused writes paused')
        : fail("set_monitor_paused: status=$s->{status}");
}

# 4. set_monitor_running resets count and writes running
{
    write_monitor_state($tmp, 'inst3', { status => 'failed', restart_count => 5, window_start => 1 });
    set_monitor_running($tmp, 'inst3');
    my $s = read_monitor_state($tmp, 'inst3');
    ($s->{status} eq 'running' && $s->{restart_count} == 0)
        ? pass('set_monitor_running resets count')
        : fail("set_monitor_running: status=$s->{status} count=$s->{restart_count}");
}

# 5. set_monitor_disabled writes disabled
{
    set_monitor_disabled($tmp, 'inst4');
    my $s = read_monitor_state($tmp, 'inst4');
    $s->{status} eq 'disabled'
        ? pass('set_monitor_disabled writes disabled')
        : fail("set_monitor_disabled: status=$s->{status}");
}

# 6. monitor_is_active: running -> true
{
    write_monitor_state($tmp, 'active', { status => 'running', restart_count => 0, window_start => time() });
    monitor_is_active($tmp, 'active')
        ? pass('monitor_is_active: running -> true')
        : fail('monitor_is_active: running should be active');
}

# 7. monitor_is_active: paused -> false
{
    write_monitor_state($tmp, 'paused', { status => 'paused', restart_count => 0, window_start => time() });
    !monitor_is_active($tmp, 'paused')
        ? pass('monitor_is_active: paused -> false')
        : fail('monitor_is_active: paused should not be active');
}

# 8. monitor_is_active: disabled -> false
{
    write_monitor_state($tmp, 'dis', { status => 'disabled', restart_count => 0, window_start => time() });
    !monitor_is_active($tmp, 'dis')
        ? pass('monitor_is_active: disabled -> false')
        : fail('monitor_is_active: disabled should not be active');
}
