# LinuxGSM-WebCore - Instance detection and registration
#
# Primary instance identifier: script basename (e.g. 'mcserver', 'valheimserver').
# For standard LGSM setups (nologin shell + $home/$user script): id = user = script-basename.
# Manual registrations allow any unix user + any script path.
#
# Registered instances stored in: $config_directory/instances
# Preferred TSV format per line:
#   script_id<TAB>unix_user<TAB>full_script_path<TAB>source<TAB>sftp_user
# Legacy format is still accepted:
#   script_id=unix_user:full_script_path
use strict;
use warnings;

# Load firewall functions using the directory of this file (works in both
# production and test environments regardless of CWD).
BEGIN {
    (my $dir = __FILE__) =~ s|/[^/]+$||;
    require "$dir/firewall.pl";
}

sub sanitize_input;

# ---------------------------------------------------------------------------
# Registration storage
# ---------------------------------------------------------------------------

sub _instances_file {
    our $config_directory;
    return "$config_directory/instances";
}

# Load registered instances from file.
# Returns hash: script_id => { user, script, source, sftp_user }
sub _load_registered {
    my %reg;
    my $file = _instances_file();
    return %reg unless -f $file;
    open(my $fh, '<', $file) or return %reg;
    while (<$fh>) {
        chomp;
        next if /^\s*#/ || !(/=/ || /\t/);
        my ($id, $user, $script, $source, $sftp_user);
        if (index($_, "\t") >= 0) {
            ($id, $user, $script, $source, $sftp_user) = split(/\t/, $_, 5);
            $source ||= 'manual';
            $sftp_user ||= '';
        } else {
            my ($val);
            ($id, $val) = split(/=/, $_, 2);
            ($user, $script) = split(/:/, $val, 2);
            $source = 'legacy';
            $sftp_user = '';
        }
        $reg{$id} = {
            user      => $user,
            script    => $script,
            source    => $source,
            sftp_user => $sftp_user,
        } if defined $id && $id =~ /\S/ && defined $user && defined $script;
    }
    close($fh);
    return %reg;
}

sub _save_registered {
    my ($reg_ref) = @_;
    my $file = _instances_file();
    open(my $fh, '>', $file) or return;
    for my $id (sort keys %$reg_ref) {
        my $u = $reg_ref->{$id}{'user'};
        my $s = $reg_ref->{$id}{'script'};
        my $src = $reg_ref->{$id}{'source'} // 'manual';
        my $ftp = $reg_ref->{$id}{'sftp_user'} // '';
        print $fh join("\t", $id, $u, $s, $src, $ftp) . "\n";
    }
    close($fh);
}

