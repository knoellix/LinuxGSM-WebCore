# LinuxGSM-WebCore - Background job management
use strict;
use warnings;

our $config_directory;
our $module_config_directory;
our $_jobs_home_base = '/home';

sub _chown_to_unix_user {
    my ($unix_user, @paths) = @_;
    return unless defined $unix_user && $unix_user ne '';
    return unless getpwnam($unix_user);
    for my $p (@paths) {
        next unless defined $p && -e $p;
        system('chown', "$unix_user:$unix_user", $p);
    }
}

sub _jobs_dir { return "$config_directory/jobs" }

sub _job_dir {
    my ($job_id) = @_;
    my $ptr = _jobs_dir() . "/$job_id";
    if (-f $ptr) {
        open(my $fh, '<', $ptr) or return $ptr;
        my $path = do { local $/; <$fh> };
        close($fh);
        chomp($path //= '');
        return $path if $path;
    }
    return $ptr;
}

sub _shell_safe_job_dir {
    my ($job_id) = @_;
    my $dir = _job_dir($job_id);
    $dir =~ s/'/'\\''/g;
    return $dir;
}

sub _read_monitor_last_job_id {
    my ($server_dir) = @_;
    return '' unless defined $server_dir && $server_dir ne '';
    my $f = "$server_dir/.monitor/state";
    return '' unless -f $f;
    open(my $fh, '<', $f) or return '';
    my $jid = '';
    while (<$fh>) {
        if (/^last_restart_job=([0-9a-f]{16})\s*$/) {
            $jid = $1;
            last;
        }
    }
    close($fh);
    return $jid;
}

sub _read_job_meta_action {
    my ($job_dir) = @_;
    return '' unless defined $job_dir && -f "$job_dir/meta";
    open(my $fh, '<', "$job_dir/meta") or return '';
    my $action = '';
    while (<$fh>) {
        if (/^action=(.*)$/) {
            $action = $1;
            last;
        }
    }
    close($fh);
    $action =~ s/[^a-z_]//g;
    return $action;
}

# Link $config_directory/jobs/<id> → $home/<user>/jobs/<id>. Returns 1 if linked.
sub _ensure_job_pointer {
    my ($job_id, $unix_user) = @_;
    return 0 unless defined $job_id && $job_id =~ /^[0-9a-f]{16}$/;
    return 0 unless defined $unix_user && $unix_user =~ /^[a-z][a-z0-9_-]{0,30}$/;
    my $user_job = "$_jobs_home_base/$unix_user/jobs/$job_id";
    return 0 unless -d $user_job;
    my $jobs_dir = _jobs_dir();
    mkdir($jobs_dir, 0700) unless -d $jobs_dir;
    my $ptr = "$jobs_dir/$job_id";
    if (-f $ptr) {
        open(my $rf, '<', $ptr) or return 0;
        my $path = do { local $/; <$rf> };
        close($rf);
        chomp($path //= '');
        return ($path eq $user_job) ? 1 : 0;
    }
    open(my $wf, '>', $ptr) or return 0;
    print $wf "$user_job\n";
    close($wf);
    chmod(0600, $ptr);
    return 1;
}

sub _flash_mark_monitor_restart {
    my ($instance_id) = @_;
    return unless defined $instance_id && $instance_id =~ /\S/;
    if (defined &module_config_flash_mark) {
        my $safe = $instance_id;
        $safe =~ s/[^a-zA-Z0-9_-]//g;
        return unless $safe ne '';
        &module_config_flash_mark("monitor_restart_$safe");
        return;
    }
    return unless defined $module_config_directory && $module_config_directory ne '';
    my $safe = $instance_id;
    $safe =~ s/[^a-zA-Z0-9_-]//g;
    return unless $safe ne '';
    my $f = "$module_config_directory/.flash_monitor_restart_$safe";
    open(my $fh, '>', $f) or return;
    print $fh time(), "\n";
    close($fh);
    chmod(0600, $f);
}

# Register game-user monitor jobs (pointer under $config_directory/jobs/) so
# jobs.cgi and manage.cgi can list monitor_restart entries.
sub sync_monitor_job_pointers {
    return 0 unless defined &_load_registered;
    my $jobs_dir = _jobs_dir();
    mkdir($jobs_dir, 0700) unless -d $jobs_dir;
    my %reg = _load_registered();
    my $synced_any = 0;
    for my $id (keys %reg) {
        my $r = $reg{$id} || {};
        my $user = $r->{user} // '';
        my $script = $r->{script} // '';
        next if $user eq '' || $script eq '';
        next unless $user =~ /^[a-z][a-z0-9_-]{0,30}$/;
        (my $sdir = $script) =~ s|/[^/]+$||;
        next if $sdir eq '';

        my %want;
        my $pending = "$sdir/.monitor/pending_job_ids";
        if (-f $pending) {
            open(my $pf, '<', $pending) or next;
            for my $line (<$pf>) {
                chomp $line;
                $want{$line} = 1 if $line =~ /^[0-9a-f]{16}$/;
            }
            close($pf);
        }
        my $last = _read_monitor_last_job_id($sdir);
        $want{$last} = 1 if $last ne '';
        if (defined &read_schedule_last_job_id) {
            my $sl = &read_schedule_last_job_id($sdir);
            $want{$sl} = 1 if $sl ne '';
        }

        my @remain;
        for my $jid (sort keys %want) {
            my $user_job = "$_jobs_home_base/$user/jobs/$jid";
            unless (-d $user_job) {
                push @remain, $jid;
                next;
            }
            my $ptr = "$jobs_dir/$jid";
            my $had_ptr = -f $ptr;
            if (_ensure_job_pointer($jid, $user)) {
                $synced_any = 1;
                if (!$had_ptr && _read_job_meta_action($user_job) eq 'monitor_restart') {
                    _flash_mark_monitor_restart($id);
                }
            } else {
                push @remain, $jid;
            }
        }

        if (-f $pending) {
            if (@remain) {
                open(my $wf, '>', $pending) or next;
                print $wf "$_\n" for @remain;
                close($wf);
            } else {
                unlink($pending);
            }
        }
    }
    _invalidate_all_jobs_cache() if $synced_any;
    return $synced_any ? 1 : 0;
}

my $_all_jobs_cache;

sub _invalidate_all_jobs_cache {
    $_all_jobs_cache = undef;
}

sub create_job {
    _invalidate_all_jobs_cache();
    my ($unix_user) = @_;
    my $raw;
    open(my $f, '<', '/dev/urandom') or die "Cannot read /dev/urandom\n";
    read($f, $raw, 8);
    close($f);
    my $job_id = lc(unpack('H*', $raw));

    my $jobs_dir = _jobs_dir();
    mkdir($jobs_dir, 0700) unless -d $jobs_dir;

    my $job_dir;
    if (defined $unix_user && $unix_user ne '') {
        my $user_home_jobs = "$_jobs_home_base/$unix_user/jobs";
        unless (-d $user_home_jobs) {
            mkdir("$_jobs_home_base/$unix_user", 0750) unless -d "$_jobs_home_base/$unix_user";
            mkdir($user_home_jobs, 0750) or die "Cannot create jobs dir for $unix_user: $!\n";
        }
        _chown_to_unix_user($unix_user, $user_home_jobs) if -d $user_home_jobs;
        $job_dir = "$user_home_jobs/$job_id";
        mkdir($job_dir, 0750) or die "Cannot create job dir: $!\n";
        _chown_to_unix_user($unix_user, $user_home_jobs, $job_dir);
        open(my $pfh, '>', "$jobs_dir/$job_id") or die "Cannot write pointer: $!\n";
        print $pfh "$job_dir\n";
        close($pfh);
    } else {
        $job_dir = _job_dir($job_id);
        mkdir($job_dir, 0700) or die "Cannot create job dir: $!\n";
    }

    open(my $fh, '>', "$job_dir/status") or die "Cannot write status: $!\n";
    print $fh "running\n";
    close($fh);
    _chown_to_unix_user($unix_user, "$job_dir/status") if defined $unix_user && $unix_user ne '';

    _auto_cleanup_jobs();

    return $job_id;
}

sub get_job_status {
    my ($job_id) = @_;
    my $file = _job_dir($job_id) . "/status";
    return undef unless -f $file;
    open(my $fh, '<', $file) or return undef;
    my $s = <$fh>; chomp $s; close($fh);
    return $s;
}

sub get_job_output {
    my ($job_id, $offset) = @_;
    $offset //= 0;
    my $content = _read_job_output_content($job_id);
    $content //= '';
    my $len   = length($content);
    my $delta = $offset < $len ? substr($content, $offset) : '';
    return ($delta, $len);
}

# Max bytes returned to browser live-log polls (full file stays on disk).
our $JOB_OUTPUT_DISPLAY_MAX_BYTES = 256 * 1024;

sub _sanitize_job_log_text {
    my ($text) = @_;
    $text //= '';
    $text =~ s/\r\n/\n/g;
    $text =~ s/\r/\n/g;
    unless (utf8::is_utf8($text)) {
        require Encode;
        $text = Encode::decode('UTF-8', $text, Encode::FB_DEFAULT());
    }
    # LGSM/steamcmd emit ANSI SGR sequences (colors). Strip for plain-text UI.
    $text =~ s/\e\[[0-9;?]*[ -\/]*[@-~]//g;
    $text =~ s/\e\][^\a]*(?:\a|\e\\)//g;
    # Orphan CSI fragments when ESC was lost before display (e.g. [32m, [0m).
    $text =~ s/\[(?:[0-9]{1,3};)*[0-9]{1,3}m//g;
    $text =~ s/\[[0-9;?]*[A-Za-z]//g;
    return $text;
}

# Tail-truncated, display-safe job output for UI polling (avoids multi-MB JSON).
sub get_job_output_display {
    my ($job_id, $max_bytes) = @_;
    $max_bytes //= $JOB_OUTPUT_DISPLAY_MAX_BYTES;
    my $content = _sanitize_job_log_text(_read_job_output_content($job_id) // '');
    return $content if length($content) <= $max_bytes;
    my $tail = substr($content, -$max_bytes);
    $tail =~ s/^[^\n]*\n//s if index($tail, "\n") >= 0;
    my $omitted = length($content) - length($tail);
    return "=== … earlier log output omitted ($omitted bytes) ===\n\n" . $tail;
}

# Read job output file; fall back to su cat when Webmin (root) cannot open the
# game-user-owned file (e.g. restrictive home dir permissions).
sub _read_job_output_content {
    my ($job_id) = @_;
    my $file = _job_dir($job_id) . "/output";
    return '' unless -f $file;
    if (open(my $fh, '<', $file)) {
        my $content = do { local $/; <$fh> };
        close($fh);
        return $content // '';
    }
    my %meta = _read_meta($job_id);
    my $user = $meta{'unix_user'} // '';
    return '' unless $user =~ /^[a-z][a-z0-9_-]{0,30}$/;
    my $safe = $file;
    $safe =~ s/'/'\\''/g;
    my $content = `su -s /bin/bash -c 'cat '\''$safe'\''' $user 2>/dev/null`;
    return defined $content ? $content : '';
}

sub get_job_error_hint {
    my ($job_id) = @_;
    my $file = _job_dir($job_id) . "/error_hint";
    return '' unless -f $file;
    open(my $fh, '<', $file) or return '';
    my $h = <$fh>; chomp $h; close($fh);
    return $h // '';
}

sub finish_job {
    my ($job_id, $status) = @_;
    my $file = _job_dir($job_id) . "/status";
    open(my $fh, '>', $file) or return 0;
    print $fh "$status\n";
    close($fh);
    _invalidate_all_jobs_cache();
    return 1;
}

sub chown_job_files_to_user {
    my ($unix_user, @paths) = @_;
    _chown_to_unix_user($unix_user, @paths);
    return 1;
}

sub write_job_meta {
    my ($job_id, $instance_id, $action, $unix_user, $extra) = @_;
    my $job_dir = _job_dir($job_id);
    open(my $fh, '>', "$job_dir/meta") or do {
        &log_error("Cannot write meta for job $job_id: $!");
        return 0;
    };
    print $fh "instance_id=$instance_id\n";
    print $fh "action=$action\n";
    print $fh "started_at=" . time() . "\n";
    print $fh "unix_user=$unix_user\n";
    if ($extra && ref($extra) eq 'HASH') {
        for my $k (sort keys %$extra) {
            my $v = $extra->{$k};
            next unless defined $v && $v ne '';
            next unless $k =~ /^([a-zA-Z0-9_]+)$/;
            $k = $1;
            $v =~ s/[\r\n]//g;
            print $fh "$k=$v\n";
        }
    }
    close($fh);
    _chown_to_unix_user($unix_user, "$job_dir/meta") if defined $unix_user && $unix_user ne '';
    return 1;
}
sub job_dispatch_verified {
    my ($job_id) = @_;
    return 0 unless defined $job_id && $job_id =~ /\S/;
    my $dir = _job_dir($job_id);
    return 0 unless -d $dir && -f "$dir/meta" && -f "$dir/status";
    return (get_job_status($job_id) // '') eq 'running' ? 1 : 0;
}

# Single-quote a value for safe embedding in a /bin/sh command.
sub _job_shq {
    my ($v) = @_;
    $v = '' unless defined $v;
    $v =~ s/'/'\\''/g;
    return "'$v'";
}

# Build the background launch command for a user-native worker.
# The ONLY privileged step at runtime: root drops to the game user via su and
# execs the worker directly (no internal su, files owned by the user).
# Returns a shell string for &system_logged(...).
#
#   user_worker_launch_cmd(
#       unix_user   => 'gs_foo',
#       module_root => $module_root,
#       worker      => "$module_root/scripts/mc_loader_install_user.sh",
#       args        => [ $job_dir, $unix_user, $server_dir, $lgsm_script ],
#       env         => { WEBCORE_JOB_DIR => $job_dir },   # optional
#   )
sub user_worker_launch_cmd {
    my (%a) = @_;
    my $unix_user   = $a{unix_user};
    my $worker      = $a{worker};
    my $module_root = $a{module_root} // '';
    my @args        = @{ $a{args} || [] };
    my %env         = %{ $a{env}  || {} };
    return undef unless defined $unix_user && $unix_user =~ /\S/;
    return undef unless defined $worker && $worker =~ /\S/;

    $env{MODULE_ROOT} = $module_root if $module_root ne '' && !exists $env{MODULE_ROOT};

    my @parts;
    for my $k (sort keys %env) {
        next unless $k =~ /^[A-Za-z_][A-Za-z0-9_]*$/;
        push @parts, "$k=" . _job_shq($env{$k});
    }
    my $inner = join(' ', @parts);
    $inner .= ' ' if length $inner;
    $inner .= 'exec bash ' . _job_shq($worker);
    $inner .= ' ' . join(' ', map { _job_shq($_) } @args) if @args;

    (my $inner_q = $inner) =~ s/'/'\\''/g;
    return "setsid nohup su -s /bin/bash -c '$inner_q' " . _job_shq($unix_user) . ' &';
}

# Mark job failed when worker could not be launched from CGI.
sub job_mark_launch_failed {
    my ($job_id) = @_;
    return 0 unless defined $job_id && $job_id =~ /\S/;
    finish_job($job_id, 'failed');
    _write_error_hint($job_id, 'hint_worker_never_started');
    return 1;
}

sub _read_meta {
    my ($job_id) = @_;
    my $file = _job_dir($job_id) . "/meta";
    return () unless -f $file;
    my %m;
    open(my $fh, '<', $file) or return ();
    while (<$fh>) {
        chomp;
        next unless /=/;
        my ($k, $v) = split(/=/, $_, 2);
        $m{$k} = $v if defined $k && defined $v;
    }
    close($fh);
    return %m;
}

sub get_job_meta {
    my ($job_id) = @_;
    return { _read_meta($job_id) };
}

sub job_output_file {
    my ($job_id) = @_;
    $job_id =~ s/[^0-9a-f]//g;
    return '' unless length($job_id) == 16;
    return _job_dir($job_id) . "/output";
}

sub validate_job_output_path {
    my ($path) = @_;
    return 0 unless defined $path && $path =~ m|^/home/[a-z][a-z0-9_-]{0,30}/jobs/[0-9a-f]{16}/output$|;
    return 1;
}

sub validate_job_for_instance {
    my ($job_id, $instance_id) = @_;
    $job_id =~ s/[^0-9a-f]//g;
    return 0 unless length($job_id) == 16;
    return 0 unless defined $instance_id && $instance_id =~ /\S/;
    my %meta = _read_meta($job_id);
    return 0 unless ($meta{'instance_id'} // '') eq $instance_id;
    return 1;
}

sub _write_error_hint {
    my ($job_id, $hint) = @_;
    my $file = _job_dir($job_id) . "/error_hint";
    open(my $fh, '>', $file) or return;
    print $fh "$hint\n";
    close($fh);
}

sub _read_job_pgid {
    my ($job_id) = @_;
    my $file = _job_dir($job_id) . "/pgid";
    return undef unless -f $file;
    open(my $fh, '<', $file) or return undef;
    my $pgid = <$fh>;
    close($fh);
    chomp($pgid //= '');
    return ($pgid =~ /^\d+$/) ? int($pgid) : undef;
}

sub _kill_job_processes {
    my ($job_id) = @_;
    my $pgid = _read_job_pgid($job_id);
    return 0 unless $pgid;

    my $killed_any = 0;

    # Phase 1: terminate process group gracefully.
    if (kill(0, -$pgid)) {
        kill('TERM', -$pgid);
        $killed_any = 1;
    }

    # Also try parent-child based cleanup in case descendants escaped the group.
    system("pkill -TERM -P $pgid >/dev/null 2>&1");
    select(undef, undef, undef, 1.0);

    # Phase 2: hard-kill remaining processes.
    if (kill(0, -$pgid)) {
        kill('KILL', -$pgid);
        $killed_any = 1;
    }
    system("pkill -KILL -P $pgid >/dev/null 2>&1");
    select(undef, undef, undef, 0.3);

    # Phase 3: fallback by full process tree query.
    system("pkill -TERM -g $pgid >/dev/null 2>&1");
    select(undef, undef, undef, 0.3);
    system("pkill -KILL -g $pgid >/dev/null 2>&1");

    return $killed_any ? 1 : 0;
}

sub _cleanup_terminal_job_processes {
    my ($job_id, $status) = @_;
    return unless defined $status;
    return if $status eq 'running';
    _kill_job_processes($job_id);
    my $pgid_file = _job_dir($job_id) . "/pgid";
    unlink $pgid_file if -f $pgid_file;
}

sub get_all_jobs {
    return @{$_all_jobs_cache} if $_all_jobs_cache;
    sync_monitor_job_pointers();
    my $jobs_dir = _jobs_dir();
    return () unless -d $jobs_dir;
    my @jobs;
    opendir(my $dh, $jobs_dir) or return ();
    for my $jid (readdir($dh)) {
        next if $jid =~ /^\./;
        my $entry = "$jobs_dir/$jid";
        next unless -d $entry || -f $entry;   # Pointer-File oder altes Dir
        my $jdir = _job_dir($jid);
        next unless -d $jdir;

        timeout_check_job($jid);
        my %meta   = _read_meta($jid);
        my $status = get_job_status($jid) // 'unknown';

        # Zombie detection: status=running but process is dead
        if ($status eq 'running' && -f "$jdir/pgid") {
            open(my $pf, '<', "$jdir/pgid") or do { next };
            my $pgid = <$pf>; close($pf);
            chomp $pgid if defined $pgid;
            if (defined $pgid && $pgid =~ /^\d+$/) {
                my $alive = kill(0, -$pgid);
                unless ($alive) {
                    finish_job($jid, 'failed');
                    _write_error_hint($jid, 'hint_zombie');
                    $status = 'failed';
                    &log_debug("Job $jid: running → failed (zombie, pgid=$pgid)");
                }
            }
        }
        _cleanup_terminal_job_processes($jid, $status);

        push @jobs, {
            job_id      => $jid,
            instance_id => $meta{instance_id} // '',
            action      => $meta{action}      // '',
            unix_user   => $meta{unix_user}   // '',
            started_at  => $meta{started_at}  // 0,
            status      => $status,
            trigger     => $meta{trigger}     // '',
        };
    }
    closedir($dh);

    # Newest first; monitor_restart always visible near the top.
    return sort {
        my $am = (($a->{action} // '') =~ /^(?:monitor_restart|scheduled_restart)$/) ? 1 : 0;
        my $bm = (($b->{action} // '') =~ /^(?:monitor_restart|scheduled_restart)$/) ? 1 : 0;
        return $bm <=> $am if $am != $bm;
        return ($b->{started_at} || 0) <=> ($a->{started_at} || 0);
    } @jobs;
    $_all_jobs_cache = \@jobs;
    return @jobs;
}

# Jobs for one instance, optionally filtered by status and/or action.
sub get_instance_jobs {
    my ($instance_id, %opts) = @_;
    return () unless defined $instance_id && $instance_id =~ /\S/;
    my @jobs = grep { ($_->{instance_id} // '') eq $instance_id } get_all_jobs();
    if (defined $opts{'status'} && $opts{'status'} ne '') {
        @jobs = grep { ($_->{status} // '') eq $opts{'status'} } @jobs;
    }
    if (defined $opts{'action'} && $opts{'action'} ne '') {
        @jobs = grep { ($_->{action} // '') eq $opts{'action'} } @jobs;
    }
    return @jobs;
}

# Newest running job for instance (optional action filter). Returns job_id or undef.
sub find_running_job_for_instance {
    my ($instance_id, $action) = @_;
    my @running = get_instance_jobs($instance_id, status => 'running');
    return undef unless @running;
    if (defined $action && $action ne '') {
        for my $j (@running) {
            return $j->{job_id} if ($j->{action} // '') eq $action;
        }
        return undef;
    }
    return $running[0]->{job_id};
}

sub timeout_check_job {
    my ($job_id) = @_;
    my $jdir = _job_dir($job_id);
    return unless -d $jdir;
    return if get_job_status($job_id) ne 'running';
    return if -f "$jdir/pgid";
    my %meta = _read_meta($job_id);
    return unless (time() - ($meta{started_at} // time())) > 30;
    finish_job($job_id, 'failed');
    _write_error_hint($job_id, 'hint_worker_never_started');
    _cleanup_terminal_job_processes($job_id, 'failed');
    &log_debug("Job $job_id: running → failed (worker never started)") if defined &log_debug;
}

sub abort_job {
    my ($job_id) = @_;
    _kill_job_processes($job_id);
    finish_job($job_id, 'aborted');
    _cleanup_terminal_job_processes($job_id, 'aborted');
}

# Re-open a finished job for resume (modpack import continue). Keeps output + pack_meta.json.
sub append_job_log_line {
    my ($job_id, $line, $unix_user) = @_;
    return 0 unless defined $job_id && $job_id =~ /^[0-9a-f]{16}$/;
    return 0 unless defined $line;
    my $file = _job_dir($job_id) . "/output";
    open(my $fh, '>>', $file) or return 0;
    print $fh "$line\n";
    close($fh);
    _chown_to_unix_user($unix_user, $file) if defined $unix_user && $unix_user ne '';
    return 1;
}

sub restart_job_for_resume {
    my ($job_id, $unix_user) = @_;
    my $jdir = _job_dir($job_id);
    return 0 unless -d $jdir;
    my $status = get_job_status($job_id) // '';
    return 0 if $status eq 'running';
    return 0 if $status eq 'ok';
    unlink "$jdir/pgid", "$jdir/error_hint";
    open(my $fh, '>', "$jdir/status") or return 0;
    print $fh "running\n";
    close($fh);
    _chown_to_unix_user($unix_user, "$jdir/status") if defined $unix_user && $unix_user ne '';
    if (defined $unix_user && $unix_user ne '') {
        _chown_to_unix_user($unix_user, "$jdir/output") if -f "$jdir/output";
        _chown_to_unix_user($unix_user, "$jdir/pack_meta.json") if -f "$jdir/pack_meta.json";
        _chown_to_unix_user($unix_user, "$jdir/cf_resolve_progress.json")
            if -f "$jdir/cf_resolve_progress.json";
        _chown_to_unix_user($unix_user, "$jdir/.worker_secrets") if -f "$jdir/.worker_secrets";
    }
    return 1;
}

sub delete_job {
    my ($job_id) = @_;
    my $ptr  = _jobs_dir() . "/$job_id";
    my $jdir = _job_dir($job_id);
    return 0 unless -d $jdir;
    my $status = get_job_status($job_id) // '';
    return 0 if $status eq 'running';
    unlink "$jdir/$_" for qw(meta pgid status output error_hint pid);
    rmdir $jdir;
    unlink $ptr if -f $ptr;
    return 1;
}

sub _auto_cleanup_jobs {
    my $jobs_dir = _jobs_dir();
    return unless -d $jobs_dir;
    my @done;
    opendir(my $dh, $jobs_dir) or return;
    for my $jid (readdir($dh)) {
        next if $jid =~ /^\./;
        my $entry = "$jobs_dir/$jid";
        next unless -d $entry || -f $entry;
        my $jdir = _job_dir($jid);
        next unless -d $jdir;
        my $status = get_job_status($jid) // '';
        next if $status eq 'running' || $status eq '';
        my %meta = _read_meta($jid);
        my $ts   = $meta{started_at} // (stat($jdir))[9] // 0;
        push @done, { job_id => $jid, started_at => $ts };
    }
    closedir($dh);
    return if @done <= 10;

    # Oldest first, delete until 10 remain
    @done = sort { ($a->{started_at} || 0) <=> ($b->{started_at} || 0) } @done;
    my $excess = @done - 10;
    for my $j (@done[0 .. $excess - 1]) {
        my $jid  = $j->{job_id};
        my $jdir = _job_dir($jid);
        my $ptr  = "$jobs_dir/$jid";
        unlink "$jdir/$_" for qw(meta pgid status output error_hint pid);
        rmdir $jdir;
        unlink $ptr if -f $ptr;
    }
}

sub cleanup_old_jobs {
    my $jobs_dir = _jobs_dir();
    return unless -d $jobs_dir;
    my $cutoff = time() - 86400;
    opendir(my $dh, $jobs_dir) or return;
    for my $jid (readdir($dh)) {
        next if $jid =~ /^\./;
        my $entry = "$jobs_dir/$jid";
        next unless -d $entry || -f $entry;
        my $jdir = _job_dir($jid);
        next unless -d $jdir;
        my $mtime = (stat($jdir))[9] // 0;
        if ($mtime < $cutoff) {
            unlink "$jdir/$_" for qw(output status pid error_hint);
            rmdir $jdir;
            unlink $entry if -f $entry;
        }
    }
    closedir($dh);
}

# Returns localized label for a background job action (shared by manage/job_live/jobs CGI).
sub job_action_label {
    my ($action, $text_ref) = @_;
    $text_ref ||= {};
    my %labels = (
        provision_deps  => $text_ref->{'jobs_action_provision_deps'}  || 'Abhängigkeiten installieren',
        install_game    => $text_ref->{'jobs_action_install_game'}    || 'Spiel installieren',
        setup_lgsm      => $text_ref->{'jobs_action_setup_lgsm'}      || 'LGSM einrichten',
        mc_java_setup   => $text_ref->{'jobs_action_mc_java_setup'}  || 'Minecraft Java-Setup',
        mc_loader_setup => $text_ref->{'jobs_action_mc_loader_setup'} || 'Mod-Loader-Installation',
        modpack_import  => $text_ref->{'jobs_action_modpack_import'}  || 'Modpack importieren',
        mc_mod_install  => $text_ref->{'jobs_action_mc_mod_install'}  || 'Mod installieren',
        update          => $text_ref->{'jobs_action_update'}         || 'Update',
        validate        => $text_ref->{'jobs_action_validate'}       || 'Dateien prüfen',
        reinstall       => $text_ref->{'jobs_action_reinstall'}      || 'Neu installieren',
        start           => $text_ref->{'jobs_action_start'}         || 'Starten',
        stop            => $text_ref->{'jobs_action_stop'}          || 'Stoppen',
        restart         => $text_ref->{'jobs_action_restart'}       || 'Neustart',
        init_game_config => $text_ref->{'jobs_action_init_game_config'} || 'Spiel-Config anlegen',
        monitor_restart    => $text_ref->{'jobs_action_monitor_restart'} || 'Neustart (Monitoring)',
        scheduled_restart  => $text_ref->{'jobs_action_scheduled_restart'} || 'Geplanter Neustart',
    );
    my $act = $action // '';
    return $labels{$act} // $act;
}

sub job_action_labels_hash {
    my ($text_ref) = @_;
    $text_ref ||= {};
    return {
        provision_deps  => job_action_label('provision_deps',  $text_ref),
        install_game    => job_action_label('install_game',    $text_ref),
        setup_lgsm      => job_action_label('setup_lgsm',      $text_ref),
        mc_java_setup   => job_action_label('mc_java_setup',   $text_ref),
        mc_loader_setup => job_action_label('mc_loader_setup', $text_ref),
        modpack_import  => job_action_label('modpack_import',  $text_ref),
        mc_mod_install  => job_action_label('mc_mod_install',  $text_ref),
        update          => job_action_label('update',          $text_ref),
        validate        => job_action_label('validate',        $text_ref),
        reinstall       => job_action_label('reinstall',       $text_ref),
        start           => job_action_label('start',           $text_ref),
        stop            => job_action_label('stop',            $text_ref),
        restart         => job_action_label('restart',         $text_ref),
        init_game_config => job_action_label('init_game_config', $text_ref),
        monitor_restart   => job_action_label('monitor_restart',   $text_ref),
        scheduled_restart => job_action_label('scheduled_restart', $text_ref),
    };
}

sub job_status_label {
    my ($status, $text_ref) = @_;
    $text_ref ||= {};
    my %labels = (
        running => $text_ref->{'jobs_status_running'} || 'Läuft…',
        ok      => $text_ref->{'jobs_status_ok'}      || 'Erfolgreich',
        failed  => $text_ref->{'jobs_status_failed'} || 'Fehlgeschlagen',
        aborted => $text_ref->{'jobs_status_aborted'} || 'Abgebrochen',
    );
    my $st = $status // '';
    return $labels{$st} // $st;
}

# Registry instance_status after a successful setup/install job.
sub job_next_instance_status {
    my ($action) = @_;
    my %map = (
        setup_lgsm      => 'lgsm_ready',
        mc_java_setup   => 'mc_ready',
        mc_loader_setup => 'installed',
        install_game    => 'installed',
    );
    return $map{$action // ''} // '';
}

1;
