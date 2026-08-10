#!/usr/bin/perl
# Tests for instance_is_lgsm() / instance_monitor_kind() — the central rule
# that decides whether an instance is monitored via LGSM (`./script monitor`)
# or the non-LGSM (steamcmd/wine) watchdog path.
use strict;
use warnings;
use Test::More tests => 20;
use FindBin qw($Bin);

require "$Bin/stubs.pl";
require "$Bin/../src/lib/instance.pl";

# LGSM-managed sources (must return true) — 'provisioned' is what wizard.cgi
# writes for real LGSM games (incl. Minecraft), so this is the regression guard.
ok(instance_is_lgsm('provisioned'), "provisioned => LGSM (MC regression guard)");
ok(instance_is_lgsm('lgsm'),        "lgsm => LGSM");
ok(instance_is_lgsm('auto'),        "auto => LGSM");
ok(instance_is_lgsm('legacy'),      "legacy => LGSM");
ok(instance_is_lgsm('manual'),      "manual => LGSM");
ok(instance_is_lgsm(''),            "empty => LGSM (safe default)");
ok(instance_is_lgsm(undef),         "undef => LGSM (safe default)");
ok(instance_is_lgsm(' PROVISIONED '), "whitespace/case-insensitive => LGSM");

# Non-LGSM sources (must return false)
ok(!instance_is_lgsm('steamcmd'),   "steamcmd => not LGSM");
ok(!instance_is_lgsm('wine'),       "wine => not LGSM");

# instance_monitor_kind maps to tokens used by cron lines / worker scripts.
is(instance_monitor_kind('provisioned'), 'lgsm',   "kind: provisioned => lgsm");
is(instance_monitor_kind('steamcmd'),    'native', "kind: steamcmd => native");

is(_parse_lgsm_details_status("Server status: STARTED\n"), 'online', 'details STARTED => online');
is(_parse_lgsm_details_status("Status: Online\n"), 'online', 'details Online => online');
is(_parse_lgsm_details_status("Status: Stopped\n"), 'offline', 'details Stopped => offline');
is(_parse_lgsm_details_status(""), 'unknown', 'empty details => unknown');
is(_parse_lgsm_details_status("server is STARTED\n"), 'online', 'case-insensitive STARTED');
is_deeply([_lgsm_tmux_session_names('pwserver')], ['pwserver', 'pw'], 'tmux names include shortname');

{
    require File::Path;
    my $sd = "$Bin/../t/tmp_lgsm_uid_$$";
    File::Path::make_path("$sd/lgsm/data");
    open(my $uf, '>', "$sd/lgsm/data/pwserver.uid") or die $!;
    print $uf "ef548d5f\n";
    close($uf);
    my @specs = _lgsm_tmux_probe_specs($sd, 'pwserver');
    ok((grep { $_->{socket} eq 'pwserver-ef548d5f' && $_->{session} eq 'pwserver' } @specs),
        'tmux probe includes LGSM unique socket');
    File::Path::remove_tree($sd);
}

is(_lgsm_read_uid(undef, 'pwserver'), '', '_lgsm_read_uid: undef server_dir safe');
