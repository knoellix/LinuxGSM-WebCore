#!/usr/bin/perl
# workshop.cgi — Steam Workshop search / subscribe (PZ-first)
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/instance.pl';
require './lib/acl.pl';
require './lib/jobs.pl';
require './lib/logging.pl';
require './lib/games_meta.pl';
require './lib/module_config.pl';
require './lib/pz_workshop.pl';

our (%text, %config, %in, %gconfig);
our ($module_root, $module_root_directory, $module_name, $config_directory);
our $current_lang;
$module_root ||= $module_root_directory;
$module_root ||= do { (my $d = __FILE__) =~ s{/[^/]+$}{}; $d };
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);
&module_config_sync_in();

sub _ws_parse_script_info {
    my ($inst) = @_;
    my $script_path = $inst->{'script'} // '';
    my ($script_name) = $script_path =~ m{/([^/]+)$};
    $script_name //= '';
    (my $server_dir = $script_path) =~ s{/[^/]+$}{};
    $script_name =~ s/[^a-zA-Z0-9_-]//g;
    return ($script_path, $script_name, $server_dir);
}

sub _ws_urlencode {
    my ($value) = @_;
    $value //= '';
    $value =~ s/([^A-Za-z0-9_\-.~])/sprintf('%%%02X', ord($1))/ge;
    return $value;
}

sub _ws_page_url {
    my ($instance_id, %extra) = @_;
    my $url = "workshop.cgi?instance_id=" . _ws_urlencode($instance_id) . "&xnavigation=1";
    for my $k (sort keys %extra) {
        my $v = $extra{$k};
        next unless defined $v && $v ne '';
        $url .= "&$k=" . _ws_urlencode($v);
    }
    return $url;
}

sub _ws_write_secrets {
    my ($job_dir, $unix_user) = @_;
    return 0 unless defined $job_dir && -d $job_dir;
    &module_config_sync_in();
    my %keys;
    my $k = $config{steam_web_api_key} // '';
    $keys{steam_web_api_key} = $k if $k =~ /\S/;
    return 0 unless %keys;
    return &write_job_worker_secrets($job_dir, $unix_user, \%keys);
}

sub _ws_launch_failed {
    &error($text{'workshop_job_launch_failed'}
        || $text{'manage_job_launch_failed'}
        || 'Background job could not be started.');
}

sub _ws_launch_subscribe {
    my ($instance_id, $inst, $unix_user, $workshop_id) = @_;
    my (undef, $script_name, $server_dir) = _ws_parse_script_info($inst);
    my $appid = &get_workshop_appid($script_name) || 108600;

    my $job_id = &create_job($unix_user);
    my $job_dir = &_job_dir($job_id);
    &write_job_meta($job_id, $instance_id, 'pz_workshop_subscribe', $unix_user)
        or do { &job_mark_launch_failed($job_id); return undef; };
    &pz_workshop_write_subscribe_job_meta($job_dir, {
        workshop_id    => $workshop_id,
        workshop_appid => $appid,
        script_name    => $script_name,
    }, $unix_user)
        or do { &delete_job($job_id); return undef; };
    _ws_write_secrets($job_dir, $unix_user);
    &log_action('job_started', $job_id, {
        instance_id => $instance_id,
        action      => 'pz_workshop_subscribe',
    });
    my $cmd = &user_worker_launch_cmd(
        unix_user   => $unix_user,
        module_root => $module_root,
        worker      => "$module_root/scripts/pz_workshop_subscribe_user.sh",
        args        => [ $job_dir, $unix_user, $server_dir, $script_name ],
        env         => { WEBCORE_JOB_DIR => $job_dir },
    );
    if (!defined $cmd || $cmd eq '') {
        &job_mark_launch_failed($job_id);
        return undef;
    }
    my $rc = &system_logged($cmd);
    if ($rc != 0 || !&job_dispatch_verified($job_id)) {
        &job_mark_launch_failed($job_id);
        return undef;
    }
    return $job_id;
}

sub _ws_action_failed {
    &error($text{'workshop_action_failed'} || 'Workshop action could not be completed.');
}

