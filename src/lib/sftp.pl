# LinuxGSM-WebCore - SFTP-only user management with SSH chroot
use strict;
use warnings;

my $SSHD_CONFIG = '/etc/ssh/sshd_config';
my $SFTP_MARKER = '# LinuxGSM-WebCore SFTP BEGIN';
my $SFTP_END    = '# LinuxGSM-WebCore SFTP END';

# Configure SFTP-only chroot access for a game user.
# Adds a Match block to sshd_config if not already present.
# Set a random SFTP password (separate from system account)
sub _sftp_set_password {
    my ($user, $pass) = @_;
    return 0 unless defined $user && $user =~ /\S/;
    return 0 unless defined $pass;
    open(my $ch, '|-', 'chpasswd') or return 0;
    print {$ch} "$user:$pass\n";
    close($ch) or return 0;
    return $? == 0 ? 1 : 0;
}

sub setup_sftp_user {
    my ($user) = @_;
    our %text;
    $user = &sanitize_input($user);

    my $sftp_pass = &generate_sftp_password();
    &_sftp_set_password($user, $sftp_pass)
        or &error($text{'err_invalid_input'} // 'Failed to set SFTP password');

    # Add SSH chroot block if not already configured
    unless (&sftp_configured($user)) {
        &append_sftp_config($user);
        &system_logged("systemctl reload sshd");
    }

    return $sftp_pass;
}

sub sftp_configured {
    my ($user) = @_;
    open(my $fh, '<', $SSHD_CONFIG) or return 0;
    while (<$fh>) { return 1 if /Match User $user/ }
    close($fh);
    return 0;
}

sub append_sftp_config {
    my ($user) = @_;
    my @pw = getpwnam($user) or return;
    my $home = $pw[7];
    open(my $fh, '>>', $SSHD_CONFIG) or return;
    print $fh "\n$SFTP_MARKER\n";
    print $fh "Match User $user\n";
    print $fh "    ChrootDirectory $home\n";
    print $fh "    ForceCommand internal-sftp\n";
    print $fh "    AllowTcpForwarding no\n";
    print $fh "    X11Forwarding no\n";
    print $fh "$SFTP_END\n";
    close($fh);
}

sub generate_sftp_password {
    my @chars = ('A'..'Z', 'a'..'z', '0'..'9');
    return join('', map { $chars[rand @chars] } 1..16);
}

1;
