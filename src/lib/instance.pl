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
# Skip if test stubs already define firewall_status to avoid "redefined" noise.
BEGIN {
    unless (defined &firewall_status) {
        (my $dir = __FILE__) =~ s|/[^/]+$||;
        require "$dir/firewall.pl";
    }
}

sub sanitize_input;

# ---------------------------------------------------------------------------
# Registration storage
# ---------------------------------------------------------------------------

sub _instances_file {
    our $config_directory;
    return "$config_directory/instances";
}

# Central rule: which instances are LGSM-managed.
#
# LGSM games are registered with source 'provisioned' (see wizard.cgi:
# ($game_source eq 'lgsm') ? 'provisioned' : $game_source), while detected
# instances use 'lgsm'/'auto'/'legacy'/'manual'. Only SteamCMD/Wine games run
# the non-LGSM start/monitor path (run.pid + steamcmd_control.sh). Treat
# everything except those explicit non-LGSM markers as LGSM-managed, so the
# monitor uses `./<script> monitor` for MC and all real LGSM instances.
#
# Returns 1 for LGSM-managed, 0 for non-LGSM (steamcmd/wine).
sub instance_is_lgsm {
    my ($source) = @_;
    $source = '' unless defined $source;
    $source =~ s/^\s+|\s+$//g;
    $source = lc $source;
    return ($source eq 'steamcmd' || $source eq 'wine') ? 0 : 1;
}

# Monitor kind token used by cron lines / worker scripts: 'lgsm' or 'native'.
sub instance_monitor_kind {
    my ($source) = @_;
    return instance_is_lgsm($source) ? 'lgsm' : 'native';
}

