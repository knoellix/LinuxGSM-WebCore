#!/usr/bin/perl
# Tests for auto_update.pl state R/W, validation, and message placeholders.
use strict;
use warnings;
use Test::More tests => 65;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);

require "$Bin/../src/lib/auto_update.pl";

# --- auto_update_file -------------------------------------------------------
{
    is(auto_update_file(''), '', 'empty server_dir => empty path');
    is(auto_update_file('/home/u/srv'), '/home/u/srv/.monitor/auto_update',
        'auto_update_file path');
    is(auto_update_secrets_file('/home/u/srv'),
        '/home/u/srv/.monitor/auto_update_secrets', 'auto_update_secrets_file path');
}

# --- read_auto_update defaults ----------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    my $r = read_auto_update("$dir/srv");
    is($r->{enabled}, 0, 'default enabled');
    is($r->{check_game}, 1, 'default check_game');
    is($r->{check_workshop}, 1, 'default check_workshop');
    is($r->{interval_min}, 30, 'default interval_min');
    is($r->{warn_minutes}, '15,10,5,1,0', 'default warn_minutes');
    is($r->{msg_template}, 'Server-Neustart in {minutes} Min - {reason}',
        'default msg_template');
    is($r->{msg_now}, 'Server startet jetzt neu - {reason}', 'default msg_now');
    is($r->{pending}, 0, 'default pending');
    is($r->{countdown_deadline}, 0, 'default countdown_deadline');
    is($r->{need_game}, 0, 'default need_game');
    is($r->{need_workshop}, 0, 'default need_workshop');
}

# --- validate_auto_update_interval ------------------------------------------
{
    ok(validate_auto_update_interval(5), 'interval min boundary 5');
    ok(validate_auto_update_interval(1440), 'interval max boundary 1440');
    ok(validate_auto_update_interval(30), 'interval mid 30');
    ok(!validate_auto_update_interval(4), 'interval too low');
    ok(!validate_auto_update_interval(1441), 'interval too high');
    ok(!validate_auto_update_interval(''), 'interval empty');
    ok(!validate_auto_update_interval('abc'), 'interval non-numeric');
}

# --- validate_warn_minutes --------------------------------------------------
{
    ok(validate_warn_minutes('15,10,5,1,0'), 'warn default csv');
    ok(validate_warn_minutes('15,10,5,1'), 'warn without 0 allowed separately');
    ok(validate_warn_minutes('0'), 'warn single zero');
    ok(validate_warn_minutes('5,10,15'), 'warn unsorted order ok');
    ok(!validate_warn_minutes(''), 'warn empty invalid');
    ok(!validate_warn_minutes('15,10,foo'), 'warn non-numeric');
    ok(!validate_warn_minutes('-1,5'), 'warn negative');
    ok(!validate_warn_minutes('15,15,5'), 'warn duplicates');
    ok(!validate_warn_minutes('15, 10'), 'warn spaces invalid');
}

# --- auto_update_fill_message -----------------------------------------------
{
    my $out = auto_update_fill_message(
        'Server-Neustart in {minutes} Min - {reason}',
        { minutes => 5, reason => 'Workshop-Update' },
    );
    is($out, 'Server-Neustart in 5 Min - Workshop-Update', 'fill minutes+reason');

    $out = auto_update_fill_message(
        '{game}: {mods} ({minutes})',
        { game => 'PZ', mods => 'modA,modB', minutes => 0 },
    );
    is($out, 'PZ: modA,modB (0)', 'fill game+mods+minutes');

    $out = auto_update_fill_message('no placeholders', {});
    is($out, 'no placeholders', 'fill no placeholders');

    $out = auto_update_fill_message('{reason}', {});
    is($out, '', 'fill missing var => empty');
}

