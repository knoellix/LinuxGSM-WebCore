# LinuxGSM-WebCore - User provisioning, port checks, LGSM installation
use strict;
use warnings;

our (%text, $module_root);

# Validate provisioning parameters. Returns error string or undef on success.
sub validate_provision {
    my ($user, $game, $port) = @_;
    return $text{'err_not_found'} unless $user && $game;
    # Username must be a valid Unix username (no shell metacharacters)
    return $text{'err_invalid_input'} unless $user =~ /^[a-z][a-z0-9_-]{0,30}$/;
    # Refuse to overwrite an existing system user
    return $text{'err_user_exists'} if getpwnam($user);
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
# Rolls back (userdel -r) if any step after useradd fails.
sub provision_server {
    my ($user, $game, $port) = @_;
    $user = &sanitize_input($user);
    $game = &sanitize_input($game);
    $port = int($port);

    # Strict whitelist already enforced by validate_provision, but guard here too
    die "Invalid username\n" unless $user =~ /^[a-z][a-z0-9_-]{0,30}$/;

    # Create system user with nologin shell.
    # $user is already sanitized to [a-z][a-z0-9_-]{0,30} by the guard above.
    &system_logged("useradd -m -s /usr/sbin/nologin $user") == 0
        or die "useradd failed for $user\n";

    # Install LGSM as game user; roll back the system user on failure.
    # $game and $script_path are already sanitized; $user is quoted for shell safety.
    my $script_path = "$module_root/../scripts/install_lgsm.sh";
    my $rc = &system_logged("su -s /bin/bash -c 'bash $script_path $game' \Q$user\E");
    if ($rc != 0) {
        &system_logged("userdel -r \Q$user\E");
        die "LGSM install failed for $user (game=$game); user removed\n";
    }

    return 1;
}

sub validate_provision_fast {
    my ($user, $servername, $is_shared) = @_;
    return $text{'err_invalid_input'} unless $user      =~ /^[a-z][a-z0-9_-]{0,30}$/;
    return $text{'err_invalid_input'} unless $servername =~ /^[a-zA-Z0-9_-]{1,64}$/;
    if (!$is_shared) {
        return $text{'err_user_exists'} if getpwnam($user);
    }
    my @pw = getpwnam($user);
    if (@pw) {
        my $home = $pw[7];
        return $text{'err_server_exists'} if -d "$home/$servername";
    }
    return undef;
}

sub provision_fast {
    my ($user, $servername) = @_;
    $user       =~ s/[^a-z0-9_-]//g;
    $servername =~ s/[^a-zA-Z0-9_-]//g;
    $servername = substr($servername, 0, 64);

    die "Invalid username\n"   unless $user       =~ /^[a-z][a-z0-9_-]{0,30}$/;
    die "Invalid servername\n" unless $servername  =~ /^[a-zA-Z0-9_-]{1,64}$/;

    my $user_existed = getpwnam($user) ? 1 : 0;

    if (!$user_existed) {
        &system_logged("useradd -m -s /usr/sbin/nologin $user") == 0
            or die "useradd failed for $user\n";
    }

    my @pw = getpwnam($user) or die "User $user not found after creation\n";
    my ($uid, $gid, $home) = @pw[2, 3, 7];
    my $server_dir = "$home/$servername";

    my $rc = &system_logged("su -s /bin/bash -c \"mkdir -p $server_dir\" $user");
    if ($rc != 0) {
        &system_logged("userdel -r $user") unless $user_existed;
        die "mkdir failed for $server_dir\n";
    }
    chown($uid, $gid, $server_dir);

    return { created_user => !$user_existed ? 1 : 0, server_dir => $server_dir };
}

1;