# Load registered instances from file.
# Returns hash: script_id => { user, script, source, sftp_user, owners, steam_account }
sub _load_registered {
    my %reg;
    my $file = _instances_file();
    return %reg unless -f $file;
    open(my $fh, '<', $file) or return %reg;
    while (<$fh>) {
        chomp;
        next if /^\s*#/ || !(/=/ || /\t/);
        my ($id, $user, $script, $source, $sftp_user, $owners, $steam_account);
        if (index($_, "\t") >= 0) {
            my @cols = split(/\t/, $_, 10);
            ($id, $user, $script, $source, $sftp_user) = @cols;
            $source    ||= 'manual';
            $sftp_user ||= '';
            $owners        = $cols[5] // '';
            $steam_account = $cols[6] // '';
            my $instance_status = do { my $v = $cols[7] // ''; chomp $v; $v || 'installed' };
            my $cached_game = do { my $v = $cols[8] // ''; chomp $v; $v };
            my $cached_port = do { my $v = $cols[9] // 0;  chomp $v; int($v || 0) };
            $reg{$id} = {
                user            => $user,
                script          => $script,
                source          => $source,
                sftp_user       => $sftp_user,
                owners          => $owners,
                steam_account   => $steam_account,
                instance_status => $instance_status,
                cached_game     => $cached_game,
                cached_port     => $cached_port,
            } if defined $id && $id =~ /\S/ && defined $user && defined $script;
            next;
        } else {
            my ($val);
            ($id, $val) = split(/=/, $_, 2);
            ($user, $script) = split(/:/, $val, 2);
            $source = 'legacy';
            $sftp_user = '';
            $owners = '';
            $steam_account = '';
        }
        $reg{$id} = {
            user            => $user,
            script          => $script,
            source          => $source,
            sftp_user       => $sftp_user,
            owners          => $owners,
            steam_account   => $steam_account,
            instance_status => 'installed',
            cached_game     => '',
            cached_port     => 0,
        } if defined $id && $id =~ /\S/ && defined $user && defined $script;
    }
    close($fh);
    return %reg;
}

sub _save_registered {
    my ($reg_ref) = @_;
    my $file = _instances_file();
    open(my $fh, '>', $file) or return 0;
    for my $id (sort keys %$reg_ref) {
        my $u       = $reg_ref->{$id}{'user'};
        my $s       = $reg_ref->{$id}{'script'};
        my $src     = $reg_ref->{$id}{'source'} // 'manual';
        my $ftp     = $reg_ref->{$id}{'sftp_user'} // '';
        my $own     = $reg_ref->{$id}{'owners'} // '';
        my $steam   = $reg_ref->{$id}{'steam_account'} // '';
        my $istatus = $reg_ref->{$id}{'instance_status'} // 'installed';
        my $cgame   = $reg_ref->{$id}{'cached_game'} // '';
        my $cport   = $reg_ref->{$id}{'cached_port'} // 0;
        print $fh join("\t", $id, $u, $s, $src, $ftp, $own, $steam, $istatus, $cgame, $cport) . "\n";
    }
    close($fh);
    return 1;
}

# Update cached game name and port for an instance after a full config read.
# Best-effort: silently skips if the instance is not registered.
sub _update_instance_cache {
    my ($id, $game, $port) = @_;
    my %reg = _load_registered();
    return unless exists $reg{$id};
    return if ($reg{$id}{'cached_game'} // '') eq ($game // '')
           && ($reg{$id}{'cached_port'} // 0) == ($port // 0);
    $reg{$id}{'cached_game'} = $game // '';
    $reg{$id}{'cached_port'} = int($port // 0);
    _save_registered(\%reg);
}

# Register (or update) an instance.
sub register_instance {
    my ($id, $user, $script_path, $opts_ref) = @_;
    my %opts = %{$opts_ref || {}};
    my %reg = _load_registered();
    $reg{$id} = {
        user            => $user,
        script          => $script_path,
        source          => $opts{'source'} || ($reg{$id}{'source'} // 'manual'),
        sftp_user       => defined $opts{'sftp_user'} ? $opts{'sftp_user'} : ($reg{$id}{'sftp_user'} // ''),
        owners          => defined $opts{'owners'} ? $opts{'owners'} : ($reg{$id}{'owners'} // ''),
        steam_account   => defined $opts{'steam_account'} ? $opts{'steam_account'} : ($reg{$id}{'steam_account'} // ''),
        instance_status => defined $opts{'instance_status'} ? $opts{'instance_status'} : ($reg{$id}{'instance_status'} // 'installed'),
        cached_game     => defined $opts{'game'} ? $opts{'game'} : ($reg{$id}{'cached_game'} // ''),
        cached_port     => defined $opts{'port'} ? int($opts{'port'}) : ($reg{$id}{'cached_port'} // 0),
    };
    return _save_registered(\%reg);
}

# Remove a registered instance. Returns 1 on successful persist.
sub unregister_instance {
    my ($id) = @_;
    my %reg = _load_registered();
    delete $reg{$id};
    return _save_registered(\%reg);
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

    # 1. Registered instances — build directly from registry cache.
    # One _load_registered() call, zero getpwnam() calls, zero script-file checks.
    my %reg = _load_registered();
    for my $id (sort keys %reg) {
        my $r           = $reg{$id};
        my $script      = $r->{'script'} // '';
        my $script_name = (split('/', $script))[-1] || $id;
        my $cgame       = $r->{'cached_game'} // '';
        my $cport       = $r->{'cached_port'} // 0;
        push @instances, {
            id                   => $id,
            user                 => $r->{'user'} // '',
            home                 => '',
            script               => $script,
            game                 => $cgame ne '' ? $cgame : $script_name,
            port                 => $cport,
            status               => 'unknown',
            fw_open              => 0,
            warnings             => [],
            steam_account        => $r->{'steam_account'} // '',
            instance_status      => $r->{'instance_status'} // 'installed',
            registration_source  => $r->{'source'} // 'manual',
            registered_sftp_user => $r->{'sftp_user'} // '',
            owners               => $r->{'owners'} // '',
        };
        $seen{$id} = 1;
    }

    # 2. Auto-detection: nologin shell + executable script named after user.
    # Build instance hash directly from /etc/passwd — no getpwnam() call needed.
    open(my $fh, '<', '/etc/passwd') or return @instances;
    while (<$fh>) {
        chomp;
        my ($user, undef, undef, undef, undef, $home, $shell) = split(':', $_);
        next unless defined $shell && $shell eq '/usr/sbin/nologin';
        next unless defined $home && -f "$home/$user" && -x "$home/$user";
        next if $seen{$user};
        push @instances, {
            id                   => $user,
            user                 => $user,
            home                 => $home,
            script               => "$home/$user",
            game                 => $user,
            port                 => 0,
            status               => 'unknown',
            fw_open              => 0,
            warnings             => [],
            steam_account        => '',
            instance_status      => 'installed',
            registration_source  => 'auto',
            registered_sftp_user => '',
            owners               => '',
        };
        $seen{$user} = 1;
    }
    close($fh);
    return @instances;
}

# Return instance details for a given script ID, or undef if invalid.
# $user and $script_path are optional: if omitted, looked up from the
# registered instances file (falling back to standard LGSM convention).
sub get_instance {
    my ($id, $user, $script_path, $quick) = @_;
    $quick //= 0;

    my %reg = _load_registered();
    unless (defined $user && defined $script_path) {
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
    my $steam_account = $reg{$id}{'steam_account'} // '';

    my %registry_meta = (
        instance_status      => ($reg{$id} && defined $reg{$id}{'instance_status'})
            ? $reg{$id}{'instance_status'} : 'installed',
        source               => $reg{$id}{'source'} // 'lgsm',
        sftp_user            => $reg{$id}{'sftp_user'} // '',
        owners               => $reg{$id}{'owners'} // '',
        registration_source  => $reg{$id}{'source'} // 'manual',
        registered_sftp_user => $reg{$id}{'sftp_user'} // '',
    );

    $user = &sanitize_input($user);
    my @pw = getpwnam($user) or return undef;
    my $home        = $pw[7];
    my $shell       = $pw[8];
    my $script_name = (split('/', $script_path))[-1];

    if ($quick) {
        # Quick mode: read only registry cache — no disk I/O, no script-file check.
        my $cgame = $reg{$id}{'cached_game'} // '';
        my $cport = $reg{$id}{'cached_port'} // 0;
        return {
            id            => $id,
            user          => $user,
            home          => $home,
            script        => $script_path,
            game          => $cgame ne '' ? $cgame : $script_name,
            port          => $cport,
            status        => 'unknown',
            fw_open       => 0,
            warnings      => [],
            steam_account => $steam_account,
            %registry_meta,
        };
    }

    return undef unless -f $script_path;

    my $script_dir = $script_path;
    $script_dir =~ s|/[^/]+$||;
    $script_name = instance_executable_script($script_dir, $script_path);

    my %cfg     = _parse_lgsm_config($script_dir, $script_name);
    # Non-LGSM SteamCMD/Wine instances must NOT shell out to './<script> details'.
    # That wrapper ignores its arguments and would launch a fresh wine on every status check,
    # piling up zombie wine/Xvfb pairs in the same WINEPREFIX until the real start hangs.
    my $reg_source = $reg{$id}{'source'} // 'lgsm';
    my $status;
    if ($reg_source eq 'steamcmd') {
        $status = _detect_status_steamcmd($script_dir);
    } else {
        $status = _detect_status($script_dir, $user, $script_name);
    }
    my $port    = $cfg{port} // 0;
    $port       = _read_port_from_game_config($script_dir, \%cfg) unless $port;
    my $fw_open = &firewall_status($port);
    my $warns   = _check_instance_health($user, $script_dir, $shell, $script_path, \%cfg);
    my $game    = $cfg{gamename} // $script_name;

    # Update cached values so the next quick-mode listing is accurate.
    _update_instance_cache($id, $game, $port);

    return {
        id            => $id,
        user          => $user,
        home          => $home,
        script        => $script_path,
        game          => $game,
        port          => $port,
        status        => $status,
        fw_open       => $fw_open,
        warnings      => $warns,
        steam_account => $steam_account,
        %registry_meta,
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

# Read port from the game-server config file (e.g. server.properties).
# Used as fallback when the LGSM config layers don't expose 'port'.
sub _read_port_from_game_config {
    my ($script_dir, $cfg_ref) = @_;
    my %cfg = %{$cfg_ref || {}};

    # Resolve LGSM variable references (simple single-pass expansion)
    $cfg{'rootdir'}     ||= $script_dir;
    $cfg{'serverfiles'} ||= "$script_dir/serverfiles";
    $cfg{'lgsmdir'}     ||= "$script_dir/lgsm";
    my $expand = sub {
        my ($val) = @_;
        return '' unless defined $val;
        for (1..5) {
            my $before = $val;
            $val =~ s/\$\{([A-Za-z_]\w*)\}/defined $cfg{$1} ? $cfg{$1} : ''/ge;
            last if $val eq $before;
        }
        return $val;
    };

    my $game_cfg_path = $expand->($cfg{'servercfgfullpath'} // '');
    if ($game_cfg_path eq '') {
        my $dir  = $expand->($cfg{'servercfgdir'}  // '');
        my $file = $expand->($cfg{'servercfg'}     // '');
        $game_cfg_path = "$dir/$file" if $dir ne '' && $file ne '';
    }
    $game_cfg_path =~ s|//+|/|g;
    return 0 unless defined $game_cfg_path && length $game_cfg_path && -f $game_cfg_path;

    open(my $fh, '<', $game_cfg_path) or return 0;
    local $/;
    my $raw = <$fh>;
    close($fh);
    return int($1) if $raw =~ /^server-port\s*=\s*(\d+)/m;
    return int($1) if $raw =~ /^port\s*=\s*(\d+)/m;
    return 0;
}

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

# steamcmd vs LGSM — mirrors manage.cgi / index.cgi heuristics.
sub instance_effective_source {
    my ($inst) = @_;
    my $src = ref($inst) eq 'HASH' ? ($inst->{'source'} // '') : '';
    return $src if $src eq 'steamcmd';
    my $script_path = ref($inst) eq 'HASH' ? ($inst->{'script'} // '') : '';
    (my $server_dir = $script_path) =~ s|/[^/]+$||;
    return 'steamcmd' if $server_dir && -f "$server_dir/.steam_app_id";
    return $src || 'lgsm';
}

sub _instance_require_games_pl {
    return if defined &resolve_lgsm_game_script;
    (my $dir = __FILE__) =~ s|/[^/]+$||;
    eval { require "$dir/games.pl"; 1 };
}

# Resolve on-disk LGSM script name (pw -> pwserver when executable exists).
sub instance_executable_script {
    my ($server_dir, $script_path) = @_;
    my $script_name = (split('/', $script_path // ''))[-1] // '';
    $script_name =~ s/[^a-zA-Z0-9_-]//g;
    return '' unless $script_name ne '';
    _instance_require_games_pl();
    if (defined &resolve_lgsm_game_script) {
        my $resolved = resolve_lgsm_game_script($script_name);
        $resolved =~ s/[^a-zA-Z0-9_-]//g;
        return $resolved if $resolved ne '' && -x "$server_dir/$resolved";
    }
    return $script_name if -x "$server_dir/$script_name";
    return $script_name;
}

sub _lgsm_tmux_session_names {
    my ($script_name) = @_;
    my @names;
    for my $c ($script_name) {
        $c =~ s/[^a-zA-Z0-9_-]//g;
        push @names, $c if $c ne '' && !grep { $_ eq $c } @names;
    }
    _instance_require_games_pl();
    if (defined &resolve_lgsm_game_shortname) {
        my $short = resolve_lgsm_game_shortname($script_name);
        $short =~ s/[^a-zA-Z0-9_-]//g;
        push @names, $short if $short ne '' && !grep { $_ eq $short } @names;
    }
    if ($script_name =~ /server$/i) {
        my $base = $script_name;
        $base =~ s/server$//i;
        $base =~ s/[^a-zA-Z0-9_-]//g;
        push @names, $base if $base ne '' && length($base) >= 2 && !grep { $_ eq $base } @names;
    }
    return @names;
}

# LGSM stores a per-instance tmux socket id under lgsm/data/<selfname>.uid.
sub _lgsm_read_uid {
    my ($server_dir, $script_name) = @_;
    return '' unless defined $server_dir && $server_dir ne '';
    $script_name =~ s/[^a-zA-Z0-9_-]//g;
    return '' unless $script_name ne '';
    my $uid_file = "$server_dir/lgsm/data/${script_name}.uid";
    return '' unless -f $uid_file;
    open(my $fh, '<', $uid_file) or return '';
    my $uid = <$fh>;
    close($fh);
    $uid =~ s/[^a-zA-Z0-9]//g;
    return $uid // '';
}

# Socket/session pairs to probe (LGSM: tmux -L <socket> -t <session>).
sub _lgsm_tmux_probe_specs {
    my ($server_dir, $script_name) = @_;
    my @specs;
    my %seen;
    my $uid = _lgsm_read_uid($server_dir, $script_name);
    for my $sess (_lgsm_tmux_session_names($script_name)) {
        $sess =~ s/[^a-zA-Z0-9_-]//g;
        next unless $sess ne '';
        if ($uid ne '') {
            my $sock = "$sess-$uid";
            my $k = "$sock|$sess";
            unless ($seen{$k}++) {
                push @specs, { socket => $sock, session => $sess };
            }
        }
        my $k2 = "$sess|$sess";
        unless ($seen{$k2}++) {
            push @specs, { socket => $sess, session => $sess };
        }
    }
    return @specs;
}

# Live runtime status for UI (manage + index). Provisioning states pass through.
sub instance_runtime_status {
    my ($inst, %opts) = @_;
    return 'unknown' unless ref($inst) eq 'HASH';
    my $istatus = $inst->{'instance_status'} // 'installed';
    return $istatus if $istatus ne '' && $istatus ne 'installed';

    my $script_path = $inst->{'script'} // '';
    (my $server_dir = $script_path) =~ s|/[^/]+$||;
    my $source = instance_effective_source($inst);

    if ($source eq 'steamcmd') {
        return _detect_status_steamcmd($server_dir);
    }

    my $user = $inst->{'user'} // '';
    my $script_name = instance_executable_script($server_dir, $script_path);
    return 'unknown' unless $user =~ /^[a-z][a-z0-9_-]{0,30}$/ && $script_name ne '';

    my $retries = $opts{'retries'} // 0;
    my $last = 'unknown';
    for my $try (0 .. $retries) {
        $last = _detect_status($server_dir, $user, $script_name, %opts);
        last if $last eq 'online' || $last eq 'offline';
        sleep 1 if $try < $retries;
    }
    return $last;
}

# Run ./script details as game user; returns stdout (may be empty).
# Note: LGSM has no "status" command — only details/monitor/start/stop.
sub _detect_status_lgsm_cmd {
    my ($server_dir, $user, $script_name, $cmd) = @_;
    $cmd = 'details' unless defined $cmd && $cmd eq 'details';
    return '' unless $user =~ /^[a-z][a-z0-9_-]{0,30}$/;
    return '' unless defined $server_dir && $server_dir ne '' && -d $server_dir;
    $script_name =~ s/[^a-zA-Z0-9_-]//g;
    return '' unless $script_name ne '' && -x "$server_dir/$script_name";
    my $out;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(15);
        (my $safe_dir = $server_dir) =~ s/'/'\\''/g;
        $out = `su -s /bin/bash -c "cd '$safe_dir' && ./'$script_name' $cmd" $user 2>/dev/null`;
        alarm(0);
    };
    alarm(0);
    return $out // '';
}

# Parse LGSM status/details output. Returns online, offline, or unknown.
sub _parse_lgsm_details_status {
    my ($out) = @_;
    return 'unknown' unless defined $out && length $out;
    return 'online' if $out =~ /(?:STARTED|ONLINE|RUNNING)/i;
    return 'offline' if $out =~ /(?:STOPPED|OFFLINE|NOT\s+STARTED)/i;
    return 'offline' if $out =~ /\bnot\s+running\b/i;
    return 'unknown';
}

sub _detect_status_tmux {
    my ($server_dir, $user, $script_name) = @_;
    return 'offline' unless $user =~ /^[a-z][a-z0-9_-]{0,30}$/;
    return 'offline' unless defined $server_dir && $server_dir ne '';
    (my $safe_dir = $server_dir) =~ s/'/'\\''/g;
    for my $spec (_lgsm_tmux_probe_specs($server_dir, $script_name)) {
        (my $safe_sock = $spec->{socket}) =~ s/[^a-zA-Z0-9_-]//g;
        (my $safe_sess = $spec->{session}) =~ s/[^a-zA-Z0-9_-]//g;
        next unless $safe_sock ne '' && $safe_sess ne '';
        my $rc = system(
            'su', '-s', '/bin/bash', '-c',
            "tmux -L '$safe_sock' has-session -t '$safe_sess' 2>/dev/null",
            $user,
        );
        return 'online' if $rc == 0;
    }
    return 'offline';
}

# Detect whether a game server instance is running (LGSM).
sub _detect_status {
    my ($server_dir, $user, $script_name, %opts) = @_;
    $script_name = instance_executable_script($server_dir, "$server_dir/$script_name")
        if defined $server_dir && $server_dir ne '' && defined $script_name;

    # tmux + LGSM socket is cheap and matches modern LinuxGSM (unique -L sockets).
    my $parsed = _detect_status_tmux($server_dir, $user, $script_name);
    return $parsed if $parsed eq 'online';
    return $parsed if $opts{'light'};

    # Fallback: LGSM details (heavy — forks npm/curl/dpkg on some games).
    my $out = _detect_status_lgsm_cmd($server_dir, $user, $script_name, 'details');
    $parsed = _parse_lgsm_details_status($out);
    return $parsed unless $parsed eq 'unknown';

    return 'offline';
}

# IPv4 suitable for a direct-connect hint (not wildcard/loopback).
sub _instance_ipv4_usable {
    my ($ip) = @_;
    return 0 unless defined $ip && $ip =~ /^(?:\d{1,3}\.){3}\d{1,3}$/;
    return 0 if $ip eq '0.0.0.0' || $ip eq '127.0.0.1' || $ip eq '255.255.255.255';
    my @oct = split /\./, $ip;
    return 0 if grep { $_ > 255 } @oct;
    return 1;
}

# Best-effort connect IP: LGSM cfg (displayip/ip) then default route, then hostname -I.
sub instance_resolve_connect_ip {
    my ($cfg_ref) = @_;
    $cfg_ref ||= {};
    for my $key (qw(displayip ip alertip)) {
        my $ip = $cfg_ref->{$key} // '';
        $ip =~ s/^\s+|\s+$//g;
        next if $ip eq '' || $ip eq '0.0.0.0' || $ip eq '*';
        return $ip if _instance_ipv4_usable($ip);
    }
    my $from_route = _instance_ip_from_default_route();
    return $from_route if _instance_ipv4_usable($from_route);
    my $from_host = _instance_ip_from_hostname();
    return $from_host if _instance_ipv4_usable($from_host);
    return '';
}

sub _instance_ip_from_default_route {
    my $out = `ip -4 route get 1.1.1.1 2>/dev/null`;
    return '' unless defined $out && $out ne '';
    return $1 if $out =~ /\bsrc\s+((?:\d{1,3}\.){3}\d{1,3})/;
    return '';
}

sub _instance_ip_from_hostname {
    my $out = `hostname -I 2>/dev/null`;
    return '' unless defined $out && $out ne '';
    for my $ip (split /\s+/, $out) {
        return $ip if _instance_ipv4_usable($ip);
    }
    return '';
}

# Returns "ip:port" for UI direct-connect line, or '' when IP unknown.
sub instance_direct_connect_endpoint {
    my ($cfg_ref, $port) = @_;
    $port = int($port // 0);
    return '' unless $port > 0 && $port <= 65535;
    my $ip = instance_resolve_connect_ip($cfg_ref);
    return '' unless $ip ne '';
    return "$ip:$port";
}

# Sum VmRSS (kB) for all processes owned by the game user (dedicated-user instances).
sub instance_memory_rss_kb {
    my ($unix_user) = @_;
    return 0 unless defined $unix_user && $unix_user =~ /^[a-z][a-z0-9_-]{0,30}$/;
    open(my $ps, '-|', 'ps', '-u', $unix_user, '-o', 'rss=', '--no-headers') or return 0;
    my $sum = 0;
    while (my $line = <$ps>) {
        $line =~ s/^\s+|\s+$//g;
        next unless $line =~ /^\d+$/;
        $sum += int($line);
    }
    close($ps);
    return $sum;
}

# Human-readable RAM for instance info table, e.g. "2.34 GB", or '' when unknown/zero.
sub instance_memory_display_gb {
    my ($unix_user) = @_;
    my $kb = instance_memory_rss_kb($unix_user);
    return '' unless $kb > 0;
    return sprintf('%.2f GB', $kb / 1024 / 1024);
}

# Lightweight status check for non-LGSM SteamCMD/Wine instances.
sub _detect_status_steamcmd {
    my ($server_dir) = @_;
    my $pidfile = "$server_dir/run.pid";
    return 'offline' unless -f $pidfile;
    open(my $fh, '<', $pidfile) or return 'offline';
    my $pid = <$fh>;
    close($fh);
    chomp($pid //= '');
    return 'offline' unless $pid =~ /^\d+$/;
    return kill(0, int($pid)) ? 'online' : 'offline';
}

sub set_instance_status {
    my ($id, $status) = @_;
    my %reg = _load_registered();
    return unless exists $reg{$id};
    $reg{$id}{'instance_status'} = $status;
    _save_registered(\%reg);
}

sub get_instance_flexible {
    my ($id) = @_;
    my $inst = get_instance($id);
    return $inst if $inst;
    my $reg = get_registered_instance($id) or return undef;
    return {
        id              => $id,
        user            => $reg->{'user'},
        script          => $reg->{'script'},
        source          => $reg->{'source'} // 'manual',
        sftp_user       => $reg->{'sftp_user'} // '',
        owners          => $reg->{'owners'} // '',
        steam_account   => $reg->{'steam_account'} // '',
        instance_status => $reg->{'instance_status'} // 'installed',
        game            => 'unknown',
        port            => 0,
        status          => 'unknown',
        fw_open         => 0,
        warnings        => [],
    };
}

1;
