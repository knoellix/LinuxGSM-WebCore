#!/usr/bin/perl
# Tests for auto_update_pz.pl — PZ adapter (build, workshop, players, broadcast).
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);

chdir "$Bin/.." or die "Cannot chdir to project root: $!";
require "$Bin/stubs.pl";

our (%text, %config, $module_root);
$module_root = "$Bin/../src";
%config = (steam_web_api_key => 'test-key');

require "$Bin/../src/lib/games_meta.pl";
require "$Bin/../src/lib/pz_workshop.pl";
require "$Bin/../src/lib/query.pl";
require "$Bin/../src/lib/auto_update_pz.pl";

our ($AUTO_UPDATE_PZ_REMOTE_BUILD_FETCH, $AUTO_UPDATE_PZ_STEAM_DETAILS_FETCH);

sub _write_appmanifest {
    my ($path, $buildid) = @_;
    make_path(dirname($path));
    open my $fh, '>', $path or die $!;
    print $fh <<"ACF";
"AppState"
{
\t"appid"\t\t"380870"
\t"buildid"\t\t"$buildid"
\t"LastUpdated"\t\t"1700000000"
}
ACF
    close $fh;
}

subtest 'auto_update_adapter_for_script' => sub {
    is(auto_update_adapter_for_script('pzserver'), 'pz', 'pzserver => pz');
    is(auto_update_adapter_for_script('pztest'), '', 'unknown pz* without workshop meta => empty');
    is(auto_update_adapter_for_script('mcserver'), '', 'mcserver => empty');
    is(auto_update_adapter_for_script(''), '', 'empty => empty');
};

subtest 'auto_update_pz_game_build_local' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    is(auto_update_pz_game_build_local(''), '', 'empty server_dir');

    my $manifest = "$tmp/srv/serverfiles/steamapps/appmanifest_380870.acf";
    _write_appmanifest($manifest, '9876543');
    is(auto_update_pz_game_build_local("$tmp/srv"), '9876543', 'reads buildid from appmanifest');

    unlink $manifest;
    is(auto_update_pz_game_build_local("$tmp/srv"), '', 'missing manifest => empty');
};

subtest 'auto_update_pz_game_build_remote' => sub {
    local $AUTO_UPDATE_PZ_REMOTE_BUILD_FETCH = sub {
        return ('5555555', undef);
    };
    my ($build, $err) = auto_update_pz_game_build_remote();
    is($build, '5555555', 'mock remote buildid');
    is($err, undef, 'no error on success');

    local $AUTO_UPDATE_PZ_REMOTE_BUILD_FETCH = sub {
        return ('', 'network_failed');
    };
    ($build, $err) = auto_update_pz_game_build_remote();
    is($build, '', 'empty build on failure');
    is($err, 'network_failed', 'error propagated');
};

subtest 'auto_update_pz_workshop_diff' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $user = getpwuid($>) // 'testuser';
    my $home = "$tmp/home";
    make_path("$home/Zomboid/Server");
    my $ini = "$home/Zomboid/Server/pzserver.ini";
    open my $fh, '>', $ini or die $!;
    print $fh "WorkshopItems=2859296945;2169435913\nMods=\n";
    close $fh;

    my $content_root = "$home/Steam/steamapps/workshop/content/108600";
    make_path("$content_root/2859296945/mods/X");
    make_path("$content_root/2169435913/mods/Y");
    utime 1600000000, 1600000000, "$content_root/2859296945";
    utime 1700000100, 1700000100, "$content_root/2169435913";

    local $AUTO_UPDATE_PZ_STEAM_DETAILS_FETCH = sub {
        my ($ids) = @_;
        return {
            '2859296945' => { time_updated => 1700000000 }, # newer than local 1600000000
            '2169435913' => { time_updated => 1690000000 }, # older than local 1700000100
        };
    };

    # Stub home lookup for test user
    no warnings 'redefine';
    local *pz_workshop_unix_home = sub {
        my ($u) = @_;
        return $u eq $user ? $home : undef;
    };

    my $res = auto_update_pz_workshop_diff($user, "$tmp/srv", 'pzserver');
    ok(ref($res) eq 'HASH', 'returns hashref');
    is($res->{err}, '', 'no err on success');
    is_deeply($res->{changed}, ['2859296945'], 'only newer remote workshop id');

    local $AUTO_UPDATE_PZ_STEAM_DETAILS_FETCH = sub { return {}; };
    local %config = (%config, steam_web_api_key => '');
    $res = auto_update_pz_workshop_diff($user, "$tmp/srv", 'pzserver');
    is($res->{err}, 'api_key_missing', 'missing api key => err');
    is_deeply($res->{changed}, [], 'no changes when skipped');
};

