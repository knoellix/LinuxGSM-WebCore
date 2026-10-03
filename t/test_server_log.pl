#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

require "$Bin/stubs.pl";
require "$Bin/../src/lib/server_log.pl";

our (%config, $module_config_directory);

my $root = tempdir(CLEANUP => 1);
my $logs = "$root/serverfiles/logs";
system('mkdir', '-p', $logs) == 0 or die "mkdir: $!";

open(my $lf, '>', "$logs/latest.log") or die $!;
print {$lf} "LINE_LATEST\n" x 20;
close($lf);

open(my $df, '>', "$logs/debug.log") or die $!;
print {$df} "LINE_DEBUG\n";
close($df);

open(my $old, '>', "$logs/2026-08-01-1.log") or die $!;
print {$old} "OLD_PLAIN\n";
close($old);

my $gz_plain = "$logs/2026-08-02-1.log";
open(my $gf, '>', $gz_plain) or die $!;
print {$gf} "GZIPPED_CONTENT_OK\n" x 5;
close($gf);
system('gzip', '-f', '--', $gz_plain) == 0 or die "gzip failed: $?";
ok(-f "$gz_plain.gz", 'rotated log compressed');

my $list = server_log_list_dir($logs);
is(scalar(@$list), 4, 'lists 4 log files');
is($list->[0]{name}, 'latest.log', 'latest first');
is($list->[1]{name}, 'debug.log', 'debug second');

my @cands = server_log_candidates(
    server_dir  => $root,
    script_name => 'mcserver',
    source      => 'lgsm',
    minecraft   => 1,
);
ok(grep { $_ eq "$logs/latest.log" } @cands, 'candidates include latest.log');
ok(grep { /\.log\.gz$/ } @cands, 'candidates include gzipped rotation');

my $picked = server_log_resolve_pick('2026-08-02-1.log.gz', \@cands);
is($picked, "$gz_plain.gz", 'resolve pick by basename');

my $tail = server_log_read_tail($picked, 8192);
ok(defined $tail, 'read gzipped log');
like($tail, qr/GZIPPED_CONTENT_OK/, 'decompressed content readable');
ok(!server_log_looks_binary($tail), 'decompressed text not binary');

my $bad = server_log_resolve_pick('../etc/passwd', \@cands);
is($bad, '', 'path traversal rejected');

my $raw_gz = do {
    open(my $fh, '<:raw', "$gz_plain.gz") or die $!;
    local $/;
    <$fh>;
};
ok(server_log_looks_binary($raw_gz), 'raw gzip bytes look binary');

{
    my $payload = server_log_monitor_poll_payload(
        server_dir  => $root,
        script_name => 'mcserver',
        source      => 'lgsm',
        minecraft   => 1,
        log_file    => 'latest.log',
    );
    ok($payload->{ok}, 'monitor poll payload ok');
    is($payload->{log_file}, 'latest.log', 'poll payload log basename');
    like($payload->{output}, qr/LINE_LATEST/, 'poll payload has tail');
    ok(!$payload->{binary}, 'poll payload not binary');
    is($payload->{started}, 0, 'poll started=0 without ready marker');
}

{
    my $empty_root = tempdir(CLEANUP => 1);
    my $payload = server_log_monitor_poll_payload(
        server_dir  => $empty_root,
        script_name => 'mcserver',
        source      => 'lgsm',
        minecraft   => 1,
    );
    ok(!$payload->{ok}, 'poll payload fails without logs');
    is($payload->{error}, 'no_log', 'poll error is no_log');
}

{
    my $ctx = server_log_monitor_prepare(
        server_dir    => $root,
        script_name   => 'mcserver',
        source        => 'lgsm',
        minecraft     => 1,
        log_file_pick => 'latest.log',
    );
    is($ctx->{log_base}, 'latest.log', 'monitor prepare picks latest.log');
    ok($ctx->{auto_refresh}, 'monitor prepare auto refresh default on');
}

ok(!server_log_monitor_resolve_auto_refresh('0'), 'auto refresh off when unchecked');
ok(server_log_monitor_resolve_auto_refresh(undef), 'auto refresh on when unset');

