#!/usr/bin/perl
# Tests for /etc/cron.d generation in schedule.pl (daily restart as game user).
use strict;
use warnings;
use Test::More tests => 21;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

require "$Bin/../src/lib/schedule.pl";

my $MR = '/usr/share/webmin/linuxgsm-webcore';

# --- validate_schedule_time ------------------------------------------------
ok(validate_schedule_time('04:00'), 'valid time 04:00');
ok(!validate_schedule_time('24:00'), 'invalid hour 24');
ok(!validate_schedule_time('ab:cd'), 'invalid format');

# --- LGSM cron line --------------------------------------------------------
{
    my $line = schedule_cron_line({
        id => 'gs_pw_keks', user => 'gs_pw_keks',
        server_dir => '/home/gs_pw_keks/pw-1', script => '/home/gs_pw_keks/pw-1/pwserver',
        kind => 'lgsm', schedule_enabled => 1, schedule_time => '04:30',
    }, $MR);
    like($line, qr{^30 4 \* \* \* gs_pw_keks }, 'LGSM: minute/hour + game user');
    like($line, qr{scheduled_restart_user\.sh}, 'LGSM: uses schedule worker');
    like($line, qr{'gs_pw_keks' lgsm }, 'LGSM: id + kind');
    unlike($line, qr{ root }, 'LGSM: never runs as root');
    like($line, qr{>>'/.+/schedule\.log'}, 'LGSM: quoted schedule log redirect');
}

# --- disabled => no line -----------------------------------------------------
{
    my $line = schedule_cron_line({
        id => 'x', user => 'x', server_dir => '/home/x/s', script => '/home/x/s/xserver',
        kind => 'lgsm', schedule_enabled => 0, schedule_time => '04:00',
    }, $MR);
    is($line, '', 'disabled schedule => empty line');
}

# --- invalid time => no line -------------------------------------------------
{
    my $line = schedule_cron_line({
        id => 'x', user => 'x', server_dir => '/home/x/s', script => '/home/x/s/xserver',
        kind => 'lgsm', schedule_enabled => 1, schedule_time => '99:99',
    }, $MR);
    is($line, '', 'invalid time => empty line');
}

# --- full content -----------------------------------------------------------
{
    my @insts = (
        { id => 'a', user => 'ua', server_dir => '/home/ua/s', script => '/home/ua/s/mcserver',
          kind => 'lgsm', schedule_enabled => 1, schedule_time => '03:15' },
        { id => 'b', user => 'ub', server_dir => '/home/ub/s', script => '/home/ub/s/windrose',
          kind => 'native', schedule_enabled => 1, schedule_time => '05:00' },
    );
    my $content = schedule_cron_content(\@insts, $MR);
    like($content, qr/^# LinuxGSM-WebCore scheduled restarts/, 'content: header');
    like($content, qr/local time/, 'content: timezone hint in header');
    my @job_lines = grep { m{^\d+ \d+ \* \* \*} } split /\n/, $content;
    is(scalar(@job_lines), 2, 'content: two enabled instances');
    like($content, qr/native/, 'content: native kind token');
}

# --- read/write schedule file roundtrip (temp dir) ---------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    my $server = "$dir/srv";
    mkdir $server or die $!;
    mkdir "$server/.monitor" or die $!;
    my %in = (enabled => 1, time => '06:45', last_run => 0, last_skip_at => 0, last_schedule_job => '');
    ok(write_restart_schedule($server, \%in, ''), 'write schedule without su');
    my $r = read_restart_schedule($server);
    is($r->{enabled}, 1, 'read back enabled');
    is($r->{time}, '06:45', 'read back time');
}

# --- rebuild_schedule_cron writes enabled instances -------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    my $cron_dest = "$dir/linuxgsm-webcore-schedule";
    no warnings 'redefine';
    local *main::_load_registered = sub {
        return (
            gs_pw => {
                user   => 'gs_pw',
                script => '/home/gs_pw/pw-1/pwserver',
                source => 'lgsm',
            },
        );
    };
    local *main::read_restart_schedule = sub {
        my ($sdir) = @_;
        return { enabled => 1, time => '04:15' } if $sdir eq '/home/gs_pw/pw-1';
        return { enabled => 0, time => '03:00' };
    };
    ok(rebuild_schedule_cron($MR, $dir, $cron_dest), 'rebuild_schedule_cron ok');
    ok(-f $cron_dest, 'rebuild_schedule_cron writes dest');
    open my $fh, '<', $cron_dest or die $!;
    my $body = do { local $/; <$fh> };
    close $fh;
    like($body, qr/scheduled_restart_user\.sh/, 'rebuild content: worker');
    like($body, qr/15 4 \* \* \*/, 'rebuild content: enabled instance time');
}
