# LinuxGSM-WebCore - Background job management
use strict;
use warnings;

our $config_directory;

sub _jobs_dir { return "$config_directory/jobs" }
sub _job_dir  { return _jobs_dir() . "/$_[0]" }

sub create_job {
    my $raw;
    open(my $f, '<', '/dev/urandom') or die "Cannot read /dev/urandom\n";
    read($f, $raw, 8);
    close($f);
    my $job_id = lc(unpack('H*', $raw));

    my $jobs_dir = _jobs_dir();
    mkdir($jobs_dir, 0700) unless -d $jobs_dir;
    my $job_dir = _job_dir($job_id);
    mkdir($job_dir, 0700) or die "Cannot create job dir: $!\n";

    open(my $fh, '>', "$job_dir/status") or die "Cannot write status: $!\n";
    print $fh "running\n";
    close($fh);

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
    my $file = _job_dir($job_id) . "/output";
    return ('', 0) unless -f $file;
    open(my $fh, '<', $file) or return ('', 0);
    my $content = do { local $/; <$fh> };
    close($fh);
    $content //= '';
    my $len   = length($content);
    my $delta = $offset < $len ? substr($content, $offset) : '';
    return ($delta, $len);
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
    open(my $fh, '>', $file) or return;
    print $fh "$status\n";
    close($fh);
}

sub write_job_meta {
    my ($job_id, $instance_id, $action, $unix_user) = @_;
    my $job_dir = _job_dir($job_id);
    open(my $fh, '>', "$job_dir/meta") or return;
    print $fh "instance_id=$instance_id\n";
    print $fh "action=$action\n";
    print $fh "started_at=" . time() . "\n";
    print $fh "unix_user=$unix_user\n";
    close($fh);
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

sub _write_error_hint {
    my ($job_id, $hint) = @_;
    my $file = _job_dir($job_id) . "/error_hint";
    open(my $fh, '>', $file) or return;
    print $fh "$hint\n";
    close($fh);
}

sub get_all_jobs {
    my $jobs_dir = _jobs_dir();
    return () unless -d $jobs_dir;
    my @jobs;
    opendir(my $dh, $jobs_dir) or return ();
    for my $jid (readdir($dh)) {
        next if $jid =~ /^\./;
        my $jdir = "$jobs_dir/$jid";
        next unless -d $jdir;

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
                }
            }
        }

        push @jobs, {
            job_id      => $jid,
            instance_id => $meta{instance_id} // '',
            action      => $meta{action}      // '',
            unix_user   => $meta{unix_user}   // '',
            started_at  => $meta{started_at}  // 0,
            status      => $status,
        };
    }
    closedir($dh);

    # Newest first
    return sort { ($b->{started_at} || 0) <=> ($a->{started_at} || 0) } @jobs;
}

sub abort_job {
    my ($job_id) = @_;
    my $jdir = _job_dir($job_id);
    if (-f "$jdir/pgid") {
        open(my $fh, '<', "$jdir/pgid") or do { finish_job($job_id, 'aborted'); return; };
        my $pgid = <$fh>; close($fh);
        chomp $pgid if defined $pgid;
        if (defined $pgid && $pgid =~ /^\d+$/) {
            kill(9, -$pgid);   # SIGKILL entire process group
        }
    }
    finish_job($job_id, 'aborted');
}

sub delete_job {
    my ($job_id) = @_;
    my $jdir = _job_dir($job_id);
    return 0 unless -d $jdir;
    my $status = get_job_status($job_id) // '';
    return 0 if $status eq 'running';
    unlink "$jdir/$_" for qw(meta pgid status output error_hint pid);
    rmdir $jdir;
    return 1;
}

sub _auto_cleanup_jobs {
    my $jobs_dir = _jobs_dir();
    return unless -d $jobs_dir;
    my @done;
    opendir(my $dh, $jobs_dir) or return;
    for my $jid (readdir($dh)) {
        next if $jid =~ /^\./;
        my $jdir = "$jobs_dir/$jid";
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
        my $jdir = "$jobs_dir/" . $j->{job_id};
        unlink "$jdir/$_" for qw(meta pgid status output error_hint pid);
        rmdir $jdir;
    }
}

sub cleanup_old_jobs {
    my $jobs_dir = _jobs_dir();
    return unless -d $jobs_dir;
    my $cutoff = time() - 86400;
    opendir(my $dh, $jobs_dir) or return;
    for my $jid (readdir($dh)) {
        next if $jid =~ /^\./;
        my $jdir = "$jobs_dir/$jid";
        next unless -d $jdir;
        my $mtime = (stat($jdir))[9] // 0;
        if ($mtime < $cutoff) {
            unlink "$jdir/$_" for qw(output status pid error_hint);
            rmdir $jdir;
        }
    }
    closedir($dh);
}

1;
