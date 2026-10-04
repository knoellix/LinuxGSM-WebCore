#!/usr/bin/perl
# t/test_player_query.pl — player_query meta accessor, config read + readiness
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/..";

chdir "$Bin/.." or die "Cannot chdir to project root: $!";

require 't/stubs.pl';

sub error { die "error: $_[0]\n" }

our ($module_root, $config_directory);
my $tmpdir = tempdir(CLEANUP => 1);
$config_directory = $tmpdir;
$module_root      = "$Bin/../src";

sub write_local_json {
    my ($content) = @_;
    open(my $fh, '>', "$tmpdir/games_meta_local.json") or die $!;
    print $fh $content;
    close $fh;
}

sub write_text_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "Cannot write $path: $!";
    print $fh $content;
    close $fh;
}

require 'src/lib/games_meta.pl';
require 'src/lib/config_editor.pl';
require 'src/lib/live_log.pl';
require 'src/lib/player_query.pl';

# ------------------------------------------------------------------
# demoserver local override exposes player_query.kind
# ------------------------------------------------------------------
write_local_json(<<'JSON');
{
  "demoserver": {
    "name": "Demo Server",
    "player_query": {
      "kind": "rcon",
      "source": "game_config",
      "command": "list",
      "parse": "mc_list"
    }
  }
}
JSON
&_reset_meta_cache();
my $pq = &get_game_player_query('demoserver');
ok($pq, 'get_game_player_query returns hashref for demoserver');
is($pq->{'kind'}, 'rcon', 'demoserver player_query kind is rcon');

# ------------------------------------------------------------------
# unknown script → undef
# ------------------------------------------------------------------
&_reset_meta_cache();
ok(!defined &get_game_player_query('nosuchserver'), 'missing script returns undef');

# ------------------------------------------------------------------
# shallow copy — caller mutation must not affect cached meta
# ------------------------------------------------------------------
&_reset_meta_cache();
$pq = &get_game_player_query('demoserver');
$pq->{'kind'} = 'rest';
$pq = &get_game_player_query('demoserver');
is($pq->{'kind'}, 'rcon', 'returned hash is a shallow copy');

