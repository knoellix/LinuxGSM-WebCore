#!/usr/bin/perl
# t/test_firewall_status.pl
use strict;
use warnings;
use Test::More tests => 4;
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

# Test 1: ufw, Port offen (TCP)
$mock_ufw = 1;
$mock_ufw_output = "Status: active\n25565/tcp                  ALLOW IN    Anywhere\n";
is(firewall_status(25565), 1, 'ufw: open tcp port detected');

# Test 2: ufw, Port geschlossen
$mock_ufw = 1;
$mock_ufw_output = "Status: active\n";
is(firewall_status(25565), 0, 'ufw: closed port returns 0');

# Test 3: ufw, Port ohne Protokoll-Suffix
$mock_ufw = 1;
$mock_ufw_output = "Status: active\n25565                      ALLOW IN    Anywhere\n";
is(firewall_status(25565), 1, 'ufw: plain port number detected');

# Test 4: kein ufw — 0 zurückgeben (iptables-Check erfordert root)
$mock_ufw = 0;
is(firewall_status(25565), 0, 'no ufw: returns 0');