# Register (or update) an instance.
sub register_instance {
    my ($id, $user, $script_path, $opts_ref) = @_;
    my %opts = %{$opts_ref || {}};
    my %reg = _load_registered();
    $reg{$id} = {
        user      => $user,
        script    => $script_path,
        source    => $opts{'source'} || ($reg{$id}{'source'} // 'manual'),
        sftp_user => defined $opts{'sftp_user'} ? $opts{'sftp_user'} : ($reg{$id}{'sftp_user'} // ''),
    };
    _save_registered(\%reg);
}

# Remove a registered instance.
sub unregister_instance {
    my ($id) = @_;
    my %reg = _load_registered();
    delete $reg{$id};
    _save_registered(\%reg);
}

sub get_registered_instance {
    my ($id) = @_;
    my %reg = _load_registered();
    return $reg{$id};
}

sub resolve_instance_sftp_user {
    my ($instance_id, $game_user) = @_;
    my %reg = _load_registered();
    if ($reg{$instance_id} && ($reg{$instance_id}{'sftp_user'} // '') ne '') {
        return $reg{$instance_id}{'sftp_user'};
    }

    my @candidates = (
        "ftp_$instance_id",
        "ftp_${game_user}_$instance_id",
        "${game_user}-ftp",
        "ftp_$game_user",
        "${instance_id}-ftp",
    );
    for my $cand (@candidates) {
        return $cand if getpwnam($cand);
    }
    return undef;
}

# ---------------------------------------------------------------------------
# Instance listing and lookup
# ---------------------------------------------------------------------------

# Return all LGSM instances: manually registered (first, takes precedence)
# plus auto-detected (nologin shell + executable script named after user).
sub list_instances {
    my %seen;
    my @instances;

    # 1. Manually registered instances
    my %reg = _load_registered();
    for my $id (sort keys %reg) {
        my $inst = get_instance($id, $reg{$id}{'user'}, $reg{$id}{'script'});
        if ($inst) {
            my $meta = $reg{$id};
            $inst->{'registration_source'} = $meta->{'source'} // 'manual';
            $inst->{'registered_sftp_user'} = $meta->{'sftp_user'} // '';
            push @instances, $inst;
            $seen{$id} = 1;
        }
    }

    # 2. Auto-detection: nologin shell + executable script named after user
    open(my $fh, '<', '/etc/passwd') or return @instances;
    while (<$fh>) {
        chomp;
        my ($user, undef, undef, undef, undef, $home, $shell) = split(':', $_);
        next unless $shell eq '/usr/sbin/nologin';
        next unless -f "$home/$user" && -x "$home/$user";
        next if $seen{$user};  # already covered by a registered entry
        my $inst = get_instance($user, $user, "$home/$user");
        if ($inst) {
            $inst->{'registration_source'} = 'auto';
            $inst->{'registered_sftp_user'} = '';
            push @instances, $inst;
            $seen{$user} = 1;
        }
    }
    close($fh);
    return @instances;
}

# Return instance details for a given script ID, or undef if invalid.
# $user and $script_path are optional: if omitted, looked up from the
# registered instances file (falling back to standard LGSM convention).
sub get_instance {
    my ($id, $user, $script_path) = @_;

    unless (defined $user && defined $script_path) {
        my %reg = _load_registered();
        if ($reg{$id}) {
            $user        = $reg{$id}{'user'};
            $script_path = $reg{$id}{'script'};
        } else {
            # Standard LGSM convention: id = unix user = script basename
            $user = $id;
            my @pw = getpwnam($user) or return undef;
            $script_path = "$pw[7]/$user";
        }
    }

    $user = &sanitize_input($user);
    my @pw = getpwnam($user) or return undef;
    my $home  = $pw[7];
    my $shell = $pw[8];
    return undef unless -f $script_path;

    my $script_name = (split('/', $script_path))[-1];
    my $script_dir  = $script_path;
    $script_dir =~ s|/[^/]+$||;
    my %cfg     = _parse_lgsm_config($script_dir, $script_name);
    my $status  = _detect_status($script_dir, $user, $script_name);
    my $port    = $cfg{port} // 0;
    my $fw_open = &firewall_status($port);
    my $warns   = _check_instance_health($user, $script_dir, $shell, $script_path, \%cfg);

    return {
        id       => $id,
        user     => $user,
        home     => $home,
        script   => $script_path,
        game     => $cfg{gamename} // 'unknown',
        port     => $port,
        status   => $status,
        fw_open  => $fw_open,
        warnings => $warns,
    };
}

# ---------------------------------------------------------------------------
# Helpers for scan page
# ---------------------------------------------------------------------------

# Return sorted list of system users that are candidates for manual registration.
# Includes users with UID >= 1000 or home directory under /home/.
sub list_system_users {
    my @users;
    open(my $fh, '<', '/etc/passwd') or return ();
    while (<$fh>) {
        chomp;
        my ($user, undef, $uid, undef, undef, $home) = split(':', $_);
        push @users, $user if int($uid) >= 1000 || $home =~ m|^/home/|;
    }
    close($fh);
    return sort @users;
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Parse LGSM config files using a layered approach.
# Read order (lowest -> highest priority):
#   1. lgsm/config-default/_default.cfg
#   2. lgsm/config-default/$scriptname.cfg
#   3. lgsm/config-lgsm/common.cfg
#   4. lgsm/config-lgsm/$scriptname/$scriptname.cfg
#
# Returns a hash of all parsed values plus:
#   _has_user_config     => 1 if any user layer (common or instance) has key=value
#   _has_user_config     => 0 if data comes only from config-default
#   _has_instance_config => 1 if instance layer has at least one key=value
#   _has_instance_config => 0 for missing/empty/template-only instance cfg
sub _parse_lgsm_config {
    my ($script_dir, $scriptname) = @_;
    my %cfg;

    # Real LGSM on-disk layout (verified against GameServerManagers/LinuxGSM):
    #   config-default/config-lgsm/$scriptname/_default.cfg  — LGSM-managed defaults
    #   config-lgsm/common.cfg                               — user common overrides
    #   config-lgsm/$scriptname/$scriptname.cfg              — user per-instance overrides
    my @layers = (
        "$script_dir/lgsm/config-default/config-lgsm/$scriptname/_default.cfg",
        "$script_dir/lgsm/config-lgsm/common.cfg",
        "$script_dir/lgsm/config-lgsm/$scriptname/$scriptname.cfg",
    );

    my $has_user_config = 0;
    my $has_instance_config = 0;

    for my $i (0 .. $#layers) {
        my $path = $layers[$i];
        next unless -f $path;
        open(my $fh, '<', $path) or next;
        my $has_content = 0;
        while (<$fh>) {
            chomp;
            next if /^\s*#/;
            next if /^\s*$/;
            next if /^\[/;    # skip bash conditionals like [ -n "..." ]
            if (/^\s*(\w+)\s*=\s*["']?([^"'\n]+?)["']?\s*$/) {
                $cfg{$1} = $2;
                $has_content = 1;
            }
        }
        close($fh);
        # Layers 2 and 3 (index 1 and 2) are user configs
        $has_user_config = 1 if $i >= 1 && $has_content;
        # Layer 3 (index 2) is instance-specific config
        $has_instance_config = 1 if $i == 2 && $has_content;
    }

    $cfg{_has_user_config} = $has_user_config;
    $cfg{_has_instance_config} = $has_instance_config;
    return %cfg;
}

# Check instance health — returns arrayref of warning strings (empty = ok).
sub _check_instance_health {
    my ($user, $home, $shell, $script_path, $cfg_ref) = @_;
    our %text;
    my @warnings;

    if ($shell ne '/usr/sbin/nologin') {
        my $msg = $text{health_warn_shell} // '';
        $msg =~ s/\{user\}/$user/g;
        push @warnings, $msg if $msg;
    }

    unless (-f $script_path) {
        push @warnings, $text{health_warn_no_script} // '';
    }

    unless (-d "$home/lgsm/config-lgsm") {
        push @warnings, $text{health_warn_no_config} // '';
    }

    return \@warnings;
}

# Detect whether a game server instance is running.
# Calls the LGSM 'details' command as the game user via su.
# Returns 'online', 'offline', or 'unknown' (on error).
sub _detect_status {
    my ($home, $user, $script_name) = @_;
    $script_name //= $user;
    my $out = `su -s /bin/bash -c "cd \Q$home\E && ./$script_name details" $user 2>/dev/null`;
    return 'unknown' unless defined $out && length $out;
    return $out =~ /Online/ ? 'online' : 'offline';
}

1;