# ------------------------------------------------------------------
# Task 5: real games_meta.json — mc-paper (variant), PZ, Palworld,
# and the Windrose note-only entry.
# ------------------------------------------------------------------
{
    local $config_directory = tempdir(CLEANUP => 1); # no games_meta_local.json
    &_reset_meta_cache();

    # mc-paper is one of mcserver's variants; it also carries its own
    # top-level meta entry (listed in mcserver's variants[] for CSV/lifecycle
    # resolution), so it gets the same RCON player_query block directly.
    my $mc = &get_game_player_query('mc-paper');
    ok($mc, 'mc-paper (variant): get_game_player_query returns hashref');
    is($mc->{'kind'}, 'rcon', 'mc-paper: kind rcon');
    is($mc->{'enabled_key'}, 'enable-rcon', 'mc-paper: enabled_key');
    is($mc->{'port_key'}, 'rcon.port', 'mc-paper: port_key');
    is($mc->{'password_key'}, 'rcon.password', 'mc-paper: password_key');
    is($mc->{'max_players_key'}, 'max-players', 'mc-paper: max_players_key');
    is($mc->{'command'}, 'list', 'mc-paper: command');
    is($mc->{'parse'}, 'mc_list', 'mc-paper: parse');

    my @mc_fields = &get_game_config_fields('mc-paper');
    ok((grep { $_->{'key'} eq 'enable-rcon' } @mc_fields), 'mc-paper: game_config_fields has enable-rcon');
    ok((grep { $_->{'key'} eq 'rcon.port' } @mc_fields), 'mc-paper: game_config_fields has rcon.port');
    ok((grep { $_->{'key'} eq 'rcon.password' } @mc_fields), 'mc-paper: game_config_fields has rcon.password');

    # Project Zomboid — no enabled_key, lines_skip_header parse.
    my $pz = &get_game_player_query('pzserver');
    ok($pz, 'pzserver: get_game_player_query returns hashref');
    is($pz->{'kind'}, 'rcon', 'pzserver: kind rcon');
    is($pz->{'port_key'}, 'RCONPort', 'pzserver: port_key');
    is($pz->{'password_key'}, 'RCONPassword', 'pzserver: password_key');
    is($pz->{'max_players_key'}, 'MaxPlayers', 'pzserver: max_players_key');
    is($pz->{'command'}, 'players', 'pzserver: command');
    is($pz->{'parse'}, 'lines_skip_header', 'pzserver: parse');
    ok(!exists $pz->{'enabled_key'}, 'pzserver: no enabled_key');

    my @pz_fields = &get_game_config_fields('pzserver');
    ok((grep { $_->{'key'} eq 'RCONPort' } @pz_fields), 'pzserver: game_config_fields has RCONPort');
    ok((grep { $_->{'key'} eq 'RCONPassword' } @pz_fields), 'pzserver: game_config_fields has RCONPassword');

    # Palworld — REST transport via json_field.
    my $pw = &get_game_player_query('pwserver');
    ok($pw, 'pwserver: get_game_player_query returns hashref');
    is($pw->{'kind'}, 'rest', 'pwserver: kind rest');
    is($pw->{'enabled_key'}, 'RESTAPIEnabled', 'pwserver: enabled_key');
    is($pw->{'port_key'}, 'RESTAPIPort', 'pwserver: port_key');
    is($pw->{'password_key'}, 'AdminPassword', 'pwserver: password_key');
    is($pw->{'max_players_key'}, 'ServerPlayerMaxNum', 'pwserver: max_players_key');
    is($pw->{'command'}, '/v1/api/metrics', 'pwserver: command');
    is($pw->{'parse'}, 'json_field', 'pwserver: parse');
    is($pw->{'players_field'}, 'currentplayernum', 'pwserver: players_field');
    is($pw->{'max_field'}, 'maxplayernum', 'pwserver: max_field');
    is($pw->{'auth_user'}, 'admin', 'pwserver: auth_user');

    my @pw_fields = &get_game_config_fields('pwserver');
    ok((grep { $_->{'key'} eq 'RESTAPIEnabled' } @pw_fields), 'pwserver: game_config_fields has RESTAPIEnabled');
    ok((grep { $_->{'key'} eq 'RESTAPIPort' } @pw_fields), 'pwserver: game_config_fields has RESTAPIPort');

    # Windrose — note only, no player_query block (code must ignore the
    # note and treat the game as having no player_query at all).
    ok(!defined &get_game_player_query('windrose'), 'windrose: no player_query block');
    my %meta = &load_games_meta();
    ok(exists $meta{'windrose'}{'player_query_note'}, 'windrose: player_query_note present in raw meta');
    ok(!exists $meta{'windrose'}{'player_query'}, 'windrose: no player_query key in raw meta');
}

# ------------------------------------------------------------------
# Task 2: config read + readiness
# ------------------------------------------------------------------

our $PLAYER_QUERY_META_OVERRIDE;

# No meta at all → readiness no_meta, config_values no_meta.
{
    local $PLAYER_QUERY_META_OVERRIDE = undef;
    my $srv = tempdir(CLEANUP => 1);
    my $r = &player_query_readiness($srv, 'nosuchserver');
    is($r->{'ok'}, 0, 'no_meta: readiness not ok');
    is($r->{'reason'}, 'no_meta', 'no_meta: reason no_meta');
    my $cfg = &player_query_config_values($srv, 'nosuchserver');
    is($cfg->{'err'}, 'no_meta', 'no_meta: config_values err no_meta');
}

# Disabled (enabled_key present, falsy value) → missing_enabled.
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "enable-rcon=false\nrcon.port=25575\nrcon.password=secret\nmax-players=10\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        enabled_key     => 'enable-rcon',
        port_key        => 'rcon.port',
        password_key    => 'rcon.password',
        max_players_key => 'max-players',
    };
    my $r = &player_query_readiness($srv, 'testgame');
    is($r->{'ok'}, 0, 'disabled: readiness not ok');
    is($r->{'reason'}, 'missing_enabled', 'disabled: reason missing_enabled');
}

