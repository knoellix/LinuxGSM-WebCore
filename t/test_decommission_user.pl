#!/usr/bin/perl
# t/test_decommission_user.pl — Tests for decommission_unix_user helper.
# These tests pin the order of operations (TERM → wait → KILL → wait →
# `userdel -r -f` → defensive rm → groupdel) so we don't regress the
# fix for "userdel -r races against still-running Wine processes".
use strict;
use warnings;
use Test::More tests => 13;
use FindBin qw($Bin);
chdir "$Bin/.." or die "cannot chdir to project root: $!";
use lib '.';

our (%text, $module_root);
%text = ();
$module_root = '/opt/webmin/linuxgsm-webcore';

# Capture every system_logged invocation in order.
my @commands;
sub system_logged {
    my ($cmd) = @_;
    push @commands, $cmd;
    return 0;
}

sub sanitize_input { my $s = $_[0] // ''; $s =~ s/[^a-zA-Z0-9_-]//g; return $s; }
sub log_debug      {}
sub log_action     {}

# Mock CORE::system to control pgrep/getent results without touching
# the real OS. Map prefixes -> exit codes (0 = found / running).
my %sys_responses = (
    'pgrep'  => 1,   # default: nothing running
    'getent passwd' => 1,
    'getent group'  => 1,
);
my @sys_calls;
BEGIN {
    *CORE::GLOBAL::system = sub {
        my ($cmd) = @_;
        push @sys_calls, $cmd;
        for my $key (qw(pgrep getent\ passwd getent\ group)) {
            (my $human = $key) =~ s/\\ / /g;
            if (index($cmd, $human) == 0) {
                return $sys_responses{$human} == 0 ? 0 : 1 << 8;
            }
        }
        return 0;
    };
}

# getpwnam mock that flips after `userdel -r -f` is logged.
my $user_in_passwd = 1;
BEGIN {
    *CORE::GLOBAL::getpwnam = sub {
        my ($u) = @_;
        return () unless $user_in_passwd;
        return ($u, 'x', 1234, 1234, '', '', "/home/$u", '/usr/sbin/nologin');
    };
}

require 'src/lib/provision.pl';

# ------------------------------------------------------------------
# Case 1: clean user, no processes — userdel still runs once.
# ------------------------------------------------------------------
@commands = (); @sys_calls = ();
$user_in_passwd  = 1;
$sys_responses{'pgrep'} = 1;       # no processes
$sys_responses{'getent passwd'} = 1;
$sys_responses{'getent group'}  = 1;

# Flip getpwnam to "gone" right after userdel runs (simulate success).
{
    no warnings 'redefine';
    my $orig = \&decommission_unix_user;
    *decommission_unix_user = sub {
        my $r = $orig->(@_);
        $user_in_passwd = 1;   # reset for next test
        return $r;
    };
}
$user_in_passwd = 1;
{
    no warnings 'redefine';
    my $orig_sl = \&system_logged;
    *system_logged = sub {
        my ($cmd) = @_;
        push @commands, $cmd;
        $user_in_passwd = 0 if $cmd =~ /^userdel\b/;
        return 0;
    };
}

my $res = decommission_unix_user('gs_test_user');
ok($res->{'ok'},                'clean user → ok');
is(scalar @{ $res->{'leftovers'} }, 0, 'clean user → no leftovers');

# We expect exactly one userdel command since pgrep already reports clean.
my @udel = grep { /^userdel\b/ } @commands;
is(scalar @udel, 1, 'exactly one userdel call when nothing is running');
like($udel[0], qr/userdel -r -f gs_test_user/,
    'userdel uses -r -f together (force + remove home)');
ok(!grep({ /^pkill -KILL/ } @commands),
    'no SIGKILL when nothing is running');

# ------------------------------------------------------------------
# Case 2: user has running processes — TERM, then KILL, then userdel.
# ------------------------------------------------------------------
@commands = (); @sys_calls = ();
$user_in_passwd  = 1;
my $kill_seen = 0;

{
    no warnings 'redefine';
    *CORE::GLOBAL::system = sub {
        my ($cmd) = @_;
        push @sys_calls, $cmd;
        # pgrep keeps reporting "alive" until SIGKILL has been issued.
        # That forces the helper through TERM-wait, KILL, KILL-wait.
        if ($cmd =~ /^pgrep/) {
            return $kill_seen ? 1 << 8 : 0;
        }
        return $cmd =~ /getent/ ? 1 << 8 : 0;
    };
    *system_logged = sub {
        my ($c) = @_;
        push @commands, $c;
        $kill_seen      = 1 if $c =~ /pkill -KILL/;
        $user_in_passwd = 0 if $c =~ /^userdel\b/;
        return 0;
    };
}

$res = decommission_unix_user('gs_busy_user');
ok($res->{'ok'}, 'busy user successfully decommissioned');

# Check command order: TERM appears before KILL appears before userdel.
my $term_idx = -1; my $kill_idx = -1; my $udel_idx = -1;
for my $i (0 .. $#commands) {
    $term_idx = $i if $commands[$i] =~ /pkill -TERM -u gs_busy_user/ && $term_idx < 0;
    $kill_idx = $i if $commands[$i] =~ /pkill -KILL -u gs_busy_user/ && $kill_idx < 0;
    $udel_idx = $i if $commands[$i] =~ /^userdel -r -f gs_busy_user/    && $udel_idx < 0;
}
ok($term_idx >= 0 && $kill_idx > $term_idx && $udel_idx > $kill_idx,
    'order: SIGTERM → SIGKILL → userdel');

# ------------------------------------------------------------------
# Case 3: user not in passwd → fast-path return without any commands.
# ------------------------------------------------------------------
@commands = (); @sys_calls = ();
$user_in_passwd = 0;
$res = decommission_unix_user('gs_phantom');
ok($res->{'ok'}, 'phantom user → ok');
is(scalar @commands, 0, 'phantom user → no shell side-effects');

# ------------------------------------------------------------------
# Case 4: leftover detection when userdel "fails".
# ------------------------------------------------------------------
@commands = (); @sys_calls = ();
$user_in_passwd = 1;
{
    no warnings 'redefine';
    *system_logged = sub {
        my ($cmd) = @_;
        push @commands, $cmd;
        # Simulate userdel that does NOT remove the account.
        return 0;
    };
    *CORE::GLOBAL::system = sub {
        my ($cmd) = @_;
        return 1 << 8;   # nothing running, no group
    };
}
$res = decommission_unix_user('gs_stuck');
ok(!$res->{'ok'}, 'stuck user → ok=false');
ok((grep { $_ eq 'user:gs_stuck' } @{ $res->{'leftovers'} }),
    'leftover list includes the still-present user');

# ------------------------------------------------------------------
# Case 5: invalid input is rejected without touching anything.
# ------------------------------------------------------------------
@commands = ();
$res = decommission_unix_user('');
ok(!$res->{'ok'}, 'empty user → not ok');
is(scalar @commands, 0, 'empty user → no commands issued');
