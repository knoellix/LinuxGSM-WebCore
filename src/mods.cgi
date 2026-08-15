#!/usr/bin/perl
use strict;
use warnings;
use File::Basename qw(dirname basename);
use File::Copy qw(copy);

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/instance.pl';
require './lib/acl.pl';
require './lib/jobs.pl';
require './lib/monitor.pl';
require './lib/games_meta.pl';
require './lib/module_config.pl';
require './lib/mc_profile.pl';
require './lib/mc_loader.pl';
require './lib/mc_mods.pl';
require './lib/live_log.pl';

our (%text, %config, %in, %gconfig);
our ($module_root, $module_root_directory, $module_name, $config_directory);
$module_root ||= $module_root_directory;
$module_root ||= do { (my $d = __FILE__) =~ s{/[^/]+$}{}; $d };
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);
&module_config_sync_in();

sub _parse_script_info {
    my ($inst) = @_;
    my $script_path = $inst->{'script'} // '';
    my ($script_name) = $script_path =~ m{/([^/]+)$};
    $script_name //= '';
    (my $server_dir = $script_path) =~ s{/[^/]+$}{};
    $script_name =~ s/[^a-zA-Z0-9_-]//g;
    return ($script_path, $script_name, $server_dir);
}

sub _mods_status_badge_html {
    my ($status) = @_;
    my %map = (
        online     => $text{'mc_mods_page_status_online'}  || 'Online',
        running    => $text{'mc_mods_page_status_online'}  || 'Online',
        offline    => $text{'mc_mods_page_status_offline'} || 'Offline',
        stopped    => $text{'mc_mods_page_status_offline'} || 'Offline',
        fresh      => $text{'mc_mods_page_status_fresh'}   || 'Provisioning pending',
        lgsm_ready => $text{'mc_mods_page_status_lgsm'}    || 'Installation pending',
        mc_ready   => $text{'mc_mods_page_status_mc'}      || 'Minecraft prepared',
        unknown    => $text{'mc_mods_page_status_unknown'} || 'Unknown',
    );
    my $label = $map{$status} || ($text{'mc_mods_page_status_unknown'} || 'Unknown');
    return &html_escape($label);
}

sub _mods_job_launch_failed {
    &error($text{'mc_mods_page_job_launch_failed'}
        || $text{'manage_job_launch_failed'}
        || 'Background job could not be started.');
}

sub _mods_launch_background_job {
    my ($instance_id, $action, $unix_user, $launch_cmd) = @_;
    my $job_id = &create_job($unix_user);
    &write_job_meta($job_id, $instance_id, $action, $unix_user)
        or do { &job_mark_launch_failed($job_id); return undef; };
    &log_action('job_started', $job_id, { instance_id => $instance_id, action => $action });
    my $cmd = ref($launch_cmd) eq 'CODE' ? $launch_cmd->($job_id) : $launch_cmd;
    my $rc = &system_logged($cmd);
    if ($rc != 0 || !&job_dispatch_verified($job_id)) {
        &job_mark_launch_failed($job_id);
        return undef;
    }
    return $job_id;
}

sub _mods_query_urlencode {
    my ($value) = @_;
    $value //= '';
    $value =~ s/([^A-Za-z0-9_\-.~])/sprintf('%%%02X', ord($1))/ge;
    return $value;
}

