#!/usr/bin/perl
# Tests for the /etc/cron.d generation in monitor.pl:
#   - ALL instances run as the game user (LGSM + native — no root cron)
#   - inactive/paused instances get no line
use strict;
use warnings;
use Test::More tests => 13;
use FindBin qw($Bin);

require "$Bin/../src/lib/monitor.pl";

my $MR = '/usr/share/webmin/linuxgsm-webcore';

# --- LGSM line: runs as the game user ------------------------------------
{
    my $line = monitor_cron_line({
        id => 'gs_mc_atm_atm10', user => 'gs_mc_atm',
        server_dir => '/home/gs_mc_atm/atm10', script => '/home/gs_mc_atm/atm10/mcserver',
        kind => 'lgsm', active => 1,
    }, $MR);
    like($line, qr{^\*/5 \* \* \* \* gs_mc_atm },      'LGSM: runs as game user');
    like($line, qr{monitor_instance_user\.sh},          'LGSM: uses user monitor script');
    like($line, qr{'gs_mc_atm_atm10' lgsm },            'LGSM: passes id + lgsm kind');
    like($line, qr{'mcserver' },                        'LGSM: passes script basename');
    unlike($line, qr{ root },                           'LGSM: never runs as root');
}

# --- native line: also runs as game user (no root wrapper) ---------------
{
    my $line = monitor_cron_line({
        id => 'gs_wr_srv', user => 'gs_wr',
        server_dir => '/home/gs_wr/srv', script => '/home/gs_wr/srv/windrose',
        kind => 'native', active => 1,
    }, $MR);
    like($line, qr{^\*/5 \* \* \* \* gs_wr },            'native: runs as game user');
    like($line, qr{'gs_wr_srv' native },                 'native: passes id + native kind');
    unlike($line, qr{monitor_native_root},               'native: no root wrapper script');
    unlike($line, qr{ root },                            'native: never runs as root');
}

# --- inactive => no line -------------------------------------------------
{
    my $line = monitor_cron_line({
        id => 'x', user => 'x', server_dir => '/home/x/s',
        script => '/home/x/s/xserver', kind => 'lgsm', active => 0,
    }, $MR);
    is($line, '', 'inactive instance => empty line');
}

# --- full content: header + only active lines ---------------------------
{
    my @insts = (
        { id => 'a', user => 'ua', server_dir => '/home/ua/s', script => '/home/ua/s/mcserver', kind => 'lgsm',   active => 1 },
        { id => 'b', user => 'ub', server_dir => '/home/ub/s', script => '/home/ub/s/windrose', kind => 'native', active => 1 },
        { id => 'c', user => 'uc', server_dir => '/home/uc/s', script => '/home/uc/s/mcserver', kind => 'lgsm',   active => 0 },
    );
    my $content = monitor_cron_content(\@insts, $MR);
    like($content, qr/^# LinuxGSM-WebCore monitoring/, 'content: has header comment');
    my @job_lines = grep { m{^\*/5} } split /\n/, $content;
    is(scalar(@job_lines), 2, 'content: only active instances get a job line');
    like($content, qr/native/, 'content: native kind token present');
}
