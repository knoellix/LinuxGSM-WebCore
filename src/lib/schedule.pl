# LinuxGSM-WebCore - Scheduled daily restart (cron + per-instance schedule file)
use strict;
use warnings;

our $SCHEDULE_CRON_PATH = '/etc/cron.d/linuxgsm-webcore-schedule';

BEGIN {
    require File::Basename;
    push @INC, File::Basename::dirname(__FILE__);
    require 'cron_helpers.pl';
}

return 1 if defined &read_restart_schedule;

sub _schedule_file {
    my ($server_dir) = @_;
    return '' unless defined $server_dir && $server_dir ne '';
    return "$server_dir/.monitor/schedule";
}

sub _read_kv_file {
    my ($file, $defaults_ref) = @_;
    my %s = %{$defaults_ref || {}};
    return \%s unless defined $file && $file ne '' && -f $file;
    open(my $fh, '<', $file) or return \%s;
    while (<$fh>) {
        chomp;
        next unless /^(\w+)=(.*)$/;
        $s{$1} = $2;
    }
    close($fh);
    return \%s;
}

sub read_restart_schedule {
    my ($server_dir) = @_;
    my %defaults = (
        enabled            => 0,
        time               => '04:00',
        last_run           => 0,
        last_schedule_job  => '',
        last_skip_at       => 0,
    );
    return {%defaults} unless defined $server_dir && $server_dir ne '';
    my $s = _read_kv_file(_schedule_file($server_dir), \%defaults);
    $s->{enabled} = ($s->{enabled} // 0) =~ /^(?:1|true|yes|on)$/i ? 1 : 0;
    $s->{last_run} = int($s->{last_run} // 0);
    $s->{last_skip_at} = int($s->{last_skip_at} // 0);
    $s->{time} = '04:00' unless defined $s->{time} && validate_schedule_time($s->{time});
    $s->{last_schedule_job} = '' unless ($s->{last_schedule_job} // '') =~ /^[0-9a-f]{16}$/;
    return $s;
}

# Returns 1 if HH:MM is valid 24h time.
sub validate_schedule_time {
    my ($time) = @_;
    return 0 unless defined $time && $time =~ /^(\d{1,2}):(\d{2})$/;
    my ($h, $m) = (int($1), int($2));
    return ($h >= 0 && $h <= 23 && $m >= 0 && $m <= 59) ? 1 : 0;
}

# Returns (hour, minute) or empty list.
sub parse_schedule_time {
    my ($time) = @_;
    return unless validate_schedule_time($time);
    my ($h, $m) = split /:/, $time, 2;
    return (int($h), int($m));
}

sub _schedule_serialize {
    my ($ref) = @_;
    return '' unless $ref && ref($ref) eq 'HASH';
    my @lines;
    my $enabled = ($ref->{enabled} // 0) ? 1 : 0;
    push @lines, "enabled=$enabled";
    my $time = $ref->{time} // '04:00';
    $time = '04:00' unless validate_schedule_time($time);
    push @lines, "time=$time";
    if (defined $ref->{last_run} && $ref->{last_run} =~ /^\d+$/ && $ref->{last_run} > 0) {
        push @lines, 'last_run=' . int($ref->{last_run});
    }
    if (defined $ref->{last_skip_at} && $ref->{last_skip_at} =~ /^\d+$/ && $ref->{last_skip_at} > 0) {
        push @lines, 'last_skip_at=' . int($ref->{last_skip_at});
    }
    if (defined $ref->{last_schedule_job} && $ref->{last_schedule_job} =~ /^[0-9a-f]{16}$/) {
        push @lines, 'last_schedule_job=' . $ref->{last_schedule_job};
    }
    return join("\n", @lines) . "\n";
}

sub _schedule_unix_user_for_id {
    my ($id) = @_;
    return '' unless defined $id && $id =~ /\S/;
    return '' unless defined &_load_registered;
    my %reg = _load_registered();
    my $user = $reg{$id}{user} // '';
    return $user if $user =~ /^[a-z][a-z0-9_-]{0,30}$/;
    return '';
}

sub write_restart_schedule {
    my ($server_dir, $ref, $unix_user) = @_;
    return 0 unless defined $server_dir && $server_dir ne '';
    my $file = _schedule_file($server_dir);
    my $dir  = "$server_dir/.monitor";
    my $content = _schedule_serialize($ref);
    return 0 unless $content ne '';

    if (defined $unix_user && $unix_user =~ /^[a-z][a-z0-9_-]{0,30}$/ && $> == 0) {
        if (defined &_repair_monitor_dir_owner) {
            &_repair_monitor_dir_owner($dir, $unix_user);
        }
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

sub read_schedule_last_job_id {
    my ($server_dir) = @_;
    my $s = read_restart_schedule($server_dir);
    return $s->{last_schedule_job} // '';
}

# Human-readable system timezone for UI (cron uses system local time).
sub schedule_system_timezone {
    if (defined $ENV{TZ} && $ENV{TZ} =~ /\S/) {
        return $ENV{TZ};
    }
    if (-r '/etc/timezone') {
        open(my $fh, '<', '/etc/timezone') or return 'localtime';
        my $tz = <$fh>;
        close($fh);
        $tz =~ s/^\s+|\s+$//g if defined $tz;
        return $tz if defined $tz && $tz ne '';
    }
    my $tz = `timedatectl show -p Timezone --value 2>/dev/null`;
    $tz =~ s/^\s+|\s+$//g if defined $tz;
    return $tz if defined $tz && $tz ne '';
    return 'localtime';
}

# $inst = { id, user, server_dir, script, kind, schedule_enabled, schedule_time }
sub schedule_cron_line {
    my ($inst, $module_root) = @_;
    return '' unless $inst && ($inst->{schedule_enabled} // 0);
    my $id     = $inst->{id}         // '';
    my $user   = $inst->{user}       // '';
    my $sdir   = $inst->{server_dir} // '';
    my $script = $inst->{script}     // '';
    my $kind   = $inst->{kind}       // 'lgsm';
    my $time   = $inst->{schedule_time} // '04:00';
    $module_root = '' unless defined $module_root;
    return '' if $id eq '' || $user eq '' || $sdir eq '' || $module_root eq '' || $script eq '';
    return '' unless validate_schedule_time($time);
    my ($hour, $min) = parse_schedule_time($time);
    my $script_base = $script;
    $script_base =~ s{.*/}{};
    return '' if $script_base eq '';
    return '' unless $user =~ /^[a-zA-Z0-9_][a-zA-Z0-9_-]*$/;

    my $mr  = cron_sq($module_root);
    my $env = "MODULE_ROOT=" . $mr;
    my $kind_token = ($kind eq 'native') ? 'native' : 'lgsm';
    my $cmd = join(' ',
        $env, 'bash',
        cron_sq("$module_root/scripts/scheduled_restart_user.sh"),
        cron_sq($id), $kind_token, cron_sq($sdir),
        cron_sq($script_base), $mr,
    );
    return "$min $hour * * * $user $cmd >>" . cron_sq("$sdir/logs/schedule.log") . " 2>&1";
}

sub schedule_cron_content {
    my ($insts, $module_root) = @_;
    my @lines = (
        "# LinuxGSM-WebCore scheduled restarts — auto-generated, do not edit by hand.",
        "# Rebuilt on schedule save (manage.cgi) and module upgrade (postinstall.pl).",
        "# Times are server local time (" . schedule_system_timezone() . ").",
        "SHELL=/bin/sh",
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "",
    );
    for my $inst (@{ $insts || [] }) {
        my $line = schedule_cron_line($inst, $module_root);
        push @lines, $line if defined $line && $line ne '';
    }
    return join("\n", @lines) . "\n";
}

sub write_schedule_cron {
    my ($insts, $module_root, $dest) = @_;
    $dest = $SCHEDULE_CRON_PATH unless defined $dest && $dest ne '';
    my $content = schedule_cron_content($insts, $module_root);
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

sub collect_schedule_instances {
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
        my $sched = read_restart_schedule($sdir);
        next unless $sched->{enabled};
        my $kind = defined &instance_monitor_kind
            ? instance_monitor_kind($r->{source})
            : 'lgsm';
        push @out, {
            id               => $id,
            user             => $r->{user},
            server_dir       => $sdir,
            script           => $script,
            kind             => $kind,
            schedule_enabled => 1,
            schedule_time    => $sched->{time},
        };
    }
    return @out;
}

sub rebuild_schedule_cron {
    my ($module_root, $config_dir, $dest) = @_;
    my @insts = collect_schedule_instances($config_dir);
    return write_schedule_cron(\@insts, $module_root, $dest);
}

1;