sub _mods_list_qs {
    my ($q, $status, $sort, $dir, $page) = @_;
    my @pairs;
    push @pairs, 'q=' . _mods_query_urlencode($q // '') if defined($q) && $q ne '';
    push @pairs, 'status=' . _mods_query_urlencode($status // 'all');
    push @pairs, 'sort=' . _mods_query_urlencode($sort // 'name');
    push @pairs, 'dir=' . _mods_query_urlencode($dir // 'asc');
    push @pairs, 'page=' . _mods_query_urlencode($page // 1);
    return join('&', @pairs);
}

sub _mods_list_url {
    my ($instance_id, $q, $status, $sort, $dir, $page) = @_;
    my $url = "mods.cgi?instance_id=" . _mods_query_urlencode($instance_id)
        . "&xnavigation=1";
    my $qs = _mods_list_qs($q, $status, $sort, $dir, $page);
    $url .= "&$qs" if $qs ne '';
    return $url;
}

sub _mods_mod_search_query {
    my ($raw) = @_;
    $raw //= '';
    $raw =~ s/[\t\n\r\0]//g;
    $raw =~ s/^\s+|\s+$//g;
    return substr($raw, 0, 100);
}

sub _mods_hidden_list_state {
    my ($q, $status, $sort, $dir, $page) = @_;
    my $out = '';
    $out .= &ui_hidden('q', $q) if defined($q) && $q ne '';
    $out .= &ui_hidden('status', $status);
    $out .= &ui_hidden('sort', $sort);
    $out .= &ui_hidden('dir', $dir);
    $out .= &ui_hidden('page', $page);
    return $out;
}

sub _mods_hidden_mod_search_state {
    my ($mod_q) = @_;
    $mod_q = _mods_mod_search_query($mod_q // '');
    return '' unless length($mod_q) >= 2;
    return &ui_hidden('mod_q', $mod_q);
}

sub _mods_pack_search_query {
    my ($raw) = @_;
    $raw //= '';
    $raw =~ s/[\t\n\r\0]//g;
    $raw =~ s/^\s+|\s+$//g;
    return substr($raw, 0, 100);
}

sub _mods_hidden_pack_search_state {
    my ($pack_q) = @_;
    $pack_q = _mods_pack_search_query($pack_q // '');
    return '' unless length($pack_q) >= 2;
    return &ui_hidden('pack_q', $pack_q);
}

sub _mods_hidden_mc_search_state {
    my ($mod_q, $pack_q) = @_;
    return _mods_hidden_mod_search_state($mod_q)
        . _mods_hidden_pack_search_state($pack_q);
}

sub _mods_modpack_resolve_error_msg {
    my ($err, $detail, $profile) = @_;
    return &mc_modpack_error_message($err, $detail, $profile, \%text);
}

sub _mods_modpack_validation_errors {
    my ($validation, $pack, $profile) = @_;
    my @msgs;
    for my $code (@{ $validation->{'errors'} // [] }) {
        if ($code eq 'loader_mismatch') {
            push @msgs, &text('mc_modpack_loader_mismatch',
                &html_escape($pack->{'loader'} // '?'),
                &html_escape($profile->{'loader'} // '?'));
        } elsif ($code eq 'version_mismatch') {
            push @msgs, &text('mc_modpack_version_mismatch',
                &html_escape($pack->{'mc_version'} // '?'),
                &html_escape($profile->{'mc_version'} // '?'));
        } elsif ($code eq 'modded_pack_on_vanilla') {
            push @msgs, $text{'mc_modpack_modded_on_vanilla'};
        } else {
            push @msgs, &html_escape($code);
        }
    }
    return @msgs;
}

sub _mods_write_job_worker_secrets {
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

sub _mods_validate_modpack_server_path {
    my ($path, $unix_user, $server_dir) = @_;
    my ($ok, $resolved, $err) = &validate_modpack_import_path($path, $unix_user, $server_dir);
    return ($ok, $resolved, $err);
}

sub _mods_finish_modpack_import_job {
    my ($job_id, $instance_id, $inst, $unix_user, $pack_path, $profile, $server_dir) = @_;
    my $job_dir = &_job_dir($job_id);

    my $pack = &parse_modpack_file($pack_path);
    unless ($pack) {
        &delete_job($job_id);
        &error($text{'mc_modpack_invalid'} || 'Invalid modpack format.');
    }

    my $validation = &validate_modpack_against_profile($pack, $profile);
    unless ($validation->{'ok'}) {
        my @errs = _mods_modpack_validation_errors($validation, $pack, $profile);
        &delete_job($job_id);
        &error(join('<br>', @errs));
    }

    if (($pack->{'format'} // '') eq 'curseforge') {
        unless (defined &curseforge_api_key && curseforge_api_key() =~ /\S/) {
            &delete_job($job_id);
            &error($text{'mc_modpack_curseforge_key_missing'});
        }
    }

    my ($files, $skipped_client) = &modpack_files_for_server_import($pack);
    unless (@$files) {
        &delete_job($job_id);
        &error($text{'mc_modpack_no_server_mods'} || 'No server-compatible mods in pack.');
    }

    &write_modpack_job_meta($job_dir, {
        format                => $pack->{'format'},
        pack_file             => $pack_path,
        pack_name             => $pack->{'name'} // '',
        pack_loader           => $pack->{'loader'} // '',
        pack_loader_version   => $pack->{'loader_version'} // '',
        pack_mc_version       => $pack->{'mc_version'} // '',
        mod_dir               => $profile->{'mod_dir'} // 'mods',
        server_dir            => $server_dir,
        skipped_client        => $skipped_client,
        files                 => $files,
        profile               => { %$profile },
        validation_warnings   => [ @{ $validation->{'warnings'} // [] } ],
    }, $unix_user) or do {
        &delete_job($job_id);
        &error($text{'mc_modpack_meta_failed'} || 'Job preparation failed.');
    };

    &write_job_meta($job_id, $instance_id, 'modpack_import', $unix_user)
        or do { &job_mark_launch_failed($job_id); _mods_job_launch_failed(); };

    _mods_write_job_worker_secrets($job_dir, $unix_user);

    my $rc = &system_logged(&user_worker_launch_cmd(
        unix_user   => $unix_user,
        module_root => $module_root,
        worker      => "$module_root/scripts/mc_modpack_install.sh",
        args        => [ $job_dir, $unix_user, $server_dir ],
    ));
    if ($rc != 0 || !&job_dispatch_verified($job_id)) {
        &job_mark_launch_failed($job_id);
        _mods_job_launch_failed();
    }
    return $job_id;
}

sub _mods_launch_modpack_from_path {
    my ($instance_id, $inst, $unix_user, $server_path) = @_;
    my (undef, undef, $server_dir) = _parse_script_info($inst);
    my $profile = &read_mc_profile($server_dir);
    &error($text{'mc_profile_missing'} || 'No Minecraft profile.') unless $profile;

    my ($ok_path, $pack_path, $path_err) = _mods_validate_modpack_server_path(
        $server_path, $unix_user, $server_dir);
    unless ($ok_path) {
        if ($path_err eq 'outside') {
            &error($text{'mc_modpack_path_outside'} || 'Path is outside server home.');
        } elsif ($path_err eq 'missing') {
            &error($text{'mc_modpack_path_missing'} || 'File not found.');
        } else {
            &error($text{'mc_modpack_path_invalid'} || 'Invalid file path.');
        }
    }

    my $job_id = &create_job($unix_user);
    my $job_dir = &_job_dir($job_id);
    my $upload_dir = "$job_dir/upload";
    mkdir($upload_dir, 0750) or do {
        &delete_job($job_id);
        &error($text{'mc_modpack_upload_failed'} || 'Modpack import failed.');
    };
    my $base = basename($pack_path);
    $base =~ s/[^a-zA-Z0-9._-]//g;
    $base = 'pack.mrpack' unless $base =~ /\.(mrpack|zip)\z/i;
    my $dest = "$upload_dir/$base";
    unless (copy($pack_path, $dest)) {
        &delete_job($job_id);
        &error($text{'mc_modpack_upload_failed'} || 'Modpack import failed.');
    }
    &chown_job_files_to_user($unix_user, $upload_dir, $dest);

    return _mods_finish_modpack_import_job(
        $job_id, $instance_id, $inst, $unix_user, $dest, $profile, $server_dir);
}

sub _mods_launch_modpack_remote {
    my ($instance_id, $inst, $unix_user, $source, $ids_ref, $adopt) = @_;
    my (undef, undef, $server_dir) = _parse_script_info($inst);
    my $profile = &read_mc_profile($server_dir);
    &error($text{'mc_profile_missing'} || 'No Minecraft profile.') unless $profile;

    $source =~ s/[^a-z]//g;
    return unless ref($ids_ref) eq 'HASH';

    unless ($source eq 'modrinth' || $source eq 'curseforge') {
        &error(_mods_modpack_resolve_error_msg('invalid_source', {}, $profile));
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
        &error(_mods_modpack_resolve_error_msg(
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
        &error($text{'mc_modpack_meta_failed'} || 'Job preparation failed.');
    };

    &write_job_meta($job_id, $instance_id, 'modpack_import', $unix_user)
        or do { &job_mark_launch_failed($job_id); _mods_job_launch_failed(); };

    _mods_write_job_worker_secrets($job_dir, $unix_user);

    my $rc = &system_logged(&user_worker_launch_cmd(
        unix_user   => $unix_user,
        module_root => $module_root,
        worker      => "$module_root/scripts/mc_modpack_install.sh",
        args        => [ $job_dir, $unix_user, $server_dir ],
    ));
    if ($rc != 0 || !&job_dispatch_verified($job_id)) {
        &job_mark_launch_failed($job_id);
        _mods_job_launch_failed();
    }
    return $job_id;
}

sub _mods_find_resumable_modpack_job {
    my ($instance_id, $server_dir) = @_;
    for my $j (&get_instance_jobs($instance_id, action => 'modpack_import')) {
        my $st = $j->{'status'} // '';
        next unless $st eq 'failed' || $st eq 'aborted';
        my $jdir = &_job_dir($j->{'job_id'});
        my ($ok, $prog) = &modpack_job_resumable(
            $jdir, $server_dir, $st, $j->{'action'} // '');
        next unless $ok && ref($prog) eq 'HASH';
        return ($j->{'job_id'}, $prog);
    }
    return (undef, undef);
}

sub _mods_render_modpack_resume_ui {
    my ($instance_id, $server_dir, $job_id, $prog, $pack_q, $q, $status, $sort, $dir, $page, $mod_q) = @_;
    if (!$job_id || !ref($prog)) {
        ($job_id, $prog) = _mods_find_resumable_modpack_job($instance_id, $server_dir);
    }
    return unless $job_id && ref($prog) eq 'HASH';
    my $installed = $prog->{'installed'} // 0;
    my $total     = $prog->{'total'} // 0;
    my $missing   = $prog->{'missing'} // ($total - $installed);
    my $last      = $prog->{'last_installed'} // '';
    my $phase     = $prog->{'phase'} // '';
    my $msg;
    if ($phase eq 'expand') {
        $msg = &text('mc_modpack_resume_expand_status')
            || 'Modpack preparation interrupted - metadata resolution can continue.';
    } else {
        $msg = &text('mc_modpack_resume_status', $installed, $total, $missing);
        $msg = "Progress: $installed/$total mods on disk, $missing remaining."
            unless defined $msg && $msg =~ /\S/;
    }
    print "<div class='alert alert-warning'>"
        . &html_escape($msg);
    if ($last ne '') {
        print "<br><small>" . &html_escape(&text('mc_modpack_resume_last', $last)
            || "Last completed: $last") . "</small>";
    }
    if ($phase ne 'expand') {
        my $jdir = &_job_dir($job_id);
        my $meta = &modpack_read_job_meta_file($jdir);
        if (ref($meta) eq 'HASH' && &modpack_is_cf_bulk_pack_meta($meta)) {
            print "<br><small><i>" . &html_escape(&text('mc_modpack_resume_cf_cdn_note')
                || 'CurseForge CDN limits around mod ~95 are normal for large packs.')
                . "</i></small>";
            if (&modpack_cf_auto_resume_enabled()) {
                print "<br><small><i>" . &html_escape(&text('mc_modpack_auto_resume_active')
                    || 'Auto-resume enabled: job continues automatically after CDN pauses.')
                    . "</i></small>";
            }
        }
    }
    print "<br>";
    print &ui_form_start('mods.cgi', 'post');
    print &ui_hidden('instance_id', &html_escape($instance_id));
    print &ui_hidden('xnavigation', '1');
    print _mods_hidden_list_state($q, $status, $sort, $dir, $page);
    print _mods_hidden_mc_search_state($mod_q, $pack_q);
    print &ui_hidden('action', 'modpack_import_resume');
    print &ui_hidden('job', &html_escape($job_id));
    print &ui_submit($text{'mc_modpack_resume_btn'} || 'Continue download',
        undef, undef, undef, 'btn-primary');
    print " ";
    print "<a href='jobs.cgi?action=view_output&amp;job_id="
        . &html_escape($job_id) . "'>"
        . &html_escape($text{'mc_modpack_resume_log'} || 'View job log') . "</a>";
    print &ui_form_end();
    print "</div>\n";
}

sub _mods_launch_modpack_resume {
    my ($instance_id, $inst, $unix_user, $job_id) = @_;
    $job_id =~ s/[^0-9a-f]//g;
    $job_id = substr($job_id, 0, 16);
    $job_id or &error($text{'err_invalid_input'});
    &validate_job_for_instance($job_id, $instance_id)
        or &error($text{'err_not_found'});
    if (&find_running_job_for_instance($instance_id, 'modpack_import')) {
        &error($text{'mc_modpack_resume_running'}
            || 'Modpack import already running.');
    }
    my $jmeta = &get_job_meta($job_id);
    ($jmeta->{'action'} // '') eq 'modpack_import'
        or &error($text{'mc_modpack_resume_invalid'}
            || 'Job is not a modpack import.');
    my $status = &get_job_status($job_id) // '';
    my $job_dir = &_job_dir($job_id);
    my (undef, undef, $server_dir) = _parse_script_info($inst);
    my ($ok, $prog) = &modpack_job_resumable(
        $job_dir, $server_dir, $status, $jmeta->{'action'} // '');
    $ok or &error($text{'mc_modpack_resume_nothing'}
        || 'No resumable modpack import found.');
    &restart_job_for_resume($job_id, $unix_user)
        or _mods_job_launch_failed();
    &append_job_log_line($job_id,
        '=== Resume requested (Webmin) - starting worker...', $unix_user);
    _mods_write_job_worker_secrets($job_dir, $unix_user);
    my $rc = &system_logged(&user_worker_launch_cmd(
        unix_user   => $unix_user,
        module_root => $module_root,
        worker      => "$module_root/scripts/mc_modpack_install.sh",
        args        => [ $job_dir, $unix_user, $server_dir, 1 ],
        env         => { WEBCORE_MODPACK_RESUME => 1 },
    ));
    if ($rc != 0 || !&job_dispatch_verified($job_id)) {
        &job_mark_launch_failed($job_id);
        _mods_job_launch_failed();
    }
    return $job_id;
}

sub _mods_page_return_target {
    my ($instance_id, $q, $status, $sort, $dir, $page, $mod_q, $pack_q) = @_;
    my $target = _mods_list_url($instance_id, $q, $status, $sort, $dir, $page);
    $target .= '&mod_q=' . _mods_query_urlencode($mod_q) if length($mod_q) >= 2;
    $target .= '&pack_q=' . _mods_query_urlencode($pack_q) if length($pack_q) >= 2;
    return $target;
}

sub _mods_versions_for_source {
    my ($source, $project_id, $hangar_owner, $hangar_slug, $profile) = @_;
    my $versions = [];
    if ($source eq 'modrinth') {
        $versions = &modrinth_list_compatible_versions($project_id // '', $profile);
    } elsif ($source eq 'curseforge') {
        $versions = &curseforge_list_compatible_files($project_id // '', $profile);
    } elsif ($source eq 'hangar') {
        $versions = &hangar_list_compatible_versions(
            $hangar_owner // '',
            $hangar_slug // '',
            $profile,
        );
    }
    return ref($versions) eq 'ARRAY' ? $versions : [];
}

sub _mods_status_label_for_row {
    my ($enabled) = @_;
    return $enabled
        ? ($text{'mc_mods_page_mod_enabled'} || 'An')
        : ($text{'mc_mods_page_mod_disabled'} || 'Aus');
}

sub _mods_source_label_for_row {
    my ($source) = @_;
    $source = lc($source // '');
    return $text{'mc_mods_source_modrinth'}   || 'Modrinth'   if $source eq 'modrinth';
    return $text{'mc_mods_source_curseforge'} || 'CurseForge' if $source eq 'curseforge';
    return $text{'mc_mods_source_hangar'}     || 'Hangar'     if $source eq 'hangar';
    return $text{'mc_mods_page_source_unknown'} || 'Unknown';
}

sub _mods_redirect_with_flash {
    my ($instance_id, $flash, $q, $status, $sort, $dir, $page) = @_;
    $flash =~ s/[^a-z_]//g;
    $flash or &error($text{'mc_mods_page_action_failed'} || 'Action could not be completed.');
    &module_config_flash_mark($flash)
        or &error($text{'mc_mods_page_action_failed'} || 'Action could not be completed.');
    my $url = _mods_list_url($instance_id, $q, $status, $sort, $dir, $page)
        . '&' . _mods_query_urlencode($flash) . '=1';
    &redirect($url);
    exit;
}

sub _mods_redirect_job_live {
    my ($job_id, $instance_id, %opts) = @_;
    $job_id or _mods_job_launch_failed();
    my $url = "job_live.cgi?instance_id=" . &html_escape($instance_id)
        . "&job=" . &html_escape($job_id)
        . "&xnavigation=1";
    $url .= "&next_status=" . &html_escape($opts{'next_status'}) if $opts{'next_status'};
    my $return_target = $opts{'return_target'}
        || ("mods.cgi?instance_id=" . _mods_query_urlencode($instance_id));
    $url .= "&return=" . _mods_query_urlencode($return_target);
    &redirect($url);
    exit;
}

sub _mods_redirect_if_job_running {
    my ($instance_id, $action) = @_;
    my $job_id = &find_running_job_for_instance($instance_id, $action);
    $job_id ||= &find_running_job_for_instance($instance_id);
    return 0 unless $job_id;
    _mods_redirect_job_live($job_id, $instance_id);
}

sub _mods_rebuild_monitor_cron {
    return unless defined &rebuild_monitor_cron;
    &rebuild_monitor_cron($module_root, $config_directory);
}

sub _mods_steamcmd_worker_cmd {
    my ($action, $job_dir, $unix_user, $server_dir) = @_;
    return &user_worker_launch_cmd(
        unix_user   => $unix_user,
        module_root => $module_root,
        worker      => "$module_root/scripts/steamcmd_control_user.sh",
        args        => [ $action, $job_dir, $unix_user, $server_dir ],
    );
}

sub _filemin_path_urlencode {
    my ($s) = @_;
    $s //= '';
    $s =~ s/([^A-Za-z0-9\-_.~\/])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}

sub _mods_sanitize_mod_basename {
    my ($raw) = @_;
    $raw //= '';
    $raw =~ s/[^a-zA-Z0-9._-]//g;
    return &mod_basename_sanitize($raw // '');
}

sub _mods_find_mod_by_basename {
    my ($mods, $basename) = @_;
    return undef unless ref($mods) eq 'ARRAY';
    return undef unless defined $basename && $basename ne '';
    for my $mod (@$mods) {
        next unless ref($mod) eq 'HASH';
        my $cand = $mod->{'basename'} // '';
        next unless $cand eq $basename;
        return $mod;
    }
    return undef;
}

sub _mods_launch_mod_install {
    my ($instance_id, $inst, $unix_user, $source, $ids_ref, %opts) = @_;
    my (undef, undef, $server_dir) = _parse_script_info($inst);
    my $profile = &read_mc_profile($server_dir);
    &error($text{'mc_profile_missing'} || 'No Minecraft profile.')
        unless ref($profile) eq 'HASH';

    my $replace_basename = '';
    if (defined $opts{'replace_basename'} && $opts{'replace_basename'} ne '') {
        $replace_basename = _mods_sanitize_mod_basename($opts{'replace_basename'});
    }
    my $prepare_opts = $replace_basename ne '' ? { force_replace => 1 } : undef;
    my ($ok, $meta, $err) = &prepare_mod_install_meta($source, $ids_ref, $profile, $server_dir, $prepare_opts);
    unless ($ok) {
        if ($err eq 'file_exists' || $err eq 'index_project') {
            &error($text{'mc_mod_already_installed'} || 'This mod is already installed.');
        } elsif ($err eq 'curseforge_key_missing') {
            &error($text{'mc_modpack_curseforge_key_missing'});
        } elsif ($err eq 'client_only') {
            &error($text{'mc_mod_client_only'} || 'Client-only mod.');
        } elsif ($err eq 'resolve_failed') {
            &error($text{'mc_mod_resolve_failed'} || 'Could not resolve mod version.');
        } else {
            &error($text{'mc_mod_install_failed'} || 'Could not prepare mod installation.');
        }
    }

    if ($opts{'prefer_disabled'}) {
        $meta->{'prefer_disabled'} = 1;
    }
    if ($replace_basename ne '') {
        $meta->{'replace_basename'} = $replace_basename;
        $meta->{'force_replace'} = 1;
    }

    my $job_id = &create_job($unix_user);
    my $job_dir = &_job_dir($job_id);
    &write_mod_install_job_meta($job_dir, $meta) or do {
        &delete_job($job_id);
        &error($text{'mc_mod_meta_failed'} || 'Job preparation failed.');
    };
    &write_job_meta($job_id, $instance_id, 'mc_mod_install', $unix_user)
        or do { &job_mark_launch_failed($job_id); _mods_job_launch_failed(); };

    my $rc = &system_logged(&user_worker_launch_cmd(
        unix_user   => $unix_user,
        module_root => $module_root,
        worker      => "$module_root/scripts/mc_mod_install_user.sh",
        args        => [ $job_dir, $unix_user, $server_dir ],
    ));
    if ($rc != 0 || !&job_dispatch_verified($job_id)) {
        &job_mark_launch_failed($job_id);
        _mods_job_launch_failed();
    }
    return $job_id;
}

my $instance_id = &sanitize_input($in{'instance_id'} || $in{'user'} || '');
my $inst = &get_instance_flexible($instance_id) or &error($text{'err_not_found'});
my $unix_user = $inst->{'user'} // '';
my ($script_path, $script_name, $server_dir) = _parse_script_info($inst);
my $action = $in{'action'} // '';
$action =~ s/[^a-z_]//g;
my $profile = &read_mc_profile($server_dir);

my $q = $in{'q'} // '';
$q =~ s/[\t\r\n\0]//g;
$q =~ s/^\s+|\s+$//g;
$q = substr($q, 0, 120) if length($q) > 120;
my $status = lc($in{'status'} // 'all');
$status = 'all' unless $status =~ /\A(?:all|enabled|disabled)\z/;
my $sort = lc($in{'sort'} // 'name');
$sort = 'name' unless $sort =~ /\A(?:name|status)\z/;
my $dir = lc($in{'dir'} // 'asc');
$dir = 'asc' unless $dir =~ /\A(?:asc|desc)\z/;
my $page = $in{'page'} // 1;
$page = ($page =~ /^\d+$/ && $page > 0) ? int($page) : 1;
my $mod_q = _mods_mod_search_query($in{'mod_q'} // '');
my $pack_q = _mods_pack_search_query($in{'pack_q'} // '');

&user_can_manage($instance_id)
    or &error($text{'err_acl_admin_only'} || 'Access denied');

if ($action ne '' && $action !~ /^(?:monitor|start|stop|mod_enable|mod_disable|mod_delete|mod_versions|mod_search_versions|mc_mod_install|modpack_import_path|modpack_import_remote|modpack_import_resume)$/) {
    &error($text{'err_invalid_action'} || 'Invalid action');
}
if ($action ne '' && $action ne 'monitor' && &user_is_readonly($instance_id)) {
    &error($text{'err_readonly'} || 'This server is read-only for your account');
}

if ($action eq 'start' || $action eq 'stop') {
    _mods_redirect_if_job_running($instance_id, $action);

    if ($action eq 'start' && &is_minecraft_game($script_name)) {
        my $profile = &read_mc_profile($server_dir);
        &error($text{'mc_eula_required'} || 'Minecraft EULA must be accepted in the wizard.')
            unless &mc_profile_has_eula_acceptance($profile);
        &ensure_mc_eula_file($server_dir, $unix_user)
            or &error($text{'mc_eula_write_failed'} || 'Could not write eula.txt.');
        my $pending = $profile ? &mc_pending_setup_steps($profile, $server_dir) : [];
        if (@$pending) {
            &error($text{'mc_setup_incomplete_start'}
                || 'Server setup incomplete. Install Java/mod loader first.');
        }
    }

    my $source = &instance_effective_source($inst);
    my $job_id;
    if ($source eq 'steamcmd') {
        $job_id = _mods_launch_background_job(
            $instance_id, $action, $unix_user,
            sub {
                my ($jid) = @_;
                my $job_dir = _shell_safe_job_dir($jid);
                return _mods_steamcmd_worker_cmd($action, $job_dir, $unix_user, $server_dir);
            },
        );
    } else {
        my $exec_script = &instance_executable_script($server_dir, $script_path);
        $job_id = _mods_launch_background_job(
            $instance_id, $action, $unix_user,
            sub {
                my ($jid) = @_;
                my $job_dir = _shell_safe_job_dir($jid);
                return &user_worker_launch_cmd(
                    unix_user   => $unix_user,
                    module_root => $module_root,
                    worker      => "$module_root/scripts/game_action_user.sh",
                    args        => [ $job_dir, $unix_user, $server_dir, $exec_script, $action ],
                );
            },
        );
    }
    $job_id or _mods_job_launch_failed();

    if ($action eq 'stop') {
        &set_monitor_paused($server_dir, $config_directory, $instance_id);
    } else {
        &set_monitor_running($server_dir, $config_directory, $instance_id);
    }
    _mods_rebuild_monitor_cron();
    my $next_status = &job_next_instance_status($action);
    _mods_redirect_job_live($job_id, $instance_id, next_status => $next_status);
}

if ($action =~ /^(?:mod_enable|mod_disable|mod_delete)$/) {
    $ENV{'REQUEST_METHOD'} eq 'POST'
        or &error($text{'err_invalid_action'} || 'Invalid action');
    &mc_mod_ui_ready($profile, $server_dir)
        or &error($text{'mc_mods_page_gate_not_ready'}
            || 'Mods page is available after Minecraft Java and loader setup is complete.');
    my $mod_basename = _mods_sanitize_mod_basename($in{'mod_basename'} // '');
    $mod_basename or &error($text{'mc_mods_page_invalid_mod'} || 'Invalid mod file.');

    my $mod_dir = $profile->{'mod_dir'} // 'mods';
    $mod_dir =~ s/[^a-zA-Z0-9_-]//g;
    $mod_dir = 'mods' if $mod_dir eq '';

    if ($action eq 'mod_delete') {
        my ($ok, $err) = &mod_delete_installed($server_dir, $unix_user, $mod_dir, $mod_basename);
        $ok or &error(($text{'mc_mods_page_delete_failed'} || 'Could not delete mod.')
            . ($err ? " ($err)" : ''));
        _mods_redirect_with_flash($instance_id, 'mod_deleted', $q, $status, $sort, $dir, $page);
    }

    my $want_enabled = $action eq 'mod_enable' ? 1 : 0;
    my ($ok, $err) = &mod_set_enabled($server_dir, $unix_user, $mod_dir, $mod_basename, $want_enabled);
    if (!$ok) {
        my $msg = $want_enabled
            ? ($text{'mc_mods_page_enable_failed'} || 'Could not enable mod.')
            : ($text{'mc_mods_page_disable_failed'} || 'Could not disable mod.');
        &error($msg . ($err ? " ($err)" : ''));
    }
    my $flash = $want_enabled ? 'mod_enabled' : 'mod_disabled';
    _mods_redirect_with_flash($instance_id, $flash, $q, $status, $sort, $dir, $page);
}

if ($action eq 'mc_mod_install') {
    $ENV{'REQUEST_METHOD'} eq 'POST'
        or &error($text{'err_invalid_action'} || 'Invalid action');
    &mc_mod_ui_ready($profile, $server_dir)
        or &error($text{'mc_mods_page_gate_not_ready'}
            || 'Mods page is available after Minecraft Java and loader setup is complete.');

    my $source = '';
    my %ids;
    my %launch_opts;
    my $return_target = _mods_page_return_target(
        $instance_id, $q, $status, $sort, $dir, $page, $mod_q, $pack_q);

    my $mod_basename = _mods_sanitize_mod_basename($in{'mod_basename'} // '');
    if ($mod_basename ne '') {
        my $installed = &list_installed_mods($server_dir, $profile);
        my $selected_mod = _mods_find_mod_by_basename($installed, $mod_basename)
            or &error($text{'mc_mods_page_invalid_mod'} || 'Invalid mod file.');
        ($selected_mod->{'has_update_meta'} // 0)
            or &error($text{'mc_mods_page_update_unavailable'} || 'No version data available for this mod.');

        $source = $selected_mod->{'source'} // '';
        $source =~ s/[^a-z]//g;
        %ids = (
            project_id   => $selected_mod->{'project_id'} // '',
            version_id   => $selected_mod->{'version_id'} // '',
            file_id      => $selected_mod->{'file_id'} // '',
            hangar_owner => $selected_mod->{'hangar_owner'} // '',
            hangar_slug  => $selected_mod->{'hangar_slug'} // '',
            title        => $selected_mod->{'title'} // $selected_mod->{'basename'} // '',
        );
        $ids{'version_id'} = $in{'mod_version_id'} // '' if defined $in{'mod_version_id'} && $in{'mod_version_id'} ne '';
        $ids{'file_id'}    = $in{'mod_file_id'} // ''    if defined $in{'mod_file_id'} && $in{'mod_file_id'} ne '';
        $launch_opts{'prefer_disabled'} = ($selected_mod->{'enabled'} // 0) ? 0 : 1;
        $launch_opts{'replace_basename'} = $selected_mod->{'basename'} // '';
    } else {
        $source = $in{'mod_source'} // '';
        $source =~ s/[^a-z]//g;
        %ids = (
            project_id   => $in{'mod_project_id'} // '',
            version_id   => $in{'mod_version_id'} // '',
            file_id      => $in{'mod_file_id'} // '',
            hangar_owner => $in{'mod_hangar_owner'} // '',
            hangar_slug  => $in{'mod_hangar_slug'} // '',
            title        => $in{'mod_title'} // '',
        );
        unless ($source eq 'modrinth' || $source eq 'curseforge' || $source eq 'hangar') {
            &error($text{'mc_mod_install_failed'} || 'Could not prepare mod installation.');
        }
    }

    for my $k (keys %ids) {
        $ids{$k} =~ s/[\t\n\r\0]//g;
        $ids{$k} = substr($ids{$k}, 0, 128);
    }
    if ($source eq 'curseforge') {
        $ids{'project_id'} =~ s/\D//g if $ids{'project_id'};
    } else {
        $ids{'project_id'} =~ s/[^a-zA-Z0-9_-]//g if $ids{'project_id'};
    }
    $ids{'version_id'} =~ s/[^a-zA-Z0-9._-]//g if $ids{'version_id'};
    $ids{'file_id'} =~ s/\D//g if $ids{'file_id'};
    $ids{'hangar_owner'} =~ s/[^a-zA-Z0-9_-]//g if $ids{'hangar_owner'};
    $ids{'hangar_slug'} =~ s/[^a-zA-Z0-9_-]//g if $ids{'hangar_slug'};

    my $job_id = _mods_launch_mod_install(
        $instance_id, $inst, $unix_user, $source, \%ids, %launch_opts
    );
    _mods_redirect_job_live($job_id, $instance_id, return_target => $return_target);
}

if ($action eq 'modpack_import_path') {
    $ENV{'REQUEST_METHOD'} eq 'POST'
        or &error($text{'err_invalid_action'} || 'Invalid action');
    &mc_mod_ui_ready($profile, $server_dir)
        or &error($text{'mc_mods_page_gate_not_ready'}
            || 'Mods page is available after Minecraft Java and loader setup is complete.');
    my $path = $in{'modpack_path'} // '';
    $path =~ s/[\t\n\r\0]//g;
    $path = substr($path, 0, 512);
    my $job_id = _mods_launch_modpack_from_path(
        $instance_id, $inst, $unix_user, $path);
    my $return_target = _mods_page_return_target(
        $instance_id, $q, $status, $sort, $dir, $page, $mod_q, $pack_q);
    _mods_redirect_job_live($job_id, $instance_id, return_target => $return_target);
}

if ($action eq 'modpack_import_remote') {
    $ENV{'REQUEST_METHOD'} eq 'POST'
        or &error($text{'err_invalid_action'} || 'Invalid action');
    &mc_mod_ui_ready($profile, $server_dir)
        or &error($text{'mc_mods_page_gate_not_ready'}
            || 'Mods page is available after Minecraft Java and loader setup is complete.');
    my $source = $in{'pack_source'} // '';
    $source =~ s/[^a-z]//g;
    my %ids = (
        project_id => $in{'pack_project_id'} // '',
        version_id => $in{'pack_version_id'} // '',
        file_id    => $in{'pack_file_id'} // '',
        title      => $in{'pack_title'} // '',
    );
    for my $k (keys %ids) {
        $ids{$k} =~ s/[\t\n\r\0]//g;
        $ids{$k} = substr($ids{$k}, 0, 128);
    }
    if ($source eq 'curseforge') {
        $ids{'project_id'} =~ s/\D//g if $ids{'project_id'};
    } else {
        $ids{'project_id'} =~ s/[^a-zA-Z0-9_-]//g if $ids{'project_id'};
    }
    $ids{'version_id'} =~ s/[^a-zA-Z0-9_-]//g if $ids{'version_id'};
    $ids{'file_id'}    =~ s/\D//g if $ids{'file_id'};
    my $adopt = (($in{'pack_adopt'} // '') eq '1') ? 1 : 0;
    my $job_id = _mods_launch_modpack_remote(
        $instance_id, $inst, $unix_user, $source, \%ids, $adopt);
    my $return_target = _mods_page_return_target(
        $instance_id, $q, $status, $sort, $dir, $page, $mod_q, $pack_q);
    _mods_redirect_job_live($job_id, $instance_id, return_target => $return_target);
}

if ($action eq 'modpack_import_resume') {
    $ENV{'REQUEST_METHOD'} eq 'POST'
        or &error($text{'err_invalid_action'} || 'Invalid action');
    &mc_mod_ui_ready($profile, $server_dir)
        or &error($text{'mc_mods_page_gate_not_ready'}
            || 'Mods page is available after Minecraft Java and loader setup is complete.');
    my $resume_job = $in{'job'} // '';
    $resume_job =~ s/[^0-9a-f]//g;
    $resume_job = substr($resume_job, 0, 16);
    unless ($resume_job) {
        ($resume_job, undef) = _mods_find_resumable_modpack_job($instance_id, $server_dir);
    }
    $resume_job or &error($text{'mc_modpack_resume_nothing'}
        || 'No resumable modpack import found.');
    my $job_id = _mods_launch_modpack_resume(
        $instance_id, $inst, $unix_user, $resume_job);
    my $return_target = _mods_page_return_target(
        $instance_id, $q, $status, $sort, $dir, $page, $mod_q, $pack_q);
    _mods_redirect_job_live($job_id, $instance_id, return_target => $return_target);
}

if ($action eq 'mod_versions') {
    &mc_mod_ui_ready($profile, $server_dir)
        or &error($text{'mc_mods_page_gate_not_ready'}
            || 'Mods page is available after Minecraft Java and loader setup is complete.');

    my $mod_basename = _mods_sanitize_mod_basename($in{'basename'} // $in{'mod_basename'} // '');
    $mod_basename or &error($text{'mc_mods_page_invalid_mod'} || 'Invalid mod file.');
    my $installed = &list_installed_mods($server_dir, $profile);
    my $selected_mod = _mods_find_mod_by_basename($installed, $mod_basename)
        or &error($text{'mc_mods_page_invalid_mod'} || 'Invalid mod file.');
    ($selected_mod->{'has_update_meta'} // 0)
        or &error($text{'mc_mods_page_update_unavailable'} || 'No version data available for this mod.');

    my $source = $selected_mod->{'source'} // '';
    my $versions = _mods_versions_for_source(
        $source,
        $selected_mod->{'project_id'} // '',
        $selected_mod->{'hangar_owner'} // '',
        $selected_mod->{'hangar_slug'} // '',
        $profile,
    );

    my $safe_id = &html_escape($instance_id);
    my $display_name = $selected_mod->{'title'} // '';
    $display_name = $selected_mod->{'basename'} // '' unless $display_name =~ /\S/;
    my $current_file = $selected_mod->{'filename_on_disk'} // ($selected_mod->{'basename'} // '');
    my $status_label = _mods_status_label_for_row(($selected_mod->{'enabled'} // 0) ? 1 : 0);

    &header($text{'mc_mods_page_versions_title'} || 'Choose mod version', '');
    print "<h3>" . &html_escape($text{'mc_mods_page_versions_title'} || 'Choose mod version') . "</h3>\n";
    print "<p><strong>" . &html_escape($text{'mc_mods_page_versions_mod'} || 'Mod')
        . ":</strong> " . &html_escape($display_name) . "<br>\n";
    print "<strong>" . &html_escape($text{'mc_mods_page_versions_current'} || 'Current file')
        . ":</strong> " . &html_escape($current_file) . "<br>\n";
    print "<strong>" . &html_escape($text{'mc_mods_page_versions_status'} || 'Status')
        . ":</strong> " . &html_escape($status_label) . "</p>\n";

    if (!@$versions) {
        print "<p>" . &html_escape($text{'mc_mods_page_versions_empty'}
            || 'No compatible versions found for this profile.')
            . "</p>\n";
    } else {
        my @rows;
        for my $row (@$versions) {
            next unless ref($row) eq 'HASH';
            my $name = $row->{'name'} // $row->{'display_name'} // '';
            $name = $row->{'version_id'} // $row->{'file_id'} // '?' unless $name =~ /\S/;
            my $file = $row->{'filename'} // '';
            my $published = $row->{'published'} // '';
            my $is_current = 0;
            $is_current = 1 if ($source eq 'modrinth' && ($selected_mod->{'version_id'} // '') ne ''
                && ($selected_mod->{'version_id'} // '') eq ($row->{'version_id'} // ''));
            $is_current = 1 if ($source eq 'curseforge' && ($selected_mod->{'file_id'} // '') ne ''
                && ($selected_mod->{'file_id'} // '') eq ($row->{'file_id'} // ''));
            $is_current = 1 if ($source eq 'hangar' && ($selected_mod->{'version_id'} // '') ne ''
                && ($selected_mod->{'version_id'} // '') eq ($row->{'version_id'} // ''));
            my $current_mark = $is_current
                ? (' <small>(' . &html_escape($text{'mc_mods_page_versions_current_mark'} || 'Current') . ')</small>')
                : '';

            my $action_form = &html_escape($text{'mc_mods_page_readonly_mod_hint'} || 'Read-only');
            unless (&user_is_readonly($instance_id)) {
                $action_form = &ui_form_start('mods.cgi', 'post');
                $action_form .= &ui_hidden('instance_id', $safe_id);
                $action_form .= &ui_hidden('xnavigation', '1');
                $action_form .= _mods_hidden_list_state($q, $status, $sort, $dir, $page);
                $action_form .= _mods_hidden_mod_search_state($mod_q);
                $action_form .= &ui_hidden('action', 'mc_mod_install');
                $action_form .= &ui_hidden('mod_basename', $selected_mod->{'basename'} // '');
                $action_form .= &ui_hidden('mod_version_id', $row->{'version_id'} // '');
                $action_form .= &ui_hidden('mod_file_id', $row->{'file_id'} // '');
                $action_form .= &ui_submit($text{'mc_mods_page_versions_install_btn'} || 'Install version',
                    undef, undef, undef, 'btn-primary');
                $action_form .= &ui_form_end();
            }

            push @rows, [
                &html_escape($name) . $current_mark,
                &html_escape($file),
                &html_escape($published),
                $action_form,
            ];
        }
        print &ui_columns_table(
            [
                $text{'mc_mods_page_versions_col_version'} || 'Version',
                $text{'mc_mods_page_versions_col_file'}    || 'File',
                $text{'mc_mods_page_versions_col_date'}    || 'Published',
                $text{'mc_mods_page_versions_col_action'}  || 'Action',
            ],
            '100%',
            \@rows,
        );
    }

    print &ui_form_start('mods.cgi', 'get');
    print &ui_hidden('instance_id', $safe_id);
    print &ui_hidden('xnavigation', '1');
    print _mods_hidden_list_state($q, $status, $sort, $dir, $page);
    print _mods_hidden_mod_search_state($mod_q);
    print &ui_submit($text{'mc_mods_page_versions_back_btn'} || 'Back to mods',
        undef, undef, undef, 'btn-default');
    print &ui_form_end();
    &footer('', '');
    exit;
}

if ($action eq 'mod_search_versions') {
    &mc_mod_ui_ready($profile, $server_dir)
        or &error($text{'mc_mods_page_gate_not_ready'}
            || 'Mods page is available after Minecraft Java and loader setup is complete.');

    my $source = $in{'mod_source'} // '';
    $source =~ s/[^a-z]//g;
    ($source eq 'modrinth' || $source eq 'curseforge' || $source eq 'hangar')
        or &error($text{'mc_mod_install_failed'} || 'Could not prepare mod installation.');

    my %ids = (
        project_id   => $in{'mod_project_id'} // '',
        version_id   => $in{'mod_version_id'} // '',
        file_id      => $in{'mod_file_id'} // '',
        hangar_owner => $in{'mod_hangar_owner'} // '',
        hangar_slug  => $in{'mod_hangar_slug'} // '',
        title        => $in{'mod_title'} // '',
    );
    for my $k (keys %ids) {
        $ids{$k} =~ s/[\t\n\r\0]//g;
        $ids{$k} = substr($ids{$k}, 0, 128);
    }
    if ($source eq 'curseforge') {
        $ids{'project_id'} =~ s/\D//g if $ids{'project_id'};
    } else {
        $ids{'project_id'} =~ s/[^a-zA-Z0-9_-]//g if $ids{'project_id'};
    }
    $ids{'version_id'} =~ s/[^a-zA-Z0-9._-]//g if $ids{'version_id'};
    $ids{'file_id'} =~ s/\D//g if $ids{'file_id'};
    $ids{'hangar_owner'} =~ s/[^a-zA-Z0-9_-]//g if $ids{'hangar_owner'};
    $ids{'hangar_slug'} =~ s/[^a-zA-Z0-9_-]//g if $ids{'hangar_slug'};

    if ($source eq 'hangar') {
        ($ids{'hangar_owner'} ne '' && $ids{'hangar_slug'} ne '')
            or &error($text{'mc_mod_install_failed'} || 'Could not prepare mod installation.');
    } else {
        $ids{'project_id'} ne ''
            or &error($text{'mc_mod_install_failed'} || 'Could not prepare mod installation.');
    }

    my $versions = _mods_versions_for_source(
        $source,
        $ids{'project_id'},
        $ids{'hangar_owner'},
        $ids{'hangar_slug'},
        $profile,
    );

    my $safe_id = &html_escape($instance_id);
    my $display_name = $ids{'title'} // '';
    $display_name = $ids{'project_id'} // '' unless $display_name =~ /\S/;
    $display_name = $ids{'hangar_slug'} // '' if $source eq 'hangar' && $display_name !~ /\S/;

    &header($text{'mc_mods_page_versions_title'} || 'Choose mod version', '');
    print "<h3>" . &html_escape($text{'mc_mods_page_versions_title'} || 'Choose mod version') . "</h3>\n";
    print "<p><strong>" . &html_escape($text{'mc_mods_page_versions_mod'} || 'Mod')
        . ":</strong> " . &html_escape($display_name) . "<br>\n";
    print "<strong>" . &html_escape($text{'mc_mods_col_source'} || 'Source')
        . ":</strong> " . &html_escape(_mods_source_label_for_row($source))
        . "</p>\n";

    if (!@$versions) {
        print "<p>" . &html_escape($text{'mc_mods_page_versions_empty'}
            || 'No compatible versions found for this profile.')
            . "</p>\n";
    } else {
        my @rows;
        for my $row (@$versions) {
            next unless ref($row) eq 'HASH';
            my $name = $row->{'name'} // $row->{'display_name'} // '';
            $name = $row->{'version_id'} // $row->{'file_id'} // '?' unless $name =~ /\S/;
            my $file = $row->{'filename'} // '';
            my $published = $row->{'published'} // '';
            my $is_current = 0;
            $is_current = 1 if ($source eq 'modrinth' && ($ids{'version_id'} // '') ne ''
                && ($ids{'version_id'} // '') eq ($row->{'version_id'} // ''));
            $is_current = 1 if ($source eq 'curseforge' && ($ids{'file_id'} // '') ne ''
                && ($ids{'file_id'} // '') eq ($row->{'file_id'} // ''));
            $is_current = 1 if ($source eq 'hangar' && ($ids{'version_id'} // '') ne ''
                && ($ids{'version_id'} // '') eq ($row->{'version_id'} // ''));
            my $current_mark = $is_current
                ? (' <small>(' . &html_escape($text{'mc_mods_page_versions_current_mark'} || 'Current') . ')</small>')
                : '';

            my $action_form = &html_escape($text{'mc_mods_page_readonly_mod_hint'} || 'Read-only');
            unless (&user_is_readonly($instance_id)) {
                $action_form = &ui_form_start('mods.cgi', 'post');
                $action_form .= &ui_hidden('instance_id', $safe_id);
                $action_form .= &ui_hidden('xnavigation', '1');
                $action_form .= _mods_hidden_list_state($q, $status, $sort, $dir, $page);
                $action_form .= _mods_hidden_mod_search_state($mod_q);
                $action_form .= &ui_hidden('action', 'mc_mod_install');
                $action_form .= &ui_hidden('mod_source', $source);
                $action_form .= &ui_hidden('mod_project_id', $ids{'project_id'} // '');
                $action_form .= &ui_hidden('mod_hangar_owner', $ids{'hangar_owner'} // '');
                $action_form .= &ui_hidden('mod_hangar_slug', $ids{'hangar_slug'} // '');
                $action_form .= &ui_hidden('mod_title', $ids{'title'} // '');
                $action_form .= &ui_hidden('mod_version_id', $row->{'version_id'} // '');
                $action_form .= &ui_hidden('mod_file_id', $row->{'file_id'} // '');
                $action_form .= &ui_submit($text{'mc_mods_page_versions_install_btn'} || 'Install version',
                    undef, undef, undef, 'btn-primary');
                $action_form .= &ui_form_end();
            }

            push @rows, [
                &html_escape($name) . $current_mark,
                &html_escape($file),
                &html_escape($published),
                $action_form,
            ];
        }
        print &ui_columns_table(
            [
                $text{'mc_mods_page_versions_col_version'} || 'Version',
                $text{'mc_mods_page_versions_col_file'}    || 'File',
                $text{'mc_mods_page_versions_col_date'}    || 'Published',
                $text{'mc_mods_page_versions_col_action'}  || 'Action',
            ],
            '100%',
            \@rows,
        );
    }

    print &ui_form_start('mods.cgi', 'get');
    print &ui_hidden('instance_id', $safe_id);
    print &ui_hidden('xnavigation', '1');
    print _mods_hidden_list_state($q, $status, $sort, $dir, $page);
    print _mods_hidden_mod_search_state($mod_q);
    print &ui_submit($text{'mc_mods_page_versions_back_btn'} || 'Back to mods',
        undef, undef, undef, 'btn-default');
    print &ui_form_end();
    &footer('', '');
    exit;
}

if ($action eq 'monitor') {
    my $source = &instance_effective_source($inst);
    my @log_candidates;
    if ($source eq 'steamcmd') {
        my @raw;
        my $rel_live = &get_game_live_log_path($script_name);
        if ($rel_live ne '') {
            (my $abs_live = "$server_dir/$rel_live") =~ s{//+}{/}g;
            push @raw, $abs_live;
        }
        my $logs_dir = "$server_dir/serverfiles/R5/Saved/Logs";
        my $newest_ue = '';
        if (-d $logs_dir && opendir(my $dh, $logs_dir)) {
            my @logs = grep { /\.log$/i } readdir($dh);
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
        push @raw,
            "$server_dir/log/console/${script_name}-console.log",
            "$server_dir/log/script/${script_name}.log",
            "$server_dir/log/${script_name}.log";
        my %seen;
        @log_candidates = grep { !$seen{$_}++ } @raw;
    } else {
        @log_candidates = (
            "$server_dir/log/console/${script_name}-console.log",
            "$server_dir/log/script/${script_name}.log",
            "$server_dir/log/${script_name}.log",
        );
    }
    my ($log_file) = grep { -f $_ } @log_candidates;
    my $auto_refresh = (($in{'auto_refresh'} // '') eq '1' && ($in{'manual'} // '') eq '1') ? 1 : 0;

    &header($text{'mc_mods_page_monitor_title'} || 'Server log (live)', '');
    print &job_log_view_page_css();
    print &job_log_view_page_open();
    print "<h3>" . &html_escape($text{'mc_mods_page_monitor_title'} || 'Server log (live)') . "</h3>\n";
    print &job_log_view_toolbar_open();

    print &ui_form_start('mods.cgi', 'get');
    print &ui_hidden('instance_id', &html_escape($instance_id));
    print &ui_hidden('action', 'monitor');
    print &ui_hidden('xnavigation', '1');
    print &ui_hidden('manual', '1');
    print &ui_checkbox('auto_refresh', 1,
        $text{'mc_mods_page_monitor_auto_label'} || 'Auto refresh (2s)', $auto_refresh);
    print " ";
    print &ui_submit($text{'mc_mods_page_monitor_refresh_btn'} || 'Refresh',
        undef, undef, undef, 'btn-default');
    print &ui_form_end();

    print &ui_form_start('mods.cgi', 'get');
    print &ui_hidden('instance_id', &html_escape($instance_id));
    print &ui_hidden('xnavigation', '1');
    print &ui_submit($text{'mc_mods_page_monitor_back_btn'} || 'Back to mods',
        undef, undef, undef, 'btn-default');
    print &ui_form_end();

    print &job_log_view_toolbar_close();

    if (!$log_file) {
        print "<p>" . &html_escape($text{'mc_mods_page_monitor_no_log'}
            || 'No log file found. Server must have been started at least once.')
            . "</p>\n";
    } else {
        my $log_dir  = dirname($log_file);
        my $log_base = basename($log_file);
        my $enc_dir  = _filemin_path_urlencode($log_dir);
        my $enc_file = _filemin_path_urlencode($log_base);
        my $href_edit = "/filemin/edit_file.cgi?path=$enc_dir&file=$enc_file";
        my $href_dl   = "/filemin/download.cgi?path=$enc_dir&file=$enc_file";
        my $href_dir  = "/filemin/?path=$enc_dir";
        my $hint = $text{'mc_mods_page_monitor_filemin_hint'}
            || 'Open folder lists the log directory; use Download for very large files.';
        print "<p><small>" . &html_escape($text{'mc_mods_page_monitor_shown_file'} || 'Log file')
            . ": <code>" . &html_escape($log_file) . "</code><br>\n";
        print "<a href=\"" . &html_escape($href_edit)
            . "\" target=\"_blank\" rel=\"noopener noreferrer\">"
            . &html_escape($text{'mc_mods_page_monitor_log_edit'} || 'View in file manager')
            . "</a> - ";
        print "<a href=\"" . &html_escape($href_dl)
            . "\" target=\"_blank\" rel=\"noopener noreferrer\">"
            . &html_escape($text{'mc_mods_page_monitor_log_download'} || 'Download full log')
            . "</a> - ";
        print "<a href=\"" . &html_escape($href_dir)
            . "\" target=\"_blank\" rel=\"noopener noreferrer\">"
            . &html_escape($text{'mc_mods_page_monitor_log_folder'} || 'Open log folder')
            . "</a><br>\n";
        print &html_escape($hint) . "</small></p>\n";

        open(my $f, '<', $log_file) or do {
            print "<p>" . &html_escape($text{'mc_mods_page_monitor_no_log'} || 'No log file found.') . "</p>\n";
            print &job_log_view_page_close();
            &footer('', '');
            exit;
        };
        my $content = do { local $/; <$f> };
        close($f);
        $content //= '';
        my $len  = length($content);
        my $tail = $len > 8192 ? substr($content, $len - 8192) : $content;
        my $refresh_url = "mods.cgi?instance_id=" . &html_escape($instance_id)
            . "&action=monitor&xnavigation=1&auto_refresh=1&manual=1";
        if ($auto_refresh) {
            print "<meta http-equiv=\"refresh\" content=\"2;url=$refresh_url\">\n";
        }
        print &job_log_view_block($tail, id => 'monitor_log');
    }

    print &job_log_view_page_close();
    &footer('', '');
    exit;
}

my $safe_id = &html_escape($instance_id);
&header($text{'mc_mods_page_title'} || 'Mods', '');

unless (&mc_mod_ui_ready($profile, $server_dir)) {
    print "<h3>" . &html_escape($text{'mc_mods_page_title'} || 'Mods') . "</h3>\n";
    print "<p>" . &html_escape($text{'mc_mods_page_gate_not_ready'}
        || 'Mods page is available after Minecraft Java and loader setup is complete.')
        . "</p>\n";
    print &ui_form_start('manage.cgi', 'get');
    print &ui_hidden('instance_id', $safe_id);
    print &ui_hidden('xnavigation', '1');
    print &ui_submit($text{'mc_mods_page_back_manage'} || 'Back to manage',
        undef, undef, undef, 'btn-default');
    print &ui_form_end();
    &footer('', '');
    exit;
}

my $runtime_status = &instance_runtime_status($inst);
if (($in{'mod_enabled'} // '') eq '1' && &module_config_flash_consume('mod_enabled')) {
    print &ui_success($text{'mc_mods_page_enabled_ok'} || 'Mod enabled.');
}
if (($in{'mod_disabled'} // '') eq '1' && &module_config_flash_consume('mod_disabled')) {
    print &ui_success($text{'mc_mods_page_disabled_ok'} || 'Mod disabled.');
}
if (($in{'mod_deleted'} // '') eq '1' && &module_config_flash_consume('mod_deleted')) {
    print &ui_success($text{'mc_mods_page_deleted_ok'} || 'Mod deleted.');
}

print "<h3>" . &html_escape($text{'mc_mods_page_header'} || 'Minecraft mods') . "</h3>\n";
print "<p><strong>" . &html_escape($text{'mc_mods_page_instance_label'} || 'Instance')
    . ":</strong> $safe_id<br>\n";
print "<strong>" . &html_escape($text{'mc_mods_page_status_label'} || 'Status')
    . ":</strong> " . _mods_status_badge_html($runtime_status) . "</p>\n";

if (&user_is_readonly($instance_id)) {
    print "<p>" . &html_escape($text{'mc_mods_page_readonly_hint'}
        || 'Read-only mode: Start/Stop actions are disabled.')
        . "</p>\n";
} else {
    print &ui_form_start('mods.cgi', 'post');
    print &ui_hidden('instance_id', $safe_id);
    print &ui_hidden('xnavigation', '1');
    print &ui_hidden('action', 'start');
    print &ui_submit($text{'mc_mods_page_start_btn'} || 'Start',
        undef, undef, undef, 'btn-success');
    print &ui_form_end();

    print &ui_form_start('mods.cgi', 'post');
    print &ui_hidden('instance_id', $safe_id);
    print &ui_hidden('xnavigation', '1');
    print &ui_hidden('action', 'stop');
    print &ui_submit($text{'mc_mods_page_stop_btn'} || 'Stop',
        undef, undef, undef, 'btn-default');
    print &ui_form_end();
}

print &ui_form_start('mods.cgi', 'get');
print &ui_hidden('instance_id', $safe_id);
print &ui_hidden('action', 'monitor');
print &ui_hidden('xnavigation', '1');
print &ui_submit($text{'mc_mods_page_log_btn'} || 'Log',
    undef, undef, undef, 'btn-default');
print &ui_form_end();

print &ui_form_start('manage.cgi', 'get');
print &ui_hidden('instance_id', $safe_id);
print &ui_hidden('xnavigation', '1');
print &ui_submit($text{'mc_mods_page_back_manage'} || 'Back to manage',
    undef, undef, undef, 'btn-default');
print &ui_form_end();

print "<h4>" . &html_escape($text{'mc_modpack_section'} || 'Import modpack') . "</h4>\n";
print "<p>" . &html_escape($text{'mc_modpack_section_desc'}
    || 'Search modpacks online or import an existing pack file from server path.')
    . "</p>\n";
&module_config_sync_in();
if (&modpack_cf_auto_resume_enabled()) {
    print "<p><em>" . &html_escape($text{'mc_modpack_auto_resume_active'}
        || 'Auto-resume enabled: jobs continue after rate-limit pauses.')
        . "</em></p>\n";
} else {
    print "<p><small><i>" . &html_escape($text{'mc_modpack_auto_resume_off_hint'}
        || 'For large CurseForge packs, enable auto-resume in Integrations.')
        . "</i></small></p>\n";
}

print "<h4>" . &html_escape($text{'mc_modpack_search_section'} || 'Modpack search') . "</h4>\n";
print &ui_form_start('mods.cgi', 'get');
print &ui_hidden('instance_id', $safe_id);
print &ui_hidden('xnavigation', '1');
print _mods_hidden_list_state($q, $status, $sort, $dir, $page);
print _mods_hidden_mod_search_state($mod_q);
print &ui_table_start('', undef, 2);
print &ui_table_row(
    &html_escape($text{'mc_modpack_search_label'} || 'Modpack search'),
    &ui_textbox('pack_q', $pack_q, 40, 0, undef,
        'placeholder="' . &html_escape($text{'mc_modpack_search_placeholder'}) . '"')
);
print &ui_table_end();
print &ui_submit($text{'mc_modpack_search_btn'} || 'Search',
    undef, undef, undef, 'btn-default');
print &ui_form_end();

if (length($pack_q) >= 2) {
    my $search = &mc_modpack_search($pack_q, $profile);
    $search = { ok => 0, results => [], errors => ['search_failed'] }
        unless ref($search) eq 'HASH';
    my $cf_only_hint_shown = 0;
    for my $code (@{ $search->{'errors'} // [] }) {
        if ($code eq 'curseforge_key_missing') {
            print "<p><em>" . &html_escape($text{'mc_mods_cf_key_hint'}) . "</em></p>\n";
        }
        if ($code eq 'curseforge_recommended') {
            print "<p><em>" . &html_escape($text{'mc_modpack_cf_only_hint'}) . "</em></p>\n";
            $cf_only_hint_shown = 1;
        }
    }
    my $filtered_incompatible = grep { $_ eq 'filtered_incompatible' }
        @{ $search->{'errors'} // [] };
    my $results = $search->{'results'} // [];
    if (!@$results) {
        print "<p>" . &html_escape($text{'mc_modpack_no_results'} || 'No matching modpacks found.') . "</p>\n";
        if ($filtered_incompatible) {
            print "<p><em>" . &html_escape($text{'mc_modpack_filtered_incompatible'}) . "</em></p>\n";
        }
        if (&mc_modpack_query_likely_curseforge_only($pack_q) && !$cf_only_hint_shown) {
            print "<p><em>" . &html_escape($text{'mc_modpack_cf_only_hint'}) . "</em></p>\n";
        }
    } else {
        my @rows;
        for my $r (@$results) {
            next unless ref($r) eq 'HASH';
            my $src = $r->{'source'} // '';
            my $src_label = $text{"mc_mods_source_$src"} // $src;
            my $title = &html_escape($r->{'title'} // '?');
            my $desc = $r->{'description'} // '';
            $desc = &html_escape(substr($desc, 0, 120)) if $desc =~ /\S/;

            my $compat_line = '';
            my @compat_parts;
            push @compat_parts, &html_escape($r->{'pack_mc'})
                if ($r->{'pack_mc'} // '') =~ /\S/;
            push @compat_parts, &html_escape($r->{'pack_loader'})
                if ($r->{'pack_loader'} // '') =~ /\S/;
            if (@compat_parts) {
                $compat_line = "<br><small style=\"opacity:0.75\">"
                    . &html_escape($text{'mc_modpack_pack_target_label'} || 'Version:')
                    . ' ' . join(' &middot; ', @compat_parts) . "</small>";
            }

            my $import_form = &html_escape($text{'mc_mods_page_readonly_mod_hint'} || 'Read-only');
            unless (&user_is_readonly($instance_id)) {
                $import_form = &ui_form_start('mods.cgi', 'post');
                $import_form .= &ui_hidden('instance_id', $safe_id);
                $import_form .= &ui_hidden('action', 'modpack_import_remote');
                $import_form .= &ui_hidden('xnavigation', '1');
                $import_form .= _mods_hidden_list_state($q, $status, $sort, $dir, $page);
                $import_form .= _mods_hidden_mc_search_state($mod_q, $pack_q);
                $import_form .= &ui_hidden('pack_source', $src);
                $import_form .= &ui_hidden('pack_project_id', $r->{'project_id'} // '');
                $import_form .= &ui_hidden('pack_version_id', $r->{'version_id'} // '');
                $import_form .= &ui_hidden('pack_file_id', $r->{'file_id'} // '');
                $import_form .= &ui_hidden('pack_title', $r->{'title'} // '');
                $import_form .= &ui_submit($text{'mc_modpack_import_search_btn'} || 'Install',
                    undef, undef, undef, 'btn-primary');
                $import_form .= &ui_form_end();
            }

            push @rows, [
                "$title<br><small>$desc</small>$compat_line",
                &html_escape($src_label),
                $import_form,
            ];
        }
        print &ui_columns_table(
            [
                $text{'mc_mods_col_name'}      || 'Name',
                $text{'mc_mods_col_source'}    || 'Source',
                $text{'mc_modpack_col_import'} || 'Action',
            ],
            '100%',
            \@rows,
        );
    }
}

print "<h4>" . &html_escape($text{'mc_modpack_path_section'} || 'Own file (FTP/SFTP)') . "</h4>\n";
print "<p>" . &html_escape($text{'mc_modpack_server_limit_hint'}
    || 'Server-side import supports large packs.')
    . "</p>\n";
my $filemin_html = '';
if ($server_dir && -d $server_dir) {
    my $enc = _filemin_path_urlencode($server_dir);
    $filemin_html = " <a href='/filemin/?path=$enc' target='_blank'>"
        . &html_escape($text{'mc_modpack_filemin_link'} || 'Open file manager') . "</a>";
}
print &ui_form_start('mods.cgi', 'post');
print &ui_hidden('instance_id', $safe_id);
print &ui_hidden('action', 'modpack_import_path');
print &ui_hidden('xnavigation', '1');
print _mods_hidden_list_state($q, $status, $sort, $dir, $page);
print _mods_hidden_mc_search_state($mod_q, $pack_q);
print &ui_table_start('', undef, 2);
my $path_ph = $text{'mc_modpack_path_placeholder'} || '';
if ($server_dir) {
    $path_ph = "$server_dir/modpack.mrpack";
}
print &ui_table_row(
    &html_escape($text{'mc_modpack_path_label'} || 'Absolute file path'),
    &ui_textbox('modpack_path', '', 60, 0, undef,
        'placeholder="' . &html_escape($path_ph) . '"')
        . "<br><small>" . &html_escape($text{'mc_modpack_path_hint'} || '')
        . $filemin_html . "</small>"
);
print &ui_table_end();
print &ui_submit($text{'mc_modpack_import_path_btn'} || 'Import',
    undef, undef, undef, 'btn-primary');
print &ui_form_end();

_mods_render_modpack_resume_ui(
    $instance_id, $server_dir, undef, undef,
    $pack_q, $q, $status, $sort, $dir, $page, $mod_q
);

print "<h4>" . &html_escape($text{'mc_mods_section'} || 'Mods / plugins') . "</h4>\n";
print "<p>" . &html_escape($text{'mc_mods_section_desc'}
    || 'Search and install mods or Paper plugins. Only server-compatible entries are shown; loader and MC version must match the profile.')
    . "</p>\n";
print &ui_form_start('mods.cgi', 'get');
print &ui_hidden('instance_id', $safe_id);
print &ui_hidden('xnavigation', '1');
print _mods_hidden_list_state($q, $status, $sort, $dir, $page);
print &ui_table_start('', undef, 2);
print &ui_table_row(
    &html_escape($text{'mc_mods_search_label'} || 'Search'),
    &ui_textbox('mod_q', $mod_q, 40, 0, undef,
        'placeholder="' . &html_escape($text{'mc_mods_search_placeholder'}) . '"')
);
print &ui_table_end();
print &ui_submit($text{'mc_mods_search_btn'} || 'Search',
    undef, undef, undef, 'btn-default');
print &ui_form_end();

if (length($mod_q) >= 2) {
    my $search = &mc_mod_search($mod_q, $profile);
    $search = { ok => 0, results => [], errors => ['search_failed'] }
        unless ref($search) eq 'HASH';
    for my $code (@{ $search->{'errors'} // [] }) {
        if ($code eq 'curseforge_key_missing') {
            print "<p><em>" . &html_escape($text{'mc_mods_cf_key_hint'}) . "</em></p>\n";
        }
    }
    my $results = $search->{'results'} // [];
    if (!@$results) {
        print "<p>" . &html_escape($text{'mc_mods_no_results'} || 'No matching mods or plugins found.') . "</p>\n";
    } else {
        my @rows;
        for my $r (@$results) {
            next unless ref($r) eq 'HASH';
            my $src = $r->{'source'} // '';
            my $src_label = $text{"mc_mods_source_$src"} // $src;
            my $env = $r->{'env'} // 'unknown';
            my $env_label = $text{"mc_mod_env_$env"} // $env;
            my $title = &html_escape($r->{'title'} // '?');
            my $desc = $r->{'description'} // '';
            $desc = &html_escape(substr($desc, 0, 120)) if $desc =~ /\S/;

            my $actions = &html_escape($text{'mc_mods_page_readonly_mod_hint'} || 'Read-only');
            unless (&user_is_readonly($instance_id)) {
                my $install_form = &ui_form_start('mods.cgi', 'post');
                $install_form .= &ui_hidden('instance_id', $safe_id);
                $install_form .= &ui_hidden('action', 'mc_mod_install');
                $install_form .= &ui_hidden('xnavigation', '1');
                $install_form .= _mods_hidden_list_state($q, $status, $sort, $dir, $page);
                $install_form .= _mods_hidden_mod_search_state($mod_q);
                $install_form .= &ui_hidden('mod_source', $src);
                $install_form .= &ui_hidden('mod_project_id', $r->{'project_id'} // '');
                $install_form .= &ui_hidden('mod_version_id', $r->{'version_id'} // '');
                $install_form .= &ui_hidden('mod_file_id', $r->{'file_id'} // '');
                $install_form .= &ui_hidden('mod_hangar_owner', $r->{'hangar_owner'} // '');
                $install_form .= &ui_hidden('mod_hangar_slug', $r->{'hangar_slug'} // '');
                $install_form .= &ui_hidden('mod_title', $r->{'title'} // '');
                $install_form .= &ui_submit($text{'mc_mods_install_btn'} || 'Install',
                    undef, undef, undef, 'btn-primary');
                $install_form .= &ui_form_end();
                $actions = $install_form;

                my $version_url = "mods.cgi?instance_id=" . _mods_query_urlencode($instance_id)
                    . "&action=mod_search_versions&xnavigation=1"
                    . "&mod_source=" . _mods_query_urlencode($src)
                    . "&mod_project_id=" . _mods_query_urlencode($r->{'project_id'} // '')
                    . "&mod_version_id=" . _mods_query_urlencode($r->{'version_id'} // '')
                    . "&mod_file_id=" . _mods_query_urlencode($r->{'file_id'} // '')
                    . "&mod_hangar_owner=" . _mods_query_urlencode($r->{'hangar_owner'} // '')
                    . "&mod_hangar_slug=" . _mods_query_urlencode($r->{'hangar_slug'} // '')
                    . "&mod_title=" . _mods_query_urlencode($r->{'title'} // '');
                my $qs = _mods_list_qs($q, $status, $sort, $dir, $page);
                $version_url .= "&$qs" if $qs ne '';
                $version_url .= "&mod_q=" . _mods_query_urlencode($mod_q) if length($mod_q) >= 2;
                $actions .= "<br><a href=\"" . &html_escape($version_url) . "\">"
                    . &html_escape($text{'mc_mods_page_update_btn'} || 'Choose version')
                    . "</a>";
            }

            push @rows, [
                "$title<br><small>$desc</small>",
                &html_escape($src_label),
                &html_escape($env_label),
                $actions,
            ];
        }
        print &ui_columns_table(
            [
                $text{'mc_mods_col_name'}    || 'Name',
                $text{'mc_mods_col_source'}  || 'Source',
                $text{'mc_mods_col_side'}    || 'Side',
                $text{'mc_mods_col_install'} || 'Action',
            ],
            '100%',
            \@rows,
        );
    }
}

my $all_mods = &list_installed_mods($server_dir, $profile);
my $filtered_mods = &filter_installed_mods($all_mods, {
    q      => $q,
    status => $status,
});
my $sorted_mods = &sort_installed_mods($filtered_mods, $sort, $dir);
my ($paged_mods, $total_mods, $total_pages) = &paginate_installed_mods($sorted_mods, $page, 50);
$total_mods ||= 0;
$total_pages ||= 1;
$page = $total_pages if $page > $total_pages;

print "<h4>" . &html_escape($text{'mc_mods_page_installed_title'} || 'Installed mods') . "</h4>\n";

print &ui_form_start('mods.cgi', 'get');
print &ui_hidden('instance_id', $safe_id);
print &ui_hidden('xnavigation', '1');
print _mods_hidden_mod_search_state($mod_q);
print &ui_table_start('', undef, 2);
print &ui_table_row(
    &html_escape($text{'mc_mods_page_filter_q'} || 'Search'),
    &ui_textbox('q', $q, 40)
);
print &ui_table_row(
    &html_escape($text{'mc_mods_page_filter_status'} || 'Status'),
    &ui_select('status', $status, [
        [ 'all',      $text{'mc_mods_page_filter_status_all'}      || 'All' ],
        [ 'enabled',  $text{'mc_mods_page_filter_status_enabled'}  || 'Enabled' ],
        [ 'disabled', $text{'mc_mods_page_filter_status_disabled'} || 'Disabled' ],
    ])
);
print &ui_table_row(
    &html_escape($text{'mc_mods_page_filter_sort'} || 'Sort'),
    &ui_select('sort', $sort, [
        [ 'name',   $text{'mc_mods_page_filter_sort_name'}   || 'Name' ],
        [ 'status', $text{'mc_mods_page_filter_sort_status'} || 'Status' ],
    ])
);
print &ui_table_row(
    &html_escape($text{'mc_mods_page_filter_dir'} || 'Direction'),
    &ui_select('dir', $dir, [
        [ 'asc',  $text{'mc_mods_page_filter_dir_asc'}  || 'Ascending' ],
        [ 'desc', $text{'mc_mods_page_filter_dir_desc'} || 'Descending' ],
    ])
);
print &ui_table_end();
print &ui_submit($text{'mc_mods_page_filter_apply'} || 'Apply',
    undef, undef, undef, 'btn-default');
print &ui_form_end();

if ($total_mods == 0) {
    print "<p>" . &html_escape($text{'mc_mods_page_empty'} || 'No installed mods found.') . "</p>\n";
} else {
    my @rows;
    for my $mod (@$paged_mods) {
        next unless ref($mod) eq 'HASH';
        my $display_name = $mod->{'title'} // '';
        $display_name = $mod->{'basename'} // '' unless $display_name =~ /\S/;
        my $filename = $mod->{'filename_on_disk'} // ($mod->{'basename'} // '');
        my $source = _mods_source_label_for_row($mod->{'source'} // '');
        my $status_label = _mods_status_label_for_row(($mod->{'enabled'} // 0) ? 1 : 0);
        my $basename = $mod->{'basename'} // '';
        my $actions = '';
        if (&user_is_readonly($instance_id)) {
            $actions = &html_escape($text{'mc_mods_page_readonly_mod_hint'} || 'Read-only');
        } else {
            my $toggle_action = ($mod->{'enabled'} // 0) ? 'mod_disable' : 'mod_enable';
            my $toggle_label  = ($mod->{'enabled'} // 0)
                ? ($text{'mc_mods_page_disable_btn'} || 'Disable')
                : ($text{'mc_mods_page_enable_btn'}  || 'Enable');
            my $toggle_class  = ($mod->{'enabled'} // 0) ? 'btn-default' : 'btn-success';
            $actions .= &ui_form_start('mods.cgi', 'post');
            $actions .= &ui_hidden('instance_id', $safe_id);
            $actions .= &ui_hidden('xnavigation', '1');
            $actions .= _mods_hidden_list_state($q, $status, $sort, $dir, $page);
            $actions .= _mods_hidden_mod_search_state($mod_q);
            $actions .= &ui_hidden('action', $toggle_action);
            $actions .= &ui_hidden('mod_basename', $basename);
            $actions .= &ui_submit($toggle_label, undef, undef, undef, $toggle_class);
            $actions .= &ui_form_end();

            my $confirm = $text{'mc_mods_page_delete_confirm'}
                || 'Really delete this mod file?';
            $actions .= &ui_form_start('mods.cgi', 'post',
                "onsubmit=\"return confirm('" . &html_escape($confirm) . "')\"");
            $actions .= &ui_hidden('instance_id', $safe_id);
            $actions .= &ui_hidden('xnavigation', '1');
            $actions .= _mods_hidden_list_state($q, $status, $sort, $dir, $page);
            $actions .= _mods_hidden_mod_search_state($mod_q);
            $actions .= &ui_hidden('action', 'mod_delete');
            $actions .= &ui_hidden('mod_basename', $basename);
            $actions .= &ui_submit($text{'mc_mods_page_delete_btn'} || 'Delete',
                undef, undef, undef, 'btn-danger');
            $actions .= &ui_form_end();

            if ($mod->{'has_update_meta'}) {
                my $versions_url = "mods.cgi?instance_id=" . _mods_query_urlencode($instance_id)
                    . "&action=mod_versions&basename=" . _mods_query_urlencode($basename)
                    . "&xnavigation=1";
                my $qs = _mods_list_qs($q, $status, $sort, $dir, $page);
                $versions_url .= "&$qs" if $qs ne '';
                $versions_url .= "&mod_q=" . _mods_query_urlencode($mod_q) if length($mod_q) >= 2;
                $actions .= "<a href=\"" . &html_escape($versions_url) . "\">"
                    . &html_escape($text{'mc_mods_page_update_btn'} || 'Choose version')
                    . "</a>";
            } else {
                $actions .= "<small>" . &html_escape(
                    $text{'mc_mods_page_update_unavailable'} || 'No version data available.'
                ) . "</small>";
            }
        }

        push @rows, [
            &html_escape($display_name),
            &html_escape($filename),
            &html_escape($source),
            &html_escape($status_label),
            $actions,
        ];
    }
    print &ui_columns_table(
        [
            $text{'mc_mods_page_col_name'}     || 'Name',
            $text{'mc_mods_page_col_filename'} || 'Filename',
            $text{'mc_mods_page_col_source'}   || 'Source',
            $text{'mc_mods_page_col_status'}   || 'Status',
            $text{'mc_mods_page_col_actions'}  || 'Actions',
        ],
        '100%',
        \@rows,
    );

    print "<p><small>" . &html_escape(sprintf(
        $text{'mc_mods_page_page_info'} || 'Page %d of %d (%d entries).',
        $page, $total_pages, $total_mods
    )) . "</small></p>\n";

    if ($total_pages > 1) {
        my @nav;
        if ($page > 1) {
            my $prev_url = _mods_list_url($instance_id, $q, $status, $sort, $dir, $page - 1);
            push @nav, "<a href=\"" . &html_escape($prev_url) . "\">"
                . &html_escape($text{'mc_mods_page_prev'} || 'Previous') . "</a>";
        }
        if ($page < $total_pages) {
            my $next_url = _mods_list_url($instance_id, $q, $status, $sort, $dir, $page + 1);
            push @nav, "<a href=\"" . &html_escape($next_url) . "\">"
                . &html_escape($text{'mc_mods_page_next'} || 'Next') . "</a>";
        }
        if (@nav) {
            print "<p>" . join(' | ', @nav) . "</p>\n";
        }
    }
}

print "<p><small>" . &html_escape($text{'mc_mods_page_restart_hint'}
    || 'Hint: restart the server after enable/disable so the loader picks up changes.')
    . "</small></p>\n";

&footer('', '');
