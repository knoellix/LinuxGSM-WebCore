# LinuxGSM-WebCore - Auto-update check state (cron + per-instance kv file)
use strict;
use warnings;

our $AUTO_UPDATE_CRON_PATH = '/etc/cron.d/linuxgsm-webcore-auto-update';

BEGIN {
    require File::Basename;
    push @INC, File::Basename::dirname(__FILE__);
    require 'cron_helpers.pl';
}

return 1 if defined &read_auto_update;

sub auto_update_file {
    my ($server_dir) = @_;
    return '' unless defined $server_dir && $server_dir ne '';
    return "$server_dir/.monitor/auto_update";
}

# Per-instance integration secrets for game-user cron (Steam Web API key).
# Same kv style as $JOB_DIR/.worker_secrets; never put keys into cron lines.
sub auto_update_secrets_file {
    my ($server_dir) = @_;
    return '' unless defined $server_dir && $server_dir ne '';
    return "$server_dir/.monitor/auto_update_secrets";
}

sub read_auto_update_last_job_id {
    my ($server_dir) = @_;
    my $s = read_auto_update($server_dir);
    my $jid = $s->{last_restart_job} // '';
    return ($jid =~ /^[0-9a-f]{16}$/) ? $jid : '';
}

# Write steam_web_api_key (etc.) for game-user detect. Root CGI/cron rebuild path.
# Mode 0600; chown to unix_user when possible. Returns 1 on success.
sub write_auto_update_secrets {
    my ($server_dir, $unix_user, $keys_ref) = @_;
    return 0 unless defined $server_dir && $server_dir =~ m{^/};
    return 0 unless ref($keys_ref) eq 'HASH';
    my @lines;
    for my $k (sort keys %$keys_ref) {
        next unless $k =~ /^[a-z][a-z0-9_]*$/;
        my $v = $keys_ref->{$k};
        next unless defined $v && $v =~ /\S/;
        $v =~ s/[\t\n\r]//g;
        push @lines, "$k=$v";
    }
    return 0 unless @lines;

    my $dir  = "$server_dir/.monitor";
    my $path = auto_update_secrets_file($server_dir);
    require File::Path;
    File::Path::make_path($dir);
    open(my $fh, '>', $path) or return 0;
    print $fh join("\n", @lines), "\n";
    close($fh) or return 0;
    chmod 0600, $path;
    if (defined $unix_user && $unix_user =~ /^[a-z][a-z0-9_-]{0,30}$/) {
        my @pw = getpwnam($unix_user);
        if (@pw) {
            chown($pw[2], $pw[3], $path);
        }
    }
    return 1;
}

sub clear_auto_update_secrets {
    my ($server_dir) = @_;
    my $path = auto_update_secrets_file($server_dir);
    return 1 unless $path ne '' && -e $path;
    unlink($path);
    return !-e $path;
}

