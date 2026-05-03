# LinuxGSM-WebCore - A2S query (Steam server query protocol)
use strict;
use warnings;

return 1 if defined &a2s_query;

# Parse a raw A2S_INFO response (FF FF FF FF 49 ...).
# Returns hashref {players, max} or undef on error.
sub _parse_a2s_response {
    my ($raw) = @_;
    return undef unless defined $raw && length($raw) >= 12;
    return undef unless substr($raw, 0, 5) eq "\xFF\xFF\xFF\xFF\x49";
    my $pos = 6;  # skip 4-byte header + type + protocol
    for (1..4) {
        my $null = index($raw, "\x00", $pos);
        return undef if $null < 0;
        $pos = $null + 1;
    }
    return undef if $pos + 4 > length($raw);
    $pos += 2;  # skip 2-byte app_id
    return undef if $pos + 1 >= length($raw);
    my $players = ord(substr($raw, $pos,     1));
    my $max     = ord(substr($raw, $pos + 1, 1));
    return { players => $players, max => $max };
}

# Query a game server via A2S_INFO (UDP).
# Returns hashref {players, max} or undef on timeout/error.
sub a2s_query {
    my ($host, $port, $timeout) = @_;
    $timeout //= 2;
    $port = int($port);
    return undef unless $port > 0 && $port < 65536;

    require IO::Socket::INET;
    my $sock = IO::Socket::INET->new(
        Proto    => 'udp',
        PeerAddr => $host,
        PeerPort => $port,
    ) or return undef;

    my $req = "\xFF\xFF\xFF\xFF\x54Source Engine Query\x00";
    $sock->send($req) or do { $sock->close(); return undef; };

    my $rin = '';
    vec($rin, fileno($sock), 1) = 1;
    my $ready = select($rin, undef, undef, $timeout);
    unless ($ready) { $sock->close(); return undef; }

    my $raw = '';
    $sock->recv($raw, 4096);
    $sock->close();

    return _parse_a2s_response($raw);
}

1;