# Empty password → missing_password.
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "enable-rcon=true\nrcon.port=25575\nrcon.password=\nmax-players=10\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        enabled_key     => 'enable-rcon',
        port_key        => 'rcon.port',
        password_key    => 'rcon.password',
        max_players_key => 'max-players',
    };
    my $r = &player_query_readiness($srv, 'testgame');
    is($r->{'ok'}, 0, 'empty password: readiness not ok');
    is($r->{'reason'}, 'missing_password', 'empty password: reason missing_password');
}

# Port 0 → missing_port.
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "enable-rcon=true\nrcon.port=0\nrcon.password=secret\nmax-players=10\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        enabled_key     => 'enable-rcon',
        port_key        => 'rcon.port',
        password_key    => 'rcon.password',
        max_players_key => 'max-players',
    };
    my $r = &player_query_readiness($srv, 'testgame');
    is($r->{'ok'}, 0, 'port 0: readiness not ok');
    is($r->{'reason'}, 'missing_port', 'port 0: reason missing_port');
}

# All good → ok, and config_values extracts the right fields.
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "enable-rcon=true\nrcon.port=25575\nrcon.password=secret\nmax-players=10\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        enabled_key     => 'enable-rcon',
        port_key        => 'rcon.port',
        password_key    => 'rcon.password',
        max_players_key => 'max-players',
    };
    my $r = &player_query_readiness($srv, 'testgame');
    is($r->{'ok'}, 1, 'ok: readiness ok');
    is($r->{'reason'}, '', 'ok: reason empty');

    my $cfg = &player_query_config_values($srv, 'testgame');
    is($cfg->{'err'}, '', 'ok: config_values no error');
    is($cfg->{'enabled'}, 1, 'ok: enabled true');
    is($cfg->{'port'}, 25575, 'ok: port parsed');
    is($cfg->{'password'}, 'secret', 'ok: password parsed');
    is($cfg->{'max_players'}, 10, 'ok: max_players parsed');
}

# Meta omits enabled_key (PZ-style) — enabled implied when password+port ok.
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "RCONPort=16261\nRCONPassword=changeme\nMaxPlayers=32\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        port_key        => 'RCONPort',
        password_key    => 'RCONPassword',
        max_players_key => 'MaxPlayers',
    };
    my $r = &player_query_readiness($srv, 'testgame');
    is($r->{'ok'}, 1, 'no enabled_key + password/port ok: readiness ok');
    is($r->{'reason'}, '', 'no enabled_key + password/port ok: reason empty');

    # Still enforces missing_password without an enabled_key.
    write_text_file("$srv/serverfiles/server.properties",
        "RCONPort=16261\nRCONPassword=\nMaxPlayers=32\n");
    my $r2 = &player_query_readiness($srv, 'testgame');
    is($r2->{'ok'}, 0, 'no enabled_key + empty password: readiness not ok');
    is($r2->{'reason'}, 'missing_password', 'no enabled_key + empty password: reason missing_password');
}

# Unsafe/unresolvable game_config_path (traversal) → config_unreadable.
{
    write_local_json(<<'JSON');
{
  "badpathgame": {
    "name": "Bad Path Game",
    "game_config_path": "../outside.properties"
  }
}
JSON
    &_reset_meta_cache();
    my $srv = tempdir(CLEANUP => 1);
    local $PLAYER_QUERY_META_OVERRIDE = {
        port_key     => 'rcon.port',
        password_key => 'rcon.password',
    };
    my $r = &player_query_readiness($srv, 'badpathgame');
    is($r->{'ok'}, 0, 'unsafe path: readiness not ok');
    is($r->{'reason'}, 'config_unreadable', 'unsafe path: reason config_unreadable');
    my $cfg = &player_query_config_values($srv, 'badpathgame');
    is($cfg->{'err'}, 'config_unreadable', 'unsafe path: config_values err config_unreadable');
}

# ------------------------------------------------------------------
# Task 3: player_query_parse (no network)
# ------------------------------------------------------------------

# mc_list — standard Minecraft `list` response.
{
    my $r = &player_query_parse('mc_list',
        "There are 3 of a max of 20 players online:\nSteve\nAlex\n",
        {});
    is($r->{'ok'}, 1, 'mc_list: ok');
    is($r->{'players'}, 3, 'mc_list: players');
    is($r->{'max'}, 20, 'mc_list: max');
}

