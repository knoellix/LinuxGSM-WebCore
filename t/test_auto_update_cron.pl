#!/usr/bin/perl
# Tests for /etc/cron.d generation in auto_update.pl (check worker as game user).
use strict;
use warnings;
use Test::More tests => 19;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

require "$Bin/../src/lib/auto_update.pl";

my $MR = '/usr/share/webmin/linuxgsm-webcore';

# --- auto_update_cron_schedule ----------------------------------------------
{
    is(auto_update_cron_schedule(30), '*/5 * * * *', 'schedule 30 → */5 for countdown ticks');
    is(auto_update_cron_schedule(60), '*/5 * * * *', 'schedule 60 → */5');
    is(auto_update_cron_schedule(120), '*/5 * * * *', 'schedule 120 → */5');
    is(auto_update_cron_schedule(5), '*/5 * * * *', 'schedule 5 min exact');
    is(auto_update_cron_schedule(90), '*/5 * * * *', 'schedule 90 → */5');
}

# --- enabled PZ instance → cron line ----------------------------------------
{
    my $line = auto_update_cron_line({
        id => 'gs_pz_world', user => 'gs_pz',
        server_dir => '/home/gs_pz/world', script => '/home/gs_pz/world/pzserver',
        kind => 'lgsm', interval_min => 30,
    }, $MR);
    like($line, qr{^\*/5 \* \* \* \* gs_pz }, 'PZ: */5 schedule + game user');
    like($line, qr{auto_update_check_user\.sh}, 'PZ: uses check worker');
    like($line, qr{'gs_pz_world' lgsm }, 'PZ: id + kind');
    unlike($line, qr{ root }, 'PZ: never runs as root');
    like($line, qr{>>'/.+/auto_update\.log'}, 'PZ: quoted auto_update log redirect');
}

# --- disabled / invalid interval → no line ----------------------------------
{
    my $line = auto_update_cron_line({
        id => 'x', user => 'x', server_dir => '/home/x/s', script => '/home/x/s/pzserver',
        kind => 'lgsm', interval_min => 4,
    }, $MR);
    is($line, '', 'interval too low => empty line');
}

# --- full content -----------------------------------------------------------
{
    my @insts = (
        { id => 'a', user => 'ua', server_dir => '/home/ua/s', script => '/home/ua/s/pzserver',
          kind => 'lgsm', interval_min => 15 },
        { id => 'b', user => 'ub', server_dir => '/home/ub/s', script => '/home/ub/s/pzserver',
          kind => 'native', interval_min => 60 },
    );
    my $content = auto_update_cron_content(\@insts, $MR);
    like($content, qr/^# LinuxGSM-WebCore auto-update checks/, 'content: header');
    my @job_lines = grep { m{^\S+ \S+ \* \* \*} } split /\n/, $content;
    is(scalar(@job_lines), 2, 'content: two enabled instances');
    like($content, qr/native/, 'content: native kind token');
}

# --- rebuild_auto_update_cron writes enabled instances ----------------------
{
    my $dir = tempdir(CLEANUP => 1);
    my $cron_dest = "$dir/linuxgsm-webcore-auto-update";
    no warnings 'redefine';
    local *main::_load_registered = sub {
        return (
            gs_pz_a => {
                user   => 'gs_pz',
                script => '/home/gs_pz/world/pzserver',
                source => 'lgsm',
            },
            gs_mc_b => {
                user   => 'gs_mc',
                script => '/home/gs_mc/srv/mcserver',
                source => 'lgsm',
            },
        );
    };
    local *main::auto_update_adapter_for_script = sub {
        my ($script) = @_;
        return 'pz' if ($script // '') eq 'pzserver';
        return '';
    };
    local *main::read_auto_update = sub {
        my ($sdir) = @_;
        return { enabled => 1, interval_min => 45 } if $sdir eq '/home/gs_pz/world';
        return { enabled => 0, interval_min => 30 };
    };
    ok(rebuild_auto_update_cron($MR, $dir, $cron_dest), 'rebuild_auto_update_cron ok');
    ok(-f $cron_dest, 'rebuild_auto_update_cron writes dest');
    open my $fh, '<', $cron_dest or die $!;
    my $body = do { local $/; <$fh> };
    close $fh;
    like($body, qr/auto_update_check_user\.sh/, 'rebuild content: worker');
    like($body, qr/\*\/5 \* \* \* \*/, 'rebuild content: */5 for countdown');
    unlike($body, qr/mcserver/, 'rebuild content: disabled MC absent');
}
