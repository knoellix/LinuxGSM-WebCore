#!/usr/bin/perl
# -------------------------------------------------------------------------
# LinuxGSM Webcore - Webmin Module
# Copyright (C) 2026 Christian Möllmann knoelliX 128321164+knoellix@users.noreply.github.com
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License.
# -------------------------------------------------------------------------
use strict;
use warnings;
use File::Basename qw(dirname basename);
use File::Find ();

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/instance.pl';
require './lib/firewall.pl';
require './lib/acl.pl';
require './lib/games_meta.pl';
require './lib/games.pl';
require './lib/config_editor.pl';
require './lib/ftp_proftpd.pl';
require './lib/steam.pl';
require './lib/jobs.pl';
require './lib/logging.pl';
require './lib/error_hints.pl';
require './lib/provision.pl';
require './lib/monitor.pl';
require './lib/schedule.pl';
require './lib/query.pl';
require './lib/mc_profile.pl';
require './lib/mc_loader.pl';
require './lib/mc_mods.pl';
require './lib/mc_modpack.pl';
require './lib/module_config.pl';
require './lib/instance_profile.pl';
require './lib/live_log.pl';
require './lib/server_log.pl';

our ($module_config_directory, $module_config_file);
&module_config_sync_in();

our (%text, %config, %in, %gconfig);
our ($module_root, $module_root_directory, $config_directory, $module_name);
our $current_lang;
$module_root ||= $module_root_directory;
$module_root ||= do { (my $d = __FILE__) =~ s{/[^/]+$}{}; $d };
$main::gconfig{'charset'} = 'utf-8';
if (($ENV{REQUEST_METHOD} // '') eq 'POST'
    && ($ENV{CONTENT_TYPE} // '') =~ /multipart\/form-data/i) {
    &ReadParseMime(\%in);
} else {
    &ReadParse(\%in);
}

# Percent-encode path for filemin query strings (same rules as config editor).
sub _filemin_path_urlencode {
    my ($s) = @_;
    $s =~ s/([^A-Za-z0-9\-_.~\/])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}

sub _write_file_as_user {
    my ($path, $content, $unix_user, %opts) = @_;
    (my $safe_path = $path) =~ s/'/'\\''/g;
    my $cmd = "cat > '$safe_path'";
    if ($opts{'mkdir'}) {
        (my $safe_dir = $opts{'mkdir'}) =~ s/'/'\\''/g;
        $cmd = "mkdir -p '$safe_dir' && $cmd";
    }
    open(my $pipe, '|-', 'su', '-s', '/bin/bash', '-c', $cmd, $unix_user)
        or &error("Cannot write $path as $unix_user: $!");
    binmode($pipe, ':raw');
    print $pipe (defined $content ? $content : '');
    close($pipe) or &error("Cannot write $path as $unix_user (pipe error): $!");
}

# Launch steamcmd control as game-user background worker (E8).
sub _manage_steamcmd_worker_cmd {
    my ($action, $job_dir, $unix_user, $server_dir, %opts) = @_;
    my %env;
    $env{STEAMCMD_PATH} = $opts{'steamcmd_path'} if defined $opts{'steamcmd_path'} && $opts{'steamcmd_path'} ne '';
    return &user_worker_launch_cmd(
        unix_user   => $unix_user,
        module_root => $module_root,
        worker      => "$module_root/scripts/steamcmd_control_user.sh",
        args        => [ $action, $job_dir, $unix_user, $server_dir ],
        env         => \%env,
    );
}

# HTML for monitor/schedule "last run" table row (E5).
sub _manage_last_run_row_html {
    my ($epoch, $text_template, $job_id, $instance_id) = @_;
    return '' unless defined $epoch && $epoch =~ /^\d+$/ && $epoch > 0;
    my $lr_ts = &monitor_format_restart_time($epoch);
    $lr_ts = '—' unless defined $lr_ts && $lr_ts ne '';
    my $lr_html = &html_escape(&text($text_template, $lr_ts));
    $job_id = '' unless defined $job_id;
    $job_id =~ s/[^0-9a-f]//g;
    if (length($job_id) == 16 && defined $instance_id && $instance_id =~ /\S/) {
        my $job_url = "job_live.cgi?instance_id=" . &html_escape($instance_id)
            . "&job=" . &html_escape($job_id) . "&xnavigation=1";
        $lr_html .= ' &mdash; <a href="' . &html_escape($job_url) . '">'
            . &html_escape($text{'monitor_job_link'}) . '</a>';
    }
    return $lr_html;
}

# Dispatch LGSM game-config bootstrap (start → sleep → stop) as background job (E4).
sub _manage_dispatch_game_config_bootstrap {
    my ($instance_id, $inst, $unix_user, %opts) = @_;
    my (undef, $script_name, $server_dir) = _parse_script_info($inst);
    $script_name = _manage_executable_script_name($server_dir, $script_name);
    my $job_id = &_manage_launch_background_job(
        $instance_id, 'init_game_config', $unix_user,
        sub {
            my ($jid) = @_;
            my $job_dir = _shell_safe_job_dir($jid);
            return &user_worker_launch_cmd(
                unix_user   => $unix_user,
                module_root => $module_root,
                worker      => "$module_root/scripts/game_action_user.sh",
                args        => [ $job_dir, $unix_user, $server_dir, $script_name, 'bootstrap_game_config' ],
            );
        },
    );
    $job_id or _manage_job_launch_failed();
    my %launch_opts = (action => 'init_game_config');
    if ($opts{'config_view'}) {
        $launch_opts{'notice_action'} = 'init_game_config';
    }
    &_manage_redirect_after_job_launch($job_id, $instance_id, %launch_opts);
}

sub _parse_script_info {
    my ($inst) = @_;
    my $script_path = $inst->{'script'} // '';
    my ($script_name) = $script_path =~ m{/([^/]+)$};
    $script_name //= '';
    (my $server_dir = $script_path) =~ s{/[^/]+$}{};
    $script_name =~ s/[^a-zA-Z0-9_-]//g;
    return ($script_path, $script_name, $server_dir);
}

# LGSM CSV shortnames (pw) differ from on-disk script names (pwserver). Prefer the
# executable that actually exists under SERVER_DIR.
sub _manage_executable_script_name {
    my ($server_dir, $script_name) = @_;
    return '' unless defined $server_dir && $server_dir ne '' && $script_name;
    return $script_name if -x "$server_dir/$script_name";
    if (defined &resolve_lgsm_game_script) {
        my $resolved = &resolve_lgsm_game_script($script_name);
        return $resolved if $resolved ne $script_name && -x "$server_dir/$resolved";
    }
    return $script_name;
}

sub _manage_read_mc_profile {
    my ($inst) = @_;
    my (undef, undef, $server_dir) = _parse_script_info($inst);
    return (undef, $server_dir) unless defined $server_dir && $server_dir ne '';
    return (undef, $server_dir) unless -d $server_dir;
    my $profile = &read_mc_profile($server_dir);
    return ($profile, $server_dir);
}

sub _manage_lgsm_script_ready {
    my ($inst) = @_;
    my (undef, $script_name, $server_dir) = _parse_script_info($inst);
    return 0 unless $script_name && defined $server_dir && $server_dir ne '';
    $script_name = _manage_executable_script_name($server_dir, $script_name);
    return -x "$server_dir/$script_name" ? 1 : 0;
}

# Derive setup phase from filesystem (works even when poll_job missed next_status).
sub _manage_infer_setup_status_from_disk {
    my ($inst, $profile, $server_dir) = @_;
    if (ref($profile) eq 'HASH') {
        return &mc_infer_setup_status(
            _manage_lgsm_script_ready($inst),
            &mc_pending_setup_steps($profile, $server_dir),
        );
    }
    return _manage_lgsm_script_ready($inst) ? 'lgsm_ready' : 'fresh';
}

sub _manage_infer_setup_status_from_jobs {
    my ($instance_id) = @_;
    my @jobs = &get_instance_jobs($instance_id);
    my %ok = map { ($_->{action} // '') => 1 }
        grep { ($_->{status} // '') eq 'ok' } @jobs;
    return 'installed' if $ok{'install_game'} || $ok{'mc_loader_setup'};
    return 'mc_ready'   if $ok{'mc_java_setup'};
    return 'lgsm_ready' if $ok{'setup_lgsm'};
    return undef;
}

# Fix registry status from on-disk MC setup progress (upgrade and downgrade).
# Disk/pending steps are authoritative: a historical ok mc_loader_setup job must
# not keep status=installed after serverfiles were wiped (reinstall / failed loader).
sub _manage_reconcile_mc_instance_status {
    my ($inst, $instance_id) = @_;
    my ($profile, $server_dir) = _manage_read_mc_profile($inst);
    return $inst unless ref($profile) eq 'HASH';

    # Heal stale java_major (e.g. 21 on MC 26.x) so pending setup offers Java upgrade.
    if (&mc_profile_java_needs_sync($profile)) {
        my $synced = &mc_profile_sync_java_fields($profile);
        my $unix = $inst->{'user'} // '';
        if ($unix && $server_dir && &write_mc_profile($server_dir, $unix, $synced)) {
            $profile = $synced;
        }
    }

    my $from_disk = _manage_infer_setup_status_from_disk($inst, $profile, $server_dir);
    return $inst unless defined $from_disk && $from_disk ne '';

    my $istatus = $inst->{'instance_status'} // 'installed';
    if ($from_disk ne $istatus) {
        &set_instance_status($instance_id, $from_disk);
        $inst->{'instance_status'} = $from_disk;
    }
    return $inst;
}

sub _manage_next_status_for_action {
    return &job_next_instance_status($_[0]);
}

# Redirect to live log if a background job is already running (never returns).
sub _manage_redirect_if_job_running {
    my ($instance_id, $action) = @_;
    my $job_id = &find_running_job_for_instance($instance_id, $action);
    $job_id ||= &find_running_job_for_instance($instance_id);
    return 0 unless $job_id;
    my $meta = &get_job_meta($job_id);
    my $job_action = $meta->{'action'} // $action // '';
    my $next = _manage_next_status_for_action($job_action);
    my %opts;
    $opts{'next_status'} = $next if $next;
    $opts{'action'} = $job_action if _manage_is_silent_job_action($job_action);
    &_manage_redirect_after_job_launch($job_id, $instance_id, %opts);
}

sub _manage_job_action_labels {
    my $h = &job_action_labels_hash(\%text);
    return %{$h};
}

sub _manage_render_active_job_notice {
    my ($instance_id) = @_;
    return unless defined $instance_id && $instance_id =~ /\S/;
    my @running = &get_instance_jobs($instance_id, status => 'running');
    return unless @running;
    my %labels = _manage_job_action_labels();
    for my $job (@running) {
        my $jid = $job->{job_id};
        my $act = $job->{action} // '';
        my $label = $labels{$act} // $act;
        my $next = _manage_next_status_for_action($act);
        print "<div class='alert alert-info'>";
        print "<strong>" . &html_escape($text{'manage_job_running_title'}) . "</strong><br>";
        print &html_escape($label) . " — " . &html_escape($text{'job_running'}) . "<br>";
        unless (_manage_is_silent_job_action($act)) {
            my $url = "job_live.cgi?instance_id=" . &html_escape($instance_id)
                . "&job=" . &html_escape($jid) . "&xnavigation=1";
            $url .= "&next_status=" . &html_escape($next) if $next;
            print "<a href=\"" . &html_escape($url) . "\">"
                . &html_escape($text{'manage_job_open_live'}) . "</a>";
        }
        print "</div>\n";
    }
}

sub _manage_render_instance_jobs_table {
    my ($instance_id, $max_rows) = @_;
    $max_rows //= 5;
    return unless defined $instance_id && $instance_id =~ /\S/;
    &sync_monitor_job_pointers();
    my @inst_jobs = &get_instance_jobs($instance_id);
    return unless @inst_jobs;
    @inst_jobs = @inst_jobs[0 .. ($max_rows - 1)] if @inst_jobs > $max_rows;

    print "<h3>" . &html_escape($text{'jobs_title'} || 'Jobs') . "</h3>\n";
    my %job_action_labels = _manage_job_action_labels();
    my %status_icons = (
        running => '&#x23F3;',
        ok      => '&#x2705;',
        failed  => '&#x1F534;',
        aborted => '&#x1F6AB;',
    );
    my @rows;
    for my $job (@inst_jobs) {
        my $jid    = $job->{job_id};
        my $status = $job->{status};
        my $act    = $job->{action} // '';
        my $ts     = $job->{started_at} || 0;
        my @lt     = localtime($ts);
        my $ts_str = $ts ? sprintf('%02d:%02d', $lt[2], $lt[1]) : '—';
        my $st_icon = $status_icons{$status} // '';
        my $next = _manage_next_status_for_action($act);
        my $out_cell = '—';
        if ($status eq 'running') {
            my $live_url = "job_live.cgi?instance_id=" . &html_escape($instance_id)
                . "&amp;job=" . &html_escape($jid) . "&amp;xnavigation=1";
            $live_url .= "&amp;next_status=" . &html_escape($next) if $next;
            $out_cell = "<a href='$live_url'>"
                . &html_escape($text{'manage_job_open_live'}) . "</a>";
        } elsif ($status eq 'ok' || $status eq 'failed' || $status eq 'aborted') {
            $out_cell = "<a href='jobs.cgi?action=view_output&amp;job_id="
                . &html_escape($jid) . "'>"
                . &html_escape($text{'jobs_view_log'} || 'Log') . "</a>";
        }
        my $act_label = $job_action_labels{$act} // $act // '—';
        my $act_cell = ($act eq 'monitor_restart' || $act eq 'scheduled_restart')
            ? '&#x1F504; ' . &html_escape($act_label)
            : &html_escape($act_label);
        my $st_label = &job_status_label($status, \%text);
        push @rows, [
            $act_cell,
            $ts_str,
            "$st_icon " . &html_escape($st_label),
            $out_cell,
        ];
    }
    print &ui_columns_table(
        [
            $text{'jobs_col_action'}  || 'Aktion',
            $text{'jobs_col_started'} || 'Gestartet',
            $text{'jobs_col_status'}  || 'Status',
            $text{'jobs_col_output'}  || 'Ausgabe',
        ],
        '100%',
        \@rows,
    );
}

sub _manage_setup_action_running {
    my ($instance_id, $action) = @_;
    return &find_running_job_for_instance($instance_id, $action) ? 1 : 0;
}

sub _effective_instance_source {
    my ($inst) = @_;
    my $src = $inst->{'source'} // '';
    return $src if $src eq 'steamcmd';
    my (undef, undef, $server_dir) = _parse_script_info($inst);
    return 'steamcmd' if $server_dir && -f "$server_dir/.steam_app_id";
    my $game_key = $inst->{'cached_game'} || $inst->{'game'} || '';
    return 'steamcmd' if $game_key && (&get_game_source($game_key) // '') eq 'steamcmd';
    return $src || 'lgsm';
}

sub _steamcmd_server_binary_exists {
    my ($server_dir) = @_;
    return 1 if -f "$server_dir/.steam_launch_cmd";
    return 1 if -x "$server_dir/steamcmd-start.sh";
    my $serverfiles = "$server_dir/serverfiles";
    return 0 unless -d $serverfiles;
    my $found = 0;
    File::Find::find(
        sub {
            return if $found;
            return unless -f $_;
            return unless -x _ || $_ =~ /\.exe$/i;
            if ($_ =~ /\.x86_64$/ || $_ =~ /Server\.sh$/ || $_ =~ /\.exe$/i) {
                $found = 1;
            }
        },
        $serverfiles
    );
    return $found;
}

# Collect every port-typed field for the instance from cfg+meta defaults.
# Returns an arrayref of { key, port, label } in field declaration order.
# Used for firewall open/close and the info table so multi-port games like
# Windrose (game/query/beacon) get treated as a port group, not a single value.
# Rebuild the per-instance /etc/cron.d monitor file from the current registry +
# monitor state. LGSM and steamcmd instances get a game-user cron line via
# monitor_instance_user.sh. Call AFTER any set_monitor_* state change.
sub _rebuild_monitor_cron {
    return unless defined &rebuild_monitor_cron;
    &rebuild_monitor_cron($module_root, $config_directory)
        or &_log_monitor_cron_failure();
}

sub _rebuild_schedule_cron {
    return 1 unless defined &rebuild_schedule_cron;
    return &rebuild_schedule_cron($module_root, $config_directory) ? 1 : 0;
}

sub _log_monitor_cron_failure {
    system('logger', '-t', 'linuxgsm-webcore',
        'failed to write /etc/cron.d/linuxgsm-webcore-monitor');
}

sub _collect_instance_ports {
    my ($script_name, $cfg_ref) = @_;
    my @out;
    my @fields = &get_game_fields($script_name);
    my $lang   = $current_lang // 'en';
    for my $f (@fields) {
        my $type = $f->{'type'} // '';
        next unless $type eq 'port';
        my $key = $f->{'key'};
        my $val = $cfg_ref->{$key};
        if (!defined $val || $val eq '') {
            $val = $f->{'default'};
        }
        my $port = int($val // 0);
        next unless $port > 0;
        my $label = $lang eq 'de' ? ($f->{'label_de'} // $f->{'label_en'} // $key)
                                  : ($f->{'label_en'} // $f->{'label_de'} // $key);
        push @out, { key => $key, port => $port, label => $label };
    }
    # Legacy fallback for games without `port`-typed fields in games_meta:
    # use the registry/cfg "port" we already have.
    if (!@out) {
        my $val = $cfg_ref->{'port'};
        my $port = int($val // 0);
        push @out, { key => 'port', port => $port, label => $text{'manage_port'} } if $port > 0;
    }
    return \@out;
}

sub _runtime_status_badge_html {
    my ($status) = @_;
    # Vocabulary union: 'online'/'offline' from _detect_status* (instance.pl),
    # plus legacy 'running'/'stopped' callers, plus provisioning states.
    my %map = (
        online     => '&#x1F7E2; L&auml;uft',
        running    => '&#x1F7E2; L&auml;uft',
        offline    => '&#x1F534; Nicht gestartet',
        stopped    => '&#x1F534; Nicht gestartet',
        fresh      => '&#x1F7E1; Bereitstellung offen',
        lgsm_ready => '&#x1F7E1; Installation offen',
        mc_ready   => '&#x1F7E1; Minecraft vorbereitet',
        unknown    => '&#x1F7E1; Unbekannt',
    );
    return $map{$status} || ('&#x1F7E1; ' . &html_escape($status));
}

sub _manage_action_failed {
    &error($text{'manage_action_failed'} || 'Aktion fehlgeschlagen.');
}

sub _manage_run_server_action {
    my ($user, $action, $script_name, $script_dir) = @_;
    my $rc = &run_server_action($user, $action, $script_name, $script_dir);
    $rc == 0 or _manage_action_failed();
    return 1;
}

sub _manage_job_launch_failed {
    &error($text{'manage_job_launch_failed'} || 'Hintergrund-Job konnte nicht gestartet werden.');
}

sub _manage_apply_firewall_ports {
    my ($ports, $mode) = @_;
    my @failed;
    for my $p (@$ports) {
        my $port = $p->{port};
        if ($mode eq 'open') {
            &firewall_open_port($port, 'tcp') or push @failed, "$port/tcp";
            &firewall_open_port($port, 'udp') or push @failed, "$port/udp";
        } else {
            &firewall_close_port($port, 'tcp') or push @failed, "$port/tcp";
            &firewall_close_port($port, 'udp') or push @failed, "$port/udp";
        }
    }
    if (@failed) {
        &error(($text{'manage_fw_failed'} || 'Firewall-Aktion fehlgeschlagen.')
            . ' ' . &html_escape(join(', ', @failed)));
    }
    return 1;
}

sub _manage_launch_background_job {
    my ($instance_id, $action, $unix_user, $launch_cmd) = @_;
    my $job_id = &create_job($unix_user);
    &write_job_meta($job_id, $instance_id, $action, $unix_user)
        or do { &job_mark_launch_failed($job_id); return undef; };
    &log_action('job_started', $job_id, {instance_id => $instance_id, action => $action});
    my $cmd = ref($launch_cmd) eq 'CODE' ? $launch_cmd->($job_id) : $launch_cmd;
    my $rc = &system_logged($cmd);
    if ($rc != 0 || !&job_dispatch_verified($job_id)) {
        &job_mark_launch_failed($job_id);
        return undef;
    }
    return $job_id;
}

sub _manage_write_job_worker_secrets {
    my ($job_dir, $unix_user) = @_;
    return 0 unless defined $job_dir && -d $job_dir;
    &module_config_sync_in();
    my %keys;
    $keys{modpack_cf_auto_resume} = &module_config_bool($config{modpack_cf_auto_resume}) ? '1' : '0';
    for my $k (qw(curseforge_api_key modrinth_contact hangar_api_token)) {
        my $v = $config{$k} // '';
        $keys{$k} = $v if $v =~ /\S/;
    }
    return &write_job_worker_secrets($job_dir, $unix_user, \%keys);
}

sub _manage_modpack_search_query {
    my ($raw) = @_;
    $raw //= '';
    $raw =~ s/[\t\n\r\0]//g;
    $raw =~ s/^\s+|\s+$//g;
    return substr($raw, 0, 100);
}

sub _manage_query_urlencode {
    my ($v) = @_;
    $v //= '';
    $v =~ s/([^A-Za-z0-9_\-.~])/sprintf('%%%02X', ord($1))/ge;
    return $v;
}

sub _manage_mc_search_url_suffix {
    my $suffix = '';
    my $pack_q = _manage_modpack_search_query($in{'pack_q'} // '');
    my $mod_q  = _manage_mod_search_query($in{'mod_q'} // '');
    $suffix .= '&pack_q=' . _manage_query_urlencode($pack_q) if length($pack_q) >= 2;
    $suffix .= '&mod_q=' . _manage_query_urlencode($mod_q) if length($mod_q) >= 2;
    return $suffix;
}

sub _manage_modpack_resolve_error_msg {
    my ($err, $detail, $profile) = @_;
    return &mc_modpack_error_message($err, $detail, $profile, \%text);
}

sub _manage_launch_modpack_remote {
    my ($instance_id, $inst, $unix_user, $source, $ids_ref, $adopt) = @_;
    my (undef, undef, $server_dir) = _parse_script_info($inst);
    my $profile = &read_mc_profile($server_dir);
    &error($text{'mc_profile_missing'} || 'Kein Minecraft-Profil.') unless $profile;

    $source =~ s/[^a-z]//g;
    return unless ref($ids_ref) eq 'HASH';

    unless ($source eq 'modrinth' || $source eq 'curseforge') {
        &error(&_manage_modpack_resolve_error_msg('invalid_source', {}, $profile));
    }

    my %ids_clean = (
        project_id => $ids_ref->{'project_id'} // '',
        version_id => $ids_ref->{'version_id'} // '',
        file_id    => $ids_ref->{'file_id'} // '',
        title      => $ids_ref->{'title'} // '',
    );
    if ($source eq 'curseforge') {
        $ids_clean{'project_id'} =~ s/\D//g;
        $ids_clean{'file_id'}    =~ s/\D//g if $ids_clean{'file_id'};
    } else {
        $ids_clean{'project_id'} =~ s/[^a-zA-Z0-9_-]//g;
        $ids_clean{'version_id'} =~ s/[^a-zA-Z0-9_-]//g if $ids_clean{'version_id'};
    }
    unless ($ids_clean{'project_id'}) {
        &error(&_manage_modpack_resolve_error_msg(
            'invalid_project', { project_id => $ids_ref->{'project_id'} // '' }, $profile));
    }

    my %profile_snapshot = %$profile;

    my $job_id = &create_job($unix_user);
    my $job_dir = &_job_dir($job_id);
    &write_modpack_job_meta($job_dir, {
        remote_pending => 1,
        remote_source  => $source,
        remote_ids     => \%ids_clean,
        format         => $source eq 'curseforge' ? 'curseforge' : 'modrinth',
        mod_dir        => $profile->{'mod_dir'} // 'mods',
        server_dir     => $server_dir,
        profile        => \%profile_snapshot,
        pack_name      => $ids_clean{'title'},
        ($adopt ? (adopt_profile => 1) : ()),
    }, $unix_user) or do {
        &delete_job($job_id);
        &error($text{'mc_modpack_meta_failed'} || 'Job-Vorbereitung fehlgeschlagen.');
    };

    &write_job_meta($job_id, $instance_id, 'modpack_import', $unix_user)
        or do { &job_mark_launch_failed($job_id); &error($text{'manage_job_launch_failed'}); };

    &_manage_write_job_worker_secrets($job_dir, $unix_user);

    my $worker = "$module_root/scripts/mc_modpack_install.sh";
    my $rc = &system_logged(
        "MODULE_ROOT='$module_root' setsid nohup bash '$worker' "
        . quotemeta($job_dir) . ' '
        . quotemeta($unix_user) . ' '
        . quotemeta($server_dir) . ' &'
    );
    if ($rc != 0 || !&job_dispatch_verified($job_id)) {
        &job_mark_launch_failed($job_id);
        &error($text{'manage_job_launch_failed'});
    }
    return $job_id;
}

sub _manage_mod_search_query {
    my ($raw) = @_;
    $raw //= '';
    $raw =~ s/[\t\n\r\0]//g;
    $raw =~ s/^\s+|\s+$//g;
    return substr($raw, 0, 100);
}

sub _manage_render_mods_page_link {
    my ($inst, $instance_id) = @_;
    my ($profile, $server_dir) = _manage_read_mc_profile($inst);
    return unless $profile && $server_dir;
    return unless &mc_mod_ui_ready($profile, $server_dir);

    my $safe_id = &html_escape($instance_id);
    print "<h3>" . &html_escape($text{'mc_mods_page_title'} || 'Mods') . "</h3>\n";
    print "<p>" . &html_escape($text{'manage_mods_page_desc'}
        || 'Open the mods page to search, install, and update mods.')
        . "</p>\n";
    print &ui_form_start('mods.cgi', 'get');
    print &ui_hidden('instance_id', $safe_id);
    print &ui_hidden('xnavigation', '1');
    print &ui_submit($text{'manage_mods_page_btn'} || 'Open mods page',
        undef, undef, undef, 'btn-default');
    print &ui_form_end();
}

sub _manage_inline_action_btn {
    my ($html, $class) = @_;
    $class //= 'btn-default';
    return "<span style='display:inline-block;margin:0 6px 6px 0;vertical-align:middle'>$html</span>";
}

sub _manage_is_silent_job_action {
    my ($action) = @_;
    $action //= '';
    $action =~ s/[^a-z_]//g;
    return ($action =~ /^(?:start|stop|restart)$/) ? 1 : 0;
}

sub _manage_runtime_status {
    my ($inst, $effective_source, %opts) = @_;
    return instance_runtime_status($inst, %opts);
}

sub _manage_job_result_flash_mark {
    my ($job_id) = @_;
    $job_id =~ s/[^0-9a-f]//g;
    return 0 unless length($job_id) == 16;
    return &module_config_flash_mark("jobres_$job_id");
}

sub _manage_job_result_flash_consume {
    my ($job_id) = @_;
    $job_id =~ s/[^0-9a-f]//g;
    return 0 unless length($job_id) == 16;
    return &module_config_flash_consume("jobres_$job_id");
}

sub _manage_action_result_text {
    my ($notice_action, $status) = @_;
    $notice_action //= '';
    $notice_action =~ s/[^a-z_]//g;
    return '' unless $notice_action ne '';
    my $suffix = ($status eq 'ok') ? '_ok' : '_failed';
    my $key = "manage_action_${notice_action}${suffix}";
    return $text{$key} // ($status eq 'ok'
        ? ($text{'job_ok'} // 'OK')
        : ($text{'manage_action_failed'} // 'Action failed.'));
}

sub _manage_redirect_poll_job {
    my ($job_id, $inst_id, %opts) = @_;
    $job_id or _manage_job_launch_failed();
    my $url = "job_live.cgi?instance_id=" . &html_escape($inst_id)
        . "&job=" . &html_escape($job_id);
    $url .= "&next_status=" . &html_escape($opts{'next_status'}) if $opts{'next_status'};
    $url .= "&next_action=" . &html_escape($opts{'next_action'}) if $opts{'next_action'};
    $url .= "&xnavigation=1";
    $url .= _manage_mc_search_url_suffix();
    if ($opts{'return_target'}) {
        $url .= "&return=" . _manage_query_urlencode($opts{'return_target'});
    }
    &redirect($url);
    exit;
}

sub _manage_redirect_silent_job {
    my ($job_id, $inst_id, %opts) = @_;
    $job_id or _manage_job_launch_failed();
    my $url = _manage_poll_job_instance_url($inst_id)
        . "&silent_job=" . &html_escape($job_id);
    $url .= "&next_status=" . &html_escape($opts{'next_status'}) if $opts{'next_status'};
    $url .= "&next_action=" . &html_escape($opts{'next_action'}) if $opts{'next_action'};
    $url .= "&notice_action=" . &html_escape($opts{'notice_action'}) if $opts{'notice_action'};
    &redirect($url);
    exit;
}

sub _manage_redirect_after_job_launch {
    my ($job_id, $inst_id, %opts) = @_;
    my $action = $opts{'action'};
    delete $opts{'action'};
    unless ($action) {
        my $meta = &get_job_meta($job_id);
        $action = $meta->{'action'} // '';
    }
    $opts{'notice_action'} //= $action if _manage_is_silent_job_action($action);
    if (_manage_is_silent_job_action($action)) {
        &_manage_redirect_silent_job($job_id, $inst_id, %opts);
    } else {
        &_manage_redirect_poll_job($job_id, $inst_id, %opts);
    }
}

sub _manage_render_silent_job_poll {
    my ($instance_id, $job_id, %opts) = @_;
    $job_id =~ s/[^0-9a-f]//g;
    return unless length($job_id) == 16;
    &validate_job_for_instance($job_id, $instance_id) or return;

    my $notice_action = $opts{'notice_action'} // '';
    $notice_action =~ s/[^a-z_]//g;
    unless ($notice_action) {
        my $meta = &get_job_meta($job_id);
        $notice_action = $meta->{'action'} // '';
        $notice_action =~ s/[^a-z_]//g;
    }

    my $poll_q = "manage.cgi?instance_id=" . &html_escape($instance_id)
        . "&action=poll_job&job=" . &html_escape($job_id)
        . "&poll_format=json&silent=1";
    $poll_q .= "&next_status=" . &html_escape($opts{'next_status'}) if $opts{'next_status'};
    $poll_q .= "&next_action=" . &html_escape($opts{'next_action'}) if $opts{'next_action'};
    $poll_q .= "&notice_action=" . &html_escape($notice_action) if $notice_action ne '';
    my $poll_path = _manage_poll_job_module_path($poll_q);
    my $manage_path = _manage_poll_job_module_path(
        "manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1"
        . _manage_mc_search_url_suffix(),
    );
    my $poll_cfg = job_log_json_for_script({
        pollUrl       => $poll_path,
        runningMsg    => $text{'manage_action_running'} || 'Aktion läuft…',
        pollInterval  => 500,
        pollErrorMsg  => $text{'manage_action_poll_error'} || 'Statusabfrage fehlgeschlagen — Seite neu laden.',
    });

    print "<div id=\"silent_job_banner\" class=\"alert alert-info\">"
        . "<strong>" . &html_escape($text{'manage_action_running'} || 'Aktion läuft…')
        . "</strong></div>\n";
    print <<"EOF";
<script>
(function () {
  var C = $poll_cfg;
  var banner = document.getElementById("silent_job_banner");
  var statusEl = document.getElementById("manage_runtime_status");
  var timer = null;
  var failCount = 0;
  function finish(d) {
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
    var markUrl = C.pollUrl + (C.pollUrl.indexOf("?") >= 0 ? "&" : "?") + "mark_result=1";
    fetch(markUrl, { credentials: "same-origin", cache: "no-store" }).catch(function () {});
    if (banner) {
      if (d.status === "ok") {
        banner.className = "alert alert-success";
        banner.innerHTML = "<strong>" + (d.notice_msg || "") + "</strong>";
      } else if (d.status === "aborted") {
        banner.className = "alert alert-info";
        banner.innerHTML = "<strong>" + (d.notice_msg || "") + "</strong>";
      } else {
        banner.className = "alert alert-danger";
        banner.innerHTML = "<strong>" + (d.notice_msg || "") + "</strong>";
      }
    }
    if (statusEl && d.runtime_html) {
      statusEl.innerHTML = d.runtime_html;
    }
    window.setTimeout(function () {
      if (banner) banner.style.display = "none";
    }, 4500);
  }
  function pollOnce() {
    fetch(C.pollUrl, { credentials: "same-origin", cache: "no-store" })
      .then(function (r) {
        if (!r.ok) throw new Error("http " + r.status);
        return r.json();
      })
      .then(function (d) {
        failCount = 0;
        if (d.status === "running") {
          if (banner) {
            banner.className = "alert alert-info";
            banner.innerHTML = "<strong>" + C.runningMsg + "</strong>";
          }
          return;
        }
        finish(d);
      })
      .catch(function () {
        failCount++;
        if (banner && failCount >= 6) {
          banner.className = "alert alert-warning";
          banner.innerHTML = "<strong>" + (C.pollErrorMsg || "Poll failed") + "</strong>";
        }
      });
  }
  pollOnce();
  timer = setInterval(pollOnce, C.pollInterval);
})();
</script>
EOF
}

# Apply poll_job side effects when a background job finishes successfully.
sub _manage_poll_job_on_ok {
    my ($instance_id, $inst, $unix_user, $next_status, $next_action) = @_;
    if ($next_status) {
        &set_instance_status($instance_id, $next_status);
        if ($next_status eq 'installed') {
            my (undef, $script_name, $server_dir) = _parse_script_info($inst);
            if ($script_name && &is_minecraft_game($script_name)) {
                &ensure_mc_eula_file($server_dir, $unix_user);
            }
            if ($server_dir) {
                &set_monitor_running($server_dir, $config_directory, $instance_id);
                &_rebuild_monitor_cron();
            }
        }
    }
    return unless $next_action eq 'start';
    my $inst_now = &get_instance_flexible($instance_id) || $inst;
    my $source = _effective_instance_source($inst_now);
    my (undef, $script_name, $server_dir) = _parse_script_info($inst_now);
    if ($source eq 'steamcmd') {
        my $start_job = &_manage_launch_background_job(
            $instance_id, 'start', $unix_user,
            sub {
                my ($jid) = @_;
                my $start_job_dir = _shell_safe_job_dir($jid);
                return &_manage_steamcmd_worker_cmd('start', $start_job_dir, $unix_user, $server_dir);
            },
        );
        if ($start_job) {
            &_manage_redirect_silent_job($start_job, $instance_id, notice_action => 'start');
        }
        &error($text{'manage_job_launch_failed'} || 'Hintergrund-Job konnte nicht gestartet werden.');
    }
    &_manage_run_server_action($unix_user, 'start', $script_name, $server_dir);
}

sub _manage_poll_job_instance_url {
    my ($instance_id) = @_;
    return "manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1"
        . _manage_mc_search_url_suffix();
}

sub _manage_poll_job_json {
    my ($job_id, $status, $all_out, %opts) = @_;
    $main::headerprinted = 1;
    print "Content-type: application/json; charset=utf-8\n\n";
    my %payload = (
        status => $status,
        output => (defined $all_out ? $all_out : ''),
        done   => ($status ne 'running' ? 1 : 0),
    );
    if ($opts{'silent'}) {
        my $notice_action = $opts{'notice_action'} // '';
        $notice_action =~ s/[^a-z_]//g;
        unless ($notice_action) {
            my $meta = &get_job_meta($job_id);
            $notice_action = $meta->{'action'} // '';
            $notice_action =~ s/[^a-z_]//g;
        }
        if ($status ne 'running') {
            $payload{'notice_msg'} = _manage_action_result_text($notice_action, $status);
            if (my $inst = $opts{'inst'}) {
                my $retries = 0;
                if ($status eq 'ok') {
                    if ($notice_action =~ /^(?:start|restart)$/) {
                        $retries = 5;
                    }
                    elsif ($notice_action eq 'stop') {
                        $retries = 3;
                    }
                }
                my $rs = _manage_runtime_status(
                    $inst, $opts{'effective_source'} // '',
                    retries => $retries, light => 1);
                $payload{'runtime_status'} = $rs;
                $payload{'runtime_html'} = _runtime_status_badge_html($rs);
            }
        }
    }
    print job_log_json_utf8(\%payload);
    exit;
}

# Minimal HTML fragment for in-page job polling (no Webmin header/footer).
sub _manage_poll_job_partial {
    my ($status, $all_out) = @_;
    $main::headerprinted = 1;
    print "Content-type: text/html; charset=utf-8\n\n";
    if ($status eq 'running') {
        print "<p id=\"job_status\">" . &html_escape($text{'job_running'}) . "</p>\n";
    } elsif ($status eq 'ok') {
        print "<p id=\"job_status\" data-done=\"ok\" style=\"color:green\"><strong>"
            . &html_escape($text{'job_ok'}) . "</strong></p>\n";
    } else {
        print "<p id=\"job_status\" data-done=\"failed\" style=\"color:red\"><strong>"
            . &html_escape($text{'job_failed'}) . "</strong></p>\n";
    }
    my $out = (defined $all_out && $all_out ne '') ? $all_out : '';
    print &job_log_view_page_css();
    print &job_log_view_block($out, id => 'job_out');
    exit;
}

sub _manage_poll_job_module_path {
    my ($path_query) = @_;
    my $mn = $module_name // $main::module_name // 'linuxgsm-webcore';
    $mn =~ s/[^a-zA-Z0-9_-]//g;
    return "/$mn/$path_query";
}

# Link into Webmin's xterm module (same stack as htop/SSH-like terminal).
sub _manage_xterm_job_dir_url {
    my ($job_dir) = @_;
    return undef unless defined $job_dir && $job_dir =~ m|^/|;
    my $enc = $job_dir;
    $enc =~ s/([^A-Za-z0-9\-_.~\/])/sprintf("%%%02X", ord($1))/ge;
    return "/xterm/index.cgi?dir=$enc&xnavigation=1";
}

sub _enqueue_install_game_job {
    my ($instance_id, $reg, $unix_user, $opts_ref) = @_;
    my %opts = %{ $opts_ref || {} };
    my $job_action = $opts{'job_action'} || 'install_game';
    my $preclean = $opts{'preclean'} ? 1 : 0;
    my $source = _effective_instance_source($reg);
    my (undef, $script_name, $server_dir) = _parse_script_info($reg);
    $script_name = _manage_executable_script_name($server_dir, $script_name)
        if $source ne 'steamcmd';
    if ($source eq 'steamcmd' && ($reg->{'source'} // '') ne 'steamcmd') {
        &register_instance($instance_id, $reg->{'user'}, $reg->{'script'}, {
            source => 'steamcmd',
        });
    }
    my $job_id = &create_job($unix_user);
    my $job_dir = _shell_safe_job_dir($job_id);
    &write_job_meta($job_id, $instance_id, $job_action, $unix_user)
        or do { &job_mark_launch_failed($job_id); return undef; };
    &log_action('job_started', $job_id, {instance_id => $instance_id, action => $job_action});

    my $rc;
    if ($source eq 'steamcmd') {
        my $app_id = $reg->{'steam_app_id'} // '';
        if (!$app_id) {
            my %gmeta = load_games_meta();
            my $game_key = $reg->{'cached_game'} || $script_name;
            $app_id = $gmeta{$game_key}{'steam_app_id'} // '';
        }
        $app_id =~ s/[^0-9]//g;
        my $steamcmd_path = &detect_steamcmd() // 'steamcmd';
        my $preclean_arg = $preclean ? '1' : '';
        my $cmd = "MODULE_ROOT='$module_root' STEAMCMD_PATH='$steamcmd_path' setsid nohup bash -lc "
            . "\"bash '$module_root/scripts/steamcmd_install.sh' '$job_dir' '$unix_user' '$server_dir' "
            . "'$app_id' '' '$script_name' '$preclean_arg'\" &";
        &log_debug("$job_action steamcmd: module_root=$module_root steamcmd=$steamcmd_path server_dir=$server_dir app_id=$app_id preclean=$preclean cmd=$cmd");
        $rc = &system_logged($cmd);
    } else {
        my $cmd2 = &user_worker_launch_cmd(
            unix_user   => $unix_user,
            module_root => $module_root,
            worker      => "$module_root/scripts/game_action_user.sh",
            args        => [ $job_dir, $unix_user, $server_dir, $script_name, 'install' ],
        );
        &log_debug("$job_action lgsm: module_root=$module_root server_dir=$server_dir cmd=$cmd2");
        $rc = &system_logged($cmd2);
    }

    if ($rc != 0 || !&job_dispatch_verified($job_id)) {
        &job_mark_launch_failed($job_id);
        return undef;
    }

    return $job_id;
}

# One-time ROOT dependency bootstrap (apt) for a new instance. After this the
# whole runtime is user-native and never touches apt. See provision_deps.sh.
sub _manage_launch_provision_deps {
    my ($instance_id, $inst, $unix_user) = @_;
    my (undef, $script_name, $server_dir) = _parse_script_info($inst);
    my $source   = _effective_instance_source($inst);
    my $game_key = $inst->{'cached_game'} || $inst->{'game'} || $script_name || '';
    $game_key =~ s/[^a-zA-Z0-9_.\-]//g;

    my %gmeta = &load_games_meta();
    my $app_id = $inst->{'steam_app_id'} // '';
    if ((!defined $app_id || $app_id eq '') && $game_key && ref($gmeta{$game_key}) eq 'HASH') {
        $app_id = $gmeta{$game_key}{'steam_app_id'} // '';
    }
    $app_id =~ s/[^0-9]//g;
    my $runtime = (ref($gmeta{$game_key}) eq 'HASH') ? ($gmeta{$game_key}{'runtime'} // '') : '';
    $runtime =~ s/[^a-z0-9_]//g;

    my $job_id = &create_job($unix_user);
    my $job_dir = _shell_safe_job_dir($job_id);
    &write_job_meta($job_id, $instance_id, 'provision_deps', $unix_user)
        or do { &job_mark_launch_failed($job_id); return undef; };

    my $cmd = "MODULE_ROOT='$module_root' setsid nohup bash '$module_root/scripts/provision_deps.sh' "
        . "'$job_dir' '$unix_user' '$server_dir' '$game_key' '$source' '$app_id' '$runtime' &";
    &log_debug("provision_deps: game=$game_key source=$source app_id=$app_id runtime=$runtime");
    my $rc = &system_logged($cmd);
    if ($rc != 0 || !&job_dispatch_verified($job_id)) {
        &job_mark_launch_failed($job_id);
        return undef;
    }
    return $job_id;
}

# --- Pending modpack-first chain -----------------------------------------
# The modpack import needs base tools (curl/unzip) from provision_deps. We stash
# the chosen pack under $config_directory and launch it once, right after the
# deps job lands back on the instance page (job_notice=ok). JS-independent.
sub _manage_pending_modpack_path {
    my ($instance_id) = @_;
    my $id = $instance_id // '';
    $id =~ s/[^a-zA-Z0-9_.\-]//g;
    return undef unless length $id;
    my $dir = $config_directory || $main::config_directory;
    return undef unless defined $dir && $dir ne '';
    return "$dir/.pending_modpack_$id";
}

sub _manage_collect_pack_params {
    my $src = $in{'pack_source'} // '';
    $src =~ s/[^a-z]//g;
    my $pid = $in{'pack_project_id'} // '';
    my $fid = $in{'pack_file_id'} // '';
    $fid =~ s/\D//g;
    my $vid = $in{'pack_version_id'} // '';
    $vid =~ s/[^a-zA-Z0-9_-]//g;
    my $tit = $in{'pack_title'} // '';
    $tit =~ s/[\t\n\r\0]//g;
    $tit = substr($tit, 0, 128);
    my $adopt = ($in{'pack_adopt'} // '') eq '1' ? 1 : 0;
    my $return_to = $in{'return_to'} // '';
    $return_to =~ s/[^a-z]//g;
    $return_to = ($return_to eq 'mods') ? 'mods' : '';
    if ($src eq 'curseforge') {
        $pid =~ s/\D//g;
    } else {
        $pid =~ s/[^a-zA-Z0-9_-]//g;
    }
    return (
        source     => $src,
        project_id => $pid,
        file_id    => $fid,
        version_id => $vid,
        title      => $tit,
        adopt      => $adopt,
        return_to  => $return_to,
    );
}

sub _manage_stash_pending_modpack {
    my ($instance_id, $params) = @_;
    my $path = _manage_pending_modpack_path($instance_id) or return 0;
    require JSON::PP;
    open(my $fh, '>', $path) or return 0;
    print {$fh} JSON::PP::encode_json($params) or do { close($fh); return 0; };
    close($fh) or return 0;
    chmod(0600, $path);
    return 1;
}

sub _manage_consume_pending_modpack {
    my ($instance_id) = @_;
    my $path = _manage_pending_modpack_path($instance_id) or return undef;
    return undef unless -f $path;
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $raw = <$fh>;
    close($fh);
    unlink($path);
    require JSON::PP;
    my $data = eval { JSON::PP::decode_json($raw) };
    return (ref($data) eq 'HASH') ? $data : undef;
}

# Launch a stashed modpack import once the deps bootstrap has finished.
sub _manage_maybe_launch_pending_modpack {
    my ($instance_id, $inst, $unix_user) = @_;
    my $path = _manage_pending_modpack_path($instance_id);
    return unless defined $path && -f $path;
    # Never stack on top of a still-running job (e.g. deps not truly done).
    return if &find_running_job_for_instance($instance_id);
    my $pending = _manage_consume_pending_modpack($instance_id);
    return unless ref($pending) eq 'HASH';
    return unless $pending->{'source'} && (($pending->{'project_id'} // '') ne '');
    my $job = &_manage_launch_modpack_remote(
        $instance_id, $inst, $unix_user, $pending->{'source'},
        {
            project_id => $pending->{'project_id'},
            file_id    => $pending->{'file_id'} // '',
            version_id => $pending->{'version_id'} // '',
            title      => $pending->{'title'} // '',
        },
        ($pending->{'adopt'} ? 1 : 0),
    );
    if ($job) {
        my %opts;
        if (($pending->{'return_to'} // '') eq 'mods') {
            $opts{'return_target'} = "mods.cgi?instance_id="
                . _manage_query_urlencode($instance_id)
                . "&xnavigation=1";
        }
        &_manage_redirect_poll_job($job, $instance_id, %opts);
    }
}

my $instance_id = &sanitize_input($in{'instance_id'} || $in{'user'} || '');
my $inst = &get_instance_flexible($instance_id) or &error($text{'err_not_found'});
$inst = _manage_reconcile_mc_instance_status($inst, $instance_id);
my $unix_user = $inst->{'user'};
my $effective_source = _effective_instance_source($inst);
my $is_fresh  = ($inst->{'instance_status'} // 'installed') ne 'installed';

&user_can_manage($instance_id)
    or &error($text{'err_acl_admin_only'} || 'Access denied');

if ($in{'action'} && $in{'action'} !~ /^(?:poll_job|monitor)$/) {
    my $action = &sanitize_input($in{'action'});
    &log_debug("action=$action instance=$instance_id");
    if (&user_is_readonly($instance_id)) {
        &error($text{'err_readonly'} || 'This server is read-only for your account');
    }

    if ($action eq 'fw_open') {
        my (undef, $sn_fw, $sd_fw) = _parse_script_info($inst);
        my %cfg_fw = $sn_fw && $sd_fw ? &_parse_lgsm_config($sd_fw, $sn_fw) : ();
        my $ports = _collect_instance_ports($sn_fw, \%cfg_fw);
        &_manage_apply_firewall_ports($ports, 'open');
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'fw_close') {
        my (undef, $sn_fw, $sd_fw) = _parse_script_info($inst);
        my %cfg_fw = $sn_fw && $sd_fw ? &_parse_lgsm_config($sd_fw, $sn_fw) : ();
        my $ports = _collect_instance_ports($sn_fw, \%cfg_fw);
        &_manage_apply_firewall_ports($ports, 'close');
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'fix_config') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        my $script_dir  = $inst->{'script'};
        $script_dir =~ s|/[^/]+$||;

        my $config_file = "$script_dir/lgsm/config-lgsm/$script_name/$script_name.cfg";
        my $default_cfg = "$script_dir/lgsm/config-default/config-lgsm/$script_name/_default.cfg";

        &validate_config_target($config_file);
        &error("Invalid default path") unless
            $default_cfg =~ m|^/[a-zA-Z0-9_./()\-]+/lgsm/config-default/config-lgsm/[a-zA-Z0-9_-]+/_default\.cfg$|;

        # Build form overrides from all games_meta fields.
        # Each field type drives validation; missing values fall back to games_meta defaults.
        my @fields_def  = &get_game_fields($script_name);
        unless (@fields_def) {
            # Legacy fallback: minimal port/gamename set.
            @fields_def = (
                {key => 'port',     type => 'port'},
                {key => 'gamename', type => 'text'},
            );
        }
        my %form_overrides;
        for my $f (@fields_def) {
            my $k   = $f->{'key'};
            my $raw = defined $in{$k} ? $in{$k} : ($f->{'default'} // '');
            my $t   = $f->{'type'} // 'text';
            if ($t eq 'port' || $t eq 'int') {
                my $n = int($raw || 0);
                # port/queryport/beaconport must be > 0; other ints can be 0.
                if ($t eq 'port') {
                    $n > 0 or &error($text{'err_invalid_input'});
                }
                $form_overrides{$k} = $n;
            } elsif ($t eq 'bool') {
                $form_overrides{$k} = $raw ? 1 : 0;
            } else {
                my $v = $raw // '';
                $v =~ s/[^a-zA-Z0-9 ._\-:\/]//g;
                $form_overrides{$k} = $v;
            }
        }
        # gamename always required (LGSM convention) when present in form.
        if (exists $form_overrides{'gamename'}) {
            length($form_overrides{'gamename'}) or &error($text{'err_invalid_input'});
        }

        # Read _default.cfg preserving section comments and all assignments.
        # Form values override whatever was in the file.
        my @output_lines;
        my %seen;
        if (-f $default_cfg) {
            open(my $src, '<', $default_cfg) or &error("Cannot read default config: $!");
            while (<$src>) {
                chomp;
                next if /^\s*$/;            # blank lines
                next if /^\[/;              # bash conditionals
                if (/^\s*#/) {
                    push @output_lines, $_;  # section comment
                } elsif (/^\s*(\w+)\s*=\s*["']?([^"'\n]*)["']?\s*$/) {
                    my ($k, $v) = ($1, $2);
                    $v = $form_overrides{$k} if exists $form_overrides{$k};
                    push @output_lines, "$k=\"$v\"";
                    $seen{$k} = 1;
                }
            }
            close($src);
        }
        # Append any form values not found in _default.cfg
        for my $k (sort keys %form_overrides) {
            push @output_lines, "$k=\"$form_overrides{$k}\"" unless $seen{$k};
        }

        # Ensure lgsm/config-lgsm/$script_name/ exists (single su with write)
        my $cfg_content = join("\n", @output_lines) . "\n";
        $cfg_content = &apply_instance_profile_to_cfg_content($cfg_content, $script_name, $script_dir);

        &_write_file_as_user($config_file, $cfg_content, $unix_user,
            mkdir => "$script_dir/lgsm/config-lgsm/$script_name");

        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'migrate_config') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        my $script_dir  = $inst->{'script'};
        $script_dir =~ s|/[^/]+$||;

        my $common_path = "$script_dir/lgsm/config-lgsm/common.cfg";
        my $script_path = "$script_dir/lgsm/config-lgsm/$script_name/$script_name.cfg";

        &validate_config_target($common_path);
        &validate_config_target($script_path);

        my ($common_vals, $common_order, undef) = &read_config_file($common_path);
        my ($script_vals, $script_order, undef) = &read_config_file($script_path);

        # Move known game fields from common.cfg → $script.cfg
        # Script-side value wins if the key already exists there.
        my @gfields = &get_game_fields($script_name);
        my %gkeys   = map { $_->{'key'} => 1 } @gfields;
        for my $key (keys %gkeys) {
            if (exists $common_vals->{$key} && !exists $script_vals->{$key}) {
                $script_vals->{$key} = $common_vals->{$key};
                push @$script_order, $key;
            }
            delete $common_vals->{$key};  # remove from common regardless
        }

        # Ensure $script subdir exists (single su with write)
        my $script_content = join('', map { exists $script_vals->{$_} ? "$_=\"$script_vals->{$_}\"\n" : () } @$script_order);
        &_write_file_as_user($script_path, $script_content, $unix_user,
            mkdir => "$script_dir/lgsm/config-lgsm/$script_name");

        # Write back common.cfg; delete if nothing remains
        my @remaining = grep { exists $common_vals->{$_} } @$common_order;
        if (@remaining) {
            my $common_content = join('', map { "$_=\"$common_vals->{$_}\"\n" } @remaining);
            &_write_file_as_user($common_path, $common_content, $unix_user);
        } else {
            unlink $common_path;
        }

        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'save_config') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        my $script_dir  = $inst->{'script'};
        $script_dir =~ s|/[^/]+$||;

        my $cfg_file_key = $in{'config_file'} // '';
        $cfg_file_key = ($cfg_file_key eq 'instance' || $cfg_file_key eq 'common' || $cfg_file_key eq 'game')
            ? $cfg_file_key : 'common';
        my $cfg_view_key = $in{'config_view'} // '';
        $cfg_view_key = ($cfg_view_key eq 'instance' || $cfg_view_key eq 'common' || $cfg_view_key eq 'game')
            ? $cfg_view_key : $cfg_file_key;
        my $cfg_path;
        if ($cfg_file_key eq 'instance') {
            $cfg_path = "$script_dir/lgsm/config-lgsm/$script_name/$script_name.cfg";
        } elsif ($cfg_file_key eq 'game') {
            my %cfg_ctx = &_parse_lgsm_config($script_dir, $script_name);
            my $hint    = &get_game_config_path($script_name);
            $cfg_path = &resolve_game_server_config_path($script_dir, $script_name, \%cfg_ctx, $hint);
            $cfg_path = &validate_game_config_path($script_dir, $cfg_path);
        } else {
            $cfg_path = "$script_dir/lgsm/config-lgsm/common.cfg";
        }
        &validate_config_target($cfg_path) unless $cfg_file_key eq 'game';

        # Ensure the parent directory exists (combined with write below)
        (my $cfg_dir = $cfg_path) =~ s|/[^/]+$||;

        if ($cfg_file_key eq 'game') {
            unless (-f $cfg_path) {
                if ($effective_source eq 'steamcmd') {
                    &error($text{'config_editor_game_missing_steamcmd'}
                        || $text{'config_editor_game_missing'});
                }
                &_manage_dispatch_game_config_bootstrap($instance_id, $inst, $unix_user);
            }
            -f $cfg_path or &error($text{'config_editor_game_missing'});
            my $new_content;
            if (int($in{'raw_mode'} || 0)) {
                $new_content = $in{'game_config_raw'} // '';
            } else {
                my $raw_base = &read_game_config_raw($cfg_path);
                if ($raw_base eq '' && ($in{'game_config_original'} // '') ne '') {
                    $raw_base = &normalize_game_config_text($in{'game_config_original'});
                }
                my ($base_vals, $base_order, $fmt) =
                    &parse_game_config_values($script_name, $cfg_path, $raw_base);
                if ($fmt eq 'json') {
                    my %updates;
                    for my $param (keys %in) {
                        next unless $param =~ /^field_(.+)$/;
                        my $key = $1;
                        my $val = $in{$param};
                        $val = '' unless defined $val;
                        $updates{$key} = $val;
                    }
                    $new_content = &update_json_config($raw_base, \%updates);
                }
                elsif ($fmt eq 'properties') {
                    my %prop_vals = %{$base_vals || {}};
                    for my $param (keys %in) {
                        next unless $param =~ /^field_(.+)$/;
                        my $key = $1;
                        $prop_vals{$key} = $in{$param} if exists $in{$param};
                    }
                    $new_content = &update_properties_file($raw_base, \%prop_vals);
                } else {
                    my %opt_vals = %{$base_vals || {}};
                    my @opt_order = @{$base_order || []};
                    for my $param (keys %in) {
                        next unless $param =~ /^field_(\w+)$/;
                        my $key = $1;
                        my $val = $in{$param} // '';
                        $opt_vals{$key} = $val;
                        push @opt_order, $key unless grep { $_ eq $key } @opt_order;
                    }
                    $new_content = &update_option_settings_in_ini($raw_base, \%opt_vals, \@opt_order);
                }
            }
            &_write_file_as_user($cfg_path, $new_content, $unix_user, mkdir => $cfg_dir);
        } elsif (int($in{'raw_mode'} || 0)) {
            # Raw mode: filter content and write as game user
            my $raw_lines = &filter_raw_config($in{'config_raw'} // '');
            &_write_file_as_user($cfg_path, join("\n", @$raw_lines) . "\n", $unix_user, mkdir => $cfg_dir);
        } else {
            # Form mode: read current file, apply field_* overrides, write back as game user
            my ($cur_vals, $cur_order, undef) = &read_config_file($cfg_path);

            # Apply form fields (field_<key> params)
            for my $param (keys %in) {
                next unless $param =~ /^field_(\w+)$/;
                my $key = $1;
                my $val = $in{$param} // '';
                $val =~ s/[<>"\\]//g;   # basic sanitize
                $cur_vals->{$key} = $val;
                push @$cur_order, $key unless grep { $_ eq $key } @$cur_order;
            }

            my $form_content = join('', map { exists $cur_vals->{$_} ? "$_=\"$cur_vals->{$_}\"\n" : () } @$cur_order);
            &_write_file_as_user($cfg_path, $form_content, $unix_user, mkdir => $cfg_dir);
        }

        &log_action('config_saved', $instance_id, {config_type => $cfg_file_key});
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) .
                  "&config_file=" . &html_escape($cfg_file_key) .
                  "&config_view=" . &html_escape($cfg_view_key) .
                  "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'delete_instance') {
        &is_admin() or &error($text{'err_acl_admin_only'} || 'Access denied');
        my $script_name = (split('/', $inst->{'script'}))[-1];
        my $script_dir  = $inst->{'script'};
        $script_dir =~ s|/[^/]+$||;
        my $game_user = $inst->{'user'};
        my $safe_game_user = $game_user // '';
        $safe_game_user =~ s/[^a-zA-Z0-9_.-]//g;
        my @game_pw_before = $safe_game_user ne '' ? getpwnam($safe_game_user) : ();
        my $game_home_before = @game_pw_before ? ($game_pw_before[7] // '') : '';
        $game_home_before ||= "/home/$safe_game_user" if $safe_game_user ne '';

        my @all_before = &list_instances();
        my @other_for_user = grep {
            ($_->{'id'} // '') ne $instance_id && ($_->{'user'} // '') eq $game_user
        } @all_before;

        my $sftp_user = &resolve_instance_sftp_user($instance_id, $game_user);

        # Always remove instance directory; keep guardrails for destructive paths.
        if ($script_dir =~ m|^/| && $script_dir ne '/' && $script_dir =~ m|^/home/|) {
            my $safe_script_dir = _shell_sq($script_dir);
            &system_logged("rm -rf $safe_script_dir");
        }

        # Remove panel registration entry (if tracked)
        &unregister_instance($instance_id);

        # FTP/SFTP cleanup is mandatory for instance deletion.
        # Virtual ftpasswd users have no /etc/passwd entry — try that first.
        # Only fall back to a real Unix-account decommission if ftpasswd
        # didn't own the user.
        my @sftp_leftovers;
        if ($sftp_user && $sftp_user ne $game_user) {
            my %ftp_state = &discover_ftp_state();
            my $auth_file = $ftp_state{'auth_user_file'} || '/etc/proftpd/ftpd.passwd';
            my $rc = &ftpasswd_delete_user(
                file => $auth_file,
                name => $sftp_user,
            );
            if ($rc != 0) {
                my $sftp_res = &decommission_unix_user($sftp_user);
                push @sftp_leftovers, @{ $sftp_res->{'leftovers'} } if !$sftp_res->{'ok'};
                &log_debug("sftp decommission: " . join(' | ', @{ $sftp_res->{'log'} }));
            }
        }

        # Remove game unix user only if this was the last instance for that user
        my @user_leftovers;
        if (!@other_for_user && $safe_game_user ne '') {
            my $game_res = &decommission_unix_user($safe_game_user);
            push @user_leftovers, @{ $game_res->{'leftovers'} } if !$game_res->{'ok'};
            &log_debug("game decommission: " . join(' | ', @{ $game_res->{'log'} }));
        }

        # Verify hard-delete actually removed artifacts.
        my @leftovers;
        push @leftovers, $script_dir
            if $script_dir =~ m|^/| && -d $script_dir;
        push @leftovers, @user_leftovers, @sftp_leftovers;
        if (@leftovers) {
            my $msg = join(', ', @leftovers);
            &error(($text{'err_delete_incomplete'} || 'Löschen unvollständig') . ": $msg");
        }

        &redirect("index.cgi?xnavigation=1");
        exit;
    }
    elsif ($action eq 'create_instance_ftp_user') {
        &can_manage_ftp() or &error($text{'err_acl_admin_only'} || 'Access denied');
        my %ftp_state  = &discover_ftp_state();
        my $auth_file  = $ftp_state{'auth_user_file'} || '/etc/proftpd/ftpd.passwd';
        my $ftp_user   = 'ftp_' . $unix_user;
        my $ftp_pass   = $in{'ftp_pass'} // '';
        length($ftp_pass) or &error($text{'err_invalid_input'});
        my @pw = getpwnam($unix_user);
        my $uid = @pw ? $pw[2] : 33;
        my $gid = @pw ? $pw[3] : 33;
        my $home = @pw ? $pw[7] : "/home/$unix_user";
        &ftpasswd_create_user(
            file     => $auth_file,
            name     => $ftp_user,
            password => $ftp_pass,
            uid      => $uid,
            gid      => $gid,
            home     => $home,
            shell    => '/bin/false',
        ) == 0 or &error("Failed creating FTP user");
        &register_instance($instance_id, $unix_user, $inst->{'script'}, {
            sftp_user => $ftp_user,
        }) or &error($text{'ftp_register_failed'} || $text{'wizard_register_failed'});
        &save_ftp_password($config_directory, $instance_id, $ftp_pass);
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'delete_instance_ftp_user') {
        &can_manage_ftp() or &error($text{'err_acl_admin_only'} || 'Access denied');
        my $ftp_user  = &sanitize_input($in{'ftp_user'});
        my %ftp_state = &discover_ftp_state();
        my $auth_file = $ftp_state{'auth_user_file'} || '/etc/proftpd/ftpd.passwd';
        &ftpasswd_delete_user(file => $auth_file, name => $ftp_user);
        &register_instance($instance_id, $unix_user, $inst->{'script'}, {
            sftp_user => '',
        }) or &error($text{'ftp_register_failed'} || $text{'wizard_register_failed'});
        &delete_ftp_password($config_directory, $instance_id);
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'save_steam_account') {
        my $sa = $in{'steam_account'} // '';
        $sa =~ s/[^a-zA-Z0-9_\-]//g;
        $sa = substr($sa, 0, 64);
        &register_instance($instance_id, $unix_user, $inst->{'script'}, {
            steam_account => $sa,
        }) or &error($text{'wizard_register_failed'});
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'provision_deps') {
        &_manage_redirect_if_job_running($instance_id, 'provision_deps');
        # Optional modpack-first chain: stash the chosen pack so it auto-starts
        # once deps are done (see _manage_maybe_launch_pending_modpack).
        my $then = $in{'then'} // '';
        $then =~ s/[^a-z_]//g;
        if ($then eq 'modpack') {
            my %pack = _manage_collect_pack_params();
            if ($pack{'source'} && $pack{'project_id'} ne '') {
                _manage_stash_pending_modpack($instance_id, \%pack);
            }
        }
        my $job_id = &_manage_launch_provision_deps($instance_id, $inst, $unix_user);
        $job_id or _manage_job_launch_failed();
        &_manage_redirect_poll_job($job_id, $instance_id);
    }
    elsif ($action eq 'setup_lgsm') {
        &_manage_redirect_if_job_running($instance_id, 'setup_lgsm');
        my $reg = &get_registered_instance($instance_id) or &error($text{'err_not_found'});
        my $script_path = $reg->{'script'} // '';
        my $script_name = (split('/', $script_path))[-1] // '';
        (my $server_dir = $script_path) =~ s|/[^/]+$||;
        $script_name =~ s/[^a-zA-Z0-9_-]//g;
        my $lgsm_short = defined &resolve_lgsm_game_shortname
            ? &resolve_lgsm_game_shortname($script_name) : $script_name;
        my $verify_script = defined &resolve_lgsm_game_script
            ? &resolve_lgsm_game_script($script_name) : $script_name;
        $verify_script =~ s/[^a-zA-Z0-9_-]//g;
        $lgsm_short =~ s/[^a-zA-Z0-9_-]//g;

        my $worker = "$module_root/scripts/setup_lgsm_user.sh";
        my $job_id = &_manage_launch_background_job(
            $instance_id, 'setup_lgsm', $unix_user,
            sub {
                my ($jid) = @_;
                return &user_worker_launch_cmd(
                    unix_user   => $unix_user,
                    module_root => $module_root,
                    worker      => $worker,
                    args        => [ &_job_dir($jid), $unix_user, $server_dir, $lgsm_short, $verify_script ],
                );
            },
        );
        &_manage_redirect_poll_job($job_id, $instance_id, next_status => 'lgsm_ready');
    }
    elsif ($action eq 'mc_java_setup') {
        &_manage_redirect_if_job_running($instance_id, 'mc_java_setup');
        my (undef, $script_name, $server_dir) = _parse_script_info($inst);
        my $profile = &read_mc_profile($server_dir);
        &error($text{'mc_profile_missing'} || 'Kein Minecraft-Profil (.mcprofile.json).') unless $profile;
        my $lgsm_script = $profile->{'lgsm_script'} // $script_name;
        $lgsm_script =~ s/[^a-zA-Z0-9_-]//g;
        my $job_id = &_manage_launch_background_job(
            $instance_id, 'mc_java_setup', $unix_user,
            sub {
                my ($jid) = @_;
                return &user_worker_launch_cmd(
                    unix_user   => $unix_user,
                    module_root => $module_root,
                    worker      => "$module_root/scripts/mc_java_install_user.sh",
                    args        => [ &_job_dir($jid), $unix_user, $server_dir, $lgsm_script ],
                );
            },
        );
        &_manage_redirect_poll_job($job_id, $instance_id, next_status => 'mc_ready');
    }
    elsif ($action eq 'mc_loader_setup') {
        &_manage_redirect_if_job_running($instance_id, 'mc_loader_setup');
        my (undef, $script_name, $server_dir) = _parse_script_info($inst);
        my $profile = &read_mc_profile($server_dir);
        &error($text{'mc_profile_missing'} || 'Kein Minecraft-Profil (.mcprofile.json).') unless $profile;
        my $loader = $profile->{'loader'} // '';
        &error($text{'mc_loader_not_modded'} || 'Dieser Loader wird nicht über Mod-Loader-Setup installiert.')
            unless &mc_loader_is_modded($loader);
        my $lgsm_script = $profile->{'lgsm_script'} // $script_name;
        $lgsm_script =~ s/[^a-zA-Z0-9_-]//g;
        my $job_id = &_manage_launch_background_job(
            $instance_id, 'mc_loader_setup', $unix_user,
            sub {
                my ($jid) = @_;
                return &user_worker_launch_cmd(
                    unix_user   => $unix_user,
                    module_root => $module_root,
                    worker      => "$module_root/scripts/mc_loader_install_user.sh",
                    args        => [ &_job_dir($jid), $unix_user, $server_dir, $lgsm_script ],
                );
            },
        );
        &_manage_redirect_poll_job($job_id, $instance_id, next_status => 'installed');
    }
    elsif ($action eq 'install_game') {
        my (undef, undef, $server_dir) = _parse_script_info($inst);
        my $profile = $server_dir ? &read_mc_profile($server_dir) : undef;
        if ($profile && &mc_loader_is_modded($profile->{'loader'} // '')) {
            &error($text{'mc_loader_use_modded_setup'}
                || 'Für Fabric/Forge/NeoForge bitte Java-Setup und Mod-Loader-Installation verwenden.');
        }
        &_manage_redirect_if_job_running($instance_id, 'install_game');
        my $reg = &get_registered_instance($instance_id) or &error($text{'err_not_found'});
        my $source = _effective_instance_source($reg);
        if ($source ne 'steamcmd') {
            my (undef, $script_name, $server_dir) = _parse_script_info($reg);
            my $exec = _manage_executable_script_name($server_dir, $script_name);
            unless (-x "$server_dir/$exec") {
                &error($text{'setup_lgsm_required'}
                    || 'LGSM-Skript fehlt — bitte zuerst „LGSM einrichten“ ausführen.');
            }
        }
        my $job_id = _enqueue_install_game_job($instance_id, $reg, $unix_user);
        &_manage_redirect_poll_job($job_id, $instance_id, next_status => 'installed');
    }
    elsif ($action eq 'update') {
        my $source = $effective_source;
        my ($script_path, $script_name, $server_dir) = _parse_script_info($inst);
        my $job_id = &_manage_launch_background_job(
            $instance_id, 'update', $unix_user,
            sub {
                my ($jid) = @_;
                my $job_dir = _shell_safe_job_dir($jid);
                if ($source eq 'steamcmd') {
                    my $steamcmd_path = &detect_steamcmd() // 'steamcmd';
                    return &_manage_steamcmd_worker_cmd('update', $job_dir, $unix_user, $server_dir,
                        steamcmd_path => $steamcmd_path);
                }
                return &user_worker_launch_cmd(
                    unix_user   => $unix_user,
                    module_root => $module_root,
                    worker      => "$module_root/scripts/game_action_user.sh",
                    args        => [ $job_dir, $unix_user, $server_dir, $script_name, 'update' ],
                );
            },
        );
        &_manage_redirect_poll_job($job_id, $instance_id);
    }
    elsif ($action eq 'validate') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        (my $server_dir = $inst->{'script'}) =~ s|/[^/]+$||;
        $script_name =~ s/[^a-zA-Z0-9_-]//g;
        my $worker = "$module_root/scripts/game_action_user.sh";
        my $job_id = &_manage_launch_background_job(
            $instance_id, 'validate', $unix_user,
            sub {
                my ($jid) = @_;
                my $job_dir = _shell_safe_job_dir($jid);
                return &user_worker_launch_cmd(
                    unix_user   => $unix_user,
                    module_root => $module_root,
                    worker      => $worker,
                    args        => [ $job_dir, $unix_user, $server_dir, $script_name, 'validate' ],
                );
            },
        );
        &_manage_redirect_poll_job($job_id, $instance_id);
    }
    elsif ($action eq 'reinstall') {
        # Modded MC: wipe serverfiles + Java + loader (not LGSM install).
        # Vanilla/Paper and non-MC keep SteamCMD/LGSM reinstall below.
        my (undef, $re_script, $re_dir) = _parse_script_info($inst);
        my $re_profile = ($re_dir && &is_minecraft_game($re_script // ''))
            ? &read_mc_profile($re_dir) : undef;
        if (&mc_reinstall_uses_loader_chain($re_profile)) {
            &_manage_redirect_if_job_running($instance_id, 'reinstall');
            my $lgsm_script = $re_profile->{'lgsm_script'} // $re_script;
            $lgsm_script =~ s/[^a-zA-Z0-9_-]//g;
            my $job_id = &_manage_launch_background_job(
                $instance_id, 'reinstall', $unix_user,
                sub {
                    my ($jid) = @_;
                    return &user_worker_launch_cmd(
                        unix_user   => $unix_user,
                        module_root => $module_root,
                        worker      => "$module_root/scripts/mc_reinstall_user.sh",
                        args        => [ &_job_dir($jid), $unix_user, $re_dir, $lgsm_script ],
                    );
                },
            );
            &_manage_redirect_poll_job($job_id, $instance_id, next_status => 'installed');
        }
        my $source = $effective_source;
        my $job_id;
        if ($source eq 'steamcmd') {
            $job_id = _enqueue_install_game_job($instance_id, $inst, $unix_user, {
                job_action => 'reinstall',
                preclean   => 1,
            });
        } else {
            my $script_name = (split('/', $inst->{'script'}))[-1];
            (my $server_dir = $inst->{'script'}) =~ s|/[^/]+$||;
            $script_name =~ s/[^a-zA-Z0-9_-]//g;
            my $worker = "$module_root/scripts/game_action_user.sh";
            $job_id = &_manage_launch_background_job(
                $instance_id, 'reinstall', $unix_user,
                sub {
                    my ($jid) = @_;
                    my $job_dir = _shell_safe_job_dir($jid);
                    return &user_worker_launch_cmd(
                        unix_user   => $unix_user,
                        module_root => $module_root,
                        worker      => $worker,
                        args        => [ $job_dir, $unix_user, $server_dir, $script_name, 'reinstall' ],
                    );
                },
            );
        }
        &_manage_redirect_poll_job($job_id, $instance_id);
    }
    elsif ($action eq 'abort_job') {
        my $job_id = $in{'job'} // '';
        $job_id =~ s/[^0-9a-f]//g;
        $job_id = substr($job_id, 0, 16);
        $job_id or &error($text{'err_invalid_input'});
        my $jmeta = &get_job_meta($job_id);
        my $juser = $jmeta->{'unix_user'} // $unix_user;
        &append_job_log_line($job_id, '=== Job aborted by user (Webmin) ===', $juser);
        &abort_job($job_id);
        &log_action('job_aborted', $job_id, {instance_id => $instance_id});
        &module_config_flash_mark("jobabort_$job_id")
            or &error($text{'manage_job_launch_failed'} || 'Job abort failed.');
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id)
            . "&xnavigation=1&job_aborted=" . &html_escape($job_id));
        exit;
    }
    elsif ($action eq 'init_game_config') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        my $script_dir  = $inst->{'script'};
        $script_dir =~ s|/[^/]+$||;
        my %cfg_ctx  = &_parse_lgsm_config($script_dir, $script_name);
        my $hint     = &get_game_config_path($script_name);
        my $cfg_path = &resolve_game_server_config_path($script_dir, $script_name, \%cfg_ctx, $hint);
        $cfg_path = &validate_game_config_path($script_dir, $cfg_path) if $cfg_path ne '';

        # Bootstrap is only safe for LGSM scripts (which return immediately).
        # For SteamCMD/Wine games './<script> start' would launch wine in the
        # CGI foreground without monitoring — refuse and tell the user to use
        # the normal Start button (which dispatches via steamcmd_control.sh).
        if ($effective_source eq 'steamcmd') {
            &error($text{'config_editor_game_missing_steamcmd'}
                || $text{'config_editor_game_missing'});
        }

        unless (-f $cfg_path) {
            &_manage_dispatch_game_config_bootstrap($instance_id, $inst, $unix_user);
        }

        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) .
                  "&config_file=game&config_view=game&xnavigation=1");
        exit;
    }
    elsif ($action eq 'start' || $action eq 'stop' || $action eq 'restart') {
        &_manage_redirect_if_job_running($instance_id, $action);
        my $source = $effective_source;
        my ($script_path, $script_name, $server_dir) = _parse_script_info($inst);

        if ($action eq 'start' && &is_minecraft_game($script_name)) {
            my $profile = &read_mc_profile($server_dir);
            &error($text{'mc_eula_required'} || 'Die Minecraft EULA muss im Wizard bestätigt werden.')
                unless &mc_profile_has_eula_acceptance($profile);
            &ensure_mc_eula_file($server_dir, $unix_user)
                or &error($text{'mc_eula_write_failed'} || 'eula.txt konnte nicht geschrieben werden.');
            my $pending = $profile ? &mc_pending_setup_steps($profile, $server_dir) : [];
            if (@$pending) {
                &error($text{'mc_setup_incomplete_start'}
                    || 'Server-Setup unvollständig — bitte zuerst Java/Mod-Loader installieren.');
            }
        }

        if ($source eq 'steamcmd') {
            if ($action eq 'restart' && !_steamcmd_server_binary_exists($server_dir)) {
                &error($text{'err_invalid_action'});
            }
            if ($action eq 'start' && !_steamcmd_server_binary_exists($server_dir)) {
                my $job_id = _enqueue_install_game_job($instance_id, $inst, $unix_user);
                &_manage_redirect_poll_job($job_id, $instance_id, next_status => 'installed', next_action => 'start');
            }
            if ($action eq 'restart') {
                my $job_id = &_manage_launch_background_job(
                    $instance_id, 'restart', $unix_user,
                    sub {
                        my ($jid) = @_;
                        my $job_dir = _shell_safe_job_dir($jid);
                        return &_manage_steamcmd_worker_cmd('restart', $job_dir, $unix_user, $server_dir);
                    },
                );
                $job_id or _manage_job_launch_failed();
                &set_monitor_resume_after_start($server_dir, $config_directory, $instance_id);
                &_rebuild_monitor_cron();
                &_manage_redirect_after_job_launch($job_id, $instance_id,
                    action => 'restart', notice_action => 'restart');
            } else {
            my $job_id = &_manage_launch_background_job(
                $instance_id, $action, $unix_user,
                sub {
                    my ($jid) = @_;
                    my $job_dir = _shell_safe_job_dir($jid);
                    return &_manage_steamcmd_worker_cmd($action, $job_dir, $unix_user, $server_dir);
                },
            );
            $job_id or _manage_job_launch_failed();
            if ($action eq 'stop') {
                &set_monitor_paused($server_dir, $config_directory, $instance_id);
            } else {
                &set_monitor_resume_after_start($server_dir, $config_directory, $instance_id);
            }
            &_rebuild_monitor_cron();
            my %launch_opts = (action => $action);
            &_manage_redirect_after_job_launch($job_id, $instance_id, %launch_opts);
            }
        } else {
            $script_name = _manage_executable_script_name($server_dir, $script_name);
            my $job_id = &_manage_launch_background_job(
                $instance_id, $action, $unix_user,
                sub {
                    my ($jid) = @_;
                    my $job_dir = _shell_safe_job_dir($jid);
                    return &user_worker_launch_cmd(
                        unix_user   => $unix_user,
                        module_root => $module_root,
                        worker      => "$module_root/scripts/game_action_user.sh",
                        args        => [ $job_dir, $unix_user, $server_dir, $script_name, $action ],
                    );
                },
            );
            $job_id or _manage_job_launch_failed();
            if ($action eq 'stop') {
                &set_monitor_paused($server_dir, $config_directory, $instance_id);
            } else {
                &set_monitor_resume_after_start($server_dir, $config_directory, $instance_id);
            }
            &_rebuild_monitor_cron();
            my %launch_opts = (action => $action);
            $launch_opts{'notice_action'} = 'restart' if ($in{'action'} // '') eq 'restart';
            &_manage_redirect_after_job_launch($job_id, $instance_id, %launch_opts);
        }
    }
    elsif ($action eq 'monitor_reset') {
        my (undef, undef, $server_dir) = _parse_script_info($inst);
        &set_monitor_running($server_dir, $config_directory, $instance_id);
        &_rebuild_monitor_cron();
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'monitor_disable') {
        my (undef, undef, $server_dir) = _parse_script_info($inst);
        &set_monitor_disabled($server_dir, $config_directory, $instance_id);
        &_rebuild_monitor_cron();
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'save_schedule') {
        my (undef, undef, $server_dir) = _parse_script_info($inst);
        my $cur = &read_restart_schedule($server_dir);
        my $enabled = &module_config_bool($in{'schedule_enabled'});
        my $time = $in{'schedule_time'} // '04:00';
        $time =~ s/[^0-9:]//g;
        &error($text{'schedule_save_failed'} || 'Schedule could not be saved.')
            unless &validate_schedule_time($time);
        my %new = (
            enabled            => $enabled ? 1 : 0,
            time               => $time,
            last_run           => $cur->{'last_run'} // 0,
            last_skip_at       => $cur->{'last_skip_at'} // 0,
            last_schedule_job  => $cur->{'last_schedule_job'} // '',
        );
        &write_restart_schedule($server_dir, \%new, $unix_user)
            or &error($text{'schedule_save_failed'} || 'Schedule could not be saved.');
        my $verify = &read_restart_schedule($server_dir);
        unless (($verify->{'enabled'} // 0) == ($enabled ? 1 : 0)
            && ($verify->{'time'} // '') eq $time) {
            &error($text{'schedule_save_failed'} || 'Schedule could not be saved.');
        }
        &_rebuild_schedule_cron()
            or &error($text{'schedule_cron_rebuild_failed'} || $text{'schedule_save_failed'});
        &module_config_flash_mark("schedule_save_$instance_id")
            or &error($text{'schedule_save_failed'} || 'Schedule could not be saved.');
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    else {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        my $script_dir  = $inst->{'script'};
        $script_dir =~ s|/[^/]+$||;
        # SteamCMD/Wine games: any action that would shell './<script> $action'
        # is forbidden. The wrapper would launch wine in the CGI foreground and
        # never escape the request lifetime cleanly. Force users through the
        # explicit start/stop dispatch (which uses steamcmd_control.sh).
        if ($effective_source eq 'steamcmd') {
            &error($text{'err_invalid_action'} . " ($action)");
        }
        &_manage_run_server_action($unix_user, $action, $script_name, $script_dir);
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
}

# GET: poll_job
if (($in{'action'} // '') eq 'poll_job') {
    my $job_id = $in{'job'} // '';
    $job_id =~ s/[^0-9a-f]//g;
    $job_id = substr($job_id, 0, 16);
    my $next_status = $in{'next_status'} // '';
    $next_status =~ s/[^a-z_]//g;
    my $next_action = $in{'next_action'} // '';
    $next_action =~ s/[^a-z_]//g;

    &timeout_check_job($job_id);
    &validate_job_for_instance($job_id, $instance_id)
        or &error($text{'err_not_found'});
    my $status = &get_job_status($job_id) // 'unknown';
    my $all_out = &get_job_output_display($job_id);

    my $json_poll = (($in{'poll_format'} // '') eq 'json');

    # JSON polls must return before on_ok redirect (job_live.cgi fetch).
    if ($json_poll) {
        if ($status eq 'ok') {
            my $apply_status = $next_status;
            unless ($apply_status) {
                my $meta = &get_job_meta($job_id);
                $apply_status = _manage_next_status_for_action($meta->{'action'});
            }
            &set_instance_status($instance_id, $apply_status) if $apply_status;
        }
        if (($in{'mark_result'} // '') eq '1' && $status =~ /^(?:ok|failed|aborted)$/) {
            &_manage_job_result_flash_mark($job_id);
        }
        my $notice_action = $in{'notice_action'} // '';
        $notice_action =~ s/[^a-z_]//g;
        &_manage_poll_job_json($job_id, $status, $all_out,
            silent            => (($in{'silent'} // '') eq '1'),
            notice_action     => $notice_action,
            inst              => $inst,
            effective_source  => $effective_source,
        );
    }

    if ($status eq 'ok' && !$json_poll) {
        unless ($next_status) {
            my $meta = &get_job_meta($job_id);
            $next_status = _manage_next_status_for_action($meta->{'action'});
        }
        &_manage_poll_job_on_ok($instance_id, $inst, $unix_user, $next_status, $next_action);
    }
    if (($in{'poll_partial'} // '') eq '1') {
        &_manage_poll_job_partial($status, $all_out);
    }

    if ($status eq 'ok') {
        &_manage_job_result_flash_mark($job_id);
        &redirect(_manage_poll_job_instance_url($instance_id)
            . "&action_result=" . &html_escape($job_id));
        exit;
    }

    my $poll_q = "manage.cgi?instance_id=$instance_id&action=poll_job&job=$job_id"
        . ($next_status ? "&next_status=$next_status" : '')
        . ($next_action ? "&next_action=$next_action" : '');
    my $poll_json_path    = _manage_poll_job_module_path("${poll_q}&poll_format=json");
    my $poll_refresh_path = _manage_poll_job_module_path("${poll_q}&xnavigation=1");
    my $manage_path       = _manage_poll_job_module_path("manage.cgi?instance_id=$instance_id&xnavigation=1");
    my $job_dir_path    = &_job_dir($job_id);
    my $xterm_url       = _manage_xterm_job_dir_url($job_dir_path);

    &header($text{'job_output_title'}, '');
    print &job_log_view_page_css();
    print &job_log_view_page_open('fill');
    print &job_log_view_toolbar_open();
    if (($in{'job_live_fallback'} // '') eq '1') {
        print "<p style=\"color:orange\"><strong>"
            . &html_escape($text{'job_live_fallback'}) . "</strong></p>\n";
        print "<p><a href=\"integrations.cgi?xnavigation=1#live_log\">"
            . &html_escape($text{'job_live_ws_setup_hint'}) . "</a></p>\n";
    }
    print "<h3 style=\"margin-top:0\">" . &html_escape($text{'job_output_title'}) . "</h3>\n";

    if ($status eq 'running') {
        print "<p id=\"job_status\"><span class=\"lgsm-job-pulse\" aria-hidden=\"true\"></span>"
            . &html_escape($text{'job_running'}) . "</p>\n";
        print "<p id=\"job_poll_hint\"><small><i>"
            . &html_escape($text{'job_poll_updating'} || 'Ausgabe wird aktualisiert…')
            . "</i></small></p>\n";
        if ($xterm_url) {
            print "<p><a href=\"" . &html_escape($xterm_url)
                . "\" target=\"_blank\" rel=\"noopener\">"
                . &html_escape($text{'job_open_terminal'} || 'Im Webmin-Terminal öffnen')
                . "</a><br><small>"
                . &html_escape($text{'job_terminal_tail_hint'}
                    || 'Startet im Job-Ordner — dort: tail -f output für Live-Log wie htop.')
                . "</small></p>\n";
        }
        print &ui_form_start('manage.cgi', 'get');
        print &ui_hidden('instance_id', &html_escape($instance_id));
        print &ui_hidden('xnavigation', '1');
        print &ui_submit($text{'job_back_to_instance'} || 'Zur Instanz', undef, undef, undef, 'btn-default');
        print &ui_form_end();
        print &ui_form_start('manage.cgi', 'post', undef,
            "onsubmit=\"return confirm('" . &html_escape($text{'jobs_abort_confirm'} || 'Abbrechen?') . "')\"");
        print &ui_hidden('instance_id', &html_escape($instance_id));
        print &ui_hidden('xnavigation', '1');
        print &ui_hidden('action', 'abort_job');
        print &ui_hidden('job', &html_escape($job_id));
        print &ui_submit($text{'jobs_abort_btn'} || 'Abbrechen', undef, undef, undef, 'btn-danger');
        print &ui_form_end();
    } else {
        my $hint_key = &get_job_error_hint($job_id);
        print "<p id=\"job_status\" style='color:red'>" . &html_escape($text{'job_failed'}) . "</p>\n";
        if ($hint_key) {
            print "<p><strong>" . &html_escape($text{'job_hint_title'}) . ":</strong> "
                . &html_escape($text{$hint_key} // $hint_key) . "</p>\n";
        }
        my $jmeta_fail = &get_job_meta($job_id);
        if (($jmeta_fail->{'action'} // '') eq 'modpack_import') {
            my (undef, undef, $sd_poll) = _parse_script_info($inst);
            my ($ok_res, undef) = &modpack_job_resumable(
                &_job_dir($job_id), $sd_poll, $status, $jmeta_fail->{'action'} // '');
            if ($ok_res) {
                my $mods_url = "mods.cgi?instance_id=" . &html_escape($instance_id)
                    . "&xnavigation=1";
                print "<p><a href=\"" . $mods_url . "\">"
                    . &html_escape($text{'manage_mods_page_btn'} || 'Open mods page')
                    . "</a></p>\n";
            }
        }
        print &ui_form_start('manage.cgi', 'get');
        print &ui_hidden('instance_id', &html_escape($instance_id));
        print &ui_hidden('xnavigation', '1');
        print &ui_submit($text{'job_back_to_instance'} || 'Zur Instanz', undef, undef, undef, 'btn-primary');
        print &ui_form_end();
    }
    print &job_log_view_toolbar_close();

    print &job_log_view_block(
        defined $all_out && $all_out ne '' ? $all_out : '', id => 'job_out', live => 1);
    print &job_log_view_page_close();
    print &job_log_live_page_js();

    if ($status eq 'running') {
        print &job_log_live_poll_client_js(
            poll_url             => $poll_json_path,
            manage_url           => $manage_path,
            refresh_url          => $poll_refresh_path,
            out_id               => 'job_out',
            status_id            => 'job_status',
            hint_id              => 'job_poll_hint',
            wait_msg             => $text{'job_waiting_output'} || 'Warte auf Worker-Ausgabe…',
            ok_msg               => $text{'job_ok'},
            fail_msg             => $text{'job_failed'},
            running_msg          => $text{'job_running'},
            fallback_msg         => $text{'job_poll_fallback'} || 'Fallback: Seiten-Refresh…',
            poll_interval        => 2000,
            redirect_delay       => 800,
            enable_meta_fallback => 1,
        );
    }
    &footer('', '');
    exit;
}

# GET: monitor
if (($in{'action'} // '') eq 'monitor') {
    my $script_name = (split('/', $inst->{'script'}))[-1] // '';
    (my $script_dir = $inst->{'script'}) =~ s|/[^/]+$||;
    my $source = _effective_instance_source($inst);
    my ($mc_prof) = _manage_read_mc_profile($inst);
    my $is_mc = ($mc_prof ? 1 : 0)
        || (&is_minecraft_game($script_name) ? 1 : 0)
        || (-d "$script_dir/serverfiles/logs" ? 1 : 0);

    my @log_candidates = grep { -f $_ } server_log_candidates(
        server_dir  => $script_dir,
        script_name => $script_name,
        source      => $source,
        minecraft   => $is_mc,
    );
    my $log_file = server_log_resolve_pick($in{'log_file'}, \@log_candidates);
    $log_file = $log_candidates[0] if $log_file eq '' && @log_candidates;
    my $log_base = $log_file ne '' ? basename($log_file) : '';
    my $auto_refresh = (($in{'auto_refresh'} // '') eq '1' && ($in{'manual'} // '') eq '1') ? 1 : 0;

    &header($text{'manage_monitor_title'}, '');
    print &job_log_view_page_css();
    print &job_log_view_page_open();
    print "<h3>" . &html_escape($text{'manage_monitor_title'}) . "</h3>\n";
    print &job_log_view_toolbar_open();
    print &ui_form_start('manage.cgi', 'get');
    print &ui_hidden('instance_id', &html_escape($instance_id));
    print &ui_hidden('action', 'monitor');
    print &ui_hidden('xnavigation', '1');
    print &ui_hidden('manual', '1');
    if (@log_candidates > 1) {
        my (%seen_bn, @opts);
        for my $p (@log_candidates) {
            my $bn = basename($p);
            next if $seen_bn{$bn}++;
            my $label = $bn;
            $label .= ' [gz]' if $bn =~ /\.gz$/i;
            push @opts, [ $bn, $label ];
        }
        print &html_escape($text{'manage_monitor_log_pick_label'} || 'Log file') . ': ';
        print &ui_select('log_file', $log_base, \@opts);
        print " ";
    } elsif ($log_base ne '') {
        print &ui_hidden('log_file', &html_escape($log_base));
    }
    print &ui_checkbox('auto_refresh', 1, $text{'manage_monitor_auto_label'}, $auto_refresh);
    print " ";
    print &ui_submit($text{'manage_monitor_refresh_btn'}, undef, undef, undef, 'btn-default');
    print &ui_form_end();
    print &ui_form_start('manage.cgi', 'get');
    print &ui_hidden('instance_id', &html_escape($instance_id));
    print &ui_hidden('xnavigation', '1');
    print &ui_submit($text{'manage_monitor_back_btn'} || 'Back to instance',
        undef, undef, undef, 'btn-default');
    print &ui_form_end();
    print &job_log_view_toolbar_close();

    if (!$log_file) {
        print "<p>" . &html_escape($text{'manage_monitor_no_log'}) . "</p>\n";
    } else {
        my $log_dir  = dirname($log_file);
        my $enc_dir  = _filemin_path_urlencode($log_dir);
        my $enc_file = _filemin_path_urlencode($log_base);
        my $href_edit = "/filemin/edit_file.cgi?path=$enc_dir&file=$enc_file";
        my $href_dl   = "/filemin/download.cgi?path=$enc_dir&file=$enc_file";
        my $href_dir  = "/filemin/?path=$enc_dir";
        my $hint = $text{'manage_monitor_filemin_hint'}
            || 'Open folder lists the log directory; use Download for very large files.';
        print "<p><small>" . &html_escape($text{'manage_monitor_shown_file'} || 'Logdatei')
            . ": <code>" . &html_escape($log_file) . "</code><br>\n";
        if ($log_base !~ /\.gz$/i) {
            print "<a href=\"" . &html_escape($href_edit)
                . "\" target=\"_blank\" rel=\"noopener noreferrer\">"
                . &html_escape($text{'manage_monitor_log_edit'} || 'View in file manager')
                . "</a> - ";
        }
        print "<a href=\"" . &html_escape($href_dl)
            . "\" target=\"_blank\" rel=\"noopener noreferrer\">"
            . &html_escape($text{'manage_monitor_log_download'} || 'Download full log')
            . "</a> - ";
        print "<a href=\"" . &html_escape($href_dir)
            . "\" target=\"_blank\" rel=\"noopener noreferrer\">"
            . &html_escape($text{'manage_monitor_log_folder'} || 'Open log folder')
            . "</a><br>\n";
        print &html_escape($hint) . "</small></p>\n";
        if ($log_base =~ /\.gz$/i) {
            print "<p><small>" . &html_escape($text{'manage_monitor_log_gzip_note'}
                || 'This file is gzip-compressed and is shown decompressed here.')
                . "</small></p>\n";
        }
        my $tail = server_log_read_tail($log_file, 8192);
        if (!defined $tail) {
            print "<p>" . &html_escape($text{'manage_monitor_no_log'}) . "</p>\n";
        } else {
            if (server_log_looks_binary($tail)) {
                print "<p>" . &html_escape($text{'manage_monitor_log_binary_warn'}
                    || 'File looks binary.') . "</p>\n";
            }
            my $refresh_url = "manage.cgi?instance_id=" . &html_escape($instance_id)
                . "&action=monitor&xnavigation=1&auto_refresh=1&manual=1"
                . ($log_base ne '' ? "&log_file=" . &urlize($log_base) : '');
            if ($auto_refresh) {
                print "<meta http-equiv=\"refresh\" content=\"2;url=$refresh_url\">\n";
            }
            print &job_log_view_block($tail, id => 'monitor_log');
        }
    }
    print &job_log_view_page_close();
    &footer('', '');
    exit;
}

# Modpack-first chain: after verified provision_deps success, auto-start stashed import.
if (!&user_is_readonly($instance_id)) {
    my $chain_job = $in{'action_result'} // '';
    $chain_job =~ s/[^0-9a-f]//g;
    $chain_job = substr($chain_job, 0, 16);
    if ($chain_job ne '' && &validate_job_for_instance($chain_job, $instance_id)) {
        my $chain_meta = &get_job_meta($chain_job);
        my $chain_st   = &get_job_status($chain_job) // '';
        if ($chain_st eq 'ok' && ($chain_meta->{'action'} // '') eq 'provision_deps') {
            &_manage_maybe_launch_pending_modpack($instance_id, $inst, $unix_user);
        }
    }
}

# Setup-Phase for fresh/lgsm_ready/mc_ready instances
if ($is_fresh) {
    my $istatus = $inst->{'instance_status'} // 'fresh';
    my $source  = _effective_instance_source($inst);
    my ($mc_prof, $server_dir_setup) = _manage_read_mc_profile($inst);
    my $reg = &get_registered_instance($instance_id);
    my $cached_game = $reg->{'cached_game'} // '';
    &header($text{'setup_phase_title'}, '');
    print "<h3>" . &html_escape($text{'setup_phase_title'}) . "</h3>\n";

    if ($mc_prof) {
        print "<p><strong>" . &html_escape($text{'mc_profile_section'}) . ":</strong> "
            . &html_escape(&mc_loader_label($mc_prof->{'loader'}, $current_lang // 'de'))
            . " / " . &html_escape($mc_prof->{'mc_version'} // '')
            . " / Java " . int($mc_prof->{'java_major'} // 0) . "</p>\n";
    } elsif ($cached_game && &is_minecraft_game($cached_game)) {
        print "<p style='color:#b45309'>&#x26A0; "
            . &html_escape($text{'setup_mc_profile_missing'}) . "</p>\n";
    }

    my $modded = $mc_prof && &mc_loader_is_modded($mc_prof->{'loader'} // '');

    &_manage_render_active_job_notice($instance_id);

    if ($source eq 'steamcmd') {
        print &ui_form_start('manage.cgi', 'post');
        print &ui_hidden('instance_id', &html_escape($instance_id));
        print &ui_hidden('action', 'install_game');
        print &ui_submit($text{'setup_install_game_btn'} || 'Spiel installieren', undef, undef, undef, 'btn-primary');
        print &ui_form_end();
    } elsif ($istatus eq 'fresh') {
        print "<ol>\n";
        print "<li>" . &html_escape($text{'setup_step_lgsm'}) . " — "
            . &html_escape($text{'setup_step_pending'}) . "</li>\n";
        if ($modded) {
            print "<li>" . &html_escape($text{'setup_step_java'}) . "</li>\n";
            print "<li>" . &html_escape($text{'setup_step_loader'}) . "</li>\n";
        } elsif ($mc_prof) {
            print "<li>" . &html_escape($text{'setup_step_java'}) . "</li>\n";
            print "<li>" . &html_escape($text{'setup_step_install_game'}) . "</li>\n";
        }
        print "</ol>\n";
        unless (&_manage_setup_action_running($instance_id, 'setup_lgsm')) {
            print &ui_form_start('manage.cgi', 'post');
            print &ui_hidden('instance_id', &html_escape($instance_id));
            print &ui_hidden('action', 'setup_lgsm');
            print &ui_submit($text{'setup_install_lgsm_btn'}, undef, undef, undef, 'btn-primary');
            print &ui_form_end();
        }
    } elsif ($istatus eq 'lgsm_ready') {
        print "<ol>\n";
        print "<li>&#x2705; " . &html_escape($text{'setup_step_lgsm'}) . "</li>\n";
        if ($modded) {
            print "<li>" . &html_escape($text{'setup_step_java'}) . " — "
                . &html_escape($text{'setup_step_next'}) . "</li>\n";
            print "<li>" . &html_escape($text{'setup_step_loader'}) . "</li>\n";
        } elsif ($mc_prof) {
            print "<li>" . &html_escape($text{'setup_step_java'}) . " — "
                . &html_escape($text{'setup_step_next'}) . "</li>\n";
            print "<li>" . &html_escape($text{'setup_step_install_game'}) . "</li>\n";
        } else {
            print "<li>" . &html_escape($text{'setup_step_install_game'}) . " — "
                . &html_escape($text{'setup_step_next'}) . "</li>\n";
        }
        print "</ol>\n";
        if ($mc_prof && !&_manage_setup_action_running($instance_id, 'mc_java_setup')) {
            print &ui_form_start('manage.cgi', 'post');
            print &ui_hidden('instance_id', &html_escape($instance_id));
            print &ui_hidden('action', 'mc_java_setup');
            print &ui_submit($text{'mc_setup_java_btn'}, undef, undef, undef, 'btn-primary');
            print &ui_form_end();
        } elsif (!$mc_prof && !&_manage_setup_action_running($instance_id, 'install_game')) {
            print &ui_form_start('manage.cgi', 'post');
            print &ui_hidden('instance_id', &html_escape($instance_id));
            print &ui_hidden('action', 'install_game');
            print &ui_submit($text{'setup_install_game_btn'}, undef, undef, undef, 'btn-primary');
            print &ui_form_end();
        }
    } elsif ($istatus eq 'mc_ready') {
        print "<ol>\n";
        print "<li>&#x2705; " . &html_escape($text{'setup_step_lgsm'}) . "</li>\n";
        print "<li>&#x2705; " . &html_escape($text{'setup_step_java'}) . "</li>\n";
        if ($modded) {
            print "<li>" . &html_escape($text{'setup_step_loader'}) . " — "
                . &html_escape($text{'setup_step_next'}) . "</li>\n";
        } else {
            print "<li>" . &html_escape($text{'setup_step_install_game'}) . " — "
                . &html_escape($text{'setup_step_next'}) . "</li>\n";
        }
        print "</ol>\n";
        &_manage_render_active_job_notice($instance_id);
        if ($modded) {
            print &ui_form_start('manage.cgi', 'post');
            print &ui_hidden('instance_id', &html_escape($instance_id));
            print &ui_hidden('action', 'mc_loader_setup');
            print &ui_submit($text{'mc_setup_loader_btn'}, undef, undef, undef, 'btn-primary');
            print &ui_form_end();
        } elsif (!$modded) {
            print &ui_form_start('manage.cgi', 'post');
            print &ui_hidden('instance_id', &html_escape($instance_id));
            print &ui_hidden('action', 'install_game');
            print &ui_submit($text{'setup_install_game_btn'}, undef, undef, undef, 'btn-primary');
            print &ui_form_end();
        }
    }

    unless (&user_is_readonly($instance_id)) {
        &_manage_render_instance_jobs_table($instance_id, 5);
        &_manage_render_mods_page_link($inst, $instance_id);
    }

    &footer('', '');
    exit;
}

my $safe_id = &html_escape($instance_id);
&header("$text{'manage_title'}: $safe_id", '');

my $action_result_job = $in{'action_result'} // '';
$action_result_job =~ s/[^0-9a-f]//g;
$action_result_job = substr($action_result_job, 0, 16);
if ($action_result_job ne '' && &_manage_job_result_flash_consume($action_result_job)) {
    if (&validate_job_for_instance($action_result_job, $instance_id)) {
        my $result_status = &get_job_status($action_result_job) // 'unknown';
        my $notice_action = $in{'notice_action'} // '';
        $notice_action =~ s/[^a-z_]//g;
        unless ($notice_action) {
            my $meta = &get_job_meta($action_result_job);
            $notice_action = $meta->{'action'} // '';
            $notice_action =~ s/[^a-z_]//g;
        }
        my $msg = _manage_action_result_text($notice_action, $result_status);
        if ($result_status eq 'ok') {
            print "<div class='alert alert-success'>" . &html_escape($msg) . "</div>\n";
        } else {
            print "<div class='alert alert-danger'>" . &html_escape($msg) . "</div>\n";
        }
    }
}

my $job_aborted_id = $in{'job_aborted'} // '';
$job_aborted_id =~ s/[^0-9a-f]//g;
$job_aborted_id = substr($job_aborted_id, 0, 16);
if ($job_aborted_id ne ''
    && &module_config_flash_consume("jobabort_$job_aborted_id")
    && &validate_job_for_instance($job_aborted_id, $instance_id)) {
    print "<div class='alert alert-info'>"
        . &html_escape($text{'job_aborted_ok'} || 'Job abgebrochen.')
        . "</div>\n";
}

{
    my $flash_id = $instance_id // '';
    $flash_id =~ s/[^a-zA-Z0-9_-]//g;
    if ($flash_id ne '' && &module_config_flash_consume("monitor_restart_$flash_id")) {
        my $sd_flash = $inst->{'script'} // '';
        $sd_flash =~ s|/[^/]+$||;
        &sync_monitor_job_pointers();
        my $mon_flash = &read_monitor_state($sd_flash, $config_directory, $instance_id);
        my $lr_ts = &monitor_format_restart_time($mon_flash->{'last_restart_at'});
        $lr_ts = '—' unless $lr_ts ne '';
        my $banner = &text('manage_monitor_restart_banner', $lr_ts);
        $banner = "Der Server wurde automatisch durch Monitoring neugestartet ($lr_ts)."
            unless defined $banner && $banner =~ /\S/;
        my $banner_html = &html_escape($banner);
        my $lr_job = $mon_flash->{'last_restart_job'} // '';
        $lr_job =~ s/[^0-9a-f]//g;
        if (length($lr_job) == 16) {
            my $log_url = "jobs.cgi?action=view_output&amp;job_id="
                . &html_escape($lr_job);
            $banner_html .= ' <a href="' . $log_url . '">'
                . &html_escape($text{'jobs_view_log'} || 'Log') . '</a>';
        }
        print "<div class='alert alert-success'>" . $banner_html . "</div>\n";
    }
    if ($flash_id ne '' && &module_config_flash_consume("schedule_save_$flash_id")) {
        print "<div class='alert alert-success'>"
            . &html_escape($text{'schedule_saved_ok'} || 'Geplanter Neustart gespeichert.')
            . "</div>\n";
    }
}

my $silent_job_id = $in{'silent_job'} // '';
$silent_job_id =~ s/[^0-9a-f]//g;
$silent_job_id = substr($silent_job_id, 0, 16);
my $silent_polling = ($silent_job_id ne '');
unless ($silent_polling) {
    unless (&user_is_readonly($instance_id)) {
        &_manage_render_active_job_notice($instance_id);
    }
} else {
    my %silent_opts;
    my $na = $in{'notice_action'} // '';
    $na =~ s/[^a-z_]//g;
    $silent_opts{'notice_action'} = $na if $na ne '';
    my $ns = $in{'next_status'} // '';
    $ns =~ s/[^a-z_]//g;
    $silent_opts{'next_status'} = $ns if $ns ne '';
    my $nact = $in{'next_action'} // '';
    $nact =~ s/[^a-z_]//g;
    $silent_opts{'next_action'} = $nact if $nact ne '';
    &_manage_render_silent_job_poll($instance_id, $silent_job_id, %silent_opts);
}

# Parse LGSM config to check _has_user_config
my $script_dir_for_cfg = $inst->{'script'};
$script_dir_for_cfg =~ s|/[^/]+$||;
my $script_name_for_cfg = (split('/', $inst->{'script'}))[-1];
my %cfg = &_parse_lgsm_config($script_dir_for_cfg, $script_name_for_cfg);
my $source_for_status = $effective_source;
my $runtime_status = _manage_runtime_status($inst, $source_for_status, light => 1);

# Server-Info table
print &ui_table_start($text{'manage_title'}, "width=100%", 2);
print &ui_table_row($text{'manage_game'},   &html_escape($inst->{'game'}));
my (undef, undef, $server_dir_info) = _parse_script_info($inst);
if ($server_dir_info) {
    my $mc_info = &read_mc_profile($server_dir_info);
    if ($mc_info) {
        print &ui_table_row($text{'mc_profile_loader'},
            &html_escape(&mc_loader_label($mc_info->{'loader'}, $current_lang // 'de')));
        print &ui_table_row($text{'mc_profile_version'}, &html_escape($mc_info->{'mc_version'} // ''));
        if ($mc_info->{'loader_version'}) {
            print &ui_table_row($text{'mc_profile_loader_version'},
                &html_escape($mc_info->{'loader_version'}));
        } elsif (&mc_loader_is_modded($mc_info->{'loader'} // '')) {
            print &ui_table_row($text{'mc_profile_loader_version'},
                &html_escape($text{'mc_loader_version_auto'} || 'Automatisch (neueste stabile)'));
        }
        print &ui_table_row($text{'mc_profile_java'}, 'Java ' . int($mc_info->{'java_major'} // 0));
    }
}
# Show every port-typed field so the user sees the full game/query/beacon set
# for multi-port games (UE5). Single-port games still render as one row.
my $info_ports = _collect_instance_ports($script_name_for_cfg, \%cfg);
if (@$info_ports == 1) {
    print &ui_table_row($text{'manage_port'}, $info_ports->[0]{port});
} else {
    for my $p (@$info_ports) {
        print &ui_table_row(&html_escape($p->{label}), $p->{port});
    }
}
{
    my $game_port = 0;
    if (@$info_ports) {
        my ($main) = grep { ($_->{key} // '') eq 'port' } @$info_ports;
        $game_port = $main ? int($main->{port}) : int($info_ports->[0]{port});
    }
    my $connect = &instance_direct_connect_endpoint(\%cfg, $game_port);
    if ($connect ne '') {
        print &ui_table_row(
            $text{'manage_direct_connect'},
            '<code>' . &html_escape($connect) . '</code>',
        );
    }
}
print &ui_table_row($text{'manage_status'},
    "<span id=\"manage_runtime_status\">" . _runtime_status_badge_html($runtime_status) . "</span>");
my $mon_state;
{
    &sync_monitor_job_pointers();
    $mon_state = &read_monitor_state($script_dir_for_cfg, $config_directory, $instance_id);
}
my $mon_status_key = 'monitor_status_' . ($mon_state->{'status'} // 'running');
my $mon_label = $text{$mon_status_key} || $mon_state->{'status'};
print &ui_table_row($text{'monitor_col'}, &html_escape($mon_label));
if (($mon_state->{'last_restart_at'} // 0) > 0) {
    my $lr_html = &_manage_last_run_row_html(
        $mon_state->{'last_restart_at'}, 'monitor_last_restart',
        $mon_state->{'last_restart_job'}, $instance_id);
    print &ui_table_row($text{'monitor_last_restart_col'}, $lr_html);
}

if ($runtime_status eq 'online' || $runtime_status eq 'running') {
    my $mem_gb = &instance_memory_display_gb($inst->{'user'} // '');
    if ($mem_gb ne '') {
        print &ui_table_row($text{'manage_memory'}, &html_escape($mem_gb));
    }
    my $qfield = &get_game_query_port_field($script_name_for_cfg);
    if ($qfield) {
        my $qport = int($cfg{$qfield} // 0);
        if ($qport > 0) {
            my $qdata = &a2s_query('127.0.0.1', $qport, 2);
            if ($qdata) {
                print &ui_table_row(
                    $text{'monitor_players'},
                    &html_escape("$qdata->{players} / $qdata->{max}")
                );
            }
        }
    }
}
print &ui_table_row($text{'manage_script'}, &html_escape($inst->{'script'}));
print &ui_table_end();

# Minecraft setup continuation (also when instance_status=installed but files missing)
{
    my ($mc_setup_prof, $mc_setup_dir) = _manage_read_mc_profile($inst);
    if ($mc_setup_prof) {
        my $pending = &mc_pending_setup_steps($mc_setup_prof, $mc_setup_dir);
        if (@$pending) {
            &_manage_render_active_job_notice($instance_id);
            print "<h3>" . &html_escape($text{'setup_incomplete_title'}) . "</h3>\n";
            print "<ol>\n";
            if (grep { $_ eq 'java' } @$pending) {
                print "<li>" . &html_escape($text{'setup_step_java'}) . " — "
                    . &html_escape($text{'setup_step_next'}) . "</li>\n";
            } else {
                print "<li>&#x2705; " . &html_escape($text{'setup_step_java'}) . "</li>\n";
            }
            if (grep { $_ eq 'loader' } @$pending) {
                print "<li>" . &html_escape($text{'setup_step_loader'}) . " — "
                    . &html_escape($text{'setup_step_next'}) . "</li>\n";
            } elsif (&mc_loader_is_modded($mc_setup_prof->{'loader'} // '')) {
                print "<li>&#x2705; " . &html_escape($text{'setup_step_loader'}) . "</li>\n";
            }
            if (grep { $_ eq 'install' } @$pending) {
                print "<li>" . &html_escape($text{'setup_step_install_game'}) . " — "
                    . &html_escape($text{'setup_step_next'}) . "</li>\n";
            } elsif (&mc_loader_phase1_ready($mc_setup_prof->{'loader'} // '')) {
                print "<li>&#x2705; " . &html_escape($text{'setup_step_install_game'}) . "</li>\n";
            }
            print "</ol>\n";
            if (grep { $_ eq 'java' } @$pending) {
                print &ui_form_start('manage.cgi', 'post');
                print &ui_hidden('instance_id', $safe_id);
                print &ui_hidden('action', 'mc_java_setup');
                print &ui_submit($text{'mc_setup_java_btn'}, undef, undef, undef, 'btn-primary');
                print &ui_form_end();
            } elsif (grep { $_ eq 'loader' } @$pending) {
                print &ui_form_start('manage.cgi', 'post');
                print &ui_hidden('instance_id', $safe_id);
                print &ui_hidden('action', 'mc_loader_setup');
                print &ui_submit($text{'mc_setup_loader_btn'}, undef, undef, undef, 'btn-primary');
                print &ui_form_end();
            } elsif (grep { $_ eq 'install' } @$pending) {
                print &ui_form_start('manage.cgi', 'post');
                print &ui_hidden('instance_id', $safe_id);
                print &ui_hidden('action', 'install_game');
                print &ui_submit($text{'setup_install_game_btn'}, undef, undef, undef, 'btn-primary');
                print &ui_form_end();
            }
            print "<p><small>" . &html_escape($text{'setup_incomplete_hint'}) . "</small></p>\n";
        }
    }
}

# Firewall section — show open/closed status per port. Use AND semantics:
# the toggle button reflects "are *all* ports open?" so a single click can re-open
# a partially closed set.
my $all_open = 1;
for my $p (@$info_ports) {
    $all_open = 0 unless &firewall_status($p->{port});
}
my $fw_open = $all_open;
my $port = $info_ports->[0]{port}; # legacy compat for downstream code paths
my ($fw_status_icon, $fw_btn_action, $fw_btn_label);
if ($fw_open) {
    $fw_status_icon = "&#x2705; offen";
    $fw_btn_action  = 'fw_close';
    $fw_btn_label   = $text{'fw_close_btn'};
} else {
    $fw_status_icon = "&#x274C; geschlossen";
    $fw_btn_action  = 'fw_open';
    $fw_btn_label   = $text{'fw_open_btn'};
}

print "<p><b>$text{'manage_fw_status'}:</b> $fw_status_icon &nbsp;";
print &ui_form_start("manage.cgi", "post");
print &ui_hidden("instance_id", $safe_id);
print &ui_hidden("action", $fw_btn_action);
print &ui_submit($fw_btn_label);
print &ui_form_end();
print "</p>\n";
if ($effective_source eq 'steamcmd' && $script_name_for_cfg eq 'windrose') {
    print "<p><small>" . &html_escape($text{'manage_fw_windrose_ephemeral_hint'}) . "</small></p>\n";
}

if (&user_can_operate($instance_id)) {
    my $mon_s = $mon_state->{'status'} // 'running';
    if ($mon_s eq 'failed' || $mon_s eq 'paused') {
        print &ui_form_start('manage.cgi', 'post');
        print &ui_hidden('instance_id', $safe_id);
        print &ui_hidden('action', 'monitor_reset');
        print &ui_submit($text{'monitor_reset_btn'}, undef, undef, undef, 'btn-success');
        print &ui_form_end();
    }
    if ($mon_s ne 'disabled') {
        print &ui_form_start('manage.cgi', 'post');
        print &ui_hidden('instance_id', $safe_id);
        print &ui_hidden('action', 'monitor_disable');
        print &ui_submit($text{'monitor_disable_btn'}, undef, undef, undef, 'btn-default');
        print &ui_form_end();
    }
    if ($mon_s eq 'disabled') {
        print &ui_form_start('manage.cgi', 'post');
        print &ui_hidden('instance_id', $safe_id);
        print &ui_hidden('action', 'monitor_reset');
        print &ui_submit($text{'monitor_reset_btn'}, undef, undef, undef, 'btn-success');
        print &ui_form_end();
    }

    my $sched = &read_restart_schedule($script_dir_for_cfg);
    my $sched_tz = &schedule_system_timezone();
    $sched_tz = 'localtime' unless defined $sched_tz && $sched_tz ne '';
    print "<h4>" . &html_escape($text{'schedule_title'} || 'Geplanter Neustart') . "</h4>\n";
    print &ui_form_start('manage.cgi', 'post');
    print &ui_hidden('instance_id', $safe_id);
    print &ui_hidden('action', 'save_schedule');
    print &ui_table_start();
    print &ui_table_row(
        $text{'schedule_enabled_label'} || 'Aktiv',
        &ui_checkbox('schedule_enabled', 1,
            $text{'schedule_enabled_hint'} || 'Täglich neu starten', $sched->{'enabled'}),
    );
    print &ui_table_row(
        $text{'schedule_time_label'} || 'Uhrzeit',
        &ui_textbox('schedule_time', $sched->{'time'}, 5, 0, 'placeholder="04:00"'),
    );
    print &ui_table_row(
        $text{'schedule_timezone_label'} || 'Zeitzone',
        &html_escape(&text('schedule_timezone_value', $sched_tz)),
    );
    if (($sched->{'last_run'} // 0) > 0) {
        my $lr_html = &_manage_last_run_row_html(
            $sched->{'last_run'}, 'schedule_last_run',
            $sched->{'last_schedule_job'}, $instance_id);
        print &ui_table_row($text{'schedule_last_run_col'} || 'Letzter Lauf', $lr_html);
    }
    print &ui_table_end();
    print &ui_submit($text{'schedule_save_btn'} || 'Speichern', undef, undef, undef, 'btn-primary');
    print &ui_form_end();
    print "<p><small>" . &html_escape($text{'schedule_skip_hint'}
        || 'Neustart nur wenn der Server online ist; sonst wird übersprungen und protokolliert.')
        . "</small></p>\n";
}

# Control buttons — server group + maintenance row
print "<h4>" . &html_escape($text{'manage_controls_server'}) . "</h4>\n";
print "<div style='margin:4px 0 12px 0'>\n";
foreach my $action (qw(start stop restart)) {
    my $btn_class = ($action eq 'start') ? 'btn-success'
                  : ($action eq 'stop')  ? 'btn-default'
                  :                        'btn-warning';
    my $form = &ui_form_start('manage.cgi', 'post');
    $form .= &ui_hidden('instance_id', $safe_id);
    $form .= &ui_hidden('action', $action);
    $form .= &ui_submit($text{"manage_$action"}, undef, undef, undef, $btn_class);
    $form .= &ui_form_end();
    print &_manage_inline_action_btn($form);
}
print "</div>\n";

print "<h4>" . &html_escape($text{'manage_controls_maintenance'}) . "</h4>\n";
print "<div style='margin:4px 0 12px 0'>\n";
{
    my $form = &ui_form_start('manage.cgi', 'post');
    $form .= &ui_hidden('instance_id', $safe_id);
    $form .= &ui_hidden('action', 'update');
    $form .= &ui_submit($text{'manage_update_btn'}, undef, undef, undef, 'btn-default');
    $form .= &ui_form_end();
    print &_manage_inline_action_btn($form);
}
{
    my $form = &ui_form_start('manage.cgi', 'post');
    $form .= &ui_hidden('instance_id', $safe_id);
    $form .= &ui_hidden('action', 'validate');
    $form .= &ui_submit($text{'manage_validate_btn'}, undef, undef, undef, 'btn-default');
    $form .= &ui_form_end();
    print &_manage_inline_action_btn($form);
}
my $monitor_link = "<a href=\"manage.cgi?instance_id=$safe_id&amp;action=monitor&amp;xnavigation=1\""
    . " class=\"btn btn-default\">" . &html_escape($text{'manage_monitor_btn'}) . "</a>";
print &_manage_inline_action_btn($monitor_link);
{
    my ($re_prof) = _manage_read_mc_profile($inst);
    my $re_confirm = $text{'manage_reinstall_confirm'};
    if (&mc_reinstall_uses_loader_chain($re_prof)) {
        $re_confirm = $text{'manage_reinstall_confirm_modded'}
            || $re_confirm;
    }
    my $re_js = &html_escape($re_confirm);
    $re_js =~ s/'/\\'/g;
    my $form = &ui_form_start('manage.cgi', 'post', undef,
        "onsubmit=\"return confirm('$re_js')\"");
    $form .= &ui_hidden('instance_id', $safe_id);
    $form .= &ui_hidden('action', 'reinstall');
    $form .= &ui_submit($text{'manage_reinstall_btn'}, undef, undef, undef, 'btn-danger');
    $form .= &ui_form_end();
    print &_manage_inline_action_btn($form);
}
print "</div>\n";

# Mods page link (below server controls)
&_manage_render_mods_page_link($inst, $instance_id);

if (&is_admin()) {
    print "<p>\n";
    print &ui_form_start("manage.cgi", "post", undef,
        "onsubmit=\"return confirm('" . &html_escape($text{'manage_delete_confirm'} || 'Instanz wirklich unwiderruflich löschen?') . "')\"");
    print &ui_hidden("instance_id", $safe_id);
    print &ui_hidden("action", "delete_instance");
    print &ui_submit($text{'manage_delete_btn'}, undef, 0, undef, 'btn-danger');
    print &ui_form_end();
    print "</p>\n";
}

# FTP section
{
    my $cur_ftp_user = &resolve_instance_sftp_user($instance_id, $unix_user);
    print "<h3>FTP</h3>\n";
    if ($cur_ftp_user && $cur_ftp_user ne $unix_user) {
        my $stored_pass = &read_ftp_password($config_directory, $instance_id);
        print &ui_table_start('', undef, 2);
        print &ui_table_row($text{'ftp_col_user'}, &html_escape($cur_ftp_user));
        if (defined $stored_pass && $stored_pass ne '') {
            print &ui_table_row($text{'ftp_pass'}, '<code>' . &html_escape($stored_pass) . '</code>');
        }
        print &ui_table_end();
        print &ui_form_start("manage.cgi", "post");
        print &ui_hidden("instance_id", $safe_id);
        print &ui_hidden("action", "delete_instance_ftp_user");
        print &ui_hidden("ftp_user", $cur_ftp_user);
        print &ui_submit($text{'ftp_delete_btn'}, undef, 0, undef, 'btn-danger');
        print &ui_form_end();
    } else {
        my $default_name = &html_escape('ftp_' . $unix_user);
        print &ui_form_start("manage.cgi", "post");
        print &ui_hidden("instance_id", $safe_id);
        print &ui_hidden("action", "create_instance_ftp_user");
        print &ui_table_start('', undef, 2);
        print &ui_table_row($text{'ftp_col_user'}, "<code>$default_name</code>");
        print &ui_table_row($text{'ftp_pass'}, &ui_password('ftp_pass', '', 24));
        print &ui_table_end();
        print &ui_submit($text{'ftp_create_btn'});
        print &ui_form_end();
    }
}

# Steam account section — shown for all servers
{
    my $sa        = $inst->{'steam_account'} // '';
    my $sa_status = $sa ? (&get_steam_account_status($sa) // '') : '';
    my $accounts  = &load_steam_accounts();
    my @ok        = grep { $_->{'status'} eq 'ok' } @$accounts;

    print "<h3>" . &html_escape($text{'steam_manage_section'}) . "</h3>\n";
    print &ui_table_start(undef, undef, 2);

    if ($sa) {
        my $badge = $sa_status eq 'ok'            ? '&#x2705; ' . &html_escape($text{'steam_status_ok'})
                  : $sa_status eq 'token_expired' ? '&#x26A0;&#xFE0F; ' . &html_escape($text{'steam_status_expired'})
                  :                                 '&#x23F3; ' . &html_escape($text{'steam_status_pending'});
        print &ui_table_row(&html_escape($text{'steam_account_label'}), &html_escape($sa) . " \x{2014} " . $badge);
    } else {
        print &ui_table_row(&html_escape($text{'steam_account_label'}), &html_escape($text{'steam_manage_no_account'}));
    }
    print &ui_table_end();

    if (@ok) {
        my @sopts = (['', '— ' . &html_escape($text{'steam_no_account_opt'} || 'Kein Account') . ' —'],
                     map { [$_->{'username'}, &html_escape($_->{'display_name'} || $_->{'username'})] } @ok);
        print &ui_form_start('manage.cgi', 'post');
        print &ui_hidden('action',      'save_steam_account');
        print &ui_hidden('instance_id', &html_escape($instance_id));
        print &ui_select('steam_account', $sa, \@sopts);
        print " ";
        print &ui_submit($text{'acl_manage_save'} || 'Speichern', undef, undef, undef, 'btn-default');
        print &ui_form_end();
    }

    if ($sa && $sa_status ne 'ok') {
        print &ui_form_start('integrations.cgi', 'get');
        print &ui_hidden('action',   'relogin_form');
        print &ui_hidden('instance', &html_escape($instance_id));
        print &ui_submit($text{'steam_relogin_btn'}, undef, undef, undef, 'btn-warning');
        print &ui_form_end();
    }
}

# Detect if common.cfg contains misplaced instance-specific fields
my $common_cfg_path = "$script_dir_for_cfg/lgsm/config-lgsm/common.cfg";
my ($common_chk, undef, undef) = &read_config_file($common_cfg_path);
my %gkeys_chk = map { $_->{'key'} => 1 } &get_game_fields($script_name_for_cfg);
my $has_misplaced = scalar grep { $gkeys_chk{$_} } keys %$common_chk;

# Warnings section
my @warnings = @{$inst->{'warnings'} || []};
if (!$cfg{_has_instance_config}) {
    push @warnings, $text{'manage_fix_config_warn'};
}
if ($has_misplaced) {
    push @warnings, $text{'manage_migrate_warn'};
}

if (@warnings) {
    print "<h3>&#x26A0; $text{'health_warn_header'}</h3>\n";
    print "<ul>\n";
    for my $w (@warnings) {
        print "<li>" . &html_escape($w) . "</li>\n";
    }
    print "</ul>\n";
}

# Migrate-Config form (if game fields are misplaced in common.cfg)
if ($has_misplaced) {
    print &ui_form_start("manage.cgi", "post");
    print &ui_hidden("instance_id", $safe_id);
    print &ui_hidden("action", "migrate_config");
    print &ui_submit($text{'manage_migrate_btn'});
    print &ui_form_end();
}

# Quick-Fix form (only if no real instance config).
# Renders all fields from games_meta.json so multi-port games (UE: port/queryport/beaconport)
# are configurable from a single form. Defaults come from games_meta; user-edited values win.
if (!$cfg{_has_instance_config}) {
    my @qf_fields = &get_game_fields($script_name_for_cfg);
    # Fallback minimal set when no fields are defined (legacy/unknown scripts).
    unless (@qf_fields) {
        @qf_fields = (
            {key => 'port',     type => 'port', label_de => $text{'manage_port'}, label_en => $text{'manage_port'}, default => ''},
            {key => 'gamename', type => 'text', label_de => $text{'manage_game'}, label_en => $text{'manage_game'}, default => ''},
        );
    }
    my $qf_lang = $current_lang // 'en';
    my $prof_over = &get_instance_profile_cfg_overrides($script_name_for_cfg, $script_dir_for_cfg);
    my $mc_prof_qf = &read_mc_profile($script_dir_for_cfg);

    if ($mc_prof_qf && ref($prof_over) eq 'HASH' && keys %$prof_over) {
        print "<h4>" . &html_escape($text{'manage_fix_profile_section'}) . "</h4>\n";
        print &ui_table_start('', undef, 2);
        print &ui_table_row($text{'mc_profile_loader'},
            &html_escape(&mc_loader_label($mc_prof_qf->{'loader'}, $qf_lang)));
        print &ui_table_row($text{'mc_profile_version'},
            &html_escape($mc_prof_qf->{'mc_version'} // ''));
        if ($prof_over->{'serverversion'}) {
            print &ui_table_row($text{'manage_fix_profile_serverversion'},
                '<code>' . &html_escape($prof_over->{'serverversion'}) . '</code>');
        }
        if ($prof_over->{'executable'}) {
            print &ui_table_row($text{'manage_fix_profile_executable'},
                '<code>' . &html_escape($prof_over->{'executable'}) . '</code>');
        }
        print &ui_table_end();
        if (!&mc_loader_phase1_ready($mc_prof_qf->{'loader'} // '')) {
            print "<p><small>" . &html_escape($text{'manage_fix_profile_modded_note'}) . "</small></p>\n";
        } else {
            print "<p><small>" . &html_escape($text{'manage_fix_profile_apply_note'}) . "</small></p>\n";
        }
    }

    print &ui_form_start("manage.cgi", "post");
    print &ui_hidden("instance_id", $safe_id);
    print &ui_hidden("action", "fix_config");
    print &ui_table_start($text{'manage_fix_config_btn'}, undef, 2);
    for my $f (@qf_fields) {
        my $type = $f->{'type'} // 'text';
        next if $type eq 'bool';
        my $key = $f->{'key'};
        my $label = $qf_lang eq 'de' ? ($f->{'label_de'} // $f->{'label_en'} // $key)
                                     : ($f->{'label_en'} // $f->{'label_de'} // $key);
        # Prefill: profile overrides > existing cfg > inst struct > games_meta default.
        my $val = $prof_over->{$key} // $cfg{$key};
        if (!defined $val || $val eq '' || $val eq 'latest') {
            if ($key eq 'port')          { $val = int($inst->{'port'}) || ($f->{'default'} // ''); }
            elsif ($key eq 'gamename')   { $val = (($inst->{'game'} // 'unknown') eq 'unknown') ? ($f->{'default'} // '') : $inst->{'game'}; }
            else                         { $val = $f->{'default'} // ''; }
        }
        print &ui_table_row(&html_escape($label), &ui_textbox($key, $val, 30));
    }
    print &ui_table_end();
    print &ui_submit($text{'manage_fix_config_btn'});
    print &ui_form_end();
}

# Config editor section
{
    my $cfg_file_key = $in{'config_file'} // '';
    $cfg_file_key = ($cfg_file_key eq 'common' || $cfg_file_key eq 'instance' || $cfg_file_key eq 'game')
        ? $cfg_file_key : 'common';
    my $cfg_view_key = $in{'config_view'} // '';
    if ($cfg_view_key ne 'common' && $cfg_view_key ne 'instance' && $cfg_view_key ne 'game') {
        $cfg_view_key = $cfg_file_key;
    }
    my $common_path   = "$script_dir_for_cfg/lgsm/config-lgsm/common.cfg";
    my $instance_path = "$script_dir_for_cfg/lgsm/config-lgsm/$script_name_for_cfg/$script_name_for_cfg.cfg";
    my $game_cfg_hint = &get_game_config_path($script_name_for_cfg);
    my $game_cfg_path = &resolve_game_server_config_path(
        $script_dir_for_cfg, $script_name_for_cfg, \%cfg, $game_cfg_hint);
    if ($game_cfg_path ne '') {
        eval { $game_cfg_path = &validate_game_config_path($script_dir_for_cfg, $game_cfg_path); 1 }
            or do { $game_cfg_path = ''; };
    }
    my $server_root_path = $script_dir_for_cfg;
    my $fileman_path = $server_root_path;
    $fileman_path =~ s/([^A-Za-z0-9\-_.~\/])/sprintf("%%%02X", ord($1))/ge;
    my $fileman_url = "/filemin/?path=$fileman_path";
    my ($common_vals, $common_order, $common_raw) = &read_config_file($common_path);
    my ($inst_vals, $inst_order, $inst_raw) = &read_config_file($instance_path);
    my $game_raw = '';
    my $game_cfg_exists = 0;
    if ($game_cfg_path && -f $game_cfg_path) {
        $game_cfg_exists = 1;
        $game_raw = &read_game_config_raw($game_cfg_path);
    }
    my @game_fields = &get_game_fields($script_name_for_cfg);
    my $profile_name = &get_game_display_name($script_name_for_cfg);

    my $lang = $current_lang // 'en';
    my $game_tab_label = &get_game_config_label($script_name_for_cfg, $lang);
    $game_tab_label = $text{'config_editor_game_btn'} unless $game_tab_label ne '';
    # Open the <details> block when the user navigated to the editor
    my $open_attr = defined($in{'config_file'}) ? ' open' : '';

    print "<details$open_attr>\n";
    print "<summary><b>$text{'config_editor_title'}</b></summary>\n";
    print "<p>" . &html_escape($text{'config_editor_profile'}) . " <b>" .
          &html_escape($profile_name) . "</b> " .
          &html_escape($text{'config_editor_profile_source'}) .
          " <code>src/lib/games_meta.json</code></p>\n";
    print "<p><b>" . &html_escape($text{'config_editor_common_path'}) . "</b> <code>" .
          &html_escape($common_path) . "</code><br>\n";
    print "<b>" . &html_escape($text{'config_editor_instance_path'}) . "</b> <code>" .
          &html_escape($instance_path) . "</code><br>\n";
    print "<b>" . &html_escape($text{'config_editor_game_path'}) . "</b> <code>" .
          &html_escape($game_cfg_path) . "</code><br>\n";
    print "<b>" . &html_escape($text{'config_editor_server_root'}) . "</b> <code>" .
          &html_escape($server_root_path) . "</code> &nbsp;" .
          "<a href='" . &html_escape($fileman_url) . "'>" .
          &html_escape($text{'config_editor_open_fileman'}) . "</a></p>\n";

    print <<'JS';
<script>
function lgsmShowConfigView(view) {
    var views = ['common', 'instance', 'game'];
    for (var i = 0; i < views.length; i++) {
        var id = views[i];
        var panel = document.getElementById('cfg_panel_' + id);
        var btn = document.getElementById('cfg_btn_' + id);
        if (panel) panel.style.display = (id === view) ? 'block' : 'none';
        if (btn) btn.disabled = (id === view);
    }
}
function lgsmToggleRaw(view, cb) {
    var f = document.getElementById('cfg_form_div_' + view);
    var r = document.getElementById('cfg_raw_div_' + view);
    if (!f || !r) return;
    if (cb.checked) { f.style.display='none'; r.style.display='block'; }
    else            { f.style.display='block'; r.style.display='none'; }
}
</script>
JS

    print "<p>";
    print "<input type='button' class='ui_submit' id='cfg_btn_common' ".
          "onclick=\"lgsmShowConfigView('common')\" value='" .
          &html_escape($text{'config_editor_global_btn'}) . "'> ";
    print "<input type='button' class='ui_submit' id='cfg_btn_instance' ".
          "onclick=\"lgsmShowConfigView('instance')\" value='" .
          &html_escape($text{'config_editor_instance_btn'}) . "'> ";
    print "<input type='button' class='ui_submit' id='cfg_btn_game' ".
          "onclick=\"lgsmShowConfigView('game')\" value='" .
          &html_escape($game_tab_label) . "'>";
    print "</p>\n";

    # Common LGSM config panel
    my ($common_editable, $common_unknown, undef) =
        &split_editor_fields('common', \@game_fields, $common_vals, $common_order);
    print "<div id='cfg_panel_common' style='display:none'>\n";
    print "<p><b>" . &html_escape($text{'config_editor_common_notice'}) . "</b></p>\n";
    print &ui_form_start("manage.cgi", "post");
    print &ui_hidden("instance_id", $safe_id);
    print &ui_hidden("action",      "save_config");
    print &ui_hidden("config_file", "common");
    print &ui_hidden("config_view", "common");
    print "<p><label>";
    print "<input type='checkbox' id='raw_mode_cb_common' name='raw_mode' value='1' ";
    print "onchange=\"lgsmToggleRaw('common', this)\"> ";
    print "$text{'config_editor_raw_mode'}</label></p>\n";
    print "<div id='cfg_form_div_common'>\n";
    print &ui_table_start($text{'config_editor_common'}, "width=100%", 2);
    if (@$common_unknown) {
        for my $key (@$common_unknown) {
            my $val = $common_vals->{$key} // '';
            print &ui_table_row(&html_escape($key),
                                &ui_textbox("field_$key", &html_escape($val), 40));
        }
    } else {
        print &ui_table_row(&html_escape($text{'config_editor_unknown_fields'}), '-');
    }
    print &ui_table_end();
    print "</div>\n";
    print "<div id='cfg_raw_div_common' style='display:none'>\n";
    print &ui_textarea("config_raw", $common_raw, 20, 72);
    print "</div>\n";
    print &ui_submit($text{'config_editor_save'});
    print &ui_form_end();
    print "</div>\n";

    # Instance LGSM config panel
    my ($inst_editable, $inst_unknown, undef) =
        &split_editor_fields('instance', \@game_fields, $inst_vals, $inst_order);
    print "<div id='cfg_panel_instance' style='display:none'>\n";
    print &ui_form_start("manage.cgi", "post");
    print &ui_hidden("instance_id", $safe_id);
    print &ui_hidden("action",      "save_config");
    print &ui_hidden("config_file", "instance");
    print &ui_hidden("config_view", "instance");
    print "<p><label>";
    print "<input type='checkbox' id='raw_mode_cb_instance' name='raw_mode' value='1' ";
    print "onchange=\"lgsmToggleRaw('instance', this)\"> ";
    print "$text{'config_editor_raw_mode'}</label></p>\n";
    print "<div id='cfg_form_div_instance'>\n";
    print &ui_table_start($text{'config_editor_instance'}, "width=100%", 2);
    my $inst_hints = &get_game_field_hints($script_name_for_cfg);
    for my $f (@$inst_editable) {
        my $key   = $f->{'key'};
        my $label = (($lang eq 'de') ? $f->{'label_de'} : $f->{'label_en'}) // $key;
        my $val   = exists $inst_vals->{$key} ? $inst_vals->{$key} : ($f->{'default'} // '');
        my $type  = $f->{'type'} // 'text';
        my $hint  = $inst_hints->{$key};
        if ($hint) {
            my $tip = &html_escape(($lang eq 'de' ? $hint->{'de'} : $hint->{'en'}) // '');
            $label = "<abbr title='$tip' style='cursor:help;text-decoration:underline dotted'>"
                   . &html_escape($label) . "</abbr>";
        } else {
            $label = &html_escape($label);
        }
        my $widget;
        if ($type eq 'bool') {
            my $yes = $text{'yes'} || 'Ja';
            my $no  = $text{'no'}  || 'Nein';
            $widget = &ui_radio("field_$key", ($val && $val ne '0') ? 1 : 0,
                                [[1, $yes], [0, $no]]);
        } else {
            my $width = ($type eq 'port' || $type eq 'int') ? 10 : 40;
            $widget = &ui_textbox("field_$key", &html_escape($val), $width);
        }
        print &ui_table_row($label, $widget);
    }
    if (@$inst_unknown) {
        print &ui_table_row("<b>$text{'config_editor_unknown_fields'}</b>", "");
        for my $key (@$inst_unknown) {
            my $val = $inst_vals->{$key} // '';
            print &ui_table_row(&html_escape($key),
                                &ui_textbox("field_$key", &html_escape($val), 40));
        }
    }
    print &ui_table_end();
    print "</div>\n";
    print "<div id='cfg_raw_div_instance' style='display:none'>\n";
    print &ui_textarea("config_raw", $inst_raw, 20, 72);
    print "</div>\n";
    print &ui_submit($text{'config_editor_save'});
    print &ui_form_end();
    print "</div>\n";

    # Game server config panel (game-specific fields on instance config)
    print "<div id='cfg_panel_game' style='display:none'>\n";
    if (!$game_cfg_exists) {
        my $missing_text = ($effective_source eq 'steamcmd'
            ? ($text{'config_editor_game_missing_steamcmd'} || $text{'config_editor_game_missing'})
            : $text{'config_editor_game_missing'});
        print "<p><b>" . &html_escape($missing_text) . "</b></p>\n";
        if ($effective_source ne 'steamcmd') {
            print &ui_form_start("manage.cgi", "post");
            print &ui_hidden("instance_id", $safe_id);
            print &ui_hidden("action", "init_game_config");
            print &ui_submit($text{'config_editor_game_create_btn'});
            print &ui_form_end();
        }
    } else {
        my ($game_vals, $game_order, undef) =
            &parse_game_config_values($script_name_for_cfg, $game_cfg_path, $game_raw);
        # Known fields from games_meta (game config section) for labelled display
        my @gcf = &get_game_config_fields($script_name_for_cfg);
        my %gcf_map = map { $_->{'key'} => $_ } @gcf;
        my @known_shown = @gcf ? @gcf : ();
        my %known_keys  = map { $_->{'key'} => 1 } @gcf;
        # Unknown keys: present in file but not in game_config_fields
        my @extra_keys  = @gcf ? (grep { !$known_keys{$_} } @$game_order) : @$game_order;

        print &ui_form_start("manage.cgi", "post");
        print &ui_hidden("instance_id", $safe_id);
        print &ui_hidden("action",      "save_config");
        print &ui_hidden("config_file", "game");
        print &ui_hidden("config_view", "game");
        print &ui_hidden("game_config_original", $game_raw);
        if ($script_name_for_cfg =~ /^pw(?:server)?$/i) {
            print "<p>" . &html_escape($text{'config_editor_pw_world_notice'}) . "</p>\n";
            my $wopt = &find_palworld_world_option_sav($script_dir_for_cfg);
            if ($wopt ne '') {
                print "<p><em>" . &html_escape(&text('config_editor_pw_worldoption_hint', $wopt))
                    . "</em></p>\n";
            }
        } else {
            print "<p>" . &html_escape($text{'config_editor_game_notice'}) . "</p>\n";
        }
        print "<p><label>";
        print "<input type='checkbox' id='raw_mode_cb_game' name='raw_mode' value='1' ";
        print "onchange=\"lgsmToggleRaw('game', this)\"> ";
        print "$text{'config_editor_raw_mode'}</label></p>\n";
        print "<div id='cfg_form_div_game'>\n";
        print &ui_table_start($game_tab_label, "width=100%", 2);
        if (@known_shown || @extra_keys) {
            # Labelled known fields first
            for my $f (@known_shown) {
                my $key   = $f->{'key'};
                my $label = (($lang eq 'de') ? $f->{'label_de'} : $f->{'label_en'}) // $key;
                my $type  = $f->{'type'} // 'text';
                my $val   = exists $game_vals->{$key} ? $game_vals->{$key} : '';
                my $width = ($type eq 'port' || $type eq 'int') ? 10 : 40;
                my $widget;
                if ($type eq 'bool') {
                    # Hidden zero-marker so an unchecked box still submits a value
                    # (browsers omit unchecked checkboxes entirely otherwise).
                    my $is_true = ($val =~ /^\s*(?:1|true|on|yes|ja)\s*$/i) ? 1 : 0;
                    $widget = "<input type='hidden' name='field_$key' value='false'>"
                            . "<input type='checkbox' name='field_$key' value='true'"
                            . ($is_true ? " checked='checked'" : '') . ">";
                }
                elsif ($type eq 'password') {
                    $widget = &ui_password("field_$key", &html_escape($val), $width);
                }
                else {
                    $widget = &ui_textbox("field_$key", &html_escape($val), $width);
                }
                print &ui_table_row(&html_escape($label), $widget);
            }
            # Remaining / unlabelled keys
            if (@extra_keys) {
                print &ui_table_row("<b>$text{'config_editor_unknown_fields'}</b>", "")
                    if @known_shown;
                for my $key (@extra_keys) {
                    my $val = $game_vals->{$key} // '';
                    print &ui_table_row(&html_escape($key),
                                        &ui_textbox("field_$key", &html_escape($val), 40));
                }
            }
        } else {
            print &ui_table_row(&html_escape($text{'config_editor_game_no_fields'}), '-');
        }
        print &ui_table_end();
        print "</div>\n";
        print "<div id='cfg_raw_div_game' style='display:none'>\n";
        print &ui_textarea("game_config_raw", $game_raw, 22, 90);
        print "</div>\n";
        print &ui_submit($text{'config_editor_save'});
        print &ui_form_end();
    }
    print "</div>\n";

    print "<script>lgsmShowConfigView('" . &html_escape($cfg_view_key) . "');</script>\n";

    print "</details>\n";
}

# Per-instance job list (operators and admins only)
unless (&user_is_readonly($instance_id)) {
    &_manage_render_instance_jobs_table($instance_id, 5);
}

&footer('index.cgi', $text{'index_title'});
