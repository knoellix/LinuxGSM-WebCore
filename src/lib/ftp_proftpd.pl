use strict;
use warnings;
use File::Glob qw(bsd_glob);

sub _read_lines {
    my ($path) = @_;
    return () unless defined $path && -f $path;
    open(my $fh, '<', $path) or return ();
    my @lines = <$fh>;
    close($fh);
    return @lines;
}

sub discover_proftpd_config_files {
    my ($main_cfg) = @_;
    $main_cfg ||= '/etc/proftpd/proftpd.conf';
    my %seen;
    my @queue = ($main_cfg);
    my @files;

    while (@queue) {
        my $cfg = shift @queue;
        next unless defined $cfg && -f $cfg;
        next if $seen{$cfg}++;
        push @files, $cfg;

        for my $line (_read_lines($cfg)) {
            $line =~ s/#.*$//;
            $line =~ s/^\s+|\s+$//g;
            next unless $line =~ /^Include(?:Optional)?\s+(.+)$/i;
            my $pattern = $1;
            $pattern =~ s/^"(.*)"$/$1/;
            # Relative include paths are resolved against the including file dir.
            if ($pattern !~ m|^/|) {
                (my $cfg_dir = $cfg) =~ s|/[^/]+$||;
                $pattern = "$cfg_dir/$pattern";
            }
            for my $inc (bsd_glob($pattern)) {
                push @queue, $inc if -f $inc;
            }
        }
    }

    return @files;
}

sub find_main_proftpd_config {
    our %config;

    if (($config{'proftpd_main_config'} // '') ne '' && -f $config{'proftpd_main_config'}) {
        return $config{'proftpd_main_config'};
    }

    # Try to detect explicit config path from systemd service command line.
    my $unit = `systemctl show -p ExecStart proftpd 2>/dev/null`;
    if (defined $unit && $unit =~ /-c\s+(\S+)/) {
        my $p = $1;
        $p =~ s/^"(.*)"$/$1/;
        return $p if -f $p;
    }

    my @candidates = (
        '/etc/proftpd/proftpd.conf',
        '/etc/proftpd.conf',
        '/usr/local/etc/proftpd.conf',
    );
    for my $p (@candidates) {
        return $p if -f $p;
    }
    return undef;
}

sub _last_directive {
    my ($files_ref, $name) = @_;
    my $val = '';
    for my $f (@{$files_ref || []}) {
        for my $line (_read_lines($f)) {
            $line =~ s/#.*$//;
            $line =~ s/^\s+|\s+$//g;
            next unless $line =~ /^$name\s+(.+)$/i;
            $val = $1;
            $val =~ s/^"(.*)"$/$1/;
        }
    }
    return $val;
}

sub discover_ftp_state {
    my $main = find_main_proftpd_config();
    my @files = $main ? discover_proftpd_config_files($main) : ();
    my %state = (
        main_config => $main,
        files => [@files],
    );
    my $files = $state{'files'};

    my @warn;
    if (!@files) {
        $state{'warnings'} = ['ProFTPD config not found (checked standard paths)'];
        return %state;
    }

    $state{'auth_user_file'} = _last_directive($files, 'AuthUserFile');
    $state{'default_root'}   = _last_directive($files, 'DefaultRoot');
    $state{'tls_required'}   = _last_directive($files, 'TLSRequired');
    $state{'tls_engine'}     = _last_directive($files, 'TLSEngine');
    $state{'tls_cert'}       = _last_directive($files, 'TLSRSACertificateFile');
    $state{'tls_key'}        = _last_directive($files, 'TLSRSACertificateKeyFile');
    $state{'passive_ports'}  = _last_directive($files, 'PassivePorts');

    push @warn, 'AuthUserFile not set' if !$state{'auth_user_file'};
    push @warn, 'DefaultRoot not set to ~' if lc($state{'default_root'} // '') ne '~';
    push @warn, 'TLSRequired not on' if lc($state{'tls_required'} // '') ne 'on';
    push @warn, 'TLSEngine not on' if lc($state{'tls_engine'} // '') ne 'on';
    push @warn, 'TLS certificate missing' if !$state{'tls_cert'} || !-f $state{'tls_cert'};
    push @warn, 'TLS key missing' if !$state{'tls_key'} || !-f $state{'tls_key'};
    push @warn, 'PassivePorts missing' if !$state{'passive_ports'};

    $state{'warnings'} = \@warn;
    return %state;
}

sub parse_ftpd_passwd {
    my ($path) = @_;
    my @users;
    return @users unless defined $path && -f $path;
    open(my $fh, '<', $path) or return @users;
    while (<$fh>) {
        chomp;
        my ($name, undef, $uid, $gid, undef, $home, $shell) = split(':', $_, 7);
        next unless defined $name && $name ne '';
        push @users, {
            name  => $name,
            uid   => $uid,
            gid   => $gid,
            home  => $home,
            shell => $shell,
        };
    }
    close($fh);
    return @users;
}

sub _sq {
    my ($s) = @_;
    $s //= '';
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub ftpasswd_create_user {
    my (%args) = @_;
    my $cmd = "printf %s " . _sq($args{'password'} // '') .
              " | ftpasswd --passwd --stdin " .
              "--file " . _sq($args{'file'}) . " " .
              "--name " . _sq($args{'name'}) . " " .
              "--uid " . int($args{'uid'} // 33) . " " .
              "--gid " . int($args{'gid'} // 33) . " " .
              "--home " . _sq($args{'home'}) . " " .
              "--shell " . _sq($args{'shell'} || '/bin/false');
    return &system_logged($cmd);
}

sub ftpasswd_change_password {
    my (%args) = @_;
    my $cmd = "printf %s " . _sq($args{'password'} // '') .
              " | ftpasswd --change-password --stdin " .
              "--file " . _sq($args{'file'}) . " " .
              "--name " . _sq($args{'name'});
    return &system_logged($cmd);
}

sub ftpasswd_delete_user {
    my (%args) = @_;
    my $cmd = "ftpasswd --delete-user " .
              "--file " . _sq($args{'file'}) . " " .
              "--name " . _sq($args{'name'});
    return &system_logged($cmd);
}

sub apply_secure_ftp_baseline {
    my (%args) = @_;
    my $target = $args{'target'} || '/etc/proftpd/conf.d/linuxgsm-webcore.conf';
    my $content = <<'EOF';
# LinuxGSM-WebCore managed hardening baseline
DefaultRoot ~
TLSEngine on
TLSRequired on
EOF
    open(my $fh, '>', $target) or return 1;
    print {$fh} $content;
    close($fh);
    my $rc = &system_logged("systemctl reload proftpd || systemctl restart proftpd");
    return $rc;
}

1;
