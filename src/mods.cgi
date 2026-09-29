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
require './lib/logging.pl';
require './lib/monitor.pl';
require './lib/games_meta.pl';
require './lib/module_config.pl';
require './lib/mc_profile.pl';
require './lib/mc_loader.pl';
require './lib/mc_mods.pl';
require './lib/mc_modpack.pl';
require './lib/mc_upgrade.pl';
require './lib/live_log.pl';
require './lib/server_log.pl';
require './lib/server_control_bar.pl';

our (%text, %config, %in, %gconfig);
our ($module_root, $module_root_directory, $module_name, $config_directory);
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

# Same pattern as manage.cgi: keep action forms/links side-by-side with spacing.
sub _mods_inline_action_btn {
    my ($html) = @_;
    $html //= '';
    # Webmin forms default to block; force inline so toolbar/row actions sit in one line.
    $html =~ s/<form(\s)/<form style="display:inline-block;margin:0;vertical-align:middle"$1/i;
    return "<span style='display:inline-block;margin:0 8px 6px 0;vertical-align:middle'>$html</span>";
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
    my ($instance_id, $q, $status, $sort, $dir, $page, $mod_q) = @_;
    my $url = "mods.cgi?instance_id=" . _mods_query_urlencode($instance_id)
        . "&xnavigation=1";
    my $qs = _mods_list_qs($q, $status, $sort, $dir, $page);
    $url .= "&$qs" if $qs ne '';
    $mod_q = _mods_mod_search_query($mod_q // '');
    $url .= "&mod_q=" . _mods_query_urlencode($mod_q) if length($mod_q) >= 2;
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

sub _mods_modpack_save_upload {
    my ($job_dir, $upload_name, $upload_data, $unix_user) = @_;
    return (0, 'missing') unless defined $upload_data && length($upload_data) > 0;
    my $max = 800 * 1024 * 1024;
    return (0, 'too_large') if length($upload_data) > $max;
    $upload_name //= 'pack.mrpack';
    $upload_name = basename($upload_name);
    $upload_name =~ s/[^a-zA-Z0-9._-]//g;
    $upload_name = 'pack.mrpack' unless $upload_name =~ /\.(mrpack|zip)\z/i;
    my $upload_dir = "$job_dir/upload";
    mkdir($upload_dir, 0750) or return (0, 'mkdir');
    my $path = "$upload_dir/$upload_name";
    open(my $fh, '>', $path) or return (0, 'write');
    binmode($fh);
    print $fh $upload_data;
    close($fh);
    if (defined $unix_user && $unix_user ne '') {
        &chown_job_files_to_user($unix_user, $upload_dir, $path);
    }
    return (1, $path);
}

sub _mods_launch_modpack_upload {
    my ($instance_id, $inst, $unix_user, $upload_name, $upload_data) = @_;
    my (undef, undef, $server_dir) = _parse_script_info($inst);
    my $profile = &read_mc_profile($server_dir);
    &error($text{'mc_profile_missing'} || 'No Minecraft profile.') unless $profile;

    my $job_id = &create_job($unix_user);
    my $job_dir = &_job_dir($job_id);
    my ($saved, $save_err) = _mods_modpack_save_upload(
        $job_dir, $upload_name, $upload_data, $unix_user);
    unless ($saved) {
        &delete_job($job_id);
        if (($save_err // '') eq 'too_large') {
            &error($text{'mc_modpack_too_large'} || 'Modpack too large.');
        }
        if (($save_err // '') eq 'missing') {
            &error($text{'mc_modpack_upload_missing'} || 'No file selected.');
        }
        &error($text{'mc_modpack_upload_failed'} || 'Modpack import failed.');
    }

    return _mods_finish_modpack_import_job(
        $job_id, $instance_id, $inst, $unix_user, $save_err, $profile, $server_dir);
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
    my $target = _mods_list_url($instance_id, $q, $status, $sort, $dir, $page, $mod_q);
    $target .= '&pack_q=' . _mods_query_urlencode($pack_q) if length($pack_q // '') >= 2;
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

sub _mods_env_label_for_row {
    my ($env) = @_;
    $env = lc($env // 'unknown');
    $env =~ s/[^a-z]//g;
    return $text{"mc_mod_env_$env"} // $env if $env =~ /\A(?:server|client|both|unknown)\z/;
    return $text{'mc_mod_env_unknown'} || 'Unknown';
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

# Webmin has no dedicated success helper; match manage/integrations alert pattern.
sub _mods_print_success {
    my ($msg) = @_;
    return unless defined $msg && $msg =~ /\S/;
    print "<div class='alert alert-success'>" . &html_escape($msg) . "</div>\n";
}

sub _mods_last_run_row_html {
    my ($epoch, $text_template, $job_id, $instance_id) = @_;
    return '' unless defined $epoch && $epoch =~ /^\d+$/ && $epoch > 0;
    my $lr_ts = &monitor_format_restart_time($epoch);
    $lr_ts = '—' unless defined $lr_ts && $lr_ts ne '';
    my $lr_html = &html_escape(&text($text_template, $lr_ts));
    $job_id = '' unless defined $job_id;
    $job_id =~ s/[^0-9a-f]//g;
    if (length($job_id) == 16 && defined $instance_id && $instance_id =~ /\S/) {
        $lr_html .= ' — ' . &job_log_open_link_html($job_id,
            $text{'jobs_view_log'} || $text{'monitor_job_link'} || 'Log');
    }
    return $lr_html;
}

sub _mods_render_instance_jobs_table {
    my ($instance_id, $max_rows) = @_;
    $max_rows //= 8;
    return unless defined $instance_id && $instance_id =~ /\S/;
    &sync_monitor_job_pointers();
    my @inst_jobs = &jobs_dedupe_periodic_restarts(&get_instance_jobs($instance_id));
    return unless @inst_jobs;
    @inst_jobs = @inst_jobs[0 .. ($max_rows - 1)] if @inst_jobs > $max_rows;

    my $running = grep { ($_->{'status'} // '') eq 'running' } @inst_jobs;
    print &job_log_view_page_css();
    print &ui_collapsible_start($text{'jobs_title'} || 'Jobs',
        id    => 'jobs',
        force => ($running ? 1 : 0),
        badge => &job_status_label($inst_jobs[0]{'status'}, \%text),
    );
    my $labels = &job_action_labels_hash(\%text);
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
        my $out_cell = '—';
        if ($status eq 'running') {
            my $live_url = "job_live.cgi?instance_id=" . &html_escape($instance_id)
                . "&amp;job=" . &html_escape($jid) . "&amp;xnavigation=1";
            $out_cell = "<a href='$live_url'>"
                . &html_escape($text{'manage_job_open_live'} || 'Live log') . "</a>";
        } elsif ($status eq 'ok' || $status eq 'failed' || $status eq 'aborted') {
            $out_cell = &job_log_open_link_html($jid, $text{'jobs_view_log'} || 'Log');
        }
        my $act_label = $labels->{$act} // $act // '—';
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
    if (@rows) {
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
    print "<div id=\"job-log-card-slot\"></div>\n";
    print &ui_collapsible_end();
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

sub _mods_source_has_dep_preview {
    my ($source) = @_;
    $source =~ s/[^a-z]//g;
    return $source eq 'modrinth' || $source eq 'curseforge';
}

sub _mods_mod_install_error {
    my ($err) = @_;
    if ($err eq 'file_exists' || $err eq 'index_project') {
        &error($text{'mc_mod_already_installed'} || 'This mod is already installed.');
    } elsif ($err eq 'curseforge_key_missing') {
        &error($text{'mc_modpack_curseforge_key_missing'});
    } elsif ($err eq 'client_only') {
        &error($text{'mc_mod_client_only'} || 'Client-only mod.');
    } elsif ($err eq 'resolve_failed' || $err eq 'dep_resolve_failed') {
        &error($text{'mc_mod_resolve_failed'} || 'Could not resolve mod version.');
    } elsif ($err eq 'deps_too_many') {
        &error($text{'mc_mod_deps_deps_too_many'}
            || 'Too many required dependencies (max. 5 auto-install).');
    } else {
        &error($text{'mc_mod_install_failed'} || 'Could not prepare mod installation.');
    }
}

sub _mods_render_dependency_table {
    my ($status) = @_;
    return '' unless ref($status) eq 'HASH';
    my @rows;
    my %state_key = (
        satisfied => 'mc_mod_deps_satisfied',
        missing   => 'mc_mod_deps_missing',
        optional  => 'mc_mod_deps_optional',
    );
    for my $kind (qw(satisfied missing optional)) {
        for my $dep (@{ $status->{$kind} // [] }) {
            next unless ref($dep) eq 'HASH';
            my $pid = $dep->{'project_id'} // '';
            next unless $pid =~ /\S/;
            my $dtype = $dep->{'dependency_type'} // 'required';
            my $type_label = $dtype eq 'optional'
                ? ($text{'mc_mod_deps_optional'} || 'Optional')
                : ($text{'mc_mod_deps_required'} || 'Required');
            push @rows, [
                &html_escape($pid),
                &html_escape($text{ $state_key{$kind} } // $kind),
                &html_escape($type_label),
            ];
        }
    }
    return '<p>' . &html_escape($text{'mc_mod_deps_none'} || 'No mod dependencies.')
        . "</p>\n" unless @rows;
    return &ui_columns_table(
        [
            $text{'mc_mod_deps_col_mod'}   || 'Dependency',
            $text{'mc_mod_deps_col_state'} || 'Status',
            $text{'mc_mod_deps_col_type'}  || 'Type',
        ],
        '100%',
        \@rows,
    );
}

sub _mods_install_deps_checkbox {
    my ($checked) = @_;
    $checked = 1 unless defined $checked;
    # Do not emit ui_hidden('install_deps','0') alongside the checkbox — Webmin
    # ReadParse then yields an arrayref / "\0"-joined value and bare eq '1' fails,
    # which silently disables dependency auto-install. Use a separate present flag.
    my $out = &ui_hidden('install_deps_present', '1');
    $out .= &ui_checkbox(
        'install_deps',
        '1',
        &html_escape($text{'mc_mod_deps_install_with'} || 'Install required dependencies'),
        $checked ? 1 : 0,
    );
    return $out;
}

sub _mods_install_preview_qs {
    my (%args) = @_;
    my @parts = (
        'action=mod_install_preview',
        'xnavigation=1',
        'instance_id=' . _mods_query_urlencode($args{'instance_id'} // ''),
    );
    my @keys = qw(mod_source mod_project_id mod_version_id mod_file_id
        mod_hangar_owner mod_hangar_slug mod_title mod_basename
        q status sort dir page mod_q);
    for my $k (@keys) {
        next unless defined $args{$k} && $args{$k} ne '';
        push @parts, "$k=" . _mods_query_urlencode($args{$k});
    }
    return join('&', @parts);
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
    my %prepare_opts;
    $prepare_opts{'force_replace'} = 1 if $replace_basename ne '';
    my $install_deps = defined $opts{'install_deps'} ? ($opts{'install_deps'} ? 1 : 0) : 1;
    $prepare_opts{'install_deps'} = $install_deps if _mods_source_has_dep_preview($source);

    my ($ok, $meta, $err, $plan);
    if ($opts{'cached_plan'} && ref($opts{'cached_plan'}) eq 'HASH') {
        $plan = $opts{'cached_plan'};
        $ok = 1;
        $meta = $plan->{'primary'};
        unless (ref($meta) eq 'HASH') {
            _mods_mod_install_error('invalid');
        }
        # Cached plans are built with install_deps=1; if the user unchecked the
        # box, drop resolved deps and enforce the missing-required guard.
        if (!$install_deps) {
            $plan->{'dependencies'} = [];
        }
    } elsif (_mods_source_has_dep_preview($source)) {
        ($ok, $plan, $err) = &build_mod_install_plan(
            $source, $ids_ref, $profile, $server_dir, \%prepare_opts);
        unless ($ok) {
            _mods_mod_install_error($err);
        }
        $meta = $plan->{'primary'};
    } else {
        ($ok, $meta, $err) = &prepare_mod_install_meta(
            $source, $ids_ref, $profile, $server_dir,
            $replace_basename ne '' ? { force_replace => 1 } : undef);
        unless ($ok) {
            _mods_mod_install_error($err);
        }
    }

    if (_mods_source_has_dep_preview($source) && ref($plan) eq 'HASH') {
        my $status = $plan->{'status'} // {};
        my @missing_required = grep {
            (&normalize_mod_dependency_type($_->{'dependency_type'} // '') eq 'required')
        } @{ $status->{'missing'} // [] };
        if (@missing_required && !$install_deps) {
            &error($text{'mc_mod_deps_missing_blocked'}
                || 'Install blocked: missing required dependencies.');
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
    my $meta_ok = 0;
    if (_mods_source_has_dep_preview($source)
        && ref($plan) eq 'HASH'
        && ref($plan->{'dependencies'}) eq 'ARRAY'
        && @{ $plan->{'dependencies'} }) {
        $plan->{'primary'} = $meta;
        $meta_ok = &write_mod_install_plan_job_meta($job_dir, $plan, $unix_user);
    } else {
        $meta_ok = &write_mod_install_job_meta($job_dir, $meta, $unix_user);
    }
    unless ($meta_ok) {
        &delete_job($job_id);
        &error($text{'mc_mod_meta_failed'} || 'Job preparation failed.');
    }
    &write_job_meta($job_id, $instance_id, 'mc_mod_install', $unix_user)
        or do { &job_mark_launch_failed($job_id); _mods_job_launch_failed(); };
    _mods_write_job_worker_secrets($job_dir, $unix_user);

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

sub _mods_pick_selected {
    my ($wanted, $candidates) = @_;
    return '' unless ref($candidates) eq 'ARRAY' && @$candidates;
    $wanted //= '';
    $wanted =~ s/[^0-9.]//g;
    return $wanted if $wanted =~ /^[0-9.]+$/ && grep { $_ eq $wanted } @$candidates;
    return $candidates->[0];
}

sub _mods_upgrade_check_form {
    my ($instance_id, $mode, $field, $selected, $candidates, $btn_label, $label) = @_;
    my $out = &ui_form_start('mods.cgi', 'post');
    $out .= &ui_hidden('instance_id', &html_escape($instance_id));
    $out .= &ui_hidden('action', 'upgrade_check');
    $out .= &ui_hidden('check_mode', $mode);
    $out .= &ui_hidden('xnavigation', '1');
    $out .= &ui_table_start('', undef, 2);
    $out .= &ui_table_row($label,
        &ui_select($field, $selected, [ map { [ $_, $_ ] } @$candidates ]));
    $out .= &ui_table_end();
    $out .= &ui_submit($btn_label, undef, undef, undef, 'btn-default');
    $out .= &ui_form_end();
    return $out;
}

# Ordered upgrade check: chosen dimension → opposite dimension → mods.
# Version lists come from cache only, so opening the page stays offline.
sub _mods_render_upgrade_check_section {
    my ($instance_id, $server_dir, $profile, $chain, $sel) = @_;
    return unless ref($profile) eq 'HASH';
    return unless &mc_loader_is_modded($profile->{'loader'} // '');
    return if &user_is_readonly($instance_id);
    return unless &user_can_operate($instance_id);
    $sel = {} unless ref($sel) eq 'HASH';

    my $loader = $profile->{'loader'} // '';
    my $cur_mc = $profile->{'mc_version'} // '';
    my @mc_avail = &mc_upgrade_cached_mc_versions({ no_fetch => 1 });
    my @mc_cand = @mc_avail
        ? &mc_upgrade_mc_upgrade_candidates($profile, \@mc_avail) : ();
    my @ld_avail = &mc_upgrade_cached_loader_versions($loader, $cur_mc, { no_fetch => 1 });
    my @ld_cand = @ld_avail
        ? &mc_upgrade_loader_upgrade_candidates($profile, \@ld_avail) : ();
    my $lists_loaded = (@mc_avail || @ld_avail) ? 1 : 0;

    my $has_chain = ref($chain) eq 'HASH' ? 1 : 0;
    my $badge = '';
    if ($has_chain) {
        my $mods_step = ref($chain->{'steps'}) eq 'HASH'
            ? ($chain->{'steps'}{'mods'} // {}) : {};
        my $issues = $mods_step->{'issues'} // 0;
        $badge = $issues > 0
            ? &text('mods_badge_compat_issues', $issues)
            : ($text{'mods_badge_compat_clean'} || '');
    } elsif (!$lists_loaded) {
        $badge = $text{'mods_badge_versions_unloaded'} || '';
    } elsif (@mc_cand || @ld_cand) {
        my @parts;
        push @parts, &text('mods_badge_mc_available', $mc_cand[0]) if @mc_cand;
        push @parts, &text('mods_badge_loader_builds', scalar @ld_cand) if @ld_cand;
        $badge = join(' · ', @parts);
    } else {
        $badge = $text{'mods_badge_no_updates'} || '';
    }

    print &ui_collapsible_start(
        $text{'mc_upgrade_check_title'} || 'Upgrade check',
        id    => 'upgrade-check',
        force => $has_chain,
        badge => $badge,
        hint  => ($text{'mc_upgrade_check_hint'} || ''),
    );

    if (@mc_cand) {
        print _mods_upgrade_check_form(
            $instance_id, 'mc', 'compat_mc',
            _mods_pick_selected($sel->{'mc'}, \@mc_cand), \@mc_cand,
            $text{'mc_upgrade_check_btn_mc'} || 'Check Minecraft version',
            $text{'mc_mods_compat_target'} || 'Target Minecraft version',
        );
    }
    if (@ld_cand) {
        print _mods_upgrade_check_form(
            $instance_id, 'loader', 'compat_loader',
            _mods_pick_selected($sel->{'loader'}, \@ld_cand), \@ld_cand,
            $text{'mc_upgrade_check_btn_loader'} || 'Check loader build',
            $text{'mc_upgrade_check_loader_target'} || 'Target loader build',
        );
    }
    if (@mc_cand || @ld_cand) {
        my $rec = &ui_form_start('mods.cgi', 'post');
        $rec .= &ui_hidden('instance_id', &html_escape($instance_id));
        $rec .= &ui_hidden('action', 'upgrade_check');
        $rec .= &ui_hidden('check_mode', 'recommended');
        $rec .= &ui_hidden('xnavigation', '1');
        $rec .= &ui_submit($text{'mc_upgrade_check_btn_recommended'} || 'Check recommended upgrade',
            undef, undef, undef, 'btn-default');
        $rec .= &ui_form_end();
        print _mods_inline_action_btn($rec);
    } elsif ($lists_loaded) {
        print "<p>" . &html_escape($text{'mc_upgrade_check_no_candidates'}
            || 'No newer Minecraft version or loader build available.') . "</p>\n";
    }

    my $reload = &ui_form_start('mods.cgi', 'post');
    $reload .= &ui_hidden('instance_id', &html_escape($instance_id));
    $reload .= &ui_hidden('action', 'upgrade_versions');
    $reload .= &ui_hidden('xnavigation', '1');
    $reload .= &ui_submit(
        $lists_loaded
            ? ($text{'mc_upgrade_versions_reload_btn'} || 'Reload versions')
            : ($text{'mc_upgrade_versions_load_btn'} || 'Load versions'),
        undef, undef, undef, 'btn-default');
    $reload .= &ui_form_end();
    print _mods_inline_action_btn($reload);

    if ($has_chain) {
        my $html = &mc_upgrade_render_check_chain_html($chain);
        print $html if defined $html && $html ne '';
    }
    print &ui_collapsible_end();
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

my $mods_upgrade_chain;
my $mods_compat_mc = $in{'compat_mc'} // '';
$mods_compat_mc =~ s/[^0-9.]//g;
my $mods_compat_loader = $in{'compat_loader'} // '';
$mods_compat_loader =~ s/[^0-9.]//g;

&user_can_manage($instance_id)
    or &error($text{'err_acl_admin_only'} || 'Access denied');

if ($action ne '' && $action !~ /^(?:monitor|poll_monitor|job_log_card|monitor_disable|monitor_reset|start|stop|restart|mod_enable|mod_disable|mod_delete|mod_versions|mod_search_versions|mod_install_preview|mc_mod_install|modpack_import|modpack_import_path|modpack_import_remote|modpack_import_resume|mod_compat_scan|upgrade_check|upgrade_versions)$/) {
    &error($text{'err_invalid_action'} || 'Invalid action');
}
if ($action ne '' && $action !~ /^(?:monitor|poll_monitor|job_log_card)$/ && &user_is_readonly($instance_id)) {
    &error($text{'err_readonly'} || 'This server is read-only for your account');
}

if ($action eq 'monitor_disable') {
    &user_can_operate($instance_id)
        or &error($text{'err_acl_admin_only'} || 'Access denied');
    &set_monitor_disabled($server_dir, $config_directory, $instance_id);
    _mods_rebuild_monitor_cron();
    &module_config_flash_mark('monitor_disabled')
        or &error($text{'err_generic'} || 'Could not confirm action.');
    &redirect('mods.cgi?instance_id=' . &urlize($instance_id)
        . '&monitor_disabled=1&xnavigation=1');
    exit;
}
if ($action eq 'monitor_reset') {
    &user_can_operate($instance_id)
        or &error($text{'err_acl_admin_only'} || 'Access denied');
    &set_monitor_running($server_dir, $config_directory, $instance_id);
    _mods_rebuild_monitor_cron();
    &module_config_flash_mark('monitor_enabled')
        or &error($text{'err_generic'} || 'Could not confirm action.');
    &redirect('mods.cgi?instance_id=' . &urlize($instance_id)
        . '&monitor_enabled=1&xnavigation=1');
    exit;
}

if ($action eq 'start' || $action eq 'stop' || $action eq 'restart') {
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

    if ($action ne 'stop') {
        my $mon = &read_monitor_state($server_dir, $config_directory, $instance_id);
        unless (($mon->{status} // '') eq 'disabled') {
            my $ready = &get_start_ready_config($script_name);
            my $secs = ($ready->{secs} && $ready->{regex}) ? $ready->{secs} : 180;
            &set_monitor_starting($server_dir, $config_directory, $instance_id, &monitor_starting_until($secs));
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
    }
    _mods_rebuild_monitor_cron();
    my $next_status = &job_next_instance_status($action);
    if (($action eq 'start' || $action eq 'restart') && &server_log_start_log_enabled()) {
        &server_log_start_log_flash_mark($instance_id)
            or _mods_job_launch_failed();
        my $url = _mods_list_url($instance_id, $q, $status, $sort, $dir, $page)
            . '&start_log=1';
        &redirect($url);
        exit;
    }
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

if ($action eq 'mod_install_preview') {
    &mc_mod_ui_ready($profile, $server_dir)
        or &error($text{'mc_mods_page_gate_not_ready'}
            || 'Mods page is available after Minecraft Java and loader setup is complete.');

    my $source = '';
    my %ids;
    my %launch_opts;
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
    }
    _mods_source_has_dep_preview($source)
        or &error($text{'mc_mod_install_failed'} || 'Could not prepare mod installation.');

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

    my %prepare_opts;
    $prepare_opts{'force_replace'} = 1 if ($launch_opts{'replace_basename'} // '') ne '';
    $prepare_opts{'install_deps'} = 1;
    my ($ok, $plan, $err) = &build_mod_install_plan(
        $source, \%ids, $profile, $server_dir, \%prepare_opts);
    unless ($ok) {
        _mods_mod_install_error($err);
    }

    my $safe_id = &html_escape($instance_id);
    my $display_name = $ids{'title'} // $ids{'project_id'} // '';
    my $dep_status = $plan->{'status'} // {};
    my $primary = $plan->{'primary'} // {};

    &header($text{'mc_mod_deps_title'} || 'Mod dependencies', '');
    print "<h3>" . &html_escape($text{'mc_mod_deps_title'} || 'Mod dependencies') . "</h3>\n";
    print "<p><strong>" . &html_escape($text{'mc_mods_col_name'} || 'Name')
        . ":</strong> " . &html_escape($display_name) . "<br>\n";
    print "<strong>" . &html_escape($text{'mc_mods_page_versions_col_file'} || 'File')
        . ":</strong> " . &html_escape($primary->{'filename'} // '') . "</p>\n";
    print _mods_render_dependency_table($dep_status);

    my $preview_token = '';
    if (_mods_source_has_dep_preview($source)) {
        $preview_token = &store_mod_install_preview(
            $instance_id, $source, \%ids, $plan, 1, \%prepare_opts);
    }

    unless (&user_is_readonly($instance_id)) {
        print &ui_form_start('mods.cgi', 'post');
        print &ui_hidden('instance_id', $safe_id);
        print &ui_hidden('xnavigation', '1');
        print _mods_hidden_list_state($q, $status, $sort, $dir, $page);
        print _mods_hidden_mod_search_state($mod_q);
        print &ui_hidden('action', 'mc_mod_install');
        if ($mod_basename ne '') {
            print &ui_hidden('mod_basename', $mod_basename);
            print &ui_hidden('mod_version_id', $ids{'version_id'} // '');
            print &ui_hidden('mod_file_id', $ids{'file_id'} // '');
        } else {
            print &ui_hidden('mod_source', $source);
            print &ui_hidden('mod_project_id', $ids{'project_id'} // '');
            print &ui_hidden('mod_version_id', $ids{'version_id'} // '');
            print &ui_hidden('mod_file_id', $ids{'file_id'} // '');
            print &ui_hidden('mod_hangar_owner', &html_escape($ids{'hangar_owner'} // ''));
            print &ui_hidden('mod_hangar_slug', &html_escape($ids{'hangar_slug'} // ''));
            print &ui_hidden('mod_title', &html_escape($ids{'title'} // ''));
        }
        if ($preview_token ne '') {
            print &ui_hidden('mod_preview_token', &html_escape($preview_token));
        }
        print '<p>' . _mods_install_deps_checkbox(1) . "</p>\n";
        print &ui_submit($text{'mc_mod_deps_confirm_btn'} || 'Start installation',
            undef, undef, undef, 'btn-primary');
        print &ui_form_end();
    }

    print &ui_form_start('mods.cgi', 'get');
    print &ui_hidden('instance_id', $safe_id);
    print &ui_hidden('xnavigation', '1');
    print _mods_hidden_list_state($q, $status, $sort, $dir, $page);
    print _mods_hidden_mod_search_state($mod_q);
    print &ui_submit($text{'mc_mod_deps_back_btn'} || 'Back',
        undef, undef, undef, 'btn-default');
    print &ui_form_end();
    &footer('', '');
    exit;
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

    $launch_opts{'install_deps'} = &mod_install_deps_flag_from_form(
        $in{'install_deps'}, $in{'install_deps_present'});

    my $preview_token = $in{'mod_preview_token'} // '';
    $preview_token =~ s/[^0-9a-f]//g;
    $preview_token = substr($preview_token, 0, 16);
    if ($preview_token ne '' && _mods_source_has_dep_preview($source)) {
        my %prepare_opts_preview;
        $prepare_opts_preview{'force_replace'} = 1 if ($launch_opts{'replace_basename'} // '') ne '';
        $prepare_opts_preview{'install_deps'} = $launch_opts{'install_deps'};
        my $cached = &consume_mod_install_preview(
            $preview_token, $instance_id, $source, \%ids,
            $launch_opts{'install_deps'}, \%prepare_opts_preview);
        $launch_opts{'cached_plan'} = $cached if ref($cached) eq 'HASH';
    }

    my $job_id = _mods_launch_mod_install(
        $instance_id, $inst, $unix_user, $source, \%ids, %launch_opts
    );
    _mods_redirect_job_live($job_id, $instance_id, return_target => $return_target);
}

if ($action eq 'modpack_import') {
    $ENV{'REQUEST_METHOD'} eq 'POST'
        or &error($text{'err_invalid_action'} || 'Invalid action');
    &mc_mod_ui_ready($profile, $server_dir)
        or &error($text{'mc_mods_page_gate_not_ready'}
            || 'Mods page is available after Minecraft Java and loader setup is complete.');
    my $upload_data = $in{'modpack_file'};
    my $upload_name = $in{'modpack_file_filename'}
        // $in{'modpack_upload_filename'}
        // 'pack.mrpack';
    unless (defined $upload_data && length($upload_data) > 0) {
        &error($text{'mc_modpack_upload_missing'} || 'No file selected.');
    }
    my $job_id = _mods_launch_modpack_upload(
        $instance_id, $inst, $unix_user, $upload_name, $upload_data);
    my $return_target = _mods_page_return_target(
        $instance_id, $q, $status, $sort, $dir, $page, $mod_q, $pack_q);
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

# `mod_compat_scan` is the 0.2.2 name and stays as an alias for old links.
if ($action eq 'upgrade_check' || $action eq 'mod_compat_scan') {
    $ENV{'REQUEST_METHOD'} eq 'POST'
        or &error($text{'err_invalid_action'} || 'Invalid action');
    &user_can_operate($instance_id)
        or &error($text{'err_acl_admin_only'} || 'Access denied');
    &mc_mod_ui_ready($profile, $server_dir)
        or &error($text{'mc_mods_page_gate_not_ready'}
            || 'Mods page is available after Minecraft Java and loader setup is complete.');
    my $check_mode = $in{'check_mode'} // '';
    $check_mode =~ s/[^a-z]//g;
    $check_mode = 'mc' unless $check_mode =~ /^(?:mc|loader|recommended)$/;

    if ($check_mode eq 'recommended') {
        my @ld_avail = &mc_upgrade_cached_loader_versions(
            $profile->{'loader'} // '', $profile->{'mc_version'} // '', {});
        my @ld_cand = &mc_upgrade_loader_upgrade_candidates($profile, \@ld_avail);
        if (@ld_cand) {
            $check_mode = 'loader';
            $mods_compat_loader = $ld_cand[0];
        } else {
            my @mc_avail = &mc_upgrade_cached_mc_versions({});
            my @mc_cand = &mc_upgrade_mc_upgrade_candidates($profile, \@mc_avail);
            &error($text{'mc_upgrade_check_no_candidates'}
                || 'No newer Minecraft version or loader build available.') unless @mc_cand;
            $check_mode = 'mc';
            $mods_compat_mc = $mc_cand[0];
        }
    }

    $mods_upgrade_chain = &mc_upgrade_check_chain($server_dir, $profile, {
        mode                  => $check_mode,
        target_mc_version     => $mods_compat_mc,
        target_loader_version => $mods_compat_loader,
    }, {});
}

if ($action eq 'upgrade_versions') {
    $ENV{'REQUEST_METHOD'} eq 'POST'
        or &error($text{'err_invalid_action'} || 'Invalid action');
    &user_can_operate($instance_id)
        or &error($text{'err_acl_admin_only'} || 'Access denied');
    my $loader = $profile && ref($profile) eq 'HASH' ? ($profile->{'loader'} // '') : '';
    my $mc     = $profile && ref($profile) eq 'HASH' ? ($profile->{'mc_version'} // '') : '';
    &mc_upgrade_cache_forget(&mc_upgrade_version_cache_names($loader, $mc));
    my @mc_list = &mc_upgrade_cached_mc_versions({ refresh => 1 });
    my @ld_list = &mc_upgrade_cached_loader_versions($loader, $mc, { refresh => 1 });
    unless (@mc_list || @ld_list) {
        &error($text{'mc_upgrade_versions_load_failed'}
            || 'Could not load version lists — check network access to Mojang/Maven.');
    }
    my $url = _mods_page_return_target(
        $instance_id, $q, $status, $sort, $dir, $page, $mod_q, $pack_q);
    &redirect("$url#upgrade-check");
    exit;
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
    my $display_name = &_mc_mods_display_name($selected_mod);
    my $current_file = $selected_mod->{'filename_on_disk'} // ($selected_mod->{'basename'} // '');
    my $current_version = &mc_mod_installed_version_label($selected_mod);
    my $status_label = _mods_status_label_for_row(($selected_mod->{'enabled'} // 0) ? 1 : 0);

    &header($text{'mc_mods_page_versions_title'} || 'Choose mod version', '');
    print "<h3>" . &html_escape($text{'mc_mods_page_versions_title'} || 'Choose mod version') . "</h3>\n";
    print "<p><strong>" . &html_escape($text{'mc_mods_page_versions_mod'} || 'Mod')
        . ":</strong> " . &html_escape($display_name) . "<br>\n";
    if ($current_version =~ /\S/) {
        print "<strong>" . &html_escape($text{'mc_mods_page_versions_current_version'} || 'Current version')
            . ":</strong> " . &html_escape($current_version) . "<br>\n";
    }
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
                if (_mods_source_has_dep_preview($source)) {
                    my $preview_url = 'mods.cgi?' . _mods_install_preview_qs(
                        instance_id   => $instance_id,
                        mod_basename  => $selected_mod->{'basename'} // '',
                        mod_version_id => $row->{'version_id'} // '',
                        mod_file_id   => $row->{'file_id'} // '',
                        q             => $q,
                        status        => $status,
                        sort          => $sort,
                        dir           => $dir,
                        page          => $page,
                        mod_q         => $mod_q,
                    );
                    $action_form = _mods_inline_action_btn(
                        "<a href=\"" . &html_escape($preview_url) . "\">"
                        . &html_escape($text{'mc_mods_page_versions_install_btn'} || 'Install version')
                        . "</a>"
                    );
                } else {
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
                if (_mods_source_has_dep_preview($source)) {
                    my $preview_url = 'mods.cgi?' . _mods_install_preview_qs(
                        instance_id    => $instance_id,
                        mod_source     => $source,
                        mod_project_id => $ids{'project_id'} // '',
                        mod_hangar_owner => $ids{'hangar_owner'} // '',
                        mod_hangar_slug  => $ids{'hangar_slug'} // '',
                        mod_title      => $ids{'title'} // '',
                        mod_version_id => $row->{'version_id'} // '',
                        mod_file_id    => $row->{'file_id'} // '',
                        q              => $q,
                        status         => $status,
                        sort           => $sort,
                        dir            => $dir,
                        page           => $page,
                        mod_q          => $mod_q,
                    );
                    $action_form = _mods_inline_action_btn(
                        "<a href=\"" . &html_escape($preview_url) . "\">"
                        . &html_escape($text{'mc_mods_page_versions_install_btn'} || 'Install version')
                        . "</a>"
                    );
                } else {
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
                    $action_form .= &ui_hidden('mod_title', &html_escape($ids{'title'} // ''));
                    $action_form .= &ui_hidden('mod_version_id', $row->{'version_id'} // '');
                    $action_form .= &ui_hidden('mod_file_id', $row->{'file_id'} // '');
                    $action_form .= &ui_submit($text{'mc_mods_page_versions_install_btn'} || 'Install version',
                        undef, undef, undef, 'btn-primary');
                    $action_form .= &ui_form_end();
                }
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

if ($action eq 'job_log_card') {
    my $job_id = $in{'job'} // '';
    $job_id =~ s/[^0-9a-f]//g;
    $job_id = substr($job_id, 0, 16);
    &validate_job_for_instance($job_id, $instance_id)
        or &error($text{'err_not_found'});
    &job_log_card_json_emit($job_id, $instance_id, \%text);
}

if ($action eq 'poll_monitor') {
    my $source = &instance_effective_source($inst);
    my $payload = server_log_monitor_poll_payload(
        server_dir  => $server_dir,
        script_name => $script_name,
        source      => $source,
        minecraft   => 1,
        log_file    => $in{'log_file'},
    );
    $main::headerprinted = 1;
    print "Content-type: application/json; charset=utf-8\n\n";
    print job_log_json_utf8($payload);
    exit;
}

if ($action eq 'monitor') {
    my $source = &instance_effective_source($inst);
    my $mn = $module_name // $main::module_name // 'linuxgsm-webcore';
    $mn =~ s/[^a-zA-Z0-9_-]//g;

    &header($text{'mc_mods_page_monitor_title'} || 'Server log (live)', '');
    print &job_log_view_page_css();
    print &job_log_view_page_open('fill');
    print &job_log_live_page_js();
    &server_log_render_monitor_page(
        form_cgi       => 'mods.cgi',
        instance_id    => $instance_id,
        server_dir     => $server_dir,
        script_name    => $script_name,
        source         => $source,
        minecraft      => 1,
        log_file_pick  => $in{'log_file'},
        auto_refresh   => $in{'auto_refresh'},
        poll_url_base  => "/$mn/mods.cgi?instance_id=" . &urlize($instance_id)
            . '&action=poll_monitor',
        text_keys      => server_log_monitor_text_keys_mods(),
        back_forms     => [
            {
                cgi        => 'mods.cgi',
                label_keys => ['mc_mods_page_monitor_back_btn'],
                default    => 'Back to mods',
            },
            {
                cgi        => 'manage.cgi',
                label_keys => ['manage_monitor_back_btn'],
                default    => 'Back to instance',
            },
        ],
    );
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
    _mods_print_success($text{'mc_mods_page_enabled_ok'} || 'Mod enabled.');
}
if (($in{'mod_disabled'} // '') eq '1' && &module_config_flash_consume('mod_disabled')) {
    _mods_print_success($text{'mc_mods_page_disabled_ok'} || 'Mod disabled.');
}
if (($in{'mod_deleted'} // '') eq '1' && &module_config_flash_consume('mod_deleted')) {
    _mods_print_success($text{'mc_mods_page_deleted_ok'} || 'Mod deleted.');
}
if (($in{'monitor_disabled'} // '') eq '1' && &module_config_flash_consume('monitor_disabled')) {
    _mods_print_success($text{'mc_mods_page_monitor_disabled_ok'} || 'Monitoring disabled.');
}
if (($in{'monitor_enabled'} // '') eq '1' && &module_config_flash_consume('monitor_enabled')) {
    _mods_print_success($text{'mc_mods_page_monitor_enabled_ok'} || 'Monitoring enabled.');
}
{
    my $flash_id = $instance_id // '';
    $flash_id =~ s/[^a-zA-Z0-9_-]//g;
    if ($flash_id ne '' && &module_config_flash_consume("monitor_restart_$flash_id")) {
        &sync_monitor_job_pointers();
        my $mon_flash = &read_monitor_state($server_dir, $config_directory, $instance_id);
        my $lr_ts = &monitor_format_restart_time($mon_flash->{'last_restart_at'});
        $lr_ts = '—' unless $lr_ts ne '';
        my $banner = &text('manage_monitor_restart_banner', $lr_ts);
        $banner = "Der Server wurde automatisch durch Monitoring neugestartet ($lr_ts)."
            unless defined $banner && $banner =~ /\S/;
        my $banner_html = &html_escape($banner);
        my $lr_job = $mon_flash->{'last_restart_job'} // '';
        $lr_job =~ s/[^0-9a-f]//g;
        if (length($lr_job) == 16) {
            $banner_html .= ' ' . &job_log_open_link_html($lr_job, $text{'jobs_view_log'} || 'Log');
        }
        print "<div class='alert alert-warning'>" . $banner_html . "</div>\n";
    }
}

print "<h3>" . &html_escape($text{'mc_mods_page_header'} || 'Minecraft mods') . "</h3>\n";

&sync_monitor_job_pointers();
my $mon_state = &read_monitor_state($server_dir, $config_directory, $instance_id);
my $after_status = '';
{
    my $mon_status_key = 'monitor_status_' . ($mon_state->{'status'} // 'disabled');
    my $mon_label = $text{$mon_status_key} || ($mon_state->{'status'} // 'disabled');
    my $profile_html = '';
    if (ref($profile) eq 'HASH') {
        my @prof = grep { defined && /\S/ } (
            &mc_loader_label($profile->{'loader'}, $current_lang // 'de'),
            $profile->{'mc_version'},
            'Java ' . int($profile->{'java_major'} // 0),
        );
        $profile_html = &html_escape(join(' / ', @prof)) if @prof;
    }
    my @extra_parts = (
        &ui_instance_status_part($text{'monitor_col'} || 'Monitor', &html_escape($mon_label)),
        &ui_instance_status_part($text{'mc_profile_loader'} || 'Loader', $profile_html),
    );
    if (($mon_state->{'last_restart_at'} // 0) > 0) {
        my $lr_html = _mods_last_run_row_html(
            $mon_state->{'last_restart_at'}, 'monitor_last_restart',
            $mon_state->{'last_restart_job'}, $instance_id);
        $after_status .= "<p><strong>" . &html_escape($text{'monitor_last_restart_col'} || 'Last auto-restart')
            . ":</strong> " . $lr_html . "</p>\n";
    }
    if (&user_can_operate($instance_id) && !&user_is_readonly($instance_id)) {
        my $mon_s = $mon_state->{'status'} // 'disabled';
        $after_status .= "<div style='margin:0 0 12px 0'>\n";
        if ($mon_s eq 'failed' || $mon_s eq 'paused' || $mon_s eq 'disabled') {
            my $en = &ui_form_start('mods.cgi', 'post');
            $en .= &ui_hidden('instance_id', $safe_id);
            $en .= &ui_hidden('xnavigation', '1');
            $en .= &ui_hidden('action', 'monitor_reset');
            $en .= &ui_submit($text{'monitor_reset_btn'} || 'Enable monitoring',
                undef, undef, undef, 'btn-success');
            $en .= &ui_form_end();
            $after_status .= _mods_inline_action_btn($en);
        }
        if ($mon_s ne 'disabled') {
            my $dis = &ui_form_start('mods.cgi', 'post');
            $dis .= &ui_hidden('instance_id', $safe_id);
            $dis .= &ui_hidden('xnavigation', '1');
            $dis .= &ui_hidden('action', 'monitor_disable');
            $dis .= &ui_submit($text{'monitor_disable_btn'} || 'Disable monitoring',
                undef, undef, undef, 'btn-default');
            $dis .= &ui_form_end();
            $after_status .= _mods_inline_action_btn($dis);
        }
        $after_status .= "</div>\n";
    }
    print &server_control_bar_html(
        cgi                 => 'mods.cgi',
        instance_id         => $instance_id,
        readonly            => (&user_is_readonly($instance_id) ? 1 : 0),
        runtime_status_html => _mods_status_badge_html($runtime_status),
        extra_status_parts  => \@extra_parts,
        after_status_html   => $after_status,
        back_cgi            => 'manage.cgi',
    );
}

if (&server_log_start_log_should_show(\%in, $instance_id)) {
    my $mn = $module_name // $main::module_name // 'linuxgsm-webcore';
    $mn =~ s/[^a-zA-Z0-9_-]//g;
    print &server_log_embed_html(
        instance_id   => $instance_id,
        server_dir    => $server_dir,
        script_name   => $script_name,
        source        => &instance_effective_source($inst),
        minecraft     => 1,
        poll_url_base => "/$mn/mods.cgi?instance_id=" . &urlize($instance_id)
            . '&action=poll_monitor',
    );
}

_mods_render_instance_jobs_table($instance_id, 8);

_mods_render_upgrade_check_section(
    $instance_id, $server_dir, $profile, $mods_upgrade_chain,
    { mc => $mods_compat_mc, loader => $mods_compat_loader });

my ($resume_job_id, $resume_prog) =
    _mods_find_resumable_modpack_job($instance_id, $server_dir);

&module_config_sync_in();
print &ui_collapsible_start($text{'mc_modpack_section'} || 'Import modpack',
    id    => 'modpack',
    force => ($resume_job_id ? 1 : 0),
    open  => (length($pack_q) >= 2 ? 1 : 0),
    badge => ($resume_job_id ? ($text{'mods_badge_modpack_resumable'} || '') : ''),
    hint  => ($text{'mc_modpack_section_desc'} || ''),
);
if (&modpack_cf_auto_resume_enabled()) {
    print "<p><em>" . &html_escape($text{'mc_modpack_auto_resume_active'}
        || 'Auto-resume enabled: jobs continue after rate-limit pauses.')
        . "</em></p>\n";
} else {
    print "<p><small><i>" . &html_escape($text{'mc_modpack_auto_resume_off_hint'}
        || 'For large CurseForge packs, enable auto-resume in Integrations.')
        . "</i></small></p>\n";
}

print &ui_collapsible_start($text{'mc_modpack_search_section'} || 'Modpack search',
    id   => 'modpack-search',
    open => (length($pack_q) >= 2 ? 1 : 0),
);
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
                $compat_line = "<br><small>"
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
                $import_form .= &ui_hidden('pack_title', &html_escape($r->{'title'} // ''));
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

print &ui_collapsible_end();

print &ui_collapsible_start($text{'mc_modpack_upload_section'} || 'Browser upload',
    id   => 'modpack-upload',
    hint => ($text{'mc_modpack_upload_hint'} || ''),
);
unless (&user_is_readonly($instance_id)) {
    print &ui_form_start('mods.cgi', 'form-data');
    print &ui_hidden('instance_id', $safe_id);
    print &ui_hidden('action', 'modpack_import');
    print &ui_hidden('xnavigation', '1');
    print _mods_hidden_list_state($q, $status, $sort, $dir, $page);
    print _mods_hidden_mc_search_state($mod_q, $pack_q);
    print &ui_table_start('', undef, 2);
    print &ui_table_row(
        &html_escape($text{'mc_modpack_upload_label'} || 'Modpack file'),
        &ui_upload('modpack_file', 50)
            . "<br><small>" . &html_escape($text{'mc_modpack_upload_types'}
                || '.mrpack or CurseForge .zip') . "</small>"
    );
    print &ui_table_end();
    print &ui_submit($text{'mc_modpack_import_upload_btn'} || 'Upload and import',
        undef, undef, undef, 'btn-primary');
    print &ui_form_end();
}

print &ui_collapsible_end();

print &ui_collapsible_start($text{'mc_modpack_path_section'} || 'Own file (FTP/SFTP)',
    id   => 'modpack-path',
    hint => ($text{'mc_modpack_server_limit_hint'} || ''),
);
my $filemin_html = '';
if ($server_dir && -d $server_dir) {
    my $enc = &server_log_filemin_path_urlencode($server_dir);
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

print &ui_collapsible_end();

if ($resume_job_id) {
    print "<a id=\"modpack-resume\"></a>\n";
    _mods_render_modpack_resume_ui(
        $instance_id, $server_dir, $resume_job_id, $resume_prog,
        $pack_q, $q, $status, $sort, $dir, $page, $mod_q
    );
}

print &ui_collapsible_end();

print &ui_collapsible_start($text{'mc_mods_section'} || 'Mods / plugins',
    id   => 'mod-search',
    open => (length($mod_q) >= 2 ? 1 : 0),
    hint => ($text{'mc_mods_section_desc'} || ''),
);
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
                if (_mods_source_has_dep_preview($src)) {
                    my $preview_url = 'mods.cgi?' . _mods_install_preview_qs(
                        instance_id    => $instance_id,
                        mod_source     => $src,
                        mod_project_id => $r->{'project_id'} // '',
                        mod_version_id => $r->{'version_id'} // '',
                        mod_file_id    => $r->{'file_id'} // '',
                        mod_hangar_owner => $r->{'hangar_owner'} // '',
                        mod_hangar_slug  => $r->{'hangar_slug'} // '',
                        mod_title      => $r->{'title'} // '',
                        q              => $q,
                        status         => $status,
                        sort           => $sort,
                        dir            => $dir,
                        page           => $page,
                        mod_q          => $mod_q,
                    );
                    $actions = _mods_inline_action_btn(
                        "<a href=\"" . &html_escape($preview_url) . "\">"
                        . &html_escape($text{'mc_mods_install_btn'} || 'Install')
                        . "</a>"
                    );
                } else {
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
                    $install_form .= &ui_hidden('mod_hangar_owner', &html_escape($r->{'hangar_owner'} // ''));
                    $install_form .= &ui_hidden('mod_hangar_slug', &html_escape($r->{'hangar_slug'} // ''));
                    $install_form .= &ui_hidden('mod_title', &html_escape($r->{'title'} // ''));
                    $install_form .= &ui_submit($text{'mc_mods_install_btn'} || 'Install',
                        undef, undef, undef, 'btn-primary');
                    $install_form .= &ui_form_end();
                    $actions = _mods_inline_action_btn($install_form);
                }

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
                $actions .= _mods_inline_action_btn(
                    "<a href=\"" . &html_escape($version_url) . "\">"
                    . &html_escape($text{'mc_mods_page_update_btn'} || 'Choose version')
                    . "</a>"
                );
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

print &ui_collapsible_end();

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

print &ui_collapsible_start($text{'mc_mods_page_installed_title'} || 'Installed mods',
    id    => 'installed-mods',
    open  => 1,
    badge => &text('mods_badge_installed_count', $total_mods),
);

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
        my $display_name = &_mc_mods_display_name($mod);
        my $filename = $mod->{'filename_on_disk'} // ($mod->{'basename'} // '');
        my $source = _mods_source_label_for_row($mod->{'source'} // '');
        my $env_label = _mods_env_label_for_row($mod->{'env'} // 'unknown');
        my $status_label = _mods_status_label_for_row(($mod->{'enabled'} // 0) ? 1 : 0);
        my $version_label = &mc_mod_installed_version_label($mod);
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
            my $toggle_form = &ui_form_start('mods.cgi', 'post');
            $toggle_form .= &ui_hidden('instance_id', $safe_id);
            $toggle_form .= &ui_hidden('xnavigation', '1');
            $toggle_form .= _mods_hidden_list_state($q, $status, $sort, $dir, $page);
            $toggle_form .= _mods_hidden_mod_search_state($mod_q);
            $toggle_form .= &ui_hidden('action', $toggle_action);
            $toggle_form .= &ui_hidden('mod_basename', $basename);
            $toggle_form .= &ui_submit($toggle_label, undef, undef, undef, $toggle_class);
            $toggle_form .= &ui_form_end();
            $actions .= _mods_inline_action_btn($toggle_form);

            my $confirm = $text{'mc_mods_page_delete_confirm'}
                || 'Really delete this mod file?';
            my $delete_form = &ui_form_start('mods.cgi', 'post',
                "onsubmit=\"return confirm('" . &html_escape($confirm) . "')\"");
            $delete_form .= &ui_hidden('instance_id', $safe_id);
            $delete_form .= &ui_hidden('xnavigation', '1');
            $delete_form .= _mods_hidden_list_state($q, $status, $sort, $dir, $page);
            $delete_form .= _mods_hidden_mod_search_state($mod_q);
            $delete_form .= &ui_hidden('action', 'mod_delete');
            $delete_form .= &ui_hidden('mod_basename', $basename);
            $delete_form .= &ui_submit($text{'mc_mods_page_delete_btn'} || 'Delete',
                undef, undef, undef, 'btn-danger');
            $delete_form .= &ui_form_end();
            $actions .= _mods_inline_action_btn($delete_form);

            if ($mod->{'has_update_meta'}) {
                my $versions_url = "mods.cgi?instance_id=" . _mods_query_urlencode($instance_id)
                    . "&action=mod_versions&basename=" . _mods_query_urlencode($basename)
                    . "&xnavigation=1";
                my $qs = _mods_list_qs($q, $status, $sort, $dir, $page);
                $versions_url .= "&$qs" if $qs ne '';
                $versions_url .= "&mod_q=" . _mods_query_urlencode($mod_q) if length($mod_q) >= 2;
                $actions .= _mods_inline_action_btn(
                    "<a href=\"" . &html_escape($versions_url) . "\">"
                    . &html_escape($text{'mc_mods_page_update_btn'} || 'Choose version')
                    . "</a>"
                );
            } else {
                $actions .= _mods_inline_action_btn(
                    "<small>" . &html_escape(
                        $text{'mc_mods_page_update_unavailable'} || 'No version data available.'
                    ) . "</small>"
                );
            }
        }

        my $version_cell = $version_label =~ /\S/
            ? &html_escape($version_label)
            : &html_escape($text{'mc_mods_page_version_unknown'} || '—');

        push @rows, [
            &html_escape($display_name),
            &html_escape($filename),
            &html_escape($source),
            &html_escape($env_label),
            &html_escape($status_label),
            $version_cell,
            $actions,
        ];
    }
    print &ui_columns_table(
        [
            $text{'mc_mods_page_col_name'}     || 'Name',
            $text{'mc_mods_page_col_filename'} || 'Filename',
            $text{'mc_mods_page_col_source'}   || 'Source',
            $text{'mc_mods_page_col_env'}      || 'Side',
            $text{'mc_mods_page_col_status'}   || 'Status',
            $text{'mc_mods_page_col_version'}  || 'Version',
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
        print "<div style='text-align:right;margin:4px 0 12px 0'>\n";
        if ($page > 1) {
            my $prev_url = _mods_list_url(
                $instance_id, $q, $status, $sort, $dir, $page - 1, $mod_q);
            print _mods_inline_action_btn(
                "<a class=\"btn btn-default\" href=\"" . &html_escape($prev_url) . "\">"
                . &html_escape($text{'mc_mods_page_prev'} || 'Previous') . "</a>"
            );
        }
        if ($page < $total_pages) {
            my $next_url = _mods_list_url(
                $instance_id, $q, $status, $sort, $dir, $page + 1, $mod_q);
            print _mods_inline_action_btn(
                "<a class=\"btn btn-default\" href=\"" . &html_escape($next_url) . "\">"
                . &html_escape($text{'mc_mods_page_next'} || 'Next') . "</a>"
            );
        }
        print "</div>\n";
    }
}

print "<p><small>" . &html_escape($text{'mc_mods_page_restart_hint'}
    || 'Hint: restart the server after enable/disable so the loader picks up changes.')
    . "</small></p>\n";
print &ui_collapsible_end();

print &ui_collapsible_state_script();
print &job_log_card_client_js(
    fetch_url_template => &job_log_card_fetch_template('mods.cgi', $instance_id),
    loading            => $text{'job_log_card_loading'} || 'Loading…',
    load_failed        => $text{'job_log_card_failed'}  || 'Could not load log.',
);

&footer('', '');
