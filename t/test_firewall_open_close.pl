#!/usr/bin/perl
# t/test_firewall_open_close.pl — firewall_open_port / firewall_close_port return values
use strict;
use warnings;
use Test::More tests => 8;
use FindBin qw($Bin);

chdir "$Bin/.." or die "Cannot chdir to repo root: $!\n";
use lib 'src/lib';

sub error { die "error: $_[0]\n"; }

my %open_ports;
my $mock_rc = 0;
my @ufw_cmds;

sub system_logged {
    my ($cmd) = @_;
    push @ufw_cmds, $cmd;
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
    *_ufw_status_output = sub {
        return join("\n", map { "$_ ALLOW IN Anywhere" } sort keys %open_ports);
    };
    # Use real firewall_status (protocol-aware) against mocked ufw output.
}

# Test 1-2: open port returns 1 and is idempotent
$mock_rc = 0;
%open_ports = ();
@ufw_cmds = ();
ok(firewall_open_port(25565, 'tcp'), 'firewall_open_port: tcp succeeds');
ok(firewall_open_port(25565, 'tcp'), 'firewall_open_port: tcp idempotent when already open');

# Test 3: tcp open must NOT skip udp open (regression — PZ needs UDP)
%open_ports = ('16261/tcp' => 1);
@ufw_cmds = ();
ok(firewall_open_port(16261, 'udp'), 'firewall_open_port: udp opens even when tcp already allowed');
ok($open_ports{'16261/udp'}, 'firewall_open_port: udp rule recorded');
ok((grep { /ufw allow 16261\/udp/ } @ufw_cmds), 'firewall_open_port: issued ufw allow udp');

# Test 4: open fails when system_logged fails
$mock_rc = 1;
%open_ports = ();
ok(!firewall_open_port(25566, 'udp'), 'firewall_open_port: returns 0 when ufw fails');

# Test 5-6: close port returns 1 per protocol
$mock_rc = 0;
%open_ports = ('25567/tcp' => 1);
ok(firewall_close_port(25567, 'tcp'), 'firewall_close_port: tcp succeeds');
%open_ports = ('25568/udp' => 1);
ok(firewall_close_port(25568, 'udp'), 'firewall_close_port: udp succeeds');