# --- write/read round-trip --------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    my $server = "$dir/srv";
    mkdir $server or die $!;
    my %in = (
        enabled            => 1,
        check_game         => 0,
        check_workshop     => 1,
        interval_min       => 60,
        warn_minutes       => '10,5,0',
        msg_template       => 'In {minutes} - {reason}',
        msg_now            => 'Now - {reason}',
        pending            => 1,
        countdown_deadline => 1700000000,
        need_game          => 0,
        need_workshop      => 1,
        reason             => 'mod bump',
        mods               => '123,456',
    );
    ok(write_auto_update($server, \%in, ''), 'write without su');
    ok(-f auto_update_file($server), 'state file created');

    my $r = read_auto_update($server);
    is($r->{enabled}, 1, 'roundtrip enabled');
    is($r->{check_game}, 0, 'roundtrip check_game');
    is($r->{check_workshop}, 1, 'roundtrip check_workshop');
    is($r->{interval_min}, 60, 'roundtrip interval_min');
    is($r->{warn_minutes}, '10,5,0', 'roundtrip warn_minutes');
    is($r->{msg_template}, 'In {minutes} - {reason}', 'roundtrip msg_template');
    is($r->{msg_now}, 'Now - {reason}', 'roundtrip msg_now');
    is($r->{pending}, 1, 'roundtrip pending');
    is($r->{countdown_deadline}, 1700000000, 'roundtrip countdown_deadline');
    is($r->{need_game}, 0, 'roundtrip need_game');
    is($r->{need_workshop}, 1, 'roundtrip need_workshop');
    is($r->{reason}, 'mod bump', 'roundtrip reason');
    is($r->{mods}, '123,456', 'roundtrip mods');
}

# --- free-text newlines must not inject kv keys -----------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    my $server = "$dir/srv";
    mkdir $server or die $!;
    my %in = (
        enabled      => 0,
        pending      => 0,
        msg_template => "line1\nenabled=1\npending=1",
        reason       => "a\r\nb",
    );
    ok(write_auto_update($server, \%in, ''), 'write with embedded newlines');
    my $r = read_auto_update($server);
    is($r->{enabled}, 0, 'newline inject cannot flip enabled');
    is($r->{pending}, 0, 'newline inject cannot flip pending');
    unlike($r->{msg_template}, qr/\n/, 'msg_template stored single-line');
    unlike($r->{reason} // '', qr/[\r\n]/, 'reason stored single-line');
}


# --- normalize em-dash / mojibake in messages -----------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    my $server = "$dir/srv";
    mkdir $server or die $!;
    make_path("$server/.monitor");
    my $file = auto_update_file($server);
    open my $fh, '>:raw', $file or die $!;
    print $fh "enabled=0\n";
    print $fh "msg_template=Server-Neustart in {minutes} Min \xE2\x80\x94 {reason}\n";
    print $fh "msg_now=Server startet jetzt neu \xE2\x80\x94 {reason}\n";
    close $fh;
    my $r = read_auto_update($server);
    is($r->{msg_template}, 'Server-Neustart in {minutes} Min - {reason}',
        'read normalizes UTF-8 em dash in msg_template');
    is($r->{msg_now}, 'Server startet jetzt neu - {reason}',
        'read normalizes UTF-8 em dash in msg_now');
}

# --- auto_update secrets + last_restart_job reader --------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    my $server = "$dir/srv";
    mkdir $server or die $!;
    is(read_auto_update_last_job_id($server), '', 'last job id empty by default');

    ok(write_auto_update_secrets($server, '', {
        steam_web_api_key => 'secret-key-xyz',
    }), 'write_auto_update_secrets ok');
    my $spath = auto_update_secrets_file($server);
    ok(-f $spath, 'secrets file created');
    my $mode = (stat($spath))[2] & 0777;
    is($mode, 0600, 'secrets mode 0600');
    open my $sf, '<', $spath or die $!;
    my $sbody = do { local $/; <$sf> };
    close $sf;
    like($sbody, qr/^steam_web_api_key=secret-key-xyz$/m, 'secrets kv content');

    ok(write_auto_update($server, {
        enabled => 1, last_restart_job => 'aabbccddeeff0011',
    }, ''), 'write last_restart_job');
    is(read_auto_update_last_job_id($server), 'aabbccddeeff0011',
        'read_auto_update_last_job_id');

    ok(clear_auto_update_secrets($server), 'clear_auto_update_secrets');
    ok(!-e $spath, 'secrets file removed');
}
