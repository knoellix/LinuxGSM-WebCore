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
