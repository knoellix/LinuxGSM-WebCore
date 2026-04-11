# LinuxGSM-WebCore - Instance detection via /etc/passwd
use strict;
use warnings;

sub sanitize_input;

# Return list of all LGSM game server instances.
# An instance is a system user whose home dir contains a LinuxGSM script.
sub list_instances {
    my @instances;
    open(my $fh, '<', '/etc/passwd') or return ();
    while (<$fh>) {
        chomp;
        my ($user, undef, undef, undef, undef, $home, $shell) = split(':', $_);
        next unless $shell eq '/usr/sbin/nologin';
        next unless -f "$home/$user";  # LGSM script named after user
        my $inst = &get_instance($user);
        push @instances, $inst if $inst;
    }
    close($fh);
    return @instances;
}

# Return instance details for a specific user, or undef if not a valid LGSM instance.
sub get_instance {
    my ($user) = @_;
    $user = &sanitize_input($user);
    my @pw = getpwnam($user) or return undef;
    my $home  = $pw[7];
    my $shell = $pw[8];
    return undef unless -f "$home/$user";

    my %cfg     = _parse_lgsm_config($home, $user);
    my $status  = _detect_status($home, $user);
    my $port    = $cfg{port} // 0;
    my $fw_open = &firewall_status($port);
    my $warns   = _check_instance_health($user, $home, $shell, \%cfg);

    return {
        user     => $user,
        home     => $home,
        game     => $cfg{gamename} // 'unknown',
        port     => $port,
        status   => $status,
        fw_open  => $fw_open,
        warnings => $warns,
    };
}

# Parse LGSM config files for a game user.
# Reads common.cfg first, then game-specific <user>.cfg (overrides common).
# Returns a flat hash of all key=value pairs found.
sub _parse_lgsm_config {
    my ($home, $user) = @_;
    my %cfg;
    for my $path (
        "$home/lgsm/config-lgsm/common.cfg",
        "$home/lgsm/config-lgsm/$user/$user.cfg",
    ) {
        next unless -f $path;
        open(my $fh, '<', $path) or next;
        while (<$fh>) {
            chomp;
            next if /^\s*#/;                          # Kommentare überspringen
            next unless /=/;
            if (/^\s*(\w+)\s*=\s*["']?([^"'\n]+?)["']?\s*$/) {
                $cfg{$1} = $2;
            }
        }
        close($fh);
    }
    return %cfg;
}


# Check instance health — returns arrayref of warning strings (empty = ok).
# $shell is the user's login shell from /etc/passwd.
sub _check_instance_health {
    my ($user, $home, $shell, $cfg_ref) = @_;
    our %text;
    my @warnings;

    if ($shell ne '/usr/sbin/nologin') {
        my $msg = $text{health_warn_shell};
        $msg =~ s/\{user\}/$user/g;
        push @warnings, $msg;
    }

    unless (-f "$home/$user") {
        push @warnings, $text{health_warn_no_script};
    }

    unless (-d "$home/lgsm/config-lgsm") {
        push @warnings, $text{health_warn_no_config};
    }

    return \@warnings;
}

# Detect whether a game server instance is running.
# Calls the LGSM 'details' command as the game user.
# Returns 'online', 'offline', or 'unknown' (on error).
sub _detect_status {
    my ($home, $user) = @_;
    my $out = `su -s /bin/bash -c "./$user details" $user 2>/dev/null`;
    return 'unknown' unless defined $out && length $out;
    return $out =~ /Online/ ? 'online' : 'offline';
}

1;
