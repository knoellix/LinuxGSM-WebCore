# LinuxGSM-WebCore - Player query (RCON/REST) config read + readiness
#
# Reads the RCON/REST connection details (enabled flag, port, password,
# max players) that games_meta `player_query` points at inside the game's
# own config file, and reports whether a live query is currently possible.
# No RCON/REST network I/O here — see player_query_count() (Task 4+).
#
# Depends on (must already be loaded by the caller):
#   src/lib/games_meta.pl   — get_game_player_query, get_game_config_path,
#                              get_game_config_path_base, resolve_game_config_home
#   src/lib/config_editor.pl — resolve_game_server_config_path,
#                              read_game_config_raw, parse_game_config_values
use strict;
use warnings;

our (%text);

# Test-only override: coderef($script) -> hashref, or a plain hashref
# returned regardless of $script. Lets Task 2+ tests exercise readiness
# without depending on the shipped games_meta.json player_query blocks.
our $PLAYER_QUERY_META_OVERRIDE;

# Test-only transport hooks (Task 4). When set to a coderef, replaces the
# real network call entirely so player_query_count() can be exercised
# without a live RCON/REST server.
#   $PLAYER_QUERY_RCON_FETCH->($host, $port, $password, $command, $timeout)
#       -> ($raw, $err)   # $err '' on success, else error code
#   $PLAYER_QUERY_REST_FETCH->($host, $port, $path, $auth_user, $password, $timeout)
#       -> ($raw, $err)
our $PLAYER_QUERY_RCON_FETCH;
our $PLAYER_QUERY_REST_FETCH;

use constant PLAYER_QUERY_HOST            => '127.0.0.1';
use constant PLAYER_QUERY_TIMEOUT         => 2;
use constant PLAYER_QUERY_CACHE_TTL       => 60;
# Failed RCON/REST must not stick for a full minute — PZ often reports
# process-online before RCON listens; short fail TTL lets the next poll recover.
use constant PLAYER_QUERY_FAIL_CACHE_TTL  => 10;

# Return shallow copy of player_query meta for $script, or undef.
sub player_query_meta {
    my ($script) = @_;
    if (defined $PLAYER_QUERY_META_OVERRIDE) {
        my $ov = $PLAYER_QUERY_META_OVERRIDE;
        $ov = $ov->($script) if ref($ov) eq 'CODE';
        return undef unless ref($ov) eq 'HASH' && keys %$ov;
        return { %$ov };
    }
    return undef unless defined &get_game_player_query;
    return &get_game_player_query($script);
}

# Truthy per spec: 1/true/yes/on (case-insensitive); everything else falsy.
sub _player_query_truthy {
    my ($v) = @_;
    $v = '' unless defined $v;
    $v =~ s/^\s+|\s+$//g;
    return ($v =~ /^(?:1|true|yes|on)$/i) ? 1 : 0;
}

