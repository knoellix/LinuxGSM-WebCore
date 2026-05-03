#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 5;

our (%text, $module_root);
%text = (
    err_not_found   => 'missing values',
    err_port_in_use => 'port already used',
);
$module_root = '/opt/webmin/linuxgsm-webcore';

my @commands;
sub system_logged {
    my ($cmd) = @_;
    push @commands, $cmd;
    return 0;
}

sub sanitize_input {
    my ($in) = @_;
    $in //= '';
    $in =~ s/[^a-zA-Z0-9_\-]//g;
    return $in;
}

my $port_busy = 0;

require './src/lib/provision.pl';
{ no warnings 'redefine'; *port_in_use = sub { return $port_busy; }; }

is(validate_provision('mcuser', 'minecraft', 25565), undef, 'validate_provision accepts valid input');
is(validate_provision('', 'minecraft', 25565), 'missing values', 'validate_provision rejects missing user');

$port_busy = 1;
is(validate_provision('mcuser', 'minecraft', 25565), 'port already used', 'validate_provision rejects used port');
$port_busy = 0;

@commands = ();
provision_server('mc user', 'mine;craft', 25565);
is($commands[0], 'useradd -m -s /usr/sbin/nologin mcuser', 'provision_server creates sanitized nologin user');
like(
    $commands[1],
    qr/^su -s \/bin\/bash -c 'bash \/opt\/webmin\/linuxgsm-webcore\/\.\.\/scripts\/install_lgsm\.sh minecraft' mcuser$/,
    'provision_server runs installer via su as target user'
);
