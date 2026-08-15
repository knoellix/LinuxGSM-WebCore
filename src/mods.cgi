#!/usr/bin/perl
use strict;
use warnings;
use File::Basename qw(dirname basename);

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/instance.pl';
require './lib/acl.pl';
require './lib/jobs.pl';
require './lib/monitor.pl';
require './lib/games_meta.pl';
require './lib/mc_profile.pl';
require './lib/mc_loader.pl';
require './lib/live_log.pl';

our (%text, %config, %in, %gconfig);
our ($module_root, $module_root_directory, $module_name, $config_directory);
$module_root ||= $module_root_directory;
$module_root ||= do { (my $d = __FILE__) =~ s{/[^/]+$}{}; $d };
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

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

sub _mods_redirect_job_live {
    my ($job_id, $instance_id, %opts) = @_;
    $job_id or _mods_job_launch_failed();
    my $url = "job_live.cgi?instance_id=" . &html_escape($instance_id)
        . "&job=" . &html_escape($job_id)
        . "&xnavigation=1";
    $url .= "&next_status=" . &html_escape($opts{'next_status'}) if $opts{'next_status'};
    my $return_target = "mods.cgi?instance_id=" . _mods_query_urlencode($instance_id);
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

my $instance_id = &sanitize_input($in{'instance_id'} || $in{'user'} || '');
my $inst = &get_instance_flexible($instance_id) or &error($text{'err_not_found'});
my $unix_user = $inst->{'user'} // '';
my ($script_path, $script_name, $server_dir) = _parse_script_info($inst);
my $action = $in{'action'} // '';
$action =~ s/[^a-z_]//g;

&user_can_manage($instance_id)
    or &error($text{'err_acl_admin_only'} || 'Access denied');

if ($action ne '' && $action ne 'monitor' && $action !~ /^(?:start|stop)$/) {
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

my $profile = &read_mc_profile($server_dir);
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

print "<p>" . &html_escape($text{'mc_mods_page_placeholder'}
    || 'Installed mods, search, and modpack sections follow in upcoming tasks.')
    . "</p>\n";

&footer('', '');
