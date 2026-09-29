#!/usr/bin/perl
# t/test_firewall_status.pl
use strict;
use warnings;
use Test::More tests => 8;
use FindBin qw($Bin);

chdir "$Bin/.." or die "Cannot chdir to repo root: $!\n";
use lib 'src/lib';

sub error { die "error: $_[0]\n"; }
sub system_logged { return system($_[0]); }

require 'firewall.pl';

# Mock has_ufw und _ufw_status_output für Tests
my $mock_ufw = 0;
my $mock_ufw_output = '';

{
    no warnings 'redefine';
    *has_ufw = sub { return $mock_ufw; };
    *_ufw_status_output = sub { return $mock_ufw_output; };
}

# Test 1: ufw, Port offen (TCP) — without proto still matches
$mock_ufw = 1;
$mock_ufw_output = "Status: active\n25565/tcp                  ALLOW IN    Anywhere\n";
is(firewall_status(25565), 1, 'ufw: open tcp port detected');
is(firewall_status(25565, 'tcp'), 1, 'ufw: tcp proto matches tcp rule');
is(firewall_status(25565, 'udp'), 0, 'ufw: udp proto does not match tcp-only rule');

# Test 2: ufw, Port geschlossen
$mock_ufw = 1;
$mock_ufw_output = "Status: active\n";
is(firewall_status(25565), 0, 'ufw: closed port returns 0');

# Test 3: ufw, Port ohne Protokoll-Suffix
$mock_ufw = 1;
$mock_ufw_output = "Status: active\n25565                      ALLOW IN    Anywhere\n";
is(firewall_status(25565), 1, 'ufw: plain port number detected');
is(firewall_status(25565, 'udp'), 1, 'ufw: bare port counts for udp check');

# Test 4: kein ufw — 0 zurückgeben (iptables-Check erfordert root)
$mock_ufw = 0;
is(firewall_status(25565), 0, 'no ufw: returns 0');

# Test 5: udp-only rule
$mock_ufw = 1;
$mock_ufw_output = "Status: active\n16261/udp                  ALLOW IN    Anywhere\n";
is(firewall_status(16261, 'udp'), 1, 'ufw: udp-only rule detected for udp');
