# LinuxGSM-WebCore - User provisioning, port checks, LGSM installation
use strict;
use warnings;

our (%text, $module_root);

sub _shell_sq {
    my ($value) = @_;
    $value //= '';
    $value =~ s/'/'\\''/g;
    return "'$value'";
}

sub _has_registered_instances_for_user {
    my ($user) = @_;
    return 1 unless defined &list_instances;
    for my $inst (&list_instances()) {
        next unless ref($inst) eq 'HASH';
        return 1 if (($inst->{'user'} // '') eq $user);
    }
    return 0;
}

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
# Returns { ok => 1, user => $user } or { ok => 0, err => $message }.
sub provision_server {
    my ($user, $game, $port) = @_;
    $user = &sanitize_input($user);
    $game = &sanitize_input($game);
    $port = int($port);

    unless ($user =~ /^[a-z][a-z0-9_-]{0,30}$/) {
        return { ok => 0, err => ($text{'err_invalid_input'} // 'Invalid username') };
    }

    if (&system_logged("useradd -m -s /usr/sbin/nologin $user") != 0) {
        return {
            ok  => 0,
            err => ($text{'provision_useradd_failed'} // "useradd failed for $user"),
        };
    }

    my $script_path = "$module_root/../scripts/install_lgsm.sh";
    my $rc = &system_logged("su -s /bin/bash -c 'bash $script_path $game' \Q$user\E");
    if ($rc != 0) {
        &system_logged("userdel -r \Q$user\E");
        return {
            ok  => 0,
            err => ($text{'provision_install_failed'} // "LGSM install failed for $user"),
        };
    }

    getpwnam($user) or return {
        ok  => 0,
        err => ($text{'provision_verify_failed'} // 'Provisioning verification failed'),
    };

    return { ok => 1, user => $user };
}

sub validate_provision_fast {
    my ($user, $servername, $is_shared) = @_;
    return $text{'err_invalid_input'} unless $user      =~ /^[a-z][a-z0-9_-]{0,30}$/;
    return $text{'err_invalid_input'} unless $servername =~ /^[a-zA-Z0-9_-]{1,64}$/;
    my $user_exists = getpwnam($user) ? 1 : 0;
    my $can_reuse_dedicated_user = 0;
    if ($user_exists && !$is_shared && defined &list_instances) {
        $can_reuse_dedicated_user = !_has_registered_instances_for_user($user);
    }
    if (!$is_shared) {
        return $text{'err_user_exists'} if $user_exists && !$can_reuse_dedicated_user;
    }
    my @pw = getpwnam($user);
    if (@pw) {
        my $home = $pw[7];
        if (-d "$home/$servername") {
            # Dedicated stale-user recovery: allow wizard to continue and clean this
            # old directory in provision_fast, but never for shared users.
            return $text{'err_server_exists'} if $is_shared || !$can_reuse_dedicated_user;
        }
    }
    return undef;
}

# Robust Unix-user decommissioning.
#
# Wine/Xvfb-backed game servers leave 5+ processes alive (Xvfb, wineserver64,
# winedevice, the actual game). A plain `pkill -u` followed immediately by
# `userdel -r` races: shadow-utils refuses to remove the account while
# processes still hold its uid. The naive `|| userdel -f` fallback drops
# the `-r`, so the home directory survives and the next provisioning attempt
# trips over the leftover. This helper folds the correct sequence into one
# function:
#
#   1. SIGTERM all user processes, wait briefly for clean exit
#   2. SIGKILL the remainder, poll until pgrep is silent
#   3. `userdel -r -f` (single combined call: account + home + force)
#   4. Defensive `rm -rf $HOME` in case userdel left something behind
#       (separate filesystem, leftover dot-locks from Wine, …)
#   5. `groupdel` for the now-orphan user-private group
#   6. Final verification — caller decides what to do with leftovers
#
# Returns a hashref:
#   { ok => 0|1, leftovers => \@strings, log => \@strings }
sub decommission_unix_user {
    my ($user) = @_;
    $user //= '';
    my $safe = $user;
    $safe =~ s/[^a-zA-Z0-9_.\-]//g;

    my @log;
    if (!length $safe) {
        return { ok => 0, leftovers => ["invalid user: $user"], log => \@log };
    }

    my @pw = getpwnam($safe);
    unless (@pw) {
        push @log, "user $safe not in passwd, skipping";
        return { ok => 1, leftovers => [], log => \@log };
    }
    my $home = $pw[7] // '';
    $home = "/home/$safe" if !$home || $home eq '' || $home eq '/';

    my $still_running = sub {
        return system("pgrep -u $safe >/dev/null 2>&1") == 0 ? 1 : 0;
    };

    if ($still_running->()) {
        push @log, "SIGTERM processes for $safe";
        &system_logged("pkill -TERM -u $safe >/dev/null 2>&1 || true");
        for (1..10) {
            last unless $still_running->();
            select(undef, undef, undef, 0.3);
        }
    }
    if ($still_running->()) {
        push @log, "SIGKILL processes for $safe";
        &system_logged("pkill -KILL -u $safe >/dev/null 2>&1 || true");
        for (1..10) {
            last unless $still_running->();
            select(undef, undef, undef, 0.3);
        }
    }

    push @log, "userdel -r -f $safe";
    my $rc = &system_logged("userdel -r -f $safe >/dev/null 2>&1");
    push @log, "userdel rc=$rc";

    if ($home =~ m|^/home/| && $home ne '/' && $home ne '/home' && -d $home) {
        push @log, "rm -rf $home (defensive)";
        my $safe_home = _shell_sq($home);
        &system_logged("rm -rf $safe_home");
    }

    if (system("getent passwd $safe >/dev/null 2>&1") != 0
        && system("getent group $safe >/dev/null 2>&1") == 0)
    {
        push @log, "groupdel $safe";
        &system_logged("groupdel $safe >/dev/null 2>&1 || true");
    }

    my @verify_pw = getpwnam($safe);
    my @leftovers;
    push @leftovers, "user:$safe" if @verify_pw;
    push @leftovers, "home:$home" if -d $home;

    return {
        ok => @leftovers ? 0 : 1,
        leftovers => \@leftovers,
        log => \@log,
    };
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
    my $stale_reuse = 0;
    if ($user_existed && defined &list_instances) {
        $stale_reuse = !_has_registered_instances_for_user($user);
    }

    if (-d $server_dir) {
        if ($stale_reuse) {
            my $safe_server_dir = _shell_sq($server_dir);
            &system_logged("rm -rf $safe_server_dir") == 0
                or die "cleanup failed for stale server directory $server_dir\n";
        } else {
            die "server directory already exists: $server_dir\n";
        }
    }

    my $server_dir_q = $server_dir;
    $server_dir_q =~ s/'/'\\''/g;
    my $rc = &system_logged("su -s /bin/bash -c 'mkdir -p \"$server_dir_q\"' $user");
    if ($rc != 0) {
        &system_logged("userdel -r $user") unless $user_existed;
        die "mkdir failed for $server_dir\n";
    }
    chown($uid, $gid, $server_dir);

    return { created_user => !$user_existed ? 1 : 0, server_dir => $server_dir };
}

1;