# mc_list — zero players.
{
    my $r = &player_query_parse('mc_list',
        "There are 0 of a max of 10 players online",
        {});
    is($r->{'ok'}, 1, 'mc_list zero: ok');
    is($r->{'players'}, 0, 'mc_list zero: players');
    is($r->{'max'}, 10, 'mc_list zero: max');
}

# mc_list — no match → parse error.
{
    my $r = &player_query_parse('mc_list', "Unknown command\n", {});
    is($r->{'ok'}, 0, 'mc_list bad: not ok');
    ok(length($r->{'err'}), 'mc_list bad: err set');
}

# lines_skip_header — header only, zero players.
{
    my $r = &player_query_parse('lines_skip_header', "Players connected:\n", {});
    is($r->{'ok'}, 1, 'lines_skip_header 0: ok');
    is($r->{'players'}, 0, 'lines_skip_header 0: players');
}

# lines_skip_header — skip first non-empty line, count rest.
{
    my $r = &player_query_parse('lines_skip_header',
        "Players connected:\nAlice\nBob\n\nCharlie\n",
        {});
    is($r->{'ok'}, 1, 'lines_skip_header N: ok');
    is($r->{'players'}, 3, 'lines_skip_header N: players');
}

# json_field — Palworld-style metrics.
{
    my $r = &player_query_parse('json_field',
        '{"currentplayernum":5,"serverplayermaxnum":32}',
        { players_field => 'currentplayernum', max_field => 'serverplayermaxnum' });
    is($r->{'ok'}, 1, 'json_field: ok');
    is($r->{'players'}, 5, 'json_field: players');
    is($r->{'max'}, 32, 'json_field: max');
}

# json_field — players only (no max_field in meta).
{
    my $r = &player_query_parse('json_field',
        '{"currentplayernum":2}',
        { players_field => 'currentplayernum' });
    is($r->{'ok'}, 1, 'json_field no max: ok');
    is($r->{'players'}, 2, 'json_field no max: players');
    is($r->{'max'}, 0, 'json_field no max: max 0');
}

# json_field — invalid JSON.
{
    my $r = &player_query_parse('json_field', 'not json', { players_field => 'x' });
    is($r->{'ok'}, 0, 'json_field bad json: not ok');
    ok(length($r->{'err'}), 'json_field bad json: err set');
}

# unknown parse type.
{
    my $r = &player_query_parse('nosuchparser', 'raw', {});
    is($r->{'ok'}, 0, 'unknown parse: not ok');
    ok(length($r->{'err'}), 'unknown parse: err set');
}

# ------------------------------------------------------------------
# Task 4: player_query_count — transports, states, cache
# ------------------------------------------------------------------

our ($PLAYER_QUERY_RCON_FETCH, $PLAYER_QUERY_REST_FETCH);

sub _pq_read_cache_json {
    my ($srv) = @_;
    my $file = "$srv/.monitor/player_query.json";
    open(my $fh, '<', $file) or die "Cannot read $file: $!";
    local $/;
    my $raw = <$fh>;
    close($fh);
    require JSON::PP;
    return JSON::PP::decode_json($raw);
}

sub _pq_write_cache_json {
    my ($srv, $data) = @_;
    my $file = "$srv/.monitor/player_query.json";
    require JSON::PP;
    open(my $fh, '>', $file) or die "Cannot write $file: $!";
    print $fh JSON::PP::encode_json($data);
    close($fh);
}

# runtime_online => 0 → waiting, no network, no meta/readiness lookup needed.
{
    local $PLAYER_QUERY_META_OVERRIDE = undef;
    my $srv = tempdir(CLEANUP => 1);
    my $r = &player_query_count($srv, 'testgame', runtime_online => 0);
    is($r->{'ok'}, 0, 'runtime offline: not ok');
    is($r->{'state'}, 'waiting', 'runtime offline: state waiting');
    is($r->{'players'}, 0, 'runtime offline: players 0');
}

# No meta at all → state none.
{
    local $PLAYER_QUERY_META_OVERRIDE = undef;
    my $srv = tempdir(CLEANUP => 1);
    my $r = &player_query_count($srv, 'nosuchserver', runtime_online => 1);
    is($r->{'ok'}, 0, 'no meta: not ok');
    is($r->{'state'}, 'none', 'no meta: state none');
}