sub _ws_redirect_with_flash {
    my ($instance_id, $flash_key, $query_flag) = @_;
    $flash_key =~ s/[^a-z_]//g;
    $flash_key or _ws_action_failed();
    &module_config_flash_mark($flash_key)
        or _ws_action_failed();
    &redirect(_ws_page_url($instance_id, $query_flag => 1));
    exit;
}

sub _ws_find_inventory_row {
    my ($inventory, $wid) = @_;
    return undef unless ref($inventory) eq 'ARRAY';
    for my $row (@$inventory) {
        next unless ref($row) eq 'HASH';
        return $row if ($row->{'workshop_id'} // '') eq $wid;
    }
    return undef;
}

sub _ws_mod_ids_from_row {
    my ($row) = @_;
    return [] unless ref($row) eq 'HASH';
    my @ids;
    for my $mi (@{ $row->{'mod_infos'} // [] }) {
        next unless ref($mi) eq 'HASH';
        my $id = $mi->{'id'} // '';
        push @ids, $id if $id =~ /\S/;
    }
    return \@ids;
}

sub _ws_steam_preview_allowed {
    my ($url) = @_;
    return 0 unless defined $url && $url =~ m{\Ahttps://([^/?#]+)}i;
    my $host = lc($1);
    return 0 unless $host =~ /\A[a-z0-9][a-z0-9.\-]*\z/;
    my @allowed = qw(
        steamstatic.com
        steamusercontent.com
        steamcommunity.com
        akamaihd.net
    );
    for my $base (@allowed) {
        return 1 if $host eq $base;
        my $suffix = ".$base";
        return 1 if length($host) > length($suffix) && substr($host, -length($suffix)) eq $suffix;
    }
    return 0;
}

sub _ws_inline_action {
    my ($form_html) = @_;
    $form_html =~ s/<form(\s)/<form style="display:inline"$1/i;
    return $form_html . ' ';
}

sub _ws_status_label {
    my ($status) = @_;
    if ($status eq 'active') {
        return $text{'workshop_status_active'} || 'Active';
    }
    if ($status eq 'inactive') {
        return $text{'workshop_status_inactive'} || 'Inactive';
    }
    if ($status eq 'orphan_ini') {
        return $text{'workshop_status_orphan'} || 'INI only';
    }
    return $status // '';
}

sub _ws_render_mod_infos {
    my ($instance_id, $workshop_id, $mod_infos) = @_;
    return '<i>—</i>' unless ref($mod_infos) eq 'ARRAY' && @$mod_infos;
    my $can_act = &user_can_operate($instance_id) && !&user_is_readonly($instance_id);
    my @parts;
    for my $mi (@$mod_infos) {
        next unless ref($mi) eq 'HASH';
        my $name = $mi->{'name'} // '';
        my $id = $mi->{'id'} // '';
        next unless $id =~ /\S/;
        my $label = $name =~ /\S/ ? "$name ($id)" : "($id)";
        $label = &html_escape($label);
        my $ver = $mi->{'modversion'} // '';
        $label .= ' · v' . &html_escape($ver) if $ver =~ /\S/;
        my $req = $mi->{'pz_require'} // '';
        $label .= ' · PZ ' . &html_escape($req) if $req =~ /\S/;
        my $on = $mi->{'enabled_in_ini'} ? 1 : 0;
        $label .= ' · <b>' . &html_escape($on
            ? ($text{'workshop_mod_on'} || 'on')
            : ($text{'workshop_mod_off'} || 'off')) . '</b>';
        if ($can_act && length($workshop_id)) {
            my $act = $on ? 'disable_mod' : 'enable_mod';
            my $btn = $on
                ? ($text{'workshop_mod_disable_btn'} || 'Disable mod')
                : ($text{'workshop_mod_enable_btn'} || 'Enable mod');
            my $cls = $on ? 'btn-default' : 'btn-success';
            my $form = &ui_form_start('workshop.cgi', 'post');
            $form .= &ui_hidden('instance_id', &html_escape($instance_id));
            $form .= &ui_hidden('xnavigation', '1');
            $form .= &ui_hidden('action', $act);
            $form .= &ui_hidden('workshop_id', &html_escape($workshop_id));
            $form .= &ui_hidden('mod_id', &html_escape($id));
            $form .= &ui_submit($btn, undef, undef, undef, $cls);
            $form .= &ui_form_end();
            $label .= ' ' . _ws_inline_action($form);
        }
        push @parts, $label;
    }
    return join('<br>', @parts) if @parts;
    return '<i>—</i>';
}

sub _ws_render_item_cell {
    my ($row, $steam) = @_;
    return '' unless ref($row) eq 'HASH';
    my $wid = $row->{'workshop_id'} // '';
    my $title = '';
    my $preview = '';
    if (ref($steam) eq 'HASH') {
        $title = $steam->{'title'} // '';
        my $preview_url = $steam->{'preview_url'} // '';
        if ($preview_url =~ /\S/ && _ws_steam_preview_allowed($preview_url)) {
            $preview = '<img src="' . &html_escape($preview_url)
                . '" alt="" style="max-width:64px;max-height:64px;vertical-align:middle;margin-right:8px">';
        }
    }
    $title = $wid unless $title =~ /\S/;
    my $html = $preview . '<b>' . &html_escape($title) . '</b>';
    my $ws_url = 'https://steamcommunity.com/sharedfiles/filedetails/?id='
        . &html_escape($wid);
    $html .= '<br><small>ID: <a href="' . $ws_url . '" rel="noopener noreferrer">'
        . &html_escape($wid) . '</a></small>';
    if (($row->{'status'} // '') eq 'orphan_ini') {
        $html .= '<br><small class="text-warning">'
            . &html_escape($text{'workshop_orphan_hint'}
                || 'Listed in INI but files are missing on disk.')
            . '</small>';
    }
    return $html;
}

sub _ws_render_row_actions {
    my ($instance_id, $row) = @_;
    return '' unless &user_can_operate($instance_id) && !&user_is_readonly($instance_id);
    return '' unless ref($row) eq 'HASH';
    my $wid = $row->{'workshop_id'} // '';
    return '' unless $wid =~ /\S/;
    my $status = $row->{'status'} // '';
    my $on_disk = $row->{'on_disk'} ? 1 : 0;
    my $actions = '';

    if ($status eq 'inactive') {
        my $form = &ui_form_start('workshop.cgi', 'post');
        $form .= &ui_hidden('instance_id', &html_escape($instance_id));
        $form .= &ui_hidden('xnavigation', '1');
        $form .= &ui_hidden('action', 'enable');
        $form .= &ui_hidden('workshop_id', $wid);
        $form .= &ui_submit($text{'workshop_enable_btn'} || 'Enable',
            undef, undef, undef, 'btn-success');
        $form .= &ui_form_end();
        $actions .= _ws_inline_action($form);
    }

    if ($status eq 'active' || $status eq 'orphan_ini') {
        my $form = &ui_form_start('workshop.cgi', 'post');
        $form .= &ui_hidden('instance_id', &html_escape($instance_id));
        $form .= &ui_hidden('xnavigation', '1');
        $form .= &ui_hidden('action', 'disable');
        $form .= &ui_hidden('workshop_id', $wid);
        $form .= &ui_submit($text{'workshop_disable_btn'} || 'Disable',
            undef, undef, undef, 'btn-default');
        $form .= &ui_form_end();
        $actions .= _ws_inline_action($form);
    }

    if ($on_disk || $status eq 'orphan_ini') {
        my $confirm = $text{'workshop_delete_confirm'}
            || 'Really delete this workshop item and its files?';
        my $form = &ui_form_start('workshop.cgi', 'post',
            "onsubmit=\"return confirm('" . &html_escape($confirm) . "')\"");
        $form .= &ui_hidden('instance_id', &html_escape($instance_id));
        $form .= &ui_hidden('xnavigation', '1');
        $form .= &ui_hidden('action', 'delete');
        $form .= &ui_hidden('workshop_id', $wid);
        $form .= &ui_submit($text{'workshop_delete_btn'} || 'Delete',
            undef, undef, undef, 'btn-danger');
        $form .= &ui_form_end();
        $actions .= _ws_inline_action($form);
    }

    return $actions;
}

# --- bootstrap instance ---
my $instance_id = $in{'instance_id'} // '';
$instance_id = &sanitize_input($instance_id);
my $inst = &get_instance($instance_id);
&error($text{'err_not_found'} || 'Instance not found') unless $inst;
my $unix_user = $inst->{'user'} // '';
$unix_user = &sanitize_input($unix_user) if $unix_user ne '';
$unix_user ne ''
    or &error($text{'workshop_job_launch_failed'}
        || 'Instance has no unix user.');

&user_can_manage($instance_id)
    or &error($text{'err_acl_admin_only'} || 'Access denied');

my (undef, $script_name, $server_dir) = _ws_parse_script_info($inst);
&error($text{'workshop_unsupported'} || 'This game has no workshop support.')
    unless &game_has_workshop_support($script_name);

my $action = $in{'action'} // '';
$action =~ s/[^a-z_]//g;

if ($action ne '' && $action !~ /^(?:search|subscribe|enable|disable|delete|enable_mod|disable_mod)$/) {
    &error($text{'err_invalid_action'} || 'Invalid action');
}
if ($action ne '' && $action ne 'search' && &user_is_readonly($instance_id)) {
    &error($text{'err_readonly'} || 'This server is read-only for your account');
}

if ($action eq 'subscribe') {
    &user_can_operate($instance_id)
        or &error($text{'err_acl_admin_only'} || 'Access denied');
    my $wid = &pz_workshop_normalize_item_id($in{'workshop_id'} // '');
    &error($text{'workshop_bad_id'} || 'Invalid workshop ID.') unless length $wid;
    my $job_id = _ws_launch_subscribe($instance_id, $inst, $unix_user, $wid);
    _ws_launch_failed() unless $job_id;
    my $ret = _ws_page_url($instance_id);
    &redirect("job_live.cgi?instance_id=" . &urlize($instance_id)
        . "&job=" . &urlize($job_id)
        . "&return=" . &urlize($ret)
        . "&xnavigation=1");
    exit;
}

if ($action =~ /^(?:enable|disable|delete|enable_mod|disable_mod)$/) {
    $ENV{'REQUEST_METHOD'} eq 'POST'
        or &error($text{'err_invalid_action'} || 'Invalid action');
    &user_can_operate($instance_id)
        or &error($text{'err_acl_admin_only'} || 'Access denied');
    my $wid = &pz_workshop_normalize_item_id($in{'workshop_id'} // '');
    &error($text{'workshop_bad_id'} || 'Invalid workshop ID.') unless length $wid;
    my ($ini_ok, $ini) = &pz_workshop_resolve_ini_path($unix_user, $script_name);
    &error($text{'workshop_ini_missing'} || 'Server INI not found.') unless $ini_ok;
    my $inventory = &pz_workshop_list_inventory($unix_user, $script_name, $server_dir);
    my $row = _ws_find_inventory_row($inventory, $wid);
    &error($text{'workshop_bad_id'} || 'Invalid workshop ID.') unless $row;
    my @mod_ids = @{ _ws_mod_ids_from_row($row) };
    my $orphan = (($row->{'status'} // '') eq 'orphan_ini');
    my $server_ver = &pz_workshop_detect_server_version($unix_user, $server_dir);

    if ($action eq 'enable') {
        my @selected = &pz_workshop_select_mod_ids_for_version(
            $row->{'mod_infos'} // [], $server_ver);
        my ($ok, $err) = &pz_workshop_enable_item($ini, $wid, \@selected);
        $ok or &error(($text{'workshop_action_failed'} || 'Workshop action failed.')
            . ($err ? " ($err)" : ''));
        _ws_redirect_with_flash($instance_id, 'workshop_enabled', 'enabled');
    }

    if ($action eq 'disable') {
        my $mids = $orphan ? [] : \@mod_ids;
        my ($ok, $err) = &pz_workshop_disable_item($ini, $wid, $mids);
        $ok or &error(($text{'workshop_action_failed'} || 'Workshop action failed.')
            . ($err ? " ($err)" : ''));
        _ws_redirect_with_flash($instance_id, 'workshop_disabled', 'disabled');
    }

    if ($action eq 'enable_mod' || $action eq 'disable_mod') {
        my $mid = &pz_workshop_normalize_mod_id($in{'mod_id'} // '');
        &error($text{'workshop_bad_mod_id'} || 'Invalid Mod ID.') unless length $mid;
        my ($ok, $err);
        if ($action eq 'enable_mod') {
            ($ok, $err) = &pz_workshop_enable_mod($ini, $wid, $mid);
        } else {
            ($ok, $err) = &pz_workshop_disable_mod($ini, $mid);
        }
        $ok or &error(($text{'workshop_action_failed'} || 'Workshop action failed.')
            . ($err ? " ($err)" : ''));
        my $flash = ($action eq 'enable_mod') ? 'workshop_mod_enabled' : 'workshop_mod_disabled';
        my $flag  = ($action eq 'enable_mod') ? 'mod_enabled' : 'mod_disabled';
        _ws_redirect_with_flash($instance_id, $flash, $flag);
    }

    if ($action eq 'delete') {
        my $appid = &get_workshop_appid($script_name) || 108600;
        my @roots = &pz_workshop_content_roots($unix_user, $server_dir, $appid);
        my $mids = $orphan ? [] : \@mod_ids;
        my ($ok, $err) = &pz_workshop_delete_item(
            $inst->{'user'}, $ini, $wid, $row->{'content_dir'}, $mids, \@roots);
        if (!$ok) {
            if (($err // '') eq 'path_rejected') {
                &error($text{'workshop_action_failed'} || 'Workshop action failed.');
            }
            &error(($text{'workshop_action_failed'} || 'Workshop action failed.')
                . ($err ? " ($err)" : ''));
        }
        _ws_redirect_with_flash($instance_id, 'workshop_deleted', 'deleted');
    }
}

# --- GET / search render ---
my $q = $in{'q'} // '';
$q =~ s/[\t\n\r\0]//g;
$q =~ s/^\s+|\s+$//g;
$q = substr($q, 0, 100);

my @search_hits;
my $search_err = '';
if (($action eq 'search' || length($q) >= 2) && length($q) >= 2) {
    my $appid = &get_workshop_appid($script_name) || 108600;
    my ($ok, $hits, $err) = &pz_workshop_search($q, $appid);
    if ($ok) {
        @search_hits = @$hits;
    } else {
        $search_err = $err // 'api_failed';
    }
}

&header($text{'workshop_title'} || 'Steam Workshop', '');
print "<p><a href=\"manage.cgi?instance_id=" . &html_escape($instance_id)
    . "&xnavigation=1\">&larr; " . &html_escape($text{'workshop_back_manage'} || 'Back to instance')
    . "</a></p>\n";

print "<h2>" . &html_escape($text{'workshop_title'} || 'Steam Workshop') . "</h2>\n";
print "<p>" . &html_escape($inst->{'name'} // $script_name) . " &middot; "
    . &html_escape($text{'workshop_hint'}
        || 'Search the Steam Workshop, subscribe items, and enable them in the server INI. Stop the server before changing mods when possible.')
    . "</p>\n";

if (($in{'enabled'} // '') eq '1' && &module_config_flash_consume('workshop_enabled')) {
    print "<div class='alert alert-success'>"
        . &html_escape($text{'workshop_enabled_ok'} || 'Workshop item enabled in the server INI.')
        . "</div>\n";
}
if (($in{'disabled'} // '') eq '1' && &module_config_flash_consume('workshop_disabled')) {
    print "<div class='alert alert-success'>"
        . &html_escape($text{'workshop_disabled_ok'} || 'Workshop item disabled in the server INI.')
        . "</div>\n";
}
if (($in{'deleted'} // '') eq '1' && &module_config_flash_consume('workshop_deleted')) {
    print "<div class='alert alert-success'>"
        . &html_escape($text{'workshop_deleted_ok'} || 'Workshop item deleted.')
        . "</div>\n";
}
if (($in{'mod_enabled'} // '') eq '1' && &module_config_flash_consume('workshop_mod_enabled')) {
    print "<div class='alert alert-success'>"
        . &html_escape($text{'workshop_mod_enabled_ok'} || 'Mod ID enabled in Mods=.')
        . "</div>\n";
}
if (($in{'mod_disabled'} // '') eq '1' && &module_config_flash_consume('workshop_mod_disabled')) {
    print "<div class='alert alert-success'>"
        . &html_escape($text{'workshop_mod_disabled_ok'} || 'Mod ID disabled in Mods=.')
        . "</div>\n";
}

my $action_result_job = $in{'action_result'} // '';
$action_result_job =~ s/[^0-9a-f]//g;
$action_result_job = substr($action_result_job, 0, 16);
if ($action_result_job ne ''
    && &module_config_flash_consume("jobres_$action_result_job"))
{
    print "<div class='alert alert-success'>"
        . &html_escape($text{'workshop_subscribed_ok'}
            || 'Workshop item subscribed and enabled in the server INI.')
        . "</div>\n";
}

my $api_key = &steam_web_api_key();
unless ($api_key =~ /\S/) {
    print "<div class=\"alert alert-warning\">"
        . &html_escape($text{'workshop_api_key_missing'}
            || 'Steam Web API key missing — configure under Integrations for search.')
        . " <a href=\"integrations.cgi?xnavigation=1\">"
        . &html_escape($text{'workshop_goto_integrations'} || 'Integrations')
        . "</a></div>\n";
}

# Search form
print &ui_collapsible_start($text{'workshop_search_section'} || 'Search',
    id => 'ws-search', open => 1, force => (@search_hits || $search_err) ? 1 : 0);
print &ui_form_start('workshop.cgi', 'get');
print &ui_hidden('instance_id', &html_escape($instance_id));
print &ui_hidden('xnavigation', '1');
print &ui_hidden('action', 'search');
print &ui_table_start();
print &ui_table_row(
    &html_escape($text{'workshop_search_label'} || 'Search'),
    &ui_textbox('q', $q, 40)
);
print &ui_table_end();
print &ui_submit($text{'workshop_search_btn'} || 'Search', undef, undef, undef, 'btn-primary');
print &ui_form_end();

# Subscribe by ID (works even without search key for download path)
if (&user_can_operate($instance_id) && !&user_is_readonly($instance_id)) {
    print "<h4>" . &html_escape($text{'workshop_subscribe_id_title'} || 'Subscribe by Workshop ID') . "</h4>\n";
    print &ui_form_start('workshop.cgi', 'post');
    print &ui_hidden('instance_id', &html_escape($instance_id));
    print &ui_hidden('action', 'subscribe');
    print &ui_table_start();
    print &ui_table_row(
        &html_escape($text{'workshop_id_label'} || 'Workshop ID / URL'),
        &ui_textbox('workshop_id', '', 40)
    );
    print &ui_table_end();
    print &ui_submit($text{'workshop_subscribe_btn'} || 'Subscribe', undef, undef, undef, 'btn-default');
    print &ui_form_end();
    print "<p><small>" . &html_escape($text{'workshop_deps_hint'}
        || 'Subscribe automatically downloads required Steam Workshop dependencies (up to 20 items).')
        . "</small></p>\n";
}

if ($search_err eq 'api_key_missing') {
    print "<p class=\"text-warning\">" . &html_escape($text{'workshop_api_key_missing'}
        || 'Steam Web API key missing.') . "</p>\n";
} elsif ($search_err ne '') {
    print "<p class=\"text-danger\">" . &html_escape($text{'workshop_search_failed'}
        || 'Workshop search failed.') . "</p>\n";
} elsif (@search_hits) {
    print "<h4>" . &html_escape($text{'workshop_results'} || 'Results') . "</h4>\n";
    my @rows;
    for my $hit (@search_hits) {
        my $title = &html_escape($hit->{'title'} // '');
        my $desc  = &html_escape($hit->{'description'} // '');
        my $id    = &html_escape($hit->{'id'} // '');
        my $creator = &html_escape($hit->{'creator'} // '');
        my $actions = '';
        if (&user_can_operate($instance_id) && !&user_is_readonly($instance_id)) {
            $actions = &ui_form_start('workshop.cgi', 'post');
            $actions .= &ui_hidden('instance_id', &html_escape($instance_id));
            $actions .= &ui_hidden('action', 'subscribe');
            $actions .= &ui_hidden('workshop_id', $id);
            $actions .= &ui_submit($text{'workshop_subscribe_btn'} || 'Subscribe',
                undef, undef, undef, 'btn-primary');
            $actions .= &ui_form_end();
            $actions =~ s/<form(\s)/<form style="display:inline"$1/i;
        }
        push @rows, [
            "<b>$title</b><br><small>ID: $id"
                . ($creator ne '' ? " &middot; SteamID: $creator" : '')
                . "</small>"
                . ($desc ne '' ? "<br><small>$desc</small>" : ''),
            $actions,
        ];
    }
    print &ui_columns_start([
        &html_escape($text{'workshop_col_item'} || 'Item'),
        &html_escape($text{'workshop_col_actions'} || 'Actions'),
    ]);
    for my $r (@rows) {
        print &ui_columns_row($r);
    }
    print &ui_columns_end();
} elsif (length($q) >= 2 && $action eq 'search') {
    print "<p><i>" . &html_escape($text{'workshop_no_results'} || 'No results.') . "</i></p>\n";
}
print &ui_collapsible_end();

# Installed inventory (disk scan ∪ INI)
my $inventory = &pz_workshop_list_inventory($unix_user, $script_name, $server_dir);
my @inventory_rows = ref($inventory) eq 'ARRAY' ? @$inventory : ();
print &ui_collapsible_start($text{'workshop_installed_section'} || 'Installed',
    id => 'ws-installed', open => 1,
    badge => scalar(@inventory_rows));

my ($ini_ok, $ini_path) = &pz_workshop_resolve_ini_path($unix_user, $script_name);
if ($ini_ok) {
    print "<p><small>" . &html_escape($text{'workshop_ini_path'} || 'INI')
        . ": " . &html_escape($ini_path)
        . (-f $ini_path ? '' : ' (' . &html_escape($text{'workshop_ini_not_created'} || 'not created yet') . ')')
        . "</small></p>\n";
}
my $pz_ver = &pz_workshop_detect_server_version($unix_user, $server_dir);
if ($pz_ver ne '') {
    print "<p><small>" . &html_escape($text{'workshop_server_pz_version'} || 'Detected PZ version')
        . ": " . &html_escape($pz_ver)
        . " — " . &html_escape($text{'workshop_mod_version_hint'}
            || 'Enable item auto-selects Mod IDs matching this version; others stay off until enabled manually.')
        . "</small></p>\n";
} else {
    print "<p><small class=\"text-warning\">"
        . &html_escape($text{'workshop_server_pz_version_unknown'}
            || 'PZ version unknown — enabling a workshop item will not auto-select Mod IDs. Enable Mod IDs manually.')
        . "</small></p>\n";
}

my $steam_details = {};
if ($api_key =~ /\S/ && @inventory_rows) {
    my @steam_ids = map { $_->{'workshop_id'} // '' } @inventory_rows;
    $steam_details = &pz_workshop_steam_details(\@steam_ids);
    $steam_details = {} unless ref($steam_details) eq 'HASH';
}

if (!@inventory_rows) {
    print "<p><i>" . &html_escape($text{'workshop_none_installed'}
        || 'No workshop items on disk or in the INI yet.') . "</i></p>\n";
} else {
    print &ui_columns_start([
        &html_escape($text{'workshop_col_item'} || 'Item'),
        &html_escape($text{'workshop_col_mods'} || 'Mods'),
        &html_escape($text{'workshop_col_status'} || 'Status'),
        &html_escape($text{'workshop_col_actions'} || 'Actions'),
    ]);
    for my $row (@inventory_rows) {
        next unless ref($row) eq 'HASH';
        my $wid = $row->{'workshop_id'} // '';
        my $steam = $steam_details->{$wid};
        print &ui_columns_row([
            _ws_render_item_cell($row, $steam),
            _ws_render_mod_infos($instance_id, $wid, $row->{'mod_infos'}),
            &html_escape(_ws_status_label($row->{'status'} // '')),
            _ws_render_row_actions($instance_id, $row),
        ]);
    }
    print &ui_columns_end();
    print "<p><small>" . &html_escape($text{'workshop_restart_hint'}
        || 'Restart the server after changing workshop mods for changes to take effect.')
        . "</small></p>\n";
}
print &ui_collapsible_end();

print &ui_collapsible_state_script();
&footer();