# Resolve the game's own config file and extract player_query fields.
# Returns { enabled, port, password, max_players, err }.
#   enabled      — 0/1, or undef when meta has no enabled_key (caller decides)
#   err          — '' on success, else 'no_meta' | 'config_unreadable'
# %opts: unix_user (PZ-style home paths), script_basename (LGSM instance name,
# defaults to $script).
sub player_query_config_values {
    my ($server_dir, $script, %opts) = @_;
    my %out = (enabled => undef, port => 0, password => '', max_players => 0, err => '');

    my $meta = player_query_meta($script);
    unless (ref($meta) eq 'HASH') {
        $out{'err'} = 'no_meta';
        return \%out;
    }

    my $unix_user = $opts{'unix_user'} // '';
    my $selfname  = $opts{'script_basename'} // $script;

    my $hint = (defined &get_game_config_path) ? &get_game_config_path($script) : '';
    $hint = 'serverfiles/server.properties' unless defined $hint && length $hint;

    my $home = '';
    if (defined &resolve_game_config_home) {
        $home = &resolve_game_config_home($unix_user, $server_dir) // '';
    }

    my $resolved = '';
    if (defined &resolve_game_server_config_path) {
        $resolved = &resolve_game_server_config_path(
            $server_dir, $script, {}, $hint, { home => $home, selfname => $selfname },
        ) // '';
    }

    unless (length $resolved) {
        $out{'err'} = 'config_unreadable';
        return \%out;
    }

    unless (defined &parse_game_config_values) {
        $out{'err'} = 'config_unreadable';
        return \%out;
    }
    my $raw = (defined &read_game_config_raw) ? &read_game_config_raw($resolved) : '';
    my ($vals) = &parse_game_config_values($script, $resolved, $raw);
    $vals = {} unless ref($vals) eq 'HASH';

    my $enabled_key     = $meta->{'enabled_key'} // '';
    my $port_key        = $meta->{'port_key'} // '';
    my $password_key    = $meta->{'password_key'} // '';
    my $max_players_key = $meta->{'max_players_key'} // '';

    $out{'enabled'} = length($enabled_key) ? _player_query_truthy($vals->{$enabled_key}) : undef;
    $out{'port'}    = length($port_key) ? int($vals->{$port_key} // 0) : 0;
    $out{'password'} = length($password_key) ? ($vals->{$password_key} // '') : '';
    $out{'password'} =~ s/^\s+|\s+$//g;
    $out{'max_players'} = length($max_players_key) ? int($vals->{$max_players_key} // 0) : 0;

    return \%out;
}

# Readiness check: { ok => 0|1, reason => '' }.
# Reasons: no_meta | missing_enabled | missing_password | missing_port |
#          config_unreadable
# If meta omits enabled_key (e.g. Project Zomboid), enable is implied once
# password + port are both ok — no separate enable check is performed.
sub player_query_readiness {
    my ($server_dir, $script, %opts) = @_;

    my $meta = player_query_meta($script);
    unless (ref($meta) eq 'HASH') {
        return { ok => 0, reason => 'no_meta' };
    }

    my $cfg = player_query_config_values($server_dir, $script, %opts);
    if (length($cfg->{'err'})) {
        return { ok => 0, reason => $cfg->{'err'} };
    }

    if (defined $cfg->{'enabled'} && !$cfg->{'enabled'}) {
        return { ok => 0, reason => 'missing_enabled' };
    }

    unless (length($cfg->{'password'})) {
        return { ok => 0, reason => 'missing_password' };
    }

    unless ($cfg->{'port'} > 0) {
        return { ok => 0, reason => 'missing_port' };
    }

    return { ok => 1, reason => '' };
}

# Parse raw query response into { ok, players, max } or { ok => 0, err }.
# $parse: mc_list | lines_skip_header | json_field
# $meta: parser hints (players_field, max_field for json_field).
sub player_query_parse {
    my ($parse, $raw, $meta) = @_;
    $raw  = '' unless defined $raw;
    $meta = {} unless ref($meta) eq 'HASH';

    if ($parse eq 'mc_list') {
        return _pq_parse_mc_list($raw);
    }
    if ($parse eq 'lines_skip_header') {
        return _pq_parse_lines_skip_header($raw);
    }
    if ($parse eq 'json_field') {
        return _pq_parse_json_field($raw, $meta);
    }
    return { ok => 0, err => 'unknown_parse' };
}

# Minecraft `list` → "There are N of a max of M players online".
sub _pq_parse_mc_list {
    my ($raw) = @_;
    if ($raw =~ /There are (\d+) of a max of (\d+) players? online/i) {
        return { ok => 1, players => int($1), max => int($2) };
    }
    return { ok => 0, err => 'parse_mismatch' };
}

# Skip first non-empty line; count remaining non-empty lines (PZ `players`).
sub _pq_parse_lines_skip_header {
    my ($raw) = @_;
    my $skipped = 0;
    my $count   = 0;
    for my $line (split /\n/, $raw) {
        $line =~ s/\r$//;
        next unless $line =~ /\S/;
        unless ($skipped) {
            $skipped = 1;
            next;
        }
        $count++;
    }
    return { ok => 1, players => $count, max => 0 };
}

# JSON object; read players_field / optional max_field from meta.
sub _pq_parse_json_field {
    my ($raw, $meta) = @_;
    my $players_field = $meta->{'players_field'} // '';
    unless (length $players_field) {
        return { ok => 0, err => 'missing_players_field' };
    }

    require JSON::PP;
    my $data = eval { JSON::PP::decode_json($raw) };
    if ($@ || ref($data) ne 'HASH') {
        return { ok => 0, err => 'json_invalid' };
    }
    unless (exists $data->{$players_field}) {
        return { ok => 0, err => 'missing_players_value' };
    }

    my $players = int($data->{$players_field});
    my $max     = 0;
    my $max_field = $meta->{'max_field'} // '';
    if (length($max_field) && exists $data->{$max_field}) {
        $max = int($data->{$max_field});
    }
    return { ok => 1, players => $players, max => $max };
}

# ------------------------------------------------------------------
# Task 4: cache (per server_dir, TTL PLAYER_QUERY_CACHE_TTL)
# ------------------------------------------------------------------

sub _pq_cache_file {
    my ($server_dir) = @_;
    return undef unless defined $server_dir && length $server_dir;
    return "$server_dir/.monitor/player_query.json";
}

# Returns the cached {ts, ok, players, max, err, state} hashref, or undef
# on missing/corrupt cache.
sub _pq_cache_read {
    my ($server_dir) = @_;
    my $file = _pq_cache_file($server_dir);
    return undef unless defined $file && -f $file;
    open(my $fh, '<', $file) or return undef;
    local $/;
    my $raw = <$fh>;
    close($fh);
    return undef unless defined $raw && length $raw;
    require JSON::PP;
    my $data = eval { JSON::PP::decode_json($raw) };
    return undef if $@ || ref($data) ne 'HASH';
    return $data;
}

sub _pq_cache_valid {
    my ($data) = @_;
    return 0 unless ref($data) eq 'HASH';
    my $ts = int($data->{'ts'} // 0);
    return 0 unless $ts > 0;
    my $ttl = PLAYER_QUERY_CACHE_TTL;
    my $state = $data->{'state'} // '';
    if (!$data->{'ok'} || $state eq 'unreachable' || $state eq 'rcon_missing') {
        $ttl = PLAYER_QUERY_FAIL_CACHE_TTL;
    }
    return (time() - $ts) < $ttl;
}

# Repairs ownership of the .monitor dir to $unix_user before an su write,
# mirroring write_monitor_state's owner-repair helper in monitor.pl —
# duplicated here (not called) so this file stays independent of monitor.pl.
sub _pq_repair_cache_dir_owner {
    my ($dir, $unix_user) = @_;
    return unless defined $dir && $dir ne '' && -d $dir;
    return unless defined $unix_user && $unix_user =~ /^[a-z][a-z0-9_-]{0,30}$/;
    return unless $> == 0;
    my $uid = getpwnam($unix_user);
    return unless defined $uid;
    my @st = stat($dir);
    return unless @st && $st[4] != $uid;
    system('chown', '-R', "$unix_user:$unix_user", $dir);
}

# Writes {ts => time(), %$result} as 0600 JSON under $server_dir/.monitor/.
# $unix_user: when running as root (Webmin CGI, $> == 0), the cache is
# written via su as the game unix user instead of root -- same su-drop
# pattern as write_monitor_state() in monitor.pl -- so root never writes
# into game-owned SERVER_DIR (security-isolation.mdc). Falls back to a
# direct write when $unix_user is absent/invalid or euid is already
# non-root (e.g. tests, or a user-native caller).
sub _pq_cache_write {
    my ($server_dir, $result, $unix_user) = @_;
    my $file = _pq_cache_file($server_dir);
    return 0 unless defined $file;
    my $dir = "$server_dir/.monitor";
    require JSON::PP;
    my $json = eval { JSON::PP::encode_json({ %$result, ts => time() }) };
    return 0 if $@ || !defined $json;

    if (defined $unix_user && $unix_user ne '' && $unix_user =~ /^[a-z][a-z0-9_-]{0,30}$/ && $> == 0) {
        _pq_repair_cache_dir_owner($dir, $unix_user);
        (my $safe_dir = $dir) =~ s/'/'\\''/g;
        (my $safe_file = $file) =~ s/'/'\\''/g;
        open(my $pipe, '|-', 'su', '-s', '/bin/bash', '-c',
            "mkdir -p '$safe_dir' && umask 077 && cat > '$safe_file'", $unix_user)
            or return 0;
        print $pipe $json;
        close($pipe) or return 0;
        return 1;
    }

    require File::Path;
    File::Path::make_path($dir);
    open(my $fh, '>', $file) or return 0;
    print $fh $json;
    close($fh) or return 0;
    chmod(0600, $file);
    return 1;
}

# ------------------------------------------------------------------
# Task 4: transports (Source RCON + REST), host always 127.0.0.1
# ------------------------------------------------------------------

# Source RCON wire ints are always 32-bit little-endian. Use i< (not l<):
# plain l can be 64-bit on some Perls and breaks AUTH against PZ/Source.
sub _pq_rcon_pack_packet {
    my ($id, $type, $body) = @_;
    $body = '' unless defined $body;
    my $payload = pack('i<i<', $id, $type) . $body . "\x00\x00";
    return pack('i<', length($payload)) . $payload;
}

# Reads exactly $n bytes from $sock, respecting $timeout. Returns the
# bytes read, or undef on timeout/EOF/error. Uses sysread (binary-safe;
# buffered $sock->read mixed with syswrite broke PZ AUTH in production).
sub _pq_sock_read_n {
    my ($sock, $n, $timeout) = @_;
    my $buf      = '';
    my $deadline = time() + $timeout;
    while (length($buf) < $n) {
        my $remaining = $deadline - time();
        return undef if $remaining <= 0;
        my $rin = '';
        vec($rin, fileno($sock), 1) = 1;
        my $ready = select($rin, undef, undef, $remaining);
        return undef unless $ready;
        my $chunk;
        my $got = sysread($sock, $chunk, $n - length($buf));
        return undef unless defined $got && $got > 0;
        $buf .= $chunk;
    }
    return $buf;
}

# Reads one Source RCON packet. Returns { id, type, body } or undef.
sub _pq_rcon_read_packet {
    my ($sock, $timeout) = @_;
    my $size_buf = _pq_sock_read_n($sock, 4, $timeout);
    return undef unless defined $size_buf;
    my $size = unpack('i<', $size_buf);
    return undef unless $size >= 8 && $size <= 65536;
    my $payload = _pq_sock_read_n($sock, $size, $timeout);
    return undef unless defined $payload;
    my ($id, $type) = unpack('i<i<', substr($payload, 0, 8));
    my $body = substr($payload, 8);
    $body =~ s/\x00+$//;
    return { id => $id, type => $type, body => $body };
}

# Short grace window (seconds) to drain any extra Source RCON response
# packets after the first one — see the EXEC comment below.
use constant PLAYER_QUERY_RCON_DRAIN_TIMEOUT => 0.2;

# Minimal Source RCON (AUTH + EXEC). Returns ($raw, $err); $err '' on
# success. Never returns a players count here — caller parses $raw.
# Err codes: bad_port | connect_failed | request_failed | auth_timeout |
# auth_failed | auth_bad_response | exec_failed
sub _pq_rcon_real_fetch {
    my ($host, $port, $password, $command, $timeout) = @_;
    $timeout //= PLAYER_QUERY_TIMEOUT;
    return (undef, 'bad_port') unless $port && $port > 0 && $port < 65536;
    $password = '' unless defined $password;

    require IO::Socket::INET;
    my $sock = IO::Socket::INET->new(
        Proto    => 'tcp',
        PeerAddr => $host,
        PeerPort => $port,
        Timeout  => $timeout,
    );
    return (undef, 'connect_failed') unless $sock;
    $sock->autoflush(1);

    my $auth_pkt = _pq_rcon_pack_packet(1, 3, $password);
    my $wrote = $sock->syswrite($auth_pkt);
    unless (defined $wrote && $wrote == length($auth_pkt)) {
        $sock->close();
        return (undef, 'request_failed');
    }

    # Some servers send an empty SERVERDATA_RESPONSE_VALUE (type 0) ahead
    # of the real SERVERDATA_AUTH_RESPONSE (type 2) — skip a few non-auth
    # packets (PZ/Source occasionally emit more than one type-0).
    my $authed = 0;
    for (1 .. 4) {
        my $pkt = _pq_rcon_read_packet($sock, $timeout);
        unless ($pkt) {
            $sock->close();
            return (undef, 'auth_timeout');
        }
        next if $pkt->{'type'} != 2;
        if ($pkt->{'id'} == -1) {
            $sock->close();
            return (undef, 'auth_failed');
        }
        $authed = 1;
        last;
    }
    unless ($authed) {
        $sock->close();
        return (undef, 'auth_bad_response');
    }

    my $cmd_pkt = _pq_rcon_pack_packet(2, 2, $command);
    $wrote = $sock->syswrite($cmd_pkt);
    unless (defined $wrote && $wrote == length($cmd_pkt)) {
        $sock->close();
        return (undef, 'request_failed');
    }
    my $resp = _pq_rcon_read_packet($sock, $timeout);
    unless ($resp) { $sock->close(); return (undef, 'exec_failed'); }
    my $body = $resp->{'body'};

    # NOTE: a single SERVERDATA_RESPONSE_VALUE packet is capped around
    # 4096 bytes by the Source RCON protocol. A large PZ `players` response
    # (many connected players) can be split across several packets, and
    # without draining them the count below would undercount. We make a
    # best-effort attempt to read any further packets that arrive within a
    # short grace window (PLAYER_QUERY_RCON_DRAIN_TIMEOUT) — this is not a
    # full multi-packet implementation (no dummy-packet echo detection per
    # the Source RCON spec), so a response that trickles in slower than the
    # grace window could still be undercounted.
    while (1) {
        my $more = _pq_rcon_read_packet($sock, PLAYER_QUERY_RCON_DRAIN_TIMEOUT);
        last unless $more;
        $body .= $more->{'body'};
    }
    $sock->close();
    return ($body, '');
}

sub _pq_rcon_fetch {
    my ($host, $port, $password, $command, $timeout) = @_;
    if (ref($PLAYER_QUERY_RCON_FETCH) eq 'CODE') {
        return $PLAYER_QUERY_RCON_FETCH->($host, $port, $password, $command, $timeout);
    }
    return _pq_rcon_real_fetch($host, $port, $password, $command, $timeout);
}

# Minimal HTTP GET with Basic auth, raw socket (no LWP dependency).
# Returns ($raw_body, $err); $err '' on success (2xx).
sub _pq_rest_real_fetch {
    my ($host, $port, $path, $user, $password, $timeout) = @_;
    $timeout //= PLAYER_QUERY_TIMEOUT;
    return (undef, 'bad_port') unless $port && $port > 0 && $port < 65536;
    $path = '/' unless defined $path && length $path;

    require IO::Socket::INET;
    my $sock = IO::Socket::INET->new(
        Proto    => 'tcp',
        PeerAddr => $host,
        PeerPort => $port,
        Timeout  => $timeout,
    );
    return (undef, 'connect_failed') unless $sock;

    require MIME::Base64;
    my $auth = MIME::Base64::encode_base64(($user // '') . ':' . ($password // ''), '');
    my $req  = "GET $path HTTP/1.1\r\n"
             . "Host: $host:$port\r\n"
             . "Authorization: Basic $auth\r\n"
             . "Connection: close\r\n"
             . "User-Agent: linuxgsm-webcore-player-query\r\n"
             . "\r\n";
    $sock->print($req) or do { $sock->close(); return (undef, 'request_failed'); };

    my $raw      = '';
    my $deadline = time() + $timeout;
    while (1) {
        my $remaining = $deadline - time();
        last if $remaining <= 0;
        my $rin = '';
        vec($rin, fileno($sock), 1) = 1;
        my $ready = select($rin, undef, undef, $remaining);
        last unless $ready;
        my $chunk;
        my $got = $sock->read($chunk, 65536);
        last unless defined $got && $got > 0;
        $raw .= $chunk;
    }
    $sock->close();
    return (undef, 'timeout') unless length $raw;

    my ($head, $body) = split /\r\n\r\n/, $raw, 2;
    return (undef, 'bad_response') unless defined $head;
    $body = '' unless defined $body;

    my ($status_line) = split /\r\n/, $head, 2;
    my $status_code = 0;
    $status_code = int($1) if $status_line =~ m{^HTTP/\d\.\d\s+(\d+)};
    return (undef, 'auth_failed') if $status_code == 401 || $status_code == 403;
    return (undef, 'http_error') unless $status_code >= 200 && $status_code < 300;

    return ($body, '');
}

sub _pq_rest_fetch {
    my ($host, $port, $path, $user, $password, $timeout) = @_;
    if (ref($PLAYER_QUERY_REST_FETCH) eq 'CODE') {
        return $PLAYER_QUERY_REST_FETCH->($host, $port, $path, $user, $password, $timeout);
    }
    return _pq_rest_real_fetch($host, $port, $path, $user, $password, $timeout);
}

# ------------------------------------------------------------------
# Task 4: player_query_count — the public entry point
# ------------------------------------------------------------------

# { ok, players, max, err, state }.
# States: waiting | none | rcon_missing | ok | unreachable
# %opts: runtime_online (required — 0 skips all network/cache), plus the
# same unix_user / script_basename accepted by readiness/config_values.
sub player_query_count {
    my ($server_dir, $script, %opts) = @_;

    unless ($opts{'runtime_online'}) {
        return { ok => 0, players => 0, max => 0, err => '', state => 'waiting' };
    }

    my $meta = player_query_meta($script);
    unless (ref($meta) eq 'HASH') {
        return { ok => 0, players => 0, max => 0, err => 'no_meta', state => 'none' };
    }

    my $readiness = player_query_readiness($server_dir, $script, %opts);
    unless ($readiness->{'ok'}) {
        return { ok => 0, players => 0, max => 0, err => $readiness->{'reason'}, state => 'rcon_missing' };
    }

    my $cached = _pq_cache_read($server_dir);
    if (_pq_cache_valid($cached)) {
        return {
            ok      => $cached->{'ok'} ? 1 : 0,
            players => int($cached->{'players'} // 0),
            max     => int($cached->{'max'} // 0),
            err     => $cached->{'err'} // '',
            state   => $cached->{'state'} // 'unreachable',
        };
    }

    my $cfg     = player_query_config_values($server_dir, $script, %opts);
    my $kind    = $meta->{'kind'} // '';
    my $command = $meta->{'command'} // '';

    my ($raw, $err);
    if ($kind eq 'rcon') {
        ($raw, $err) = _pq_rcon_fetch(
            PLAYER_QUERY_HOST, $cfg->{'port'}, $cfg->{'password'}, $command, PLAYER_QUERY_TIMEOUT,
        );
    }
    elsif ($kind eq 'rest') {
        my $auth_user = $meta->{'auth_user'} // 'admin';
        ($raw, $err) = _pq_rest_fetch(
            PLAYER_QUERY_HOST, $cfg->{'port'}, $command, $auth_user, $cfg->{'password'}, PLAYER_QUERY_TIMEOUT,
        );
    }
    else {
        return { ok => 0, players => 0, max => 0, err => 'unknown_kind', state => 'rcon_missing' };
    }

    my $result;
    if (defined $err && length $err) {
        $result = { ok => 0, players => 0, max => 0, err => $err, state => 'unreachable' };
    }
    else {
        my $parsed = player_query_parse($meta->{'parse'} // '', $raw, $meta);
        unless ($parsed->{'ok'}) {
            $result = {
                ok => 0, players => 0, max => 0,
                err => $parsed->{'err'} // 'parse_failed', state => 'unreachable',
            };
        }
        else {
            my $cfg_max = int($cfg->{'max_players'} // 0);
            my $max     = $cfg_max > 0 ? $cfg_max : int($parsed->{'max'} // 0);
            $result = {
                ok => 1, players => int($parsed->{'players'} // 0), max => $max,
                err => '', state => 'ok',
            };
        }
    }

    _pq_cache_write($server_dir, $result, $opts{'unix_user'});
    return $result;
}

# ------------------------------------------------------------------
# Task 6: player_query_status_html — manage status cell value
# ------------------------------------------------------------------

# Escaped "<value>" or "<span title=\"<tip>\"><value></span>" when a tip is
# given. Both value and tip are HTML-escaped — never interpolate raw meta
# or lang strings.
sub _pq_status_span {
    my ($value, $tip) = @_;
    my $html = &html_escape($value);
    return $html unless defined $tip && length $tip;
    return '<span title="' . &html_escape($tip) . '">' . $html . '</span>';
}

# Status cell value HTML for the manage player-count row, or '' when the
# game has no player_query meta at all (caller must skip the whole row).
# %opts: unix_user / script_basename (see readiness/config_values), plus
# runtime_status (required — gates the live query, same as player_query_count).
# Never returns the RCON/REST password; only count + generic status text.
sub player_query_status_html {
    my ($server_dir, $script, %opts) = @_;

    my $meta = player_query_meta($script);
    return '' unless ref($meta) eq 'HASH';

    my $runtime_status = $opts{'runtime_status'} // '';
    unless ($runtime_status eq 'online' || $runtime_status eq 'running') {
        return _pq_status_span(
            $text{'manage_players_waiting'} // '—',
            $text{'manage_players_waiting_tip'} // 'Warten, bis der Server online ist.',
        );
    }

    my $readiness = player_query_readiness($server_dir, $script, %opts);
    unless ($readiness->{'ok'}) {
        return _pq_status_span(
            $text{'manage_players_rcon_missing'} // 'RCON fehlt',
            $text{'manage_players_rcon_missing_tip'}
                // 'RCON/REST-Admin-Query muss aktiviert sein, mit gesetztem Passwort und gültigem Port.',
        );
    }

    my $count = player_query_count($server_dir, $script, %opts, runtime_online => 1);
    if ($count->{'ok'}) {
        my $players = int($count->{'players'} // 0);
        my $max     = int($count->{'max'} // 0);
        return &html_escape($max > 0 ? "$players/$max" : "$players");
    }

    my $tip = $text{'manage_players_unreachable_tip'}
        // 'RCON/REST-Admin-Query nicht erreichbar oder Zugangsdaten falsch.';
    # Append machine err code (auth_failed / connect_failed / …) — never password.
    my $err = $count->{'err'} // '';
    $err =~ s/[^a-z0-9_]//g;
    $tip .= " ($err)" if length($err);
    return _pq_status_span(
        $text{'manage_players_unreachable'} // '?',
        $tip,
    );
}

# ------------------------------------------------------------------
# Task 7: player_query_poll_js — 60s visibility-aware client poll
# ------------------------------------------------------------------

# Poll `.js-player-query` every 60s while the manage page is open; pause
# while the tab is hidden, refresh once immediately when it becomes visible
# again. $html from the poll endpoint is a trusted, server-escaped fragment
# (player_query_status_html output) — same innerHTML update pattern as
# setRuntimeHtml / `.js-runtime-status` in live_log.pl. Depends on the
# caller having loaded live_log.pl (job_log_json_for_script).
sub player_query_poll_js {
    my ($poll_url) = @_;
    $poll_url //= '';
    return '' if $poll_url eq '';
    my $cfg = &job_log_json_for_script({ pollUrl => $poll_url, pollInterval => 60000 });
    return <<"JS";
<script>
(function () {
  var C = $cfg;
  function setPlayerHtml(html) {
    if (typeof html !== "string") return;
    var nodes = document.querySelectorAll(".js-player-query");
    for (var i = 0; i < nodes.length; i++) {
      nodes[i].innerHTML = html;
    }
  }
  function poll() {
    if (document.hidden) return;
    fetch(C.pollUrl, { credentials: "same-origin", cache: "no-store" })
      .then(function (r) { if (!r.ok) throw new Error("http"); return r.json(); })
      .then(function (d) {
        if (d && typeof d.html === "string") setPlayerHtml(d.html);
      })
      .catch(function () {
        /* keep last rendered value; next tick retries */
      });
  }
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) poll();
  });
  window.setInterval(poll, C.pollInterval || 60000);
})();
</script>
JS
}

1;
