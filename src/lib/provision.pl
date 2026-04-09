# LinuxGSM-WebCore - User provisioning, port checks, LGSM installation
use strict;
use warnings;

our (%text, $module_root);

sub sanitize_input;
sub system_logged;

# Validate provisioning parameters. Returns error string or undef on success.
sub validate_provision {
    my ($user, $game, $port) = @_;
    return $text{'err_not_found'} unless $user && $game;
    return $text{'err_port_in_use'} if &port_in_use($port);
    return undef;
}

# Check if a port is already in use system-wide.
sub port_in_use {
    my ($port) = @_;
    $port = int($port);
    return 1 if system("ss -tuln | grep -q ':$port '") == 0;
    return 0;
}

# Provision a new game server instance.
# Creates system user, installs LGSM, runs install script.
# Never runs as root — uses su.
sub provision_server {
    my ($user, $game, $port) = @_;
    $user = &sanitize_input($user);
    $game = &sanitize_input($game);
    $port = int($port);

    # Create system user with nologin shell
    &system_logged("useradd -m -s /usr/sbin/nologin $user");

    # Install LGSM as game user
    my $script_path = "$module_root/../scripts/install_lgsm.sh";
    &system_logged("su -s /bin/bash -c 'bash $script_path $game' $user");

    return 1;
}

1;
