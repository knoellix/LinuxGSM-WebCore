# LinuxGSM-WebCore - Steam integration library
#
# Account vault: $config_directory/steam_accounts.tsv
#   steam_username<TAB>display_name<TAB>status
#   status in: ok | guard_pending | token_expired
#
# Passwords are NEVER stored.
use strict;
use warnings;

our ($config_directory, $module_root);

# ---------------------------------------------------------------------------
# System detection
# ---------------------------------------------------------------------------

# Return steamcmd path (e.g. /usr/games/steamcmd) or undef if not installed.
sub detect_steamcmd {
    # Search PATH with explicit which-like logic
    for my $dir (split ':', $ENV{PATH} // '') {
        next unless length $dir;
        my $path = "$dir/steamcmd";
        return $path if -x $path;
    }
    # Also check standard installation paths if not in PATH
    for my $candidate (qw(/usr/games/steamcmd /usr/bin/steamcmd)) {
        return $candidate if -x $candidate;
    }
    return undef;
}

# Check /etc/apt/sources.list (or $path for testing).
# Returns hashref: { non_free => 0/1, contrib => 0/1, cdrom_active => 0/1 }
sub check_apt_repos {
    my ($path) = @_;
    $path //= '/etc/apt/sources.list';
    my %result = (non_free => 0, contrib => 0, cdrom_active => 0);
    return \%result unless -f $path;
    open(my $fh, '<', $path) or return \%result;
    while (<$fh>) {
        next if /^\s*#/;
        $result{'non_free'}     = 1 if /\bnon-free\b/;
        $result{'contrib'}      = 1 if /\bcontrib\b/;
        $result{'cdrom_active'} = 1 if /^\s*deb\s+cdrom:/;
    }
    close($fh);
    return \%result;
}

# Patch /etc/apt/sources.list (or $path for testing):
# 1. Comment out cdrom: lines
# 2. Add non-free contrib to deb http:// lines that lack them
sub patch_apt_sources {
    my ($path) = @_;
    $path //= '/etc/apt/sources.list';
    # Safety: only allow canonical path or tmp paths (for tests)
    return unless $path eq '/etc/apt/sources.list' || $path =~ m{^/tmp/};
    open(my $fh, '<', $path) or return;
    my @lines = <$fh>;
    close($fh);

    my @out;
    for my $line (@lines) {
        if ($line =~ /^\s*deb\s+cdrom:/) {
            $line = "# $line";
        } elsif ($line =~ /^\s*deb\s+https?:\/\// && $line !~ /\bnon-free\b/) {
            chomp $line;
            $line .= " contrib non-free\n";
        }
        push @out, $line;
    }
    open($fh, '>', $path) or return;
    print $fh $_ for @out;
    close($fh);
}

# Install steamcmd via apt-get.
sub install_steamcmd {
    &system_logged('apt-get install -y steamcmd 2>&1');
}

# ---------------------------------------------------------------------------
# Account vault — $config_directory/steam_accounts.tsv
# ---------------------------------------------------------------------------

sub _accounts_file {
    our $config_directory;
    return "$config_directory/steam_accounts.tsv";
}

# Return arrayref of account hashrefs: { username, display_name, status }
sub load_steam_accounts {
    my $file = _accounts_file();
    return [] unless -f $file;
    open(my $fh, '<:encoding(UTF-8)', $file) or return [];
    my @accounts;
    while (<$fh>) {
        chomp;
        next if /^\s*#/ || !length;
        my ($username, $display_name, $status) = split(/\t/, $_, 3);
        next unless defined $username && $username =~ /\S/;
        push @accounts, {
            username     => $username,
            display_name => $display_name // '',
            status       => $status       // 'guard_pending',
        };
    }
    close($fh);
    return \@accounts;
}

sub _save_steam_accounts {
    my ($accounts_ref) = @_;
    my $file = _accounts_file();
    open(my $fh, '>:encoding(UTF-8)', $file) or return;
    for my $acc (@$accounts_ref) {
        print $fh join("\t", $acc->{'username'}, $acc->{'display_name'} // '', $acc->{'status'} // 'guard_pending') . "\n";
    }
    close($fh);
    chmod(0600, $file);
}

# Add new account with status=guard_pending. No-op if username already exists.
sub add_steam_account {
    my ($username, $display_name) = @_;
    my $accounts = load_steam_accounts();
    return if grep { $_->{'username'} eq $username } @$accounts;
    push @$accounts, { username => $username, display_name => $display_name // '', status => 'guard_pending' };
    _save_steam_accounts($accounts);
}

# Remove account by username.
sub remove_steam_account {
    my ($username) = @_;
    my $accounts = load_steam_accounts();
    $accounts = [grep { $_->{'username'} ne $username } @$accounts];
    _save_steam_accounts($accounts);
}

# Return status string for given username, or undef if not found.
sub get_steam_account_status {
    my ($username) = @_;
    my $accounts = load_steam_accounts();
    for my $acc (@$accounts) {
        return $acc->{'status'} if $acc->{'username'} eq $username;
    }
    return undef;
}

# Update status for a given username.
sub update_steam_account_status {
    my ($username, $new_status) = @_;
    my $accounts = load_steam_accounts();
    for my $acc (@$accounts) {
        if ($acc->{'username'} eq $username) {
            $acc->{'status'} = $new_status;
            last;
        }
    }
    _save_steam_accounts($accounts);
}

1;