{
    our %text;
    local $text{manage_monitor_title} = 'Manage title';
    is(server_log_monitor_text(['manage_monitor_title'], 'fallback'),
        'Manage title', 'monitor text from lang');
    is(server_log_monitor_text(['missing_key'], 'fallback'), 'fallback',
        'monitor text fallback');
}

{
    my $mods_keys = server_log_monitor_text_keys_mods();
    ok(ref($mods_keys->{title}) eq 'ARRAY', 'mods monitor text keys');
    ok(grep { $_ eq 'mc_mods_page_monitor_title' } @{ $mods_keys->{title} },
        'mods title key present');
}

like(server_log_filemin_path_urlencode('/foo bar'), qr/%20/,
    'filemin path urlencode spaces');

{
    require "$Bin/../src/lib/live_log.pl";
    require "$Bin/../src/lib/module_config.pl";

    ok(!server_log_start_log_enabled(), 'start log disabled when config unset');
    local $config{manage_show_start_log} = '1';
    ok(server_log_start_log_enabled(), 'start log enabled when config is 1');
    local $config{manage_show_start_log} = '0';
    ok(!server_log_start_log_enabled(), 'start log off when config is 0');

    is(server_log_start_log_flash_name('inst-1'), 'start_log_inst-1',
        'flash name includes instance id');
    is(server_log_start_log_flash_name('../x'), 'start_log_x',
        'flash name strips path chars');

    my $tmpdir = tempdir(CLEANUP => 1);
    local $module_config_directory = $tmpdir;
    local $main::module_config_directory = $tmpdir;
    ok(server_log_start_log_flash_mark('demo1'), 'flash mark succeeds');
    ok(!server_log_start_log_should_show({ start_log => '0' }, 'demo1'),
        'no show without start_log=1');
    ok(server_log_start_log_should_show({ start_log => '1' }, 'demo1'),
        'show when start_log=1 and flash fresh');
    ok(!server_log_start_log_should_show({ start_log => '1' }, 'demo1'),
        'flash consumed only once');

    our %text;
    local $text{start_log_panel_title} = 'Start-Log';
    local $text{start_log_ready_banner} = 'Server gestartet';
    my $html = server_log_embed_html(
        instance_id   => 'demo1',
        server_dir    => $root,
        script_name   => 'mcserver',
        source        => 'lgsm',
        minecraft     => 1,
        poll_url_base => '/linuxgsm-webcore/mods.cgi?instance_id=demo1&action=poll_monitor',
    );
    like($html, qr/Start-Log/, 'embed title present');
    like($html, qr/start_log_panel/, 'embed panel id present');
    like($html, qr/poll_monitor/, 'embed poll url present');
    like($html, qr/setInterval/, 'embed auto-poll JS present');
    like($html, qr/start_log_ready_banner/, 'embed ready banner id present');
    like($html, qr/readyBannerId/, 'embed wires readyBannerId into poll JS');
    like($html, qr/LINE_LATEST/, 'embed includes initial log tail');

    # Poll payload exposes started/online when ready marker is in the tail.
    open(my $done_fh, '>>', "$logs/latest.log") or die $!;
    print {$done_fh} "[Server thread/INFO]: Done (1.2s)! For help, type \"help\"\n";
    close($done_fh);
    my $payload_ready = server_log_monitor_poll_payload(
        server_dir  => $root,
        script_name => 'mcserver',
        source      => 'lgsm',
        minecraft   => 1,
    );
    ok($payload_ready->{ok}, 'poll payload ok');
    is($payload_ready->{started}, 1, 'poll started=1 when Done in log');
    is($payload_ready->{status}, 'online', 'poll status online when Done in log');
    # Without server_control_bar loaded, runtime_html is omitted (CGI loads it).
    # Stub the helper and re-poll to assert blink-stop fields.
    no warnings 'redefine';
    *main::server_runtime_status_badge_html = sub {
        my ($st) = @_;
        return "BADGE:$st";
    };
    my $payload_badge = server_log_monitor_poll_payload(
        server_dir  => $root,
        script_name => 'mcserver',
        source      => 'lgsm',
        minecraft   => 1,
    );
    is($payload_badge->{runtime_status}, 'online', 'poll runtime_status online when ready');
    is($payload_badge->{runtime_html}, 'BADGE:online', 'poll runtime_html for blink stop');
    is($payload_badge->{starting}, 0, 'poll starting=0 when ready marker seen');
}

done_testing();