# Readiness fail (empty password) → state rcon_missing, no fetch attempted.
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "enable-rcon=true\nrcon.port=25575\nrcon.password=\nmax-players=10\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        kind             => 'rcon',
        enabled_key      => 'enable-rcon',
        port_key         => 'rcon.port',
        password_key     => 'rcon.password',
        max_players_key  => 'max-players',
        command          => 'list',
        parse            => 'mc_list',
    };
    my $calls = 0;
    local $PLAYER_QUERY_RCON_FETCH = sub { $calls++; return ('', ''); };
    my $r = &player_query_count($srv, 'testgame', runtime_online => 1);
    is($r->{'ok'}, 0, 'not ready: not ok');
    is($r->{'state'}, 'rcon_missing', 'not ready: state rcon_missing');
    is($calls, 0, 'not ready: fetch never called');
}

# RCON success + cache: two counts hit cache once; TTL expiry triggers a
# second fetch. Also verifies config max_players wins over parsed max.
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "enable-rcon=true\nrcon.port=25575\nrcon.password=secret\nmax-players=10\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        kind             => 'rcon',
        enabled_key      => 'enable-rcon',
        port_key         => 'rcon.port',
        password_key     => 'rcon.password',
        max_players_key  => 'max-players',
        command          => 'list',
        parse            => 'mc_list',
    };
    my $calls = 0;
    local $PLAYER_QUERY_RCON_FETCH = sub {
        $calls++;
        return ("There are 3 of a max of 20 players online", '');
    };

    my $r1 = &player_query_count($srv, 'testgame', runtime_online => 1);
    is($r1->{'ok'}, 1, 'rcon ok: ok');
    is($r1->{'players'}, 3, 'rcon ok: players');
    is($r1->{'max'}, 10, 'rcon ok: max prefers config max_players over parsed max');
    is($r1->{'state'}, 'ok', 'rcon ok: state ok');
    is($calls, 1, 'rcon ok: fetch called once');

    my $r2 = &player_query_count($srv, 'testgame', runtime_online => 1);
    is($r2->{'players'}, 3, 'cache hit: players from cache');
    is($calls, 1, 'cache hit: fetch not called again within TTL');

    ok(-f "$srv/.monitor/player_query.json", 'cache file written');
    my @st = stat("$srv/.monitor/player_query.json");
    is($st[2] & 0777, 0600, 'cache file mode 0600');

    # Backdate the cache ts beyond the 60s TTL to force a refetch.
    my $data = _pq_read_cache_json($srv);
    $data->{'ts'} = time() - 61;
    _pq_write_cache_json($srv, $data);

    my $r3 = &player_query_count($srv, 'testgame', runtime_online => 1);
    is($r3->{'players'}, 3, 'ttl expiry: players refetched');
    is($calls, 2, 'ttl expiry: fetch called again after TTL');
}

# Cache write with opts{unix_user} threaded through (Important #1 fix).
# player_query_count() must pass opts{unix_user} into _pq_cache_write(), but
# the su branch there only fires when the user string matches the strict
# unix_user format AND $> == 0 (root). To get a deterministic cross-host
# result (this suite may run as root or non-root — unlike write_monitor_state
# tests, which never pass a unix_user at all), use a syntactically invalid
# unix_user so the direct-write fallback is always taken, regardless of
# euid. This still exercises the opts{unix_user} -> _pq_cache_write wiring
# and the fallback path's 0600 mode / TTL behavior; the su path itself
# mirrors write_monitor_state's (already-shipped, unexercised-in-tests) su
# branch and is left to manual QA on the live Webmin CGI (always root).
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "enable-rcon=true\nrcon.port=25575\nrcon.password=secret\nmax-players=10\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        kind             => 'rcon',
        enabled_key      => 'enable-rcon',
        port_key         => 'rcon.port',
        password_key     => 'rcon.password',
        max_players_key  => 'max-players',
        command          => 'list',
        parse            => 'mc_list',
    };
    local $PLAYER_QUERY_RCON_FETCH = sub {
        return ("There are 2 of a max of 20 players online", '');
    };

    # Uppercase does not match /^[a-z][a-z0-9_-]{0,30}$/ -> direct-write
    # fallback on any host, root or not.
    my $r = &player_query_count($srv, 'testgame', runtime_online => 1, unix_user => 'Not_A_Valid_Unix_User');
    is($r->{'ok'}, 1, 'cache write with unix_user opt: still succeeds (direct-write fallback)');

    ok(-f "$srv/.monitor/player_query.json", 'cache write with unix_user opt: cache file written');
    my @st = stat("$srv/.monitor/player_query.json");
    is($st[2] & 0777, 0600, 'cache write with unix_user opt: cache file mode 0600');
    my $data = _pq_read_cache_json($srv);
    is($data->{'players'}, 2, 'cache write with unix_user opt: cache content correct');
}

