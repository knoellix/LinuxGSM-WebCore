# LinuxGSM-WebCore - Instance detection via /etc/passwd
use strict;
use warnings;

our $text;

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

# Return instance details for a specific user, or undef if not found.
sub get_instance {
    my ($user) = @_;
    $user = &sanitize_input($user);
    my @pw = getpwnam($user) or return undef;
    my $home = $pw[7];
    return undef unless -f "$home/$user";
    return {
        user   => $user,
        home   => $home,
        game   => _detect_game($home, $user),
        port   => _detect_port($home, $user),
        status => _detect_status($home, $user),
    };
}

sub _detect_game {
    my ($home, $user) = @_;
    # LGSM stores game ID in serverfiles/common.cfg or similar
    return 'unknown';  # TODO: parse LGSM config
}

sub _detect_port {
    my ($home, $user) = @_;
    return 0;  # TODO: parse LGSM config
}

sub _detect_status {
    my ($home, $user) = @_;
    my $rc = system("su -s /bin/bash -c \"./$user details\" $user 2>/dev/null | grep -q 'Online'");
    return $rc == 0 ? 'online' : 'offline';
}

1;
