# Server / game log discovery and reading for manage + mods monitor.
# Minecraft rotates dated logs to *.log.gz — Filemin shows those as binary;
# we decompress via gzip -dc for the in-module viewer.

use strict;
use warnings;
use File::Basename qw(basename dirname);

# Absolute paths to try (order = preference). Deduped.
# When $minecraft is true, Minecraft serverfiles/logs come first.
sub server_log_candidates {
    my (%opts) = @_;
    my $server_dir  = $opts{server_dir}  // '';
    my $script_name = $opts{script_name} // '';
    my $source      = $opts{source}      // '';
    my $minecraft   = $opts{minecraft} ? 1 : 0;
    return () unless $server_dir =~ /\S/;

    $script_name =~ s/[^a-zA-Z0-9_-]//g;
    my @raw;

    if ($minecraft) {
        push @raw, server_log_minecraft_paths($server_dir);
    }

    if ($source eq 'steamcmd') {
        my $rel_live = '';
        if (defined &get_game_live_log_path && $script_name ne '') {
            $rel_live = &get_game_live_log_path($script_name) // '';
        }
        if ($rel_live ne '') {
            (my $abs_live = "$server_dir/$rel_live") =~ s{//+}{/}g;
            push @raw, $abs_live;
        }
        my $logs_dir = "$server_dir/serverfiles/R5/Saved/Logs";
        my $newest_ue = '';
        if (-d $logs_dir && opendir(my $dh, $logs_dir)) {
            my @logs = grep { /\.log$/i && !/\.gz$/i } readdir($dh);
            closedir($dh);
            if (@logs) {
                my @sorted = sort { (stat("$logs_dir/$b"))[9] <=> (stat("$logs_dir/$a"))[9] }
                             map  { "$logs_dir/$_" } @logs;
                $newest_ue = $sorted[0];
            }
        }
        push @raw,
            "$server_dir/server.log",
            "$server_dir/windrose-debug.log",
            "$server_dir/serverfiles/server.log",
            "$server_dir/serverfiles/R5/Saved/Logs/R5.log",
            "$server_dir/serverfiles/R5/Saved/Logs/WindroseServer.log",
            "$server_dir/serverfiles/R5/Saved/Logs/Windrose.log";
        push @raw, $newest_ue if $newest_ue;
    }

    if ($script_name ne '') {
        push @raw,
            "$server_dir/log/console/${script_name}-console.log",
            "$server_dir/log/script/${script_name}.log",
            "$server_dir/log/${script_name}.log";
    }

    my %seen;
    return grep { defined $_ && $_ ne '' && !$seen{$_}++ } @raw;
}

# Prefer latest.log / debug.log, then other plain .log, then .log.gz by mtime.
sub server_log_minecraft_paths {
    my ($server_dir) = @_;
    my @dirs = (
        "$server_dir/serverfiles/logs",
        "$server_dir/logs",
    );
    my @out;
    for my $dir (@dirs) {
        next unless -d $dir;
        my $list = server_log_list_dir($dir);
        push @out, map { $_->{path} } @$list;
    }
    return @out;
}

# Returns arrayref of { name, path, mtime, gzip }.
sub server_log_list_dir {
    my ($dir) = @_;
    return [] unless defined $dir && -d $dir;
    opendir(my $dh, $dir) or return [];
    my @names = grep {
        $_ ne '.' && $_ ne '..'
        && (/\.log$/i || /\.log\.gz$/i)
        && !/^\./
    } readdir($dh);
    closedir($dh);

    my @entries;
    for my $name (@names) {
        next if $name =~ m{[\\/]};
        my $path = "$dir/$name";
        next unless -f $path;
        my $mtime = (stat($path))[9] // 0;
        push @entries, {
            name  => $name,
            path  => $path,
            mtime => $mtime,
            gzip  => ($name =~ /\.gz$/i) ? 1 : 0,
        };
    }

    my %prio = (
        'latest.log' => 0,
        'debug.log'  => 1,
    );
    @entries = sort {
        my $pa = exists $prio{lc $a->{name}} ? $prio{lc $a->{name}} : 100;
        my $pb = exists $prio{lc $b->{name}} ? $prio{lc $b->{name}} : 100;
        return $pa <=> $pb if $pa != $pb;
        return $b->{mtime} <=> $a->{mtime};
    } @entries;
    return \@entries;
}

# Sanitize basename pick; must resolve to an allowed absolute path.
sub server_log_resolve_pick {
    my ($pick, $allowed_paths) = @_;
    $pick //= '';
    $pick =~ s{.*[/\\]}{};
    $pick =~ s/[^a-zA-Z0-9._+-]//g;
    return '' if $pick eq '';
    my @allowed = @{$allowed_paths // []};
    for my $path (@allowed) {
        next unless defined $path && -f $path;
        return $path if basename($path) eq $pick;
    }
    return '';
}

# Read full text; decompress .gz via gzip -dc (list-form open, no shell).
# Returns undef on open/read failure.
sub server_log_read_text {
    my ($path) = @_;
    return undef unless defined $path && $path ne '' && -f $path;

    my $fh;
    if ($path =~ /\.gz$/i) {
        open($fh, '-|', 'gzip', '-dc', '--', $path) or return undef;
    } else {
        open($fh, '<', $path) or return undef;
    }
    binmode($fh);
    my $content = do { local $/; <$fh> };
    close($fh);
    return defined $content ? $content : '';
}

# Last $max_bytes of decoded text (default 8192).
sub server_log_read_tail {
    my ($path, $max_bytes) = @_;
    $max_bytes = 8192 unless defined $max_bytes && $max_bytes > 0;
    my $content = server_log_read_text($path);
    return undef unless defined $content;
    my $len = length($content);
    return $len > $max_bytes ? substr($content, $len - $max_bytes) : $content;
}

# True if buffer looks like binary (nul / high ratio of non-text).
sub server_log_looks_binary {
    my ($buf) = @_;
    return 0 unless defined $buf && length($buf);
    my $sample = substr($buf, 0, 512);
    return 1 if index($sample, "\0") >= 0;
    my $bad = ($sample =~ tr/\x00-\x08\x0b\x0c\x0e-\x1f//);
    return 1 if length($sample) > 32 && ($bad / length($sample)) > 0.15;
    return 0;
}

1;
