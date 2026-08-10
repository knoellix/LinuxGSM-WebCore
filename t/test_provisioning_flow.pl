#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 9;
use FindBin qw($Bin);

chdir "$Bin/.." or die "Cannot chdir to repo root: $!\n";

our (%text, $module_root);
%text = (
    err_not_found            => 'missing values',
    err_port_in_use          => 'port already used',
    err_invalid_input        => 'invalid input',
    provision_useradd_failed => 'useradd failed',
    provision_install_failed => 'install failed',
    provision_verify_failed  => 'verify failed',
);
$module_root = '/opt/webmin/linuxgsm-webcore';

my @commands;
my $cmd_rc = 0;
my %provisioned_users;
sub system_logged {
    my ($cmd) = @_;
    push @commands, $cmd;
    if ($cmd_rc == 0 && $cmd =~ /useradd -m -s \S+ (\S+)/) {
        $provisioned_users{$1} = 1;
    }
    if ($cmd =~ /userdel -r (\S+)/) {
        delete $provisioned_users{$1};
    }
    return $cmd_rc;
}

BEGIN {
    no warnings 'redefine';
    *CORE::GLOBAL::getpwnam = sub {
        my ($name) = @_;
        return ('x', 'x', 1000, 1000, '', '', "/home/$name") if $provisioned_users{$name};
        return;
    };
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
$cmd_rc = 0;
my $result = provision_server('mc user', 'mine;craft', 25565);
ok($result->{'ok'}, 'provision_server returns ok on success');
is($result->{'user'}, 'mcuser', 'provision_server returns provisioned user');
is($commands[0], 'useradd -m -s /usr/sbin/nologin mcuser', 'provision_server creates sanitized nologin user');
like(
    $commands[1],
    qr/^su -s \/bin\/bash -c 'bash \/opt\/webmin\/linuxgsm-webcore\/\.\.\/scripts\/install_lgsm\.sh minecraft' mcuser$/,
    'provision_server runs installer via su as target user'
);

@commands = ();
$cmd_rc = 1;
$result = provision_server('failuser', 'minecraft', 25565);
ok(!$result->{'ok'}, 'provision_server returns ok=0 when useradd fails');
is($result->{'err'}, 'useradd failed', 'provision_server returns useradd error message');
