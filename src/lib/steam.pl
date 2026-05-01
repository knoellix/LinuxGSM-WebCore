# LinuxGSM-WebCore - Steam integration library
#
# Account vault: $config_directory/steam_accounts.tsv
#   steam_username<TAB>display_name<TAB>status
#   status in: ok | guard_pending | token_expired
#
# Passwords are NEVER stored.
use strict;
use warnings;

our ($config_directory, $module_root, $module_root_directory);

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

# ---------------------------------------------------------------------------
# Login session management
# ---------------------------------------------------------------------------

sub _sessions_dir {
    our $config_directory;
    return "$config_directory/steam_sessions";
}

# Generate a cryptographically random 32-char hex token.
sub _generate_session_token {
    open(my $fh, '<', '/dev/urandom') or die "Cannot open /dev/urandom: $!";
    my $raw;
    read($fh, $raw, 16) or die "Cannot read /dev/urandom";
    close($fh);
    return unpack('H*', $raw);
}

# Create a session directory and return ($token, $session_dir).
sub create_login_session {
    my $base = _sessions_dir();
    mkdir $base, 0700 unless -d $base;
    my $token       = _generate_session_token();
    my $session_dir = "$base/$token";
    mkdir $session_dir, 0700 or die "Cannot create session dir: $!";
    return ($token, $session_dir);
}

# Read status from session dir. Returns undef if session does not exist.
sub read_session_status {
    my ($token) = @_;
    my $status_file = _sessions_dir() . "/$token/status";
    return undef unless -f $status_file;
    open(my $fh, '<', $status_file) or return undef;
    my $status = <$fh>;
    close($fh);
    chomp $status if defined $status;
    return $status;
}

# Read steamcmd output log from session dir.
sub read_session_output {
    my ($token) = @_;
    my $out_file = _sessions_dir() . "/$token/steam_out";
    return '' unless -f $out_file;
    open(my $fh, '<', $out_file) or return '';
    local $/;
    my $content = <$fh>;
    close($fh);
    return $content // '';
}

# Write guard code to session dir. Validates: only uppercase letters and digits, max 5 chars.
sub submit_guard_code {
    my ($token, $code) = @_;
    $code =~ s/[^A-Z0-9]//g;
    $code = substr($code, 0, 5);
    my $code_file = _sessions_dir() . "/$token/guard_code";
    open(my $fh, '>', $code_file) or die "Cannot write guard code: $!";
    print $fh "$code\n";
    close($fh);
}

# Delete session directory (cleanup after ok/failed/timeout).
sub cleanup_session {
    my ($token) = @_;
    my $session_dir = _sessions_dir() . "/$token";
    return unless -d $session_dir;
    for my $file (glob("$session_dir/*")) {
        unlink $file;
    }
    rmdir $session_dir;
}

# Start login worker in background.
# $password is written to a chmod-600 temp file; worker deletes it immediately.
# Returns $token.
sub start_login_session {
    my ($username, $password) = @_;
    our $module_root;

    my ($token, $session_dir) = create_login_session();

    # Write password to temp file with strict permissions
    my $pass_file = "$session_dir/pass_tmp";
    open(my $fh, '>', $pass_file) or die "Cannot write pass_tmp: $!";
    print $fh $password;
    close($fh);
    chmod(0600, $pass_file);

    my $worker = "$module_root/scripts/steam_login_worker.sh";
    my $steamcmd_path = detect_steamcmd() // 'steamcmd';
    (my $w  = $worker)      =~ s/'/'\\''/g;
    (my $sd = $session_dir) =~ s/'/'\\''/g;
    (my $un = $username)    =~ s/'/'\\''/g;
    (my $pf = $pass_file)   =~ s/'/'\\''/g;
    (my $sc = $steamcmd_path) =~ s/'/'\\''/g;
    my $log = '/var/webmin/miniserv.error';
    my $cmd = "STEAMCMD_PATH='$sc' nohup '$w' '$sd' '$un' '$pf' </dev/null >>'$log' 2>&1 &";
    &log_debug("steam login start: user=$username worker=$worker steamcmd=$steamcmd_path session=$session_dir");
    system($cmd);

    return $token;
}

1;
