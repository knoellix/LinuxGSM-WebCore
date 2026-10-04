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

# Resolve + tail for monitor AJAX poll. Returns hashref for JSON:
#   { ok => 1, output => $text, log_file => $basename, binary => 0|1 }
#   { ok => 0, error => 'no_log'|'read_failed' }
sub server_log_monitor_poll_payload {
    my (%opts) = @_;
    my $server_dir  = $opts{'server_dir'}  // '';
    my $script_name = $opts{'script_name'} // '';
    my $source      = $opts{'source'}      // '';
    my $minecraft   = $opts{'minecraft'}   ? 1 : 0;
    my $pick        = $opts{'log_file'}    // '';
    my $max_bytes   = $opts{'max_bytes'}   // 8192;

    my @candidates = grep { -f $_ } server_log_candidates(
        server_dir  => $server_dir,
        script_name => $script_name,
        source      => $source,
        minecraft   => $minecraft,
    );
    my $log_file = server_log_resolve_pick($pick, \@candidates);
    $log_file = $candidates[0] if $log_file eq '' && @candidates;
    unless ($log_file) {
        return { ok => 0, error => 'no_log', output => '', log_file => '', binary => 0 };
    }
    my $tail = server_log_read_tail($log_file, $max_bytes);
    unless (defined $tail) {
        return {
            ok       => 0,
            error    => 'read_failed',
            output   => '',
            log_file => basename($log_file),
            binary   => 0,
        };
    }
    my $ready_hit = (defined $tail && $tail =~ /(?:\*\*\* SERVER STARTED \*\*\*\*|Done\s*\()/m) ? 1 : 0;
    my %payload = (
        ok       => 1,
        error    => '',
        output   => $tail,
        log_file => basename($log_file),
        binary   => server_log_looks_binary($tail) ? 1 : 0,
        # Hint for start-log embed: show ready banner when tail looks online/started.
        started  => $ready_hit,
        status   => $ready_hit ? 'online' : '',
    );
    # When ready marker is in the tail, hand the client a solid online badge so the
    # Startet… blink stops immediately (monitor starting grace may still be armed
    # until the start job finishes / monitor_mark_ready runs).
    if ($ready_hit && defined &server_runtime_status_badge_html) {
        $payload{runtime_status} = 'online';
        $payload{runtime_html}   = server_runtime_status_badge_html('online');
        $payload{starting}       = 0;
    }
    return \%payload;
}

# Percent-encode path for filemin query strings (same rules as config editor).
sub server_log_filemin_path_urlencode {
    my ($s) = @_;
    $s //= '';
    $s =~ s/([^A-Za-z0-9\-_.~\/])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}

sub server_log_monitor_resolve_auto_refresh {
    my ($in_val) = @_;
    return 0 if defined $in_val && ($in_val // '') ne '1';
    return 1;
}

# Resolve log candidates + pick for monitor GET / render.
sub server_log_monitor_prepare {
    my (%opts) = @_;
    my $server_dir  = $opts{server_dir}  // '';
    my $script_name = $opts{script_name} // '';
    my $source      = $opts{source}      // '';
    my $minecraft   = $opts{minecraft}   ? 1 : 0;
    my $pick        = $opts{log_file_pick} // $opts{log_file} // '';

    my @log_candidates = grep { -f $_ } server_log_candidates(
        server_dir  => $server_dir,
        script_name => $script_name,
        source      => $source,
        minecraft   => $minecraft,
    );
    my $log_file = server_log_resolve_pick($pick, \@log_candidates);
    $log_file = $log_candidates[0] if $log_file eq '' && @log_candidates;
    my $log_base = $log_file ne '' ? basename($log_file) : '';

    return {
        log_candidates => \@log_candidates,
        log_file       => $log_file,
        log_base       => $log_base,
        auto_refresh   => server_log_monitor_resolve_auto_refresh($opts{auto_refresh}),
    };
}

sub server_log_monitor_text {
    my ($keys, $default) = @_;
    our %text;
    if (ref($keys) eq 'ARRAY') {
        for my $k (@$keys) {
            return $text{$k} if defined $text{$k} && $text{$k} =~ /\S/;
        }
    } elsif (defined $keys && $keys ne '' && defined $text{$keys} && $text{$keys} =~ /\S/) {
        return $text{$keys};
    }
    return $default // '';
}

sub server_log_monitor_text_keys_manage {
    return {
        title          => ['manage_monitor_title'],
        log_pick_label => ['manage_monitor_log_pick_label'],
        auto_label     => ['manage_monitor_auto_label'],
        refresh_btn    => ['manage_monitor_refresh_btn'],
        no_log         => ['manage_monitor_no_log'],
        shown_file     => ['manage_monitor_shown_file'],
        log_edit       => ['manage_monitor_log_edit'],
        log_download   => ['manage_monitor_log_download'],
        log_folder     => ['manage_monitor_log_folder'],
        filemin_hint   => ['manage_monitor_filemin_hint'],
        log_gzip_note  => ['manage_monitor_log_gzip_note'],
        log_binary_warn => ['manage_monitor_log_binary_warn'],
    };
}

sub server_log_monitor_text_keys_mods {
    return {
        title          => ['mc_mods_page_monitor_title'],
        log_pick_label => ['mc_mods_page_monitor_log_pick_label', 'manage_monitor_log_pick_label'],
        auto_label     => ['mc_mods_page_monitor_auto_label', 'manage_monitor_auto_label'],
        refresh_btn    => ['mc_mods_page_monitor_refresh_btn', 'manage_monitor_refresh_btn'],
        no_log         => ['mc_mods_page_monitor_no_log', 'manage_monitor_no_log'],
        shown_file     => ['mc_mods_page_monitor_shown_file', 'manage_monitor_shown_file'],
        log_edit       => ['mc_mods_page_monitor_log_edit', 'manage_monitor_log_edit'],
        log_download   => ['mc_mods_page_monitor_log_download', 'manage_monitor_log_download'],
        log_folder     => ['mc_mods_page_monitor_log_folder', 'manage_monitor_log_folder'],
        filemin_hint   => ['mc_mods_page_monitor_filemin_hint', 'manage_monitor_filemin_hint'],
        log_gzip_note  => ['mc_mods_page_monitor_log_gzip_note', 'manage_monitor_log_gzip_note'],
        log_binary_warn => ['mc_mods_page_monitor_log_binary_warn', 'manage_monitor_log_binary_warn'],
    };
}

# Shared monitor page body (toolbar + log tail + poll JS). Caller prints header/footer.
sub server_log_render_monitor_page {
    my (%opts) = @_;
    my $form_cgi      = $opts{form_cgi}      // 'manage.cgi';
    my $instance_id   = $opts{instance_id}   // '';
    my $poll_url_base = $opts{poll_url_base} // '';
    my $text_keys     = $opts{text_keys}     // server_log_monitor_text_keys_manage();
    my $back_forms    = $opts{back_forms}    // [];

    my $ctx = server_log_monitor_prepare(%opts);
    my $log_candidates = $ctx->{log_candidates};
    my $log_file       = $ctx->{log_file};
    my $log_base       = $ctx->{log_base};
    my $auto_refresh   = $ctx->{auto_refresh};

    my $t = sub {
        my ($suffix, $default) = @_;
        return server_log_monitor_text($text_keys->{$suffix}, $default);
    };

    my $safe_id = &html_escape($instance_id);
    print "<h3>" . &html_escape($t->('title', 'Server log (live)')) . "</h3>\n";
    print &job_log_view_toolbar_open();

    print &ui_form_start($form_cgi, 'get', undef, 'id="monitor_refresh_form"');
    print &ui_hidden('instance_id', $safe_id);
    print &ui_hidden('action', 'monitor');
    print &ui_hidden('xnavigation', '1');
    if (@$log_candidates > 1) {
        my (%seen_bn, @select_opts);
        for my $p (@$log_candidates) {
            my $bn = basename($p);
            next if $seen_bn{$bn}++;
            my $label = $bn;
            $label .= ' [gz]' if $bn =~ /\.gz$/i;
            push @select_opts, [ $bn, $label ];
        }
        print &html_escape($t->('log_pick_label', 'Log file')) . ': ';
        print &ui_select('log_file', $log_base, \@select_opts);
        print " ";
    } elsif ($log_base ne '') {
        print &ui_hidden('log_file', &html_escape($log_base));
    }
    print '<label style="margin-right:8px"><input type="checkbox" name="auto_refresh"'
        . ' id="monitor_auto_refresh" value="1"'
        . ($auto_refresh ? ' checked' : '') . '> '
        . &html_escape($t->('auto_label', 'Auto refresh (3s)')) . '</label> ';
    print &ui_submit($t->('refresh_btn', 'Refresh'), undef, undef, undef, 'btn-default');
    print &ui_form_end();

    for my $bf (@$back_forms) {
        my $cgi = $bf->{cgi} // $form_cgi;
        print &ui_form_start($cgi, 'get');
        print &ui_hidden('instance_id', $safe_id);
        print &ui_hidden('xnavigation', '1');
        if (defined $bf->{action} && $bf->{action} ne '') {
            print &ui_hidden('action', $bf->{action});
        }
        my $label = server_log_monitor_text($bf->{label_keys}, $bf->{default} // 'Back');
        print &ui_submit($label, undef, undef, undef, $bf->{btn_class} // 'btn-default');
        print &ui_form_end();
    }

    print &job_log_view_toolbar_close();

    my $no_log_msg = $t->('no_log', 'No log file found.');
    unless ($log_file) {
        print "<p>" . &html_escape($no_log_msg) . "</p>\n";
        return;
    }

    my $log_dir  = dirname($log_file);
    my $enc_dir  = server_log_filemin_path_urlencode($log_dir);
    my $enc_file = server_log_filemin_path_urlencode($log_base);
    my $href_edit = "/filemin/edit_file.cgi?path=$enc_dir&file=$enc_file";
    my $href_dl   = "/filemin/download.cgi?path=$enc_dir&file=$enc_file";
    my $href_dir  = "/filemin/?path=$enc_dir";
    my $hint = $t->('filemin_hint',
        'Open folder lists the log directory; use Download for very large files.');
    print "<p><small>" . &html_escape($t->('shown_file', 'Log file'))
        . ": <code>" . &html_escape($log_file) . "</code><br>\n";
    if ($log_base !~ /\.gz$/i) {
        print "<a href=\"" . &html_escape($href_edit)
            . "\" target=\"_blank\" rel=\"noopener noreferrer\">"
            . &html_escape($t->('log_edit', 'View in file manager'))
            . "</a> - ";
    }
    print "<a href=\"" . &html_escape($href_dl)
        . "\" target=\"_blank\" rel=\"noopener noreferrer\">"
        . &html_escape($t->('log_download', 'Download full log'))
        . "</a> - ";
    print "<a href=\"" . &html_escape($href_dir)
        . "\" target=\"_blank\" rel=\"noopener noreferrer\">"
        . &html_escape($t->('log_folder', 'Open log folder'))
        . "</a><br>\n";
    print &html_escape($hint) . "</small></p>\n";
    if ($log_base =~ /\.gz$/i) {
        print "<p><small>" . &html_escape($t->('log_gzip_note',
            'This file is gzip-compressed and is shown decompressed here.'))
            . "</small></p>\n";
    }

    my $tail = server_log_read_tail($log_file, 8192);
    unless (defined $tail) {
        print "<p>" . &html_escape($no_log_msg) . "</p>\n";
        return;
    }
    if (server_log_looks_binary($tail)) {
        print "<p>" . &html_escape($t->('log_binary_warn', 'File looks binary.'))
            . "</p>\n";
    }
    print &job_log_view_block($tail, id => 'monitor_log', live => 1);
    return unless $poll_url_base ne '';

    print &server_monitor_poll_client_js(
        poll_url_base  => $poll_url_base,
        out_id         => 'monitor_log',
        form_id        => 'monitor_refresh_form',
        checkbox_id    => 'monitor_auto_refresh',
        log_file       => $log_base,
        wait_msg       => $no_log_msg,
        poll_fail_msg  => $no_log_msg,
        poll_interval  => 3000,
        auto_start     => $auto_refresh,
    );
}

# Module config: optional embedded start-log after Start/Restart (default off).
sub server_log_start_log_enabled {
    our %config;
    return 0 unless defined &module_config_bool;
    return &module_config_bool($config{'manage_show_start_log'});
}

# True when Integrations default is on, or the per-click Dev-Start checkbox (dev_start=1).
sub server_log_start_log_wanted {
    my ($in_href) = @_;
    $in_href = \%main::in unless ref($in_href) eq 'HASH';
    return 1 if server_log_start_log_enabled();
    my $dev = $in_href->{'dev_start'} // '';
    return 1 if $dev eq '1' || lc($dev) eq 'yes' || lc($dev) eq 'on';
    return 0;
}

sub server_log_start_log_flash_name {
    my ($instance_id) = @_;
    $instance_id //= '';
    $instance_id =~ s/[^a-zA-Z0-9_-]//g;
    return '' if $instance_id eq '';
    return "start_log_$instance_id";
}

sub server_log_start_log_flash_mark {
    my ($instance_id) = @_;
    my $name = server_log_start_log_flash_name($instance_id);
    return 0 unless $name ne '' && defined &module_config_flash_mark;
    return &module_config_flash_mark($name);
}

# True only when URL has start_log=1 and a fresh flash was consumed.
sub server_log_start_log_should_show {
    my ($in_href, $instance_id) = @_;
    return 0 unless ref($in_href) eq 'HASH';
    return 0 unless (($in_href->{'start_log'} // '') eq '1');
    my $name = server_log_start_log_flash_name($instance_id);
    return 0 unless $name ne '' && defined &module_config_flash_consume;
    return &module_config_flash_consume($name);
}

# Compact embedded console panel for Start/Restart (poll_monitor JSON, ~3s).
# Returns HTML string; caller prints it. Does not force job_live.cgi.
sub server_log_embed_html {
    my (%opts) = @_;
    our %text;
    my $poll_url_base = $opts{poll_url_base} // '';
    my $out_id = $opts{out_id} // 'start_log_panel';
    $out_id =~ s/[^a-zA-Z0-9_-]//g;
    $out_id = 'start_log_panel' if $out_id eq '';

    my $title = $opts{title};
    if (!defined $title || $title eq '') {
        $title = (defined $text{'start_log_panel_title'} && $text{'start_log_panel_title'} =~ /\S/)
            ? $text{'start_log_panel_title'}
            : 'Start-Log';
    }
    my $ready_banner = $opts{ready_banner};
    if (!defined $ready_banner || $ready_banner eq '') {
        $ready_banner = (defined $text{'start_log_ready_banner'} && $text{'start_log_ready_banner'} =~ /\S/)
            ? $text{'start_log_ready_banner'}
            : 'Server started';
    }

    my $initial = $opts{initial_text} // '';
    if ($initial eq '' && ($opts{server_dir} // '') ne '') {
        my $payload = server_log_monitor_poll_payload(
            server_dir  => $opts{server_dir},
            script_name => $opts{script_name} // '',
            source      => $opts{source} // '',
            minecraft   => $opts{minecraft} ? 1 : 0,
            log_file    => $opts{log_file} // '',
        );
        $initial = $payload->{output} // '' if ref($payload) eq 'HASH' && $payload->{ok};
    }

    my $wait_msg = $opts{wait_msg}
        // server_log_monitor_text(['manage_monitor_no_log'], 'No log file found.');

    my $html = "<div class=\"lgsm-start-log\" id=\"start_log_wrap\">\n";
    $html .= "<h3>" . &html_escape($title) . "</h3>\n";
    $html .= "<div id=\"start_log_ready_banner\" class=\"alert alert-success\" style=\"display:none\">"
        . &html_escape($ready_banner) . "</div>\n";
    if (defined &job_log_view_page_css) {
        $html .= &job_log_view_page_css();
    }
    if (defined &job_log_view_block) {
        $html .= &job_log_view_block($initial, id => $out_id, live => 1);
    } else {
        $html .= "<pre id=\"" . &html_escape($out_id) . "\">"
            . &html_escape($initial) . "</pre>\n";
    }
    if ($poll_url_base ne '' && defined &server_monitor_poll_client_js) {
        $html .= &server_monitor_poll_client_js(
            poll_url_base   => $poll_url_base,
            out_id          => $out_id,
            form_id         => '',
            checkbox_id     => '',
            log_file        => $opts{log_file} // '',
            wait_msg        => $wait_msg,
            poll_fail_msg   => $wait_msg,
            poll_interval   => $opts{poll_interval} // 3000,
            auto_start      => 1,
            ready_banner_id => 'start_log_ready_banner',
        );
    }
    $html .= "</div>\n";
    return $html;
}

1;
