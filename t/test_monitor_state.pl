#!/usr/bin/perl
use strict;
use warnings;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/..";
chdir "$Bin/.." or die "Cannot chdir: $!";

print "1..14\n";
sub pass { print "ok - $_[0]\n" }
sub fail { print "not ok - $_[0]\n" }

my $tmp = tempdir(CLEANUP => 1);

require './src/lib/monitor.pl';

# server_dir = "$tmp/inst" (new path: $tmp/inst/.monitor/state)
# config_dir = $tmp, id = 'inst' (legacy fallback: $tmp/monitor/inst/state)

# 1. read_monitor_state returns disabled for missing file (pre-first-start)
{
    my $server_dir = "$tmp/inst1";
    my $s = read_monitor_state($server_dir, $tmp, 'inst1');
    ($s->{status} eq 'disabled' && $s->{restart_count} == 0)
        ? pass('read_monitor_state: disabled default for missing state file')
        : fail("read_monitor_state: wrong defaults: status=$s->{status} count=$s->{restart_count}");
}

# 2. write then read round-trip
{
    my $server_dir = "$tmp/inst1";
    write_monitor_state($server_dir, { status => 'failed', restart_count => 5, window_start => 1000 });
    my $s = read_monitor_state($server_dir, $tmp, 'inst1');
    ($s->{status} eq 'failed' && $s->{restart_count} == 5)
        ? pass('write/read monitor state round-trip')
        : fail("write/read round-trip failed: status=$s->{status} count=$s->{restart_count}");
}

# 3. set_monitor_paused writes paused
{
    my $server_dir = "$tmp/inst2";
    set_monitor_paused($server_dir, $tmp, 'inst2');
    my $s = read_monitor_state($server_dir, $tmp, 'inst2');
    $s->{status} eq 'paused'
        ? pass('set_monitor_paused writes paused')
        : fail("set_monitor_paused: status=$s->{status}");
}

# 4. set_monitor_running resets count and writes running
{
    my $server_dir = "$tmp/inst3";
    write_monitor_state($server_dir, { status => 'failed', restart_count => 5, window_start => 1 });
    set_monitor_running($server_dir, $tmp, 'inst3');
    my $s = read_monitor_state($server_dir, $tmp, 'inst3');
    ($s->{status} eq 'running' && $s->{restart_count} == 0)
        ? pass('set_monitor_running resets count')
        : fail("set_monitor_running: status=$s->{status} count=$s->{restart_count}");
}

# 5. set_monitor_disabled writes disabled
{
    my $server_dir = "$tmp/inst4";
    set_monitor_disabled($server_dir, $tmp, 'inst4');
    my $s = read_monitor_state($server_dir, $tmp, 'inst4');
    $s->{status} eq 'disabled'
        ? pass('set_monitor_disabled writes disabled')
        : fail("set_monitor_disabled: status=$s->{status}");
}

# 6. monitor_is_active: running -> true
{
    my $server_dir = "$tmp/active";
    write_monitor_state($server_dir, { status => 'running', restart_count => 0, window_start => time() });
    monitor_is_active($server_dir, $tmp, 'active')
        ? pass('monitor_is_active: running -> true')
        : fail('monitor_is_active: running should be active');
}

# 7. monitor_is_active: paused -> false
{
    my $server_dir = "$tmp/paused";
    write_monitor_state($server_dir, { status => 'paused', restart_count => 0, window_start => time() });
    !monitor_is_active($server_dir, $tmp, 'paused')
        ? pass('monitor_is_active: paused -> false')
        : fail('monitor_is_active: paused should not be active');
}

# 8. monitor_is_active: disabled -> false
{
    my $server_dir = "$tmp/dis";
    write_monitor_state($server_dir, { status => 'disabled', restart_count => 0, window_start => time() });
    !monitor_is_active($server_dir, $tmp, 'dis')
        ? pass('monitor_is_active: disabled -> false')
        : fail('monitor_is_active: disabled should not be active');
}

# 9. Fallback: legacy path is read when new path does not exist
{
    my $sd = "$tmp/fallback_test";
    my $old_dir = "$tmp/monitor/fallback_test";
    require File::Path; File::Path::make_path($old_dir);
    open(my $fh, '>', "$old_dir/state") or die;
    print $fh "status=paused\nrestart_count=3\nwindow_start=999\n";
    close($fh);
    # No new state file -> should read legacy
    my $s = read_monitor_state($sd, $tmp, 'fallback_test');
    ($s->{status} eq 'paused' && $s->{restart_count} == 3)
        ? pass('Migrations-Fallback liest Legacy-State')
        : fail("Migrations-Fallback: status=$s->{status} count=$s->{restart_count}");
}

# 10. read_monitor_state mit undef server_dir → gibt Defaults zurück (kein Crash)
{
    my $s = read_monitor_state(undef, $tmp, 'x');
    $s->{status} eq 'disabled'
        ? pass('read_monitor_state: undef server_dir → safe defaults')
        : fail("read_monitor_state undef: status=$s->{status}");
}

# 11. write_monitor_state mit undef server_dir → kein Crash, kein /.monitor
{
    eval { write_monitor_state(undef, { status => 'running', restart_count => 0, window_start => 0 }) };
    !$@
        ? pass('write_monitor_state: undef server_dir → kein Crash')
        : fail("write_monitor_state undef crashed: $@");
}

# 12. last_restart_at / last_restart_job round-trip
{
    my $server_dir = "$tmp/inst_restart";
    write_monitor_state($server_dir, {
        status           => 'running',
        restart_count    => 1,
        window_start     => 1000,
        last_restart_at  => 1700000000,
        last_restart_job => 'abcd1234abcd1234',
    });
    my $s = read_monitor_state($server_dir, $tmp, 'inst_restart');
    ($s->{last_restart_at} == 1700000000 && $s->{last_restart_job} eq 'abcd1234abcd1234')
        ? pass('last_restart fields round-trip')
        : fail("last_restart round-trip: at=$s->{last_restart_at} job=$s->{last_restart_job}");
}

# 13. set_monitor_resume_after_start: paused -> running
{
    my $server_dir = "$tmp/resume_paused";
    set_monitor_paused($server_dir, $tmp, 'resume_paused');
    my $changed = set_monitor_resume_after_start($server_dir, $tmp, 'resume_paused');
    my $s = read_monitor_state($server_dir, $tmp, 'resume_paused');
    ($changed && $s->{status} eq 'running')
        ? pass('resume_after_start: paused -> running')
        : fail("resume_after_start paused: changed=$changed status=$s->{status}");
}

# 14. set_monitor_resume_after_start: disabled stays disabled
{
    my $server_dir = "$tmp/resume_dis";
    set_monitor_disabled($server_dir, $tmp, 'resume_dis');
    my $changed = set_monitor_resume_after_start($server_dir, $tmp, 'resume_dis');
    my $s = read_monitor_state($server_dir, $tmp, 'resume_dis');
    (!$changed && $s->{status} eq 'disabled')
        ? pass('resume_after_start: disabled stays disabled')
        : fail("resume_after_start disabled: changed=$changed status=$s->{status}");
}