# Refresh or clear secrets for all adapter-capable registered instances.
# Write when enabled + check_workshop + key present; otherwise clear.
# Skips missing server dirs (unit tests / deleted instances). Never fails rebuild.
sub sync_auto_update_instance_secrets {
    my ($config_dir) = @_;
    return 1 unless defined &_load_registered;

    our %config;
    my $key = '';
    if (defined &steam_web_api_key) {
        $key = steam_web_api_key() // '';
    }
    $key = $config{'steam_web_api_key'} // '' unless defined $key && $key =~ /\S/;
    # postinstall / rebuild without %config in memory: read module config file.
    if ((!defined $key || $key !~ /\S/)
        && defined $config_dir && $config_dir ne ''
        && -r "$config_dir/config")
    {
        my %file;
        if (open(my $cf, '<', "$config_dir/config")) {
            while (my $line = <$cf>) {
                chomp $line;
                next if $line =~ /^\s*#/ || $line !~ /=/;
                my ($k, $v) = split(/=/, $line, 2);
                next unless defined $k;
                $file{$k} = $v // '';
            }
            close($cf);
        }
        $key = $file{'steam_web_api_key'} // '';
    }
    $key = '' unless defined $key;
    $key =~ s/[\t\n\r]//g;

    my $lib = __FILE__;
    $lib =~ s{/[^/]+$}{};
    require "$lib/auto_update_pz.pl" unless defined &auto_update_adapter_for_script;

    my %reg = _load_registered();
    for my $id (sort keys %reg) {
        my $r      = $reg{$id} || {};
        my $script = $r->{script} // '';
        my $user   = $r->{user}   // '';
        next if $script eq '';
        my $script_base = $script;
        $script_base =~ s{.*/}{};
        next if auto_update_adapter_for_script($script_base) eq '';

        (my $sdir = $script) =~ s{/[^/]+$}{};
        next if $sdir eq '' || !-d $sdir;

        my $au = read_auto_update($sdir);
        if (($au->{enabled} // 0)
            && ($au->{check_workshop} // 0)
            && defined $key && $key =~ /\S/)
        {
            write_auto_update_secrets($sdir, $user, { steam_web_api_key => $key });
        }
        else {
            clear_auto_update_secrets($sdir);
        }
    }
    return 1;
}

sub _auto_update_defaults {
    return (
        enabled            => 0,
        check_game         => 1,
        check_workshop     => 1,
        interval_min       => 30,
        warn_minutes       => '15,10,5,1,0',
        # ASCII hyphen only — em/en dashes mojibake under Webmin Latin-1 paths.
        msg_template       => 'Server-Neustart in {minutes} Min - {reason}',
        msg_now            => 'Server startet jetzt neu - {reason}',
        pending            => 0,
        countdown_deadline => 0,
        need_game          => 0,
        need_workshop      => 0,
    );
}

# Strip newlines and replace em/en dashes (and their UTF-8/Latin-1 mojibake) with '-'.
sub _auto_update_normalize_message {
    my ($v) = @_;
    $v = '' unless defined $v;
    $v =~ s/[\r\n]+/ /g;
    # Unicode en/em dash if the string is already decoded.
    $v =~ s/\x{2013}/-/g;
    $v =~ s/\x{2014}/-/g;
    # Raw UTF-8 byte sequences for en/em dash (source without use utf8).
    $v =~ s/\xE2\x80\x93/-/g;
    $v =~ s/\xE2\x80\x94/-/g;
    # Classic mojibake of UTF-8 em/en dash read as Latin-1/CP1252.
    $v =~ s/â\x{20AC}[\x{201C}\x{201D}]/-/g;  # â€œ / â€
    $v =~ s/â\x80[\x93\x94]/-/g;              # â + 0x80 + 0x93/0x94
    $v =~ s/â€“/-/g;
    $v =~ s/â€”/-/g;
    return $v;
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

sub _auto_update_bool {
    my ($val, $default) = @_;
    return $default unless defined $val;
    return ($val =~ /^(?:1|true|yes|on)$/i) ? 1 : 0;
}

sub read_auto_update {
    my ($server_dir) = @_;
    my %defaults = _auto_update_defaults();
    return {%defaults} unless defined $server_dir && $server_dir ne '';

    my $s = _read_kv_file(auto_update_file($server_dir), \%defaults);

    $s->{enabled}        = _auto_update_bool($s->{enabled},        0);
    $s->{check_game}     = _auto_update_bool($s->{check_game},     1);
    $s->{check_workshop} = _auto_update_bool($s->{check_workshop}, 1);
    $s->{pending}        = _auto_update_bool($s->{pending},        0);
    $s->{need_game}      = _auto_update_bool($s->{need_game},      0);
    $s->{need_workshop}  = _auto_update_bool($s->{need_workshop},  0);

    my $interval = int($s->{interval_min} // 30);
    $s->{interval_min} = validate_auto_update_interval($interval) ? $interval : 30;

    $s->{countdown_deadline} = int($s->{countdown_deadline} // 0);

    unless (validate_warn_minutes($s->{warn_minutes} // '')) {
        $s->{warn_minutes} = $defaults{warn_minutes};
    }

    $s->{msg_template} = $defaults{msg_template}
        unless defined $s->{msg_template} && $s->{msg_template} ne '';
    $s->{msg_now} = $defaults{msg_now}
        unless defined $s->{msg_now} && $s->{msg_now} ne '';
    $s->{msg_template} = _auto_update_normalize_message($s->{msg_template});
    $s->{msg_now}      = _auto_update_normalize_message($s->{msg_now});

    return $s;
}

# Returns 1 if interval is valid (5–1440 minutes).
sub validate_auto_update_interval {
    my ($min) = @_;
    return 0 unless defined $min && $min =~ /^\d+$/;
    my $n = int($min);
    return ($n >= 5 && $n <= 1440) ? 1 : 0;
}

# Returns 1 if CSV is comma-separated unique non-negative integers.
# Zero may appear in the list or be handled separately via msg_now.
sub validate_warn_minutes {
    my ($csv) = @_;
    return 0 unless defined $csv && $csv ne '';
    my @parts = split /,/, $csv;
    return 0 unless @parts;
    my %seen;
    for my $p (@parts) {
        return 0 unless defined $p && $p =~ /^\d+$/;
        return 0 if $seen{$p}++;
    }
    return 1;
}

sub auto_update_fill_message {
    my ($template, $vars_ref) = @_;
    return '' unless defined $template;
    my %v = %{$vars_ref || {}};
    my $out = $template;
    for my $key (qw(minutes reason mods game)) {
        my $val = defined $v{$key} ? $v{$key} : '';
        $out =~ s/\{$key\}/$val/g;
    }
    return $out;
}

# Single-line kv values only — strip CR/LF so free-text templates cannot inject keys.
sub _auto_update_kv_value {
    my ($v) = @_;
    return _auto_update_normalize_message($v);
}

sub _auto_update_serialize {
    my ($ref) = @_;
    return '' unless $ref && ref($ref) eq 'HASH';

    my @lines;
    push @lines, 'enabled=' . (($ref->{enabled} // 0) ? 1 : 0);
    push @lines, 'check_game=' . (($ref->{check_game} // 1) ? 1 : 0);
    push @lines, 'check_workshop=' . (($ref->{check_workshop} // 1) ? 1 : 0);

    my $interval = int($ref->{interval_min} // 30);
    $interval = 30 unless validate_auto_update_interval($interval);
    push @lines, "interval_min=$interval";

    my $warn = $ref->{warn_minutes} // '15,10,5,1,0';
    $warn = '15,10,5,1,0' unless validate_warn_minutes($warn);
    push @lines, "warn_minutes=$warn";

    my $tpl = _auto_update_kv_value(
        $ref->{msg_template} // 'Server-Neustart in {minutes} Min - {reason}');
    push @lines, "msg_template=$tpl";

    my $now = _auto_update_kv_value(
        $ref->{msg_now} // 'Server startet jetzt neu - {reason}');
    push @lines, "msg_now=$now";

    push @lines, 'pending=' . (($ref->{pending} // 0) ? 1 : 0);
    push @lines, 'countdown_deadline=' . int($ref->{countdown_deadline} // 0);
    push @lines, 'need_game=' . (($ref->{need_game} // 0) ? 1 : 0);
    push @lines, 'need_workshop=' . (($ref->{need_workshop} // 0) ? 1 : 0);

    for my $key (qw(reason mods last_check last_restart_job msg_sent)) {
        next unless defined $ref->{$key} && $ref->{$key} ne '';
        push @lines, "$key=" . _auto_update_kv_value($ref->{$key});
    }

    return join("\n", @lines) . "\n";
}

sub write_auto_update {
    my ($server_dir, $ref, $unix_user) = @_;
    return 0 unless defined $server_dir && $server_dir ne '';
    my $file = auto_update_file($server_dir);
    my $dir  = "$server_dir/.monitor";
    my $content = _auto_update_serialize($ref);
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

# Always */5 (or */N when interval_min <= 5). Detect cadence is enforced by
# last_check+interval_min in the check worker; countdown ticks need ≤5 min cron.
sub auto_update_cron_schedule {
    my ($interval_min) = @_;
    my $min = int($interval_min // 30);
    $min = 30 unless validate_auto_update_interval($min);
    return $min <= 5 ? "*/$min * * * *" : '*/5 * * * *';
}

# $inst = { id, user, server_dir, script, kind, interval_min }
sub auto_update_cron_line {
    my ($inst, $module_root) = @_;
    return '' unless $inst && validate_auto_update_interval($inst->{interval_min} // 0);
    my $id     = $inst->{id}         // '';
    my $user   = $inst->{user}       // '';
    my $sdir   = $inst->{server_dir} // '';
    my $script = $inst->{script}     // '';
    my $kind   = $inst->{kind}       // 'lgsm';
    $module_root = '' unless defined $module_root;
    return '' if $id eq '' || $user eq '' || $sdir eq '' || $module_root eq '' || $script eq '';
    return '' unless $user =~ /^[a-zA-Z0-9_][a-zA-Z0-9_-]*$/;

    my $script_base = $script;
    $script_base =~ s{.*/}{};
    return '' if $script_base eq '';

    my $sched = auto_update_cron_schedule($inst->{interval_min});
    my $mr    = cron_sq($module_root);
    my $env   = "MODULE_ROOT=" . $mr;
    my $kind_token = ($kind eq 'native') ? 'native' : 'lgsm';
    my $cmd = join(' ',
        $env, 'bash',
        cron_sq("$module_root/scripts/auto_update_check_user.sh"),
        cron_sq($id), $kind_token, cron_sq($sdir),
        cron_sq($script_base), $mr,
    );
    return "$sched $user $cmd >>" . cron_sq("$sdir/logs/auto_update.log") . " 2>&1";
}

sub auto_update_cron_content {
    my ($insts, $module_root) = @_;
    my @lines = (
        "# LinuxGSM-WebCore auto-update checks — auto-generated, do not edit by hand.",
        "# Rebuilt on auto-update save (manage.cgi) and module upgrade (postinstall.pl).",
        "SHELL=/bin/sh",
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "",
    );
    for my $inst (@{ $insts || [] }) {
        my $line = auto_update_cron_line($inst, $module_root);
        push @lines, $line if defined $line && $line ne '';
    }
    return join("\n", @lines) . "\n";
}

sub write_auto_update_cron {
    my ($insts, $module_root, $dest) = @_;
    $dest = $AUTO_UPDATE_CRON_PATH unless defined $dest && $dest ne '';
    my $content = auto_update_cron_content($insts, $module_root);
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

sub collect_auto_update_instances {
    my ($config_dir, $module_root) = @_;
    my @out;
    return @out unless defined &_load_registered;

    my $lib = __FILE__;
    $lib =~ s{/[^/]+$}{};
    require "$lib/auto_update_pz.pl" unless defined &auto_update_adapter_for_script;

    my %reg = _load_registered();
    for my $id (sort keys %reg) {
        my $r      = $reg{$id} || {};
        my $script = $r->{script} // '';
        next if $script eq '';
        my $script_base = $script;
        $script_base =~ s{.*/}{};
        next if auto_update_adapter_for_script($script_base) eq '';

        (my $sdir = $script) =~ s{/[^/]+$}{};
        next if $sdir eq '';

        my $au = read_auto_update($sdir);
        next unless $au->{enabled};

        my $kind = defined &instance_monitor_kind
            ? instance_monitor_kind($r->{source})
            : 'lgsm';

        push @out, {
            id           => $id,
            user         => $r->{user},
            server_dir   => $sdir,
            script       => $script,
            kind         => $kind,
            interval_min => $au->{interval_min},
        };
    }
    return @out;
}

sub rebuild_auto_update_cron {
    my ($module_root, $config_dir, $dest) = @_;
    # Drop/refresh Steam API key for game-user detect (not in cron line).
    sync_auto_update_instance_secrets($config_dir);
    my @insts = collect_auto_update_instances($config_dir, $module_root);
    return write_auto_update_cron(\@insts, $module_root, $dest);
}

# Launch auto_update_restart_user.sh as the current game user (cron check path).
# Creates $HOME/jobs/<16hex>/ (not root create_job / su). Returns job_id or ''.
# On any failure after status=running is written, marks the job failed so the
# check cron does not skip forever on a stuck "running" orphan.
sub auto_update_launch_restart_job {
    my ($instance_id, $server_dir, $script, $unix_user, $module_root) = @_;
    return '' unless defined $instance_id && $instance_id =~ /\S/;
    return '' unless defined $server_dir && $server_dir =~ m{^/};
    return '' unless defined $unix_user && $unix_user =~ /^[a-z][a-z0-9_-]{0,30}$/;
    return '' unless defined $module_root && $module_root =~ m{^/};
    return '' unless defined $script && $script =~ /\S/;

    my $instance_id_safe = $instance_id;
    $instance_id_safe =~ s/[^a-zA-Z0-9_\-]//g;
    return '' if $instance_id_safe eq '';

    my $me = getpwuid($>) // '';
    return '' unless $me eq $unix_user;

    my $home = $ENV{HOME} // '';
    return '' unless $home =~ m{^/};

    my $script_base = $script;
    $script_base =~ s{.*/}{};
    $script_base =~ s/[^a-zA-Z0-9_-]//g;
    return '' if $script_base eq '';

    my $worker = "$module_root/scripts/auto_update_restart_user.sh";
    return '' unless -f $worker && -x $worker;

    my $raw;
    open(my $rf, '<', '/dev/urandom') or return '';
    read($rf, $raw, 8) == 8 or do { close($rf); return ''; };
    close($rf);
    my $job_id = lc(unpack('H*', $raw));
    return '' unless $job_id =~ /^[0-9a-f]{16}$/;

    require File::Path;
    my $jobs_root = "$home/jobs";
    my $job_dir   = "$jobs_root/$job_id";
    File::Path::make_path($jobs_root, { mode => 0700 });
    mkdir($job_dir, 0700) or return '';
    chmod(0700, $jobs_root, $job_dir);

    my $drop_incomplete = sub {
        eval { File::Path::remove_tree($job_dir) };
        return '';
    };

    my $now = time();
    open(my $mf, '>', "$job_dir/meta") or return $drop_incomplete->();
    print $mf "instance_id=$instance_id_safe\n";
    print $mf "action=auto_update_restart\n";
    print $mf "started_at=$now\n";
    print $mf "unix_user=$unix_user\n";
    print $mf "trigger=auto_update\n";
    close($mf) or return $drop_incomplete->();

    open(my $sf, '>', "$job_dir/status") or return $drop_incomplete->();
    print $sf "running\n";
    close($sf) or return $drop_incomplete->();

    # From here status=running is visible to the check cron — must finalize failed on abort.
    my $mark_failed = sub {
        if (open(my $ef, '>', "$job_dir/status")) {
            print $ef "failed\n";
            close($ef);
        }
        return '';
    };

    open(my $of, '>', "$job_dir/output") or return $mark_failed->();
    close($of) or return $mark_failed->();
    chmod(0600, "$job_dir/meta", "$job_dir/status", "$job_dir/output");

    my $marker_dir = "$server_dir/.monitor";
    File::Path::make_path($marker_dir);
    {
        open(my $pf, '>>', "$marker_dir/pending_job_ids") or return $mark_failed->();
        print $pf "$job_id\n" or do { close($pf); return $mark_failed->(); };
        close($pf) or return $mark_failed->();
    }

    # Write last_restart_job before launch (avoids race with worker clear).
    # On launch failure, roll it back so a stuck pointer is not left behind.
    my $au_before = read_auto_update($server_dir);
    my $prev_restart = $au_before->{last_restart_job} // '';
    $au_before->{last_restart_job} = $job_id;
    write_auto_update($server_dir, $au_before, '') or return $mark_failed->();

    my $rollback_and_fail = sub {
        my $au_rb = read_auto_update($server_dir);
        if (($au_rb->{last_restart_job} // '') eq $job_id) {
            if ($prev_restart ne '') {
                $au_rb->{last_restart_job} = $prev_restart;
            }
            else {
                delete $au_rb->{last_restart_job};
            }
            write_auto_update($server_dir, $au_rb, '');
        }
        return $mark_failed->();
    };

    my $shq = sub {
        my ($v) = @_;
        $v = '' unless defined $v;
        $v =~ s/'/'\\''/g;
        return "'$v'";
    };
    my $cmd = join(
        ' ',
        'MODULE_ROOT=' . $shq->($module_root),
        'setsid', 'nohup', 'bash', $shq->($worker),
        $shq->($job_dir), $shq->($unix_user), $shq->($server_dir),
        $shq->($script_base), $shq->($module_root),
        '</dev/null', '>/dev/null', '2>&1', '&',
    );
    system('/bin/bash', '-c', $cmd);
    return $rollback_and_fail->() if $? != 0;

    return $job_id;
}

1;