# C1: game-user cron cannot read /etc/webmin config — secrets file overlays key.
subtest 'auto_update secrets overlay for workshop detect' => sub {
    require "$Bin/../src/lib/module_config.pl";
    require "$Bin/../src/lib/auto_update.pl";

    my $tmp = tempdir(CLEANUP => 1);
    my $user = getpwuid($>) // 'testuser';
    my $home = "$tmp/home";
    my $server = "$tmp/srv";
    make_path("$home/Zomboid/Server", "$server/.monitor",
        "$home/Steam/steamapps/workshop/content/108600/2859296945");
    open my $ini, '>', "$home/Zomboid/Server/pzserver.ini" or die $!;
    print $ini "WorkshopItems=2859296945\nMods=\n";
    close $ini;
    utime 1600000000, 1600000000,
        "$home/Steam/steamapps/workshop/content/108600/2859296945";

    local $AUTO_UPDATE_PZ_STEAM_DETAILS_FETCH = sub {
        return { '2859296945' => { time_updated => 1700000000 } };
    };
    no warnings 'redefine';
    local *pz_workshop_unix_home = sub {
        my ($u) = @_;
        return $u eq $user ? $home : undef;
    };

    # Simulate unreadable/empty Webmin config (game user).
    local %config = (steam_web_api_key => '');
    my $res = auto_update_pz_workshop_diff($user, $server, 'pzserver');
    is($res->{err}, 'api_key_missing', 'C1: no secrets => api_key_missing');

    ok(write_auto_update_secrets($server, '', {
        steam_web_api_key => 'from-instance-secrets',
    }), 'C1: write instance secrets');
    ok(module_config_apply_auto_update_secrets($server),
        'C1: apply auto_update_secrets overlay');
    is($config{steam_web_api_key}, 'from-instance-secrets',
        'C1: key loaded from secrets file');

    $res = auto_update_pz_workshop_diff($user, $server, 'pzserver');
    isnt($res->{err}, 'api_key_missing',
        'C1: secrets present => not api_key_missing');
    is($res->{err}, '', 'C1: workshop diff succeeds with secrets overlay');
    is_deeply($res->{changed}, ['2859296945'], 'C1: detects workshop change');
};

subtest 'auto_update_pz_player_count' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $server = "$tmp/srv";
    make_path("$server/lgsm/config-lgsm/pzserver");
    open my $fh, '>', "$server/lgsm/config-lgsm/pzserver/pzserver.cfg" or die $!;
    print $fh "queryport=16261\n";
    close $fh;

    no warnings 'redefine';
    local *a2s_query = sub {
        my ($host, $port) = @_;
        return { players => 3, max => 16 } if $port == 16261;
        return undef;
    };
    is(auto_update_pz_player_count($server, 'pzserver'), 3, 'a2s returns player count');

    local *a2s_query = sub { return undef; };
    is(auto_update_pz_player_count($server, 'pzserver'), -1, 'a2s fail => -1 unknown');

    is(auto_update_pz_player_count($server, 'mcserver'), -1, 'non-pz script => -1');
};