# RCON transport failure → unreachable, never a fake players=0 success.
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "enable-rcon=true\nrcon.port=25575\nrcon.password=secret\nmax-players=10\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        kind             => 'rcon',
        enabled_key      => 'enable-rcon',
        port_key         => 'rcon.port',
        password_key     => 'rcon.password',
        max_players_key  => 'max-players',
        command          => 'list',
        parse            => 'mc_list',
    };
    local $PLAYER_QUERY_RCON_FETCH = sub { return (undef, 'auth_failed'); };

    my $r = &player_query_count($srv, 'testgame', runtime_online => 1);
    is($r->{'ok'}, 0, 'rcon fail: not ok');
    is($r->{'players'}, 0, 'rcon fail: players 0 (not a fake success)');
    is($r->{'state'}, 'unreachable', 'rcon fail: state unreachable');
    is($r->{'err'}, 'auth_failed', 'rcon fail: err propagated');
}

# Failed cache expires quickly (10s) so post-boot RCON can recover.
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "enable-rcon=true\nrcon.port=25575\nrcon.password=secret\nmax-players=10\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        kind             => 'rcon',
        enabled_key      => 'enable-rcon',
        port_key         => 'rcon.port',
        password_key     => 'rcon.password',
        max_players_key  => 'max-players',
        command          => 'list',
        parse            => 'mc_list',
    };
    my $calls = 0;
    local $PLAYER_QUERY_RCON_FETCH = sub {
        $calls++;
        return (undef, 'conn_refused') if $calls == 1;
        return ("There are 1 of a max of 10 players online", '');
    };
    my $r1 = &player_query_count($srv, 'testgame', runtime_online => 1);
    is($r1->{'state'}, 'unreachable', 'fail-cache: first call unreachable');
    my $r2 = &player_query_count($srv, 'testgame', runtime_online => 1);
    is($calls, 1, 'fail-cache: second call within 10s still cached');
    is($r2->{'state'}, 'unreachable', 'fail-cache: still unreachable from cache');
    my $data = _pq_read_cache_json($srv);
    $data->{'ts'} = time() - 11;
    _pq_write_cache_json($srv, $data);
    my $r3 = &player_query_count($srv, 'testgame', runtime_online => 1);
    is($calls, 2, 'fail-cache: after 10s TTL refetch');
    is($r3->{'ok'}, 1, 'fail-cache: recovers after TTL');
}

# RCON parse mismatch (garbage response) → unreachable, not success.
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "enable-rcon=true\nrcon.port=25575\nrcon.password=secret\nmax-players=10\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        kind             => 'rcon',
        enabled_key      => 'enable-rcon',
        port_key         => 'rcon.port',
        password_key     => 'rcon.password',
        max_players_key  => 'max-players',
        command          => 'list',
        parse            => 'mc_list',
    };
    local $PLAYER_QUERY_RCON_FETCH = sub { return ("Unknown command", ''); };

    my $r = &player_query_count($srv, 'testgame', runtime_online => 1);
    is($r->{'ok'}, 0, 'rcon parse mismatch: not ok');
    is($r->{'state'}, 'unreachable', 'rcon parse mismatch: state unreachable');
}

