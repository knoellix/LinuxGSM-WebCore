#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
chdir "$Bin/.." or die "Cannot chdir: $!";

print "1..5\n";
sub pass { print "ok - $_[0]\n" }
sub fail { print "not ok - $_[0]\n" }

require './src/lib/query.pl';

# Helper: build a minimal valid A2S_INFO response
# Header FF FF FF FF 49, protocol 0x11, then 4 null-terminated strings, 2-byte appid, players, max
sub _fake_a2s_response {
    my ($players, $max) = @_;
    my $hdr = "\xFF\xFF\xFF\xFF\x49\x11";
    my $strings = "My Server\x00mymap\x00myfolder\x00mygame\x00";
    my $appid   = pack('v', 730);  # little-endian short
    my $counts  = pack('CCC', $players, $max, 0);  # players, max, bots
    return $hdr . $strings . $appid . $counts;
}

# 1. _parse_a2s_response: valid packet -> players and max
{
    my $raw = _fake_a2s_response(7, 20);
    my $r = _parse_a2s_response($raw);
    (defined $r && $r->{players} == 7 && $r->{max} == 20)
        ? pass('_parse_a2s_response: valid packet returns correct players/max')
        : fail("_parse_a2s_response: got " . (defined $r ? "p=$r->{players} m=$r->{max}" : 'undef'));
}

# 2. _parse_a2s_response: 0 players valid
{
    my $raw = _fake_a2s_response(0, 16);
    my $r = _parse_a2s_response($raw);
    (defined $r && $r->{players} == 0 && $r->{max} == 16)
        ? pass('_parse_a2s_response: 0 players is valid')
        : fail('_parse_a2s_response: 0 players failed');
}

# 3. _parse_a2s_response: too short -> undef
{
    my $r = _parse_a2s_response("\xFF\xFF\xFF\xFF\x49");
    !defined($r)
        ? pass('_parse_a2s_response: too short returns undef')
        : fail('_parse_a2s_response: too short should return undef');
}

# 4. _parse_a2s_response: wrong magic -> undef
{
    my $raw = _fake_a2s_response(3, 10);
    substr($raw, 4, 1) = "\x41";  # wrong type byte
    my $r = _parse_a2s_response($raw);
    !defined($r)
        ? pass('_parse_a2s_response: wrong type byte returns undef')
        : fail('_parse_a2s_response: wrong type byte should return undef');
}

# 5. _parse_a2s_response: truncated strings -> undef
{
    my $raw = "\xFF\xFF\xFF\xFF\x49\x11" . "NoNullTerminator";
    my $r = _parse_a2s_response($raw);
    !defined($r)
        ? pass('_parse_a2s_response: missing null terminator returns undef')
        : fail('_parse_a2s_response: missing null terminator should return undef');
}
