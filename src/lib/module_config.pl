# LinuxGSM-WebCore — reliable module config load/save (Webmin namespace-safe)
use strict;
use warnings;

our (%config, $config_directory, $module_name,
     $module_config_directory, $module_config_file, $module_root, $module_root_directory);

# Resolve /etc/webmin/<module>/config regardless of package vs main:: globals.
sub module_config_file_path {
    if (defined $module_config_file && $module_config_file ne '') {
        return $module_config_file;
    }
    if (defined $main::module_config_file && $main::module_config_file ne '') {
        return $main::module_config_file;
    }
    my $dir = module_config_dir_path();
    return $dir ? "$dir/config" : '';
}

sub module_config_dir_path {
    if (defined $module_config_directory && $module_config_directory ne '') {
        return $module_config_directory;
    }
    if (defined $main::module_config_directory && $main::module_config_directory ne '') {
        return $main::module_config_directory;
    }
    my $base = defined $config_directory && $config_directory ne ''
        ? $config_directory : ($main::config_directory // '');
    return '' unless $base ne '';
    my $mn = $module_name // $main::module_name // '';
    if ($mn && $base !~ /\Q$mn\E/) {
        return "$base/$mn";
    }
    return $base;
}

# Plain key=value reader for background workers (no Webmin web-lib.pl).
sub _module_config_read_file_plain {
    my ($file, $hash_ref) = @_;
    return unless defined $file && -r $file && ref($hash_ref) eq 'HASH';
    open(my $fh, '<', $file) or return;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/ || $line !~ /=/;
        my ($k, $v) = split(/=/, $line, 2);
        next unless defined $k;
        $v //= '';
        $hash_ref->{$k} = $v;
    }
    close($fh);
}

sub module_config_webmin_base {
    my $cfg = $ENV{'WEBMIN_CONFIG'} // '';
    if ($cfg && -f "$cfg/miniserv.conf") {
        return $cfg;
    }
    for my $c ('/etc/webmin', '/usr/local/etc/webmin') {
        return $c if -f "$c/miniserv.conf";
    }
    return '/etc/webmin';
}

sub module_config_module_name_from_root {
    my ($root) = @_;
    return 'linuxgsm-webcore' unless defined $root && $root ne '';
    if (-r "$root/module.info") {
        if (open(my $fh, '<', "$root/module.info")) {
            while (my $line = <$fh>) {
                if ($line =~ /^name=(.+)/) {
                    my $n = $1;
                    $n =~ s/\s+//g;
                    close($fh);
                    return $n if $n ne '';
                }
            }
            close($fh);
        }
    }
    $root =~ s{/$}{};
    return $1 if $root =~ m{/([^/]+)$};
    return 'linuxgsm-webcore';
}

# Bootstrap module config for background Perl workers (no Webmin CGI context).
sub module_config_bootstrap_standalone {
    my ($module_root) = @_;
    $module_root //= $ENV{'MODULE_ROOT'} // '';
    return 0 unless $module_root && -d $module_root;

    unless (defined &read_file) {
        no warnings 'redefine';
        *read_file = \&_module_config_read_file_plain;
    }

    $module_root_directory = $module_root unless defined $module_root_directory && $module_root_directory ne '';
    $module_root = $module_root_directory unless defined $module_root && $module_root ne '';

    $module_name = module_config_module_name_from_root($module_root)
        unless defined $module_name && $module_name ne '';

    unless (defined $module_config_directory && $module_config_directory ne '') {
        my $base = module_config_webmin_base();
        $module_config_directory = "$base/$module_name";
    }
    unless (defined $config_directory && $config_directory ne '') {
        $config_directory = $module_config_directory;
    }
    $module_config_file = module_config_file_path()
        unless defined $module_config_file && $module_config_file ne '';

    module_config_sync_in();
    module_config_apply_job_secrets();
    return 1;
}

# Path to per-job integration secrets (written by CGI at dispatch; readable by game user).
sub module_config_job_secrets_path {
    my $job_dir = $ENV{'WEBCORE_JOB_DIR'} // '';
    return '' unless $job_dir =~ m{/jobs/[0-9a-f]{16}\z};
    return "$job_dir/.worker_secrets";
}

# Overlay job-local secrets onto %config (game-user workers cannot read /etc/webmin/.../config).
sub module_config_apply_job_secrets {
    my $path = module_config_job_secrets_path();
    return 0 unless $path && -r $path;
    my %job;
    _module_config_read_file_plain($path, \%job);
    for my $k (keys %job) {
        next unless $k =~ /^[a-z][a-z0-9_]*$/;
        next unless defined $job{$k} && $job{$k} =~ /\S/;
        $config{$k} = $job{$k};
    }
    %main::config = %config if %config;
    return 1;
}