# REST (Palworld-style) success via json_field; max falls back to parsed
# value when config max_players is 0 (not configured).
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "RESTAPIEnabled=true\nRESTAPIPort=8212\nAdminPassword=secret\nServerPlayerMaxNum=0\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        kind             => 'rest',
        enabled_key      => 'RESTAPIEnabled',
        port_key         => 'RESTAPIPort',
        password_key     => 'AdminPassword',
        max_players_key  => 'ServerPlayerMaxNum',
        command          => '/v1/api/metrics',
        parse            => 'json_field',
        players_field    => 'currentplayernum',
        max_field        => 'serverplayermaxnum',
        auth_user        => 'admin',
    };
    my @seen_args;
    local $PLAYER_QUERY_REST_FETCH = sub {
        @seen_args = @_;
        return ('{"currentplayernum":5,"serverplayermaxnum":32}', '');
    };

    my $r = &player_query_count($srv, 'testgame', runtime_online => 1);
    is($r->{'ok'}, 1, 'rest ok: ok');
    is($r->{'players'}, 5, 'rest ok: players');
    is($r->{'max'}, 32, 'rest ok: max falls back to parsed value');
    is($r->{'state'}, 'ok', 'rest ok: state ok');
    is($seen_args[0], '127.0.0.1', 'rest fetch: host always 127.0.0.1');
    is($seen_args[1], 8212, 'rest fetch: port from config');
    is($seen_args[2], '/v1/api/metrics', 'rest fetch: command/path');
    is($seen_args[3], 'admin', 'rest fetch: auth_user default admin');
    is($seen_args[4], 'secret', 'rest fetch: password from config');
}

# REST transport failure → unreachable, not a fake success.
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "RESTAPIEnabled=true\nRESTAPIPort=8212\nAdminPassword=secret\nServerPlayerMaxNum=0\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        kind             => 'rest',
        enabled_key      => 'RESTAPIEnabled',
        port_key         => 'RESTAPIPort',
        password_key     => 'AdminPassword',
        max_players_key  => 'ServerPlayerMaxNum',
        command          => '/v1/api/metrics',
        parse            => 'json_field',
        players_field    => 'currentplayernum',
    };
    local $PLAYER_QUERY_REST_FETCH = sub { return (undef, 'connect_failed'); };

    my $r = &player_query_count($srv, 'testgame', runtime_online => 1);
    is($r->{'ok'}, 0, 'rest fail: not ok');
    is($r->{'players'}, 0, 'rest fail: players 0 (not a fake success)');
    is($r->{'state'}, 'unreachable', 'rest fail: state unreachable');
    is($r->{'err'}, 'connect_failed', 'rest fail: err propagated');
}

# ------------------------------------------------------------------
# Task 6: player_query_status_html — value HTML, lang keys, escaping
# ------------------------------------------------------------------

our %text;

# No meta at all → ''.
{
    local $PLAYER_QUERY_META_OVERRIDE = undef;
    my $srv = tempdir(CLEANUP => 1);
    my $html = &player_query_status_html($srv, 'nosuchserver', runtime_status => 'online');
    is($html, '', 'status_html no meta: empty string');
}

# Not online (e.g. starting/offline) → waiting value + tip, escaped.
{
    local $PLAYER_QUERY_META_OVERRIDE = {
        kind => 'rcon', port_key => 'rcon.port', password_key => 'rcon.password',
        command => 'list', parse => 'mc_list',
    };
    local %text = (
        manage_players_waiting     => 'Wait <me>',
        manage_players_waiting_tip => 'Tip "with" quotes',
    );
    my $srv = tempdir(CLEANUP => 1);
    my $html = &player_query_status_html($srv, 'testgame', runtime_status => 'starting');
    like($html, qr/Wait &lt;me&gt;/, 'status_html not online: waiting value escaped');
    like($html, qr/title="Tip &quot;with&quot; quotes"/, 'status_html not online: waiting tip escaped in title');
}

# Not online with no %text set → sane fallback value+tip present (non-empty).
{
    local $PLAYER_QUERY_META_OVERRIDE = {
        kind => 'rcon', port_key => 'rcon.port', password_key => 'rcon.password',
        command => 'list', parse => 'mc_list',
    };
    local %text = ();
    my $srv = tempdir(CLEANUP => 1);
    my $html = &player_query_status_html($srv, 'testgame', runtime_status => 'offline');
    ok(length($html), 'status_html not online, no lang keys: fallback non-empty');
    like($html, qr/title="/, 'status_html not online, no lang keys: has a tooltip');
}

# Readiness fail (empty password) → RCON fehlt value + tip, escaped.
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "enable-rcon=true\nrcon.port=25575\nrcon.password=\nmax-players=10\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        kind => 'rcon', enabled_key => 'enable-rcon', port_key => 'rcon.port',
        password_key => 'rcon.password', max_players_key => 'max-players',
        command => 'list', parse => 'mc_list',
    };
    local %text = (
        manage_players_rcon_missing     => 'RCON <fehlt>',
        manage_players_rcon_missing_tip => 'Need "RCON" on',
    );
    my $html = &player_query_status_html($srv, 'testgame', runtime_status => 'online');
    like($html, qr/RCON &lt;fehlt&gt;/, 'status_html readiness fail: value escaped');
    like($html, qr/title="Need &quot;RCON&quot; on"/, 'status_html readiness fail: tip escaped in title');
}

