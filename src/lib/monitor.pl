# LinuxGSM-WebCore - Monitor state management
use strict;
use warnings;

return 1 if defined &read_monitor_state;

sub _state_file {
    my ($config_dir, $id) = @_;
    return "$config_dir/monitor/$id/state";
}

sub read_monitor_state {
    my ($config_dir, $id) = @_;
    my %defaults = (status => 'running', restart_count => 0, window_start => time());
    my $file = _state_file($config_dir, $id);
    return {%defaults} unless -f $file;
    my %state = %defaults;
    open(my $fh, '<', $file) or return {%defaults};
    while (<$fh>) {
        chomp;
        next unless /^(\w+)=(.*)$/;
        $state{$1} = $2;
    }
    close($fh);
    $state{restart_count} = int($state{restart_count} // 0);
    $state{window_start}  = int($state{window_start}  // 0);
    return \%state;
}

sub write_monitor_state {
    my ($config_dir, $id, $state_ref) = @_;
    my $file = _state_file($config_dir, $id);
    my $dir  = $file;
    $dir =~ s|/[^/]+$||;
    unless (-d $dir) {
        require File::Path;
        File::Path::make_path($dir) or return;
    }
    open(my $fh, '>', $file) or return;
    print $fh "status=$state_ref->{status}\n";
    print $fh "restart_count=" . int($state_ref->{restart_count} // 0) . "\n";
    print $fh "window_start=" . int($state_ref->{window_start} // time()) . "\n";
    close($fh);
}

sub set_monitor_paused {
    my ($config_dir, $id) = @_;
    my $s = read_monitor_state($config_dir, $id);
    $s->{status} = 'paused';
    write_monitor_state($config_dir, $id, $s);
}

sub set_monitor_running {
    my ($config_dir, $id) = @_;
    write_monitor_state($config_dir, $id, {
        status        => 'running',
        restart_count => 0,
        window_start  => time(),
    });
}

sub set_monitor_disabled {
    my ($config_dir, $id) = @_;
    my $s = read_monitor_state($config_dir, $id);
    $s->{status} = 'disabled';
    write_monitor_state($config_dir, $id, $s);
}

sub monitor_is_active {
    my ($config_dir, $id) = @_;
    my $s = read_monitor_state($config_dir, $id);
    return $s->{status} !~ /^(?:paused|disabled)$/;
}

1;