# Write integration keys into job dir for game-user workers (0600, owned by unix_user).
sub write_job_worker_secrets {
    my ($job_dir, $unix_user, $keys_ref) = @_;
    return 0 unless defined $job_dir && -d $job_dir && ref($keys_ref) eq 'HASH';
    my @lines;
    for my $k (sort keys %$keys_ref) {
        next unless $k =~ /^[a-z][a-z0-9_]*$/;
        my $v = $keys_ref->{$k};
        next unless defined $v && $v =~ /\S/;
        $v =~ s/[\t\n\r]//g;
        push @lines, "$k=$v";
    }
    return 0 unless @lines;
    my $path = "$job_dir/.worker_secrets";
    open(my $fh, '>', $path) or return 0;
    print $fh join("\n", @lines), "\n";
    close($fh);
    chmod 0600, $path;
    if (defined $unix_user && $unix_user ne '') {
        my @pw = getpwnam($unix_user);
        if (@pw) {
            chown($pw[2], $pw[3], $path);
        }
    }
    return 1;
}

# Load config from disk into package %config (and mirror to main::config).
sub module_config_sync_in {
    if (!%config && %main::config) {
        %config = %main::config;
    }

    my $path = module_config_file_path();
    if ($path && -r $path) {
        my %file;
        eval { &read_file($path, \%file) };
        if (%file) {
            for my $k (keys %file) {
                $config{$k} = $file{$k};
            }
        }
    } elsif (!%config && %main::config) {
        %config = %main::config;
    }

    # Seed missing keys from shipped template (does not overwrite stored values).
    my $root = $module_root // $module_root_directory // $main::module_root_directory // '';
    if ($root && -r "$root/config") {
        my %defaults;
        eval { &read_file("$root/config", \%defaults) };
        for my $k (keys %defaults) {
            $config{$k} = $defaults{$k} unless exists $config{$k};
        }
    }

    %main::config = %config if %config;
    return \%config;
}

# Parse Webmin ui_radio / checkbox POST values ("0" is truthy in Perl — never use bare if).
sub module_config_bool {
    my ($v) = @_;
    return 1 if defined $v && $v =~ /^[1yYtT]/;
    return 0;
}

# Persist package %config to the module config file.
# Returns 1 only after write + read-back verification succeed.
sub module_config_save {
    my $path = module_config_file_path();
    return 0 unless $path;

    my $dir = $path;
    $dir =~ s{/[^/]+$}{};
    &make_dir($dir, 0700) if $dir && !-d $dir;

    my $write_ok = 0;
    if (defined &lock_file) {
        &lock_file($path);
    }
    eval { &write_file($path, \%config); $write_ok = 1; };
    if (defined &unlock_file) {
        &unlock_file($path);
    }
    return 0 unless $write_ok && -f $path;

    my %check;
    eval { &read_file($path, \%check) };
    return 0 unless %check;

    for my $k (keys %config) {
        my $exp = defined $config{$k} ? $config{$k} : '';
        my $got = defined $check{$k} ? $check{$k} : '';
        return 0 if "$exp" ne "$got";
    }

    %main::config = %config;
    return 1;
}

# One-time flash marker: success banner only if mark was set during save.
sub module_config_flash_path {
    my ($name) = @_;
    $name //= 'save';
    $name =~ s/[^a-zA-Z0-9_-]//g;
    return '' unless $name ne '';
    my $dir = module_config_dir_path();
    return $dir ? "$dir/.flash_$name" : '';
}

sub module_config_flash_mark {
    my ($name) = @_;
    my $f = module_config_flash_path($name);
    return 0 unless $f;
    open(my $fh, '>', $f) or return 0;
    print $fh time(), "\n";
    close($fh);
    chmod 0600, $f if -f $f;
    return 1;
}

sub module_config_flash_consume {
    my ($name) = @_;
    my $f = module_config_flash_path($name);
    return 0 unless $f && -f $f;
    open(my $fh, '<', $f) or return 0;
    my $line = <$fh>;
    close($fh);
    unlink($f);
    $line =~ s/\s+//g;
    return 0 unless defined $line && $line =~ /^\d+$/;
    return (time() - $line) <= 120 ? 1 : 0;
}

sub module_config_flash_mark_ok    { return module_config_flash_mark('save'); }
sub module_config_flash_consume_ok { return module_config_flash_consume('save'); }

1;
