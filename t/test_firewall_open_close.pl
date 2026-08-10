#!/usr/bin/perl
# t/test_firewall_open_close.pl — firewall_open_port / firewall_close_port return values
use strict;
use warnings;
use Test::More tests => 6;
use FindBin qw($Bin);

chdir "$Bin/.." or die "Cannot chdir to repo root: $!\n";
use lib 'src/lib';

sub error { die "error: $_[0]\n"; }

my %open_ports;
my $mock_rc = 0;

sub system_logged {
    my ($cmd) = @_;
    if ($cmd =~ /ufw allow (\d+)\/(tcp|udp)/) {
        $open_ports{"$1/$2"} = 1;
        return $mock_rc;
    }
    if ($cmd =~ /ufw delete allow (\d+)\/(tcp|udp)/) {
        delete $open_ports{"$1/$2"};
        return $mock_rc;
    }
    return $mock_rc;
}

require 'firewall.pl';

{
    no warnings 'redefine';
    *has_ufw = sub { return 1; };
    *_ufw_status_output = sub { return join("\n", map { "$_ ALLOW IN Anywhere" } sort keys %open_ports); };
    *firewall_status = sub {
        my ($port) = @_;
        return 1 if $open_ports{"$port/tcp"} || $open_ports{"$port/udp"};
        return 0;
    };
}

# Test 1-2: open port returns 1 and is idempotent
$mock_rc = 0;
%open_ports = ();
ok(firewall_open_port(25565, 'tcp'), 'firewall_open_port: tcp succeeds');
ok(firewall_open_port(25565, 'tcp'), 'firewall_open_port: tcp idempotent when already open');

# Test 3: open fails when system_logged fails
$mock_rc = 1;
%open_ports = ();
ok(!firewall_open_port(25566, 'udp'), 'firewall_open_port: returns 0 when ufw fails');

# Test 4-5: close port returns 1 per protocol
$mock_rc = 0;
%open_ports = ('25567/tcp' => 1);
ok(firewall_close_port(25567, 'tcp'), 'firewall_close_port: tcp succeeds');
%open_ports = ('25568/udp' => 1);
ok(firewall_close_port(25568, 'udp'), 'firewall_close_port: udp succeeds');

# Test 6: close idempotent when already closed
ok(firewall_close_port(25568, 'udp'), 'firewall_close_port: idempotent when already closed');
