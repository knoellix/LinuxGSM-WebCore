# LinuxGSM-WebCore - Monitor state management
use strict;
use warnings;

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
    return \%s;
}

sub read_monitor_state {
    my ($server_dir, $config_dir, $id) = @_;
    my %defaults = (status => 'running', restart_count => 0, window_start => time());
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

sub write_monitor_state {
    my ($server_dir, $state_ref) = @_;
    return unless defined $server_dir && $server_dir ne '';
    my $file = _state_file($server_dir);
    return unless defined $file;
    my $dir  = "$server_dir/.monitor";
    require File::Path;
    File::Path::make_path($dir);
    open(my $fh, '>', $file) or return;
    print $fh "status=$state_ref->{status}\n";
    print $fh "restart_count=" . int($state_ref->{restart_count} // 0) . "\n";
    print $fh "window_start="  . int($state_ref->{window_start}  // time()) . "\n";
    close($fh);
}

sub set_monitor_paused {
    my ($server_dir, $config_dir, $id) = @_;
    my $s = read_monitor_state($server_dir, $config_dir, $id);
    $s->{status} = 'paused';
    write_monitor_state($server_dir, $s);
}

sub set_monitor_running {
    my ($server_dir) = @_;  # no migration args needed — always writes fresh state
    write_monitor_state($server_dir, {
        status        => 'running',
        restart_count => 0,
        window_start  => time(),
    });
}

sub set_monitor_disabled {
    my ($server_dir, $config_dir, $id) = @_;
    my $s = read_monitor_state($server_dir, $config_dir, $id);
    $s->{status} = 'disabled';
    write_monitor_state($server_dir, $s);
}

sub monitor_is_active {
    my ($server_dir, $config_dir, $id) = @_;
    my $s = read_monitor_state($server_dir, $config_dir, $id);
    return $s->{status} !~ /^(?:paused|disabled)$/;
}

1;