# Count ok with max>0 → "players/max", no tooltip markup.
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "enable-rcon=true\nrcon.port=25575\nrcon.password=secret\nmax-players=10\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        kind => 'rcon', enabled_key => 'enable-rcon', port_key => 'rcon.port',
        password_key => 'rcon.password', max_players_key => 'max-players',
        command => 'list', parse => 'mc_list',
    };
    local $PLAYER_QUERY_RCON_FETCH = sub {
        return ("There are 3 of a max of 20 players online", '');
    };
    my $html = &player_query_status_html($srv, 'testgame', runtime_status => 'online');
    is($html, '3/10', 'status_html count ok: players/max (config max wins)');
}

# Count ok with max=0 (no max_players_key / config max 0, parser gives no max
# either) → bare player count, no slash.
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "RCONPort=16261\nRCONPassword=changeme\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        kind => 'rcon', port_key => 'RCONPort', password_key => 'RCONPassword',
        command => 'players', parse => 'lines_skip_header',
    };
    local $PLAYER_QUERY_RCON_FETCH = sub {
        return ("Players connected:\nAlice\nBob\nCharlie\n", '');
    };
    my $html = &player_query_status_html($srv, 'testgame', runtime_status => 'running');
    is($html, '3', 'status_html count ok, no max: bare player count');
}

# Unreachable (transport failure) → '?' value + tip, escaped.
{
    my $srv = tempdir(CLEANUP => 1);
    make_path("$srv/serverfiles");
    write_text_file("$srv/serverfiles/server.properties",
        "enable-rcon=true\nrcon.port=25575\nrcon.password=secret\nmax-players=10\n");
    local $PLAYER_QUERY_META_OVERRIDE = {
        kind => 'rcon', enabled_key => 'enable-rcon', port_key => 'rcon.port',
        password_key => 'rcon.password', max_players_key => 'max-players',
        command => 'list', parse => 'mc_list',
    };
    local $PLAYER_QUERY_RCON_FETCH = sub { return (undef, 'auth_failed'); };
    local %text = (
        manage_players_unreachable     => '?<x>',
        manage_players_unreachable_tip => 'Down "now"',
    );
    my $html = &player_query_status_html($srv, 'testgame', runtime_status => 'online');
    like($html, qr/\?&lt;x&gt;/, 'status_html unreachable: value escaped');
    like($html, qr/title="Down &quot;now&quot; \(auth_failed\)"/,
        'status_html unreachable: tip escaped + err code appended');
}

# ------------------------------------------------------------------
# Task 7: player_query_poll_js — 60s visibility-aware client poll emission
# ------------------------------------------------------------------

{
    my $js = &player_query_poll_js('');
    is($js, '', 'poll_js: empty poll_url returns empty string');
}

{
    my $js = &player_query_poll_js('/linuxgsm-webcore/manage.cgi?instance_id=demo&action=poll_players');
    like($js, qr/<script>/, 'poll_js: emits a script tag');
    like($js, qr/\.js-player-query/, 'poll_js: targets .js-player-query');
    like($js, qr/innerHTML/, 'poll_js: uses innerHTML (trusted server fragment)');
    like($js, qr/document\.hidden/, 'poll_js: checks document.hidden');
    like($js, qr/visibilitychange/, 'poll_js: listens for visibilitychange');
    like($js, qr/60000/, 'poll_js: 60s interval');
    like($js, qr{manage\.cgi\?instance_id=demo&action=poll_players},
        'poll_js: embeds the poll URL');
}

done_testing();