subtest 'auto_update_pz_broadcast_cmd' => sub {
    is(auto_update_pz_broadcast_cmd('Hello'), 'servermsg "Hello"', 'simple message');
    is(auto_update_pz_broadcast_cmd('Say "hi"'), 'servermsg "Say \"hi\""', 'escapes double quotes');
    is(auto_update_pz_broadcast_cmd(''), 'servermsg ""', 'empty message');
    like(auto_update_pz_broadcast_cmd("a\nb\$c"), qr/servermsg "a b\\\$c"/, 'strips newline escapes dollar');
};

subtest 'auto_update_pz_detect_print bash-eval safe' => sub {
    my $out = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        auto_update_pz_detect_print({
            need_game     => 1,
            need_workshop => 1,
            mods          => [ '123', '456' ],
            players       => 2,
            reason        => 'Spiel-Update + Workshop-Update',
            err           => 'game:timeout; workshop:api_failed',
        });
        close STDOUT;
    }
    like($out, qr/^REASON='Spiel-Update \+ Workshop-Update'$/m, 'REASON single-quoted');
    like($out, qr/^ERR='game:timeout; workshop:api_failed'$/m, 'ERR single-quoted');
    my %env;
    for my $line (split /\n/, $out) {
        next unless $line =~ /^([A-Z_]+)=(.*)$/;
        my ($k, $v) = ($1, $2);
        if ($v =~ /^'(.*)'\z/s) {
            $v = $1;
            $v =~ s/'\\''/'/g;
        }
        $env{$k} = $v;
    }
    is($env{REASON}, 'Spiel-Update + Workshop-Update', 'REASON survives parse');
    is($env{ERR}, 'game:timeout; workshop:api_failed', 'ERR survives parse');
    is($env{MODS}, '123,456', 'MODS ok');
};

subtest 'auto_update_pz_detect' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $user = getpwuid($>) // 'testuser';
    my $home = "$tmp/home";
    my $server = "$tmp/srv";
    make_path("$home/Zomboid/Server", "$server/lgsm/config-lgsm/pzserver",
        "$server/serverfiles/steamapps",
        "$home/Steam/steamapps/workshop/content/108600/2859296945");
    open my $ini, '>', "$home/Zomboid/Server/pzserver.ini" or die $!;
    print $ini "WorkshopItems=2859296945\nMods=\n";
    close $ini;
    utime 1600000000, 1600000000, "$home/Steam/steamapps/workshop/content/108600/2859296945";
    open my $cfg, '>', "$server/lgsm/config-lgsm/pzserver/pzserver.cfg" or die $!;
    print $cfg "queryport=16261\n";
    close $cfg;
    _write_appmanifest("$server/serverfiles/steamapps/appmanifest_380870.acf", '100');

    no warnings 'redefine';
    local *pz_workshop_unix_home = sub {
        my ($u) = @_;
        return $u eq $user ? $home : undef;
    };
    local $AUTO_UPDATE_PZ_REMOTE_BUILD_FETCH = sub { return ('200', undef); };
    local $AUTO_UPDATE_PZ_STEAM_DETAILS_FETCH = sub {
        return { '2859296945' => { time_updated => 1700000000 } };
    };
    local *a2s_query = sub { return { players => 0, max => 16 }; };

    my $r = auto_update_pz_detect($user, $server, 'pzserver', {
        check_game     => 1,
        check_workshop => 1,
    });
    is($r->{need_game}, 1, 'detect need_game when build differs');
    is($r->{need_workshop}, 1, 'detect need_workshop when mod newer');
    is($r->{players}, 0, 'detect players');
    is_deeply($r->{mods}, ['2859296945'], 'detect mods list');
    like($r->{reason}, qr/Spiel-Update/, 'reason mentions game');
    like($r->{reason}, qr/Workshop-Update/, 'reason mentions workshop');
    is($r->{err}, '', 'no err on success');
};

done_testing();
