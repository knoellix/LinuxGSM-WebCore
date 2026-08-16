# LinuxGSM-WebCore - Monitor state management
use strict;
use warnings;

# Cron config — assigned before the load-guard below so a second require()
# (subs already defined) still (re)initializes these package variables.
our $MONITOR_CRON_PATH     = '/etc/cron.d/linuxgsm-webcore-monitor';
our $MONITOR_CRON_SCHEDULE = '*/5 * * * *';

BEGIN {
    require File::Basename;
    push @INC, File::Basename::dirname(__FILE__);
    require 'cron_helpers.pl';
}

return 1 if defined &read_monitor_state;

sub _state_file {
    my ($server_dir) = @_;
    return undef unless defined $server_dir && $server_dir ne '';
    return "$server_dir/.monitor/state";
}

sub _read_state_from_file {
    my ($file) = @_;
    my %d = (status => 'running', restart_count => 0, window_start => time());
    open(my $fh, '<', $file) or return undef;
    my %s = %d;
    while (<$fh>) {
        chomp; next unless /^(\w+)=(.*)$/;
        $s{$1} = $2;
    }
    close($fh);
    $s{restart_count} = int($s{restart_count} // 0);
    $s{window_start}  = int($s{window_start}  // 0);
    $s{last_restart_at} = int($s{last_restart_at} // 0) if defined $s{last_restart_at};
    return \%s;
}

sub read_monitor_state {
    my ($server_dir, $config_dir, $id) = @_;
    # No state file yet → disabled until first manual start enables monitoring.
    my %defaults = (status => 'disabled', restart_count => 0, window_start => time());
    return {%defaults} unless defined $server_dir && $server_dir ne '';
    # Try new path first
    my $new_file = _state_file($server_dir);
    if (-f $new_file) {
        return _read_state_from_file($new_file) // {%defaults};
    }
    # Fallback to legacy path
    if (defined $config_dir && defined $id) {
        my $old_file = "$config_dir/monitor/$id/state";
        if (-f $old_file) {
            return _read_state_from_file($old_file) // {%defaults};
        }
    }
    return {%defaults};
}

sub _monitor_state_serialize {
    my ($state_ref) = @_;
    return '' unless $state_ref && ref($state_ref) eq 'HASH';
    my @lines;
    for my $k (qw(status restart_count window_start last_restart_at last_restart_job)) {
        next unless exists $state_ref->{$k} && defined $state_ref->{$k} && $state_ref->{$k} ne '';
        my $v = $state_ref->{$k};
        $v = int($v) if $k =~ /^(?:restart_count|window_start|last_restart_at)$/;
        next if $k eq 'last_restart_at' && !$v;
        next if $k eq 'last_restart_job' && $v !~ /^[0-9a-f]{16}$/;
        push @lines, "$k=$v";
    }
    return join("\n", @lines) . (@lines ? "\n" : '');
}

sub _monitor_unix_user_for_id {
    my ($id) = @_;
    return '' unless defined $id && $id =~ /\S/;
    return '' unless defined &_load_registered;
    my %reg = _load_registered();
    my $user = $reg{$id}{user} // '';
    return $user if $user =~ /^[a-z][a-z0-9_-]{0,30}$/;
    return '';
}

# One-time repair when legacy CGI wrote .monitor as root.
sub _repair_monitor_dir_owner {
    my ($dir, $unix_user) = @_;
    return unless defined $dir && $dir ne '' && -d $dir;
    return unless defined $unix_user && $unix_user =~ /^[a-z][a-z0-9_-]{0,30}$/;
    return unless $> == 0;
    my $uid = getpwnam($unix_user);
    return unless defined $uid;
    my @st = stat($dir);
    return unless @st && $st[4] != $uid;
    system('chown', '-R', "$unix_user:$unix_user", $dir);
}

sub write_monitor_state {
    my ($server_dir, $state_ref, $unix_user) = @_;
    return 0 unless defined $server_dir && $server_dir ne '';
    my $file = _state_file($server_dir);
    return 0 unless defined $file;
    my $dir  = "$server_dir/.monitor";
    my $content = _monitor_state_serialize($state_ref);
    return 0 unless $content ne '';

    if (defined $unix_user && $unix_user ne '' && $unix_user =~ /^[a-z][a-z0-9_-]{0,30}$/ && $> == 0) {
        _repair_monitor_dir_owner($dir, $unix_user);
        (my $safe_dir = $dir) =~ s/'/'\\''/g;
        (my $safe_file = $file) =~ s/'/'\\''/g;
        open(my $pipe, '|-', 'su', '-s', '/bin/bash', '-c',
            "mkdir -p '$safe_dir' && cat > '$safe_file'", $unix_user)
            or return 0;
        print $pipe $content;
        close($pipe) or return 0;
        return 1;
    }

    require File::Path;
    File::Path::make_path($dir);
    open(my $fh, '>', $file) or return 0;
    print $fh $content;
    close($fh) or return 0;
    return 1;
}

sub set_monitor_paused {
    my ($server_dir, $config_dir, $id) = @_;
    my $s = read_monitor_state($server_dir, $config_dir, $id);
    $s->{status} = 'paused';
    write_monitor_state($server_dir, $s, _monitor_unix_user_for_id($id));
}

sub set_monitor_running {
    my ($server_dir, $config_dir, $id) = @_;
    my $s = read_monitor_state($server_dir, $config_dir, $id);
    write_monitor_state($server_dir, {
        status           => 'running',
        restart_count    => 0,
        window_start     => time(),
        last_restart_at  => $s->{last_restart_at},
        last_restart_job => $s->{last_restart_job},
    }, _monitor_unix_user_for_id($id));
}

# After Start/Restart from the panel: resume only if monitor was paused (Stop).
# Never override an explicit "disabled" — that re-enabled LGSM query-restart loops.
sub set_monitor_resume_after_start {
    my ($server_dir, $config_dir, $id) = @_;
    my $s = read_monitor_state($server_dir, $config_dir, $id);
    my $st = $s->{status} // 'disabled';
    return 0 if $st eq 'disabled';
    set_monitor_running($server_dir, $config_dir, $id);
    return 1;
}

sub set_monitor_disabled {
    my ($server_dir, $config_dir, $id) = @_;
    my $s = read_monitor_state($server_dir, $config_dir, $id);
    $s->{status} = 'disabled';
    write_monitor_state($server_dir, $s, _monitor_unix_user_for_id($id));
}

sub monitor_is_active {
    my ($server_dir, $config_dir, $id) = @_;
    my $s = read_monitor_state($server_dir, $config_dir, $id);
    return $s->{status} !~ /^(?:paused|disabled)$/;
}

# Format last_restart_at epoch for UI (German locale default via caller lang).
sub monitor_format_restart_time {
    my ($epoch) = @_;
    return '' unless defined $epoch && $epoch =~ /^\d+$/ && $epoch > 0;
    my @t = localtime(int($epoch));
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# ---------------------------------------------------------------------------
# Cron generation (per-instance /etc/cron.d entries)
#
# Design: every instance gets a cron.d line with the **game user** field.
#   - LGSM:   monitor_instance_user.sh … lgsm  → ./script monitor
#   - native: monitor_instance_user.sh … native → PID/A2S + steamcmd_control_user.sh restart
# No root cron lines — steamcmd/Wine start/stop runs as the game user.
# ---------------------------------------------------------------------------

# Build one cron.d line for an instance, or '' if it should not be monitored.
# $inst = { id, user, server_dir, script, kind (lgsm|native), active }
sub monitor_cron_line {
    my ($inst, $module_root) = @_;
    return '' unless $inst && $inst->{active};
    my $id     = $inst->{id}         // '';
    my $user   = $inst->{user}       // '';
    my $sdir   = $inst->{server_dir} // '';
    my $script = $inst->{script}     // '';
    my $kind   = $inst->{kind}       // 'lgsm';
    $module_root = '' unless defined $module_root;
    return '' if $id eq '' || $user eq '' || $sdir eq '' || $module_root eq '' || $script eq '';
    my $script_base = $script;
    $script_base =~ s{.*/}{};
    return '' if $script_base eq '';
    # Guard the bare cron user field: only well-formed unix names allowed.
    return '' unless $user =~ /^[a-zA-Z0-9_][a-zA-Z0-9_-]*$/;

    my $mr  = cron_sq($module_root);
    my $env = "MODULE_ROOT=" . $mr;

    my $kind_token = ($kind eq 'native') ? 'native' : 'lgsm';
    my $cmd = join(' ',
        $env, 'bash',
        cron_sq("$module_root/scripts/monitor_instance_user.sh"),
        cron_sq($id), $kind_token, cron_sq($sdir),
        cron_sq($script_base), $mr,
    );
    return "$MONITOR_CRON_SCHEDULE $user $cmd >/dev/null 2>&1";
}

# Render the full /etc/cron.d file content for the given instance list.
sub monitor_cron_content {
    my ($insts, $module_root) = @_;
    my @lines = (
        "# LinuxGSM-WebCore monitoring — auto-generated, do not edit by hand.",
        "# Rebuilt on monitor changes (manage.cgi) and module upgrade (postinstall.pl).",
        "SHELL=/bin/sh",
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "",
    );
    for my $inst (@{ $insts || [] }) {
        my $line = monitor_cron_line($inst, $module_root);
        push @lines, $line if defined $line && $line ne '';
    }
    return join("\n", @lines) . "\n";
}

# Atomically write the cron.d file. Returns 1 on success, 0 on failure.
sub write_monitor_cron {
    my ($insts, $module_root, $dest) = @_;
    $dest = $MONITOR_CRON_PATH unless defined $dest && $dest ne '';
    my $content = monitor_cron_content($insts, $module_root);
    my $tmp = "$dest.tmp.$$";
    open(my $fh, '>', $tmp) or return 0;
    print $fh $content;
    close($fh) or do { unlink($tmp); return 0; };
    chmod(0644, $tmp);
    unless (rename($tmp, $dest)) {
        unlink($tmp);
        return 0;
    }
    return 1;
}

# Build the instance list for cron generation from the registry.
# Requires instance.pl (_load_registered, instance_monitor_kind) to be loaded.
# Returns a list of hashrefs suitable for write_monitor_cron().
sub collect_monitor_instances {
    my ($config_dir) = @_;
    my @out;
    return @out unless defined &_load_registered;
    my %reg = _load_registered();
    for my $id (sort keys %reg) {
        my $r      = $reg{$id} || {};
        my $script = $r->{script} // '';
        next if $script eq '';
        (my $sdir = $script) =~ s{/[^/]+$}{};
        next if $sdir eq '';
        my $kind = defined &instance_monitor_kind
            ? instance_monitor_kind($r->{source})
            : 'lgsm';
        push @out, {
            id         => $id,
            user       => $r->{user},
            server_dir => $sdir,
            script     => $script,
            kind       => $kind,
            active     => (monitor_is_active($sdir, $config_dir, $id) ? 1 : 0),
        };
    }
    return @out;
}

# Convenience: rebuild the cron.d file from the current registry state.
# Returns 1/0. Safe to call from CGI (root) and postinstall.
sub rebuild_monitor_cron {
    my ($module_root, $config_dir, $dest) = @_;
    my @insts = collect_monitor_instances($config_dir);
    return write_monitor_cron(\@insts, $module_root, $dest);
}

1;
