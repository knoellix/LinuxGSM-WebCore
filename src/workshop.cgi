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
require './lib/monitor.pl';
require './lib/live_log.pl';
require './lib/server_log.pl';
require './lib/server_control_bar.pl';
require './lib/progressive_ui.pl';
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

sub _ws_rebuild_monitor_cron {
    return unless defined &rebuild_monitor_cron;
    &rebuild_monitor_cron($module_root, $config_directory);
}

sub _ws_redirect_job_live {
    my ($job_id, $instance_id, %opts) = @_;
    $job_id or _ws_launch_failed();
    my $ret = $opts{'return'} // _ws_page_url($instance_id);
    my $url = "job_live.cgi?instance_id=" . &urlize($instance_id)
        . "&job=" . &urlize($job_id)
        . "&return=" . &urlize($ret)
        . "&xnavigation=1";
    $url .= "&next_status=" . &urlize($opts{'next_status'}) if $opts{'next_status'};
    &redirect($url);
    exit;
}

# Stay on workshop.cgi with banner poll (same UX as manage start/stop/restart).
sub _ws_redirect_silent_job {
    my ($job_id, $instance_id, %opts) = @_;
    $job_id or _ws_launch_failed();
    my %extra = (silent_job => $job_id);
    $extra{next_status}   = $opts{'next_status'}   if ($opts{'next_status'} // '') ne '';
    $extra{notice_action} = $opts{'notice_action'} if ($opts{'notice_action'} // '') ne '';
    my $na = $opts{'notice_action'} // '';
    $na =~ s/[^a-z_]//g;
    if (!$opts{'start_log'}
        && ($na eq 'start' || $na eq 'restart')
        && defined &server_log_start_log_wanted
        && &server_log_start_log_wanted(\%in))
    {
        $opts{'start_log'} = 1;
    }
    if ($opts{'start_log'}) {
        if (&server_log_start_log_flash_mark($instance_id)) {
            $extra{start_log} = 1;
        }
        else {
            &module_config_flash_mark('start_log_embed_warn')
                if defined &module_config_flash_mark;
            $extra{start_log_warn} = 1;
        }
    }
    if (defined &server_control_async_requested && &server_control_async_requested(\%in)) {
        my $poll_q = "workshop.cgi?instance_id=" . &urlize($instance_id)
            . "&action=poll_job&job=" . &urlize($job_id)
            . "&poll_format=json&silent=1";
        $poll_q .= "&next_status=" . &urlize($opts{'next_status'})
            if ($opts{'next_status'} // '') ne '';
        $poll_q .= "&notice_action=" . &urlize($na) if $na ne '';
        my $runtime_html = '';
        $runtime_html = _ws_runtime_badge_html('starting')
            if $na =~ /^(?:start|restart)$/;
        my $start_log_on = $extra{start_log} ? 1 : 0;
        my %payload = (
            ok               => 1,
            mode             => 'silent',
            job_id           => $job_id,
            notice_action    => $na,
            poll_url         => _ws_module_cgi_path($poll_q),
            runtime_poll_url => _ws_module_cgi_path(
                "workshop.cgi?instance_id=" . &urlize($instance_id) . "&action=poll_runtime"),
            live_url         => _ws_module_cgi_path(
                "job_live.cgi?instance_id=" . &urlize($instance_id)
                    . "&job=" . &urlize($job_id) . "&xnavigation=1"),
            start_blink      => ($na =~ /^(?:start|restart)$/ ? 1 : 0),
            runtime_html     => $runtime_html,
            start_log        => $start_log_on,
        );
        if ($start_log_on) {
            $payload{'start_log_panel_url'} = _ws_module_cgi_path(
                "workshop.cgi?instance_id=" . &urlize($instance_id)
                    . "&action=start_log_panel&start_log=1");
        }
        &server_control_async_json_exit(\%payload);
    }
    &redirect(_ws_page_url($instance_id, %extra));
    exit;
}

sub _ws_module_cgi_path {
    my ($query) = @_;
    my $mn = $module_name // $main::module_name // 'linuxgsm-webcore';
    $mn =~ s/[^a-zA-Z0-9_-]//g;
    $query //= '';
    $query =~ s{^\./}{};
    return "/$mn/$query";
}

sub _ws_action_result_text {
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

sub _ws_render_silent_job_poll {
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

    my $poll_q = "workshop.cgi?instance_id=" . &urlize($instance_id)
        . "&action=poll_job&job=" . &urlize($job_id)
        . "&poll_format=json&silent=1";
    $poll_q .= "&next_status=" . &urlize($opts{'next_status'}) if ($opts{'next_status'} // '') ne '';
    $poll_q .= "&notice_action=" . &urlize($notice_action) if $notice_action ne '';
    my $poll_cfg = job_log_json_for_script({
        pollUrl        => _ws_module_cgi_path($poll_q),
        runtimePollUrl => _ws_module_cgi_path(
            "workshop.cgi?instance_id=" . &urlize($instance_id) . "&action=poll_runtime"),
        runningMsg     => $text{'manage_action_running'} || 'Aktion läuft…',
        pollInterval   => 500,
        pollErrorMsg   => $text{'manage_action_poll_error'}
            || 'Statusabfrage fehlgeschlagen — Seite neu laden.',
        startBlink     => ($notice_action =~ /^(?:start|restart)$/ ? 1 : 0),
    });

    print "<div id=\"silent_job_banner\" class=\"alert alert-info\">"
        . "<strong>" . &html_escape($text{'manage_action_running'} || 'Aktion läuft…')
        . "</strong></div>\n";
    # JS mirrors manage.cgi silent poll (trusted JSON notice_msg from our poll_job).
    print <<"EOF";
<script>
(function () {
  var C = $poll_cfg;
  var banner = document.getElementById("silent_job_banner");
  var timer = null;
  var failCount = 0;
  var runtimeTimer = null;
  function setRuntimeHtml(html) {
    if (!html) return;
    if (window.__lgsmStartReadySeen && html.indexOf("lgsm-job-pulse") >= 0) return;
    var nodes = document.querySelectorAll(".js-runtime-status");
    for (var i = 0; i < nodes.length; i++) {
      nodes[i].innerHTML = html;
    }
  }
  function pollRuntimeUntilReady() {
    if (!C.runtimePollUrl) return;
    if (runtimeTimer) return;
    function once() {
      if (window.__lgsmStartReadySeen) { runtimeTimer = null; return; }
      fetch(C.runtimePollUrl, { credentials: "same-origin", cache: "no-store" })
        .then(function (r) { if (!r.ok) throw new Error("http"); return r.json(); })
        .then(function (d) {
          if (window.__lgsmStartReadySeen) { runtimeTimer = null; return; }
          if (d.runtime_html) setRuntimeHtml(d.runtime_html);
          if (d.starting) {
            runtimeTimer = window.setTimeout(once, 2000);
          } else {
            runtimeTimer = null;
          }
        })
        .catch(function () {
          runtimeTimer = window.setTimeout(once, 3000);
        });
    }
    once();
  }
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
    if (d.runtime_html) setRuntimeHtml(d.runtime_html);
    if (d.starting || (C.startBlink && d.status === "ok" && d.runtime_status === "starting")) {
      pollRuntimeUntilReady();
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
          if (d.runtime_html) setRuntimeHtml(d.runtime_html);
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

sub _ws_redirect_if_job_running {
    my ($instance_id, $action) = @_;
    my $job_id = &find_running_job_for_instance($instance_id, $action);
    $job_id ||= &find_running_job_for_instance($instance_id);
    return 0 unless $job_id;
    my $act = $action // '';
    $act =~ s/[^a-z_]//g;
    unless ($act) {
        my $meta = &get_job_meta($job_id);
        $act = $meta->{'action'} // '';
        $act =~ s/[^a-z_]//g;
    }
    if ($act =~ /^(?:start|stop|restart)$/) {
        _ws_redirect_silent_job(
            $job_id, $instance_id,
            notice_action => $act,
            next_status   => &job_next_instance_status($act),
        );
    }
    _ws_redirect_job_live($job_id, $instance_id);
}

sub _ws_launch_background_job {
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

sub _ws_steamcmd_worker_cmd {
    my ($action, $job_dir, $unix_user, $server_dir) = @_;
    return &user_worker_launch_cmd(
        unix_user   => $unix_user,
        module_root => $module_root,
        worker      => "$module_root/scripts/steamcmd_control_user.sh",
        args        => [ $action, $job_dir, $unix_user, $server_dir ],
    );
}

sub _ws_runtime_badge_html {
    my ($status) = @_;
    return &server_runtime_status_badge_html($status);
}

sub _ws_inv_page_hidden {
    my $inv_page = int($in{'inv_page'} // 1);
    $inv_page = 1 if $inv_page < 1;
    return &ui_hidden('inv_page', $inv_page);
}

sub _ws_inventory_cache_invalidate {
    my ($instance_id) = @_;
    my $path = _ws_inventory_cache_path($instance_id);
    unlink $path if $path ne '' && -f $path;
    return 1;
}

sub _ws_redirect_with_flash {
    my ($instance_id, $flash_key, $query_flag) = @_;
    $flash_key =~ s/[^a-z_]//g;
    $flash_key or _ws_action_failed();
    &module_config_flash_mark($flash_key)
        or _ws_action_failed();
    _ws_inventory_cache_invalidate($instance_id);
    my %extra = ($query_flag => 1);
    my $inv_page = int($in{'inv_page'} // 0);
    $extra{inv_page} = $inv_page if $inv_page > 1;
    &redirect(_ws_page_url($instance_id, %extra));
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
        return $text{'workshop_status_active'} || 'Subscribed';
    }
    if ($status eq 'workshop_only') {
        return $text{'workshop_status_workshop_only'}
            || 'Subscribed (mods off)';
    }
    if ($status eq 'inactive') {
        return $text{'workshop_status_inactive'} || 'Files only';
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
            $form .= _ws_inv_page_hidden();
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

sub _ws_render_pz_version_cell {
    my ($mod_infos, $server_ver) = @_;
    return '<i>—</i>' unless ref($mod_infos) eq 'ARRAY' && @$mod_infos;
    my @parts;
    for my $mi (@$mod_infos) {
        next unless ref($mi) eq 'HASH';
        my $id = $mi->{'id'} // '';
        next unless $id =~ /\S/;
        my $cell = &pz_workshop_pz_version_cell($mi->{'pz_require'}, $server_ver, $mi);
        my $label = &html_escape($cell->{'label'} // '');
        if (($cell->{'label'} // '') eq 'keine Angabe') {
            $label = &html_escape($text{'workshop_pz_version_none'} || 'keine Angabe');
        } elsif (($cell->{'label'} // '') eq 'unbekannt') {
            $label = &html_escape($text{'workshop_pz_version_unknown'} || 'unbekannt');
        }
        my $match = $cell->{'match'} // 'none';
        if ($match eq 'ok') {
            $label .= ' <small class="text-success">'
                . &html_escape($text{'workshop_pz_match_ok'} || 'passt')
                . '</small>';
        } elsif ($match eq 'bad') {
            $label .= ' <small class="text-danger">'
                . &html_escape($text{'workshop_pz_match_bad'} || 'unpassend')
                . '</small>';
        } elsif ($match eq 'unknown') {
            $label .= ' <small class="text-muted">'
                . &html_escape($text{'workshop_pz_match_unknown'} || 'unbekannt')
                . '</small>';
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
            $preview = '<img class="lgsm-ws-preview" src="' . &html_escape($preview_url)
                . '" alt="" width="32" height="32">';
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

    # Files on disk but not in WorkshopItems → local "subscribe" (INI only, no re-download).
    # No item-level disable: unused items are deleted (de-subscribed).
    if ($status eq 'inactive') {
        my $form = &ui_form_start('workshop.cgi', 'post');
        $form .= &ui_hidden('instance_id', &html_escape($instance_id));
        $form .= &ui_hidden('xnavigation', '1');
        $form .= _ws_inv_page_hidden();
        $form .= &ui_hidden('action', 'enable');
        $form .= &ui_hidden('workshop_id', $wid);
        $form .= &ui_submit(
            $text{'workshop_subscribe_local_btn'} || 'Subscribe',
            undef, undef, undef, 'btn-success');
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
        $form .= _ws_inv_page_hidden();
        $form .= &ui_hidden('action', 'delete');
        $form .= &ui_hidden('workshop_id', $wid);
        $form .= &ui_submit($text{'workshop_delete_btn'} || 'Delete',
            undef, undef, undef, 'btn-danger');
        $form .= &ui_form_end();
        $actions .= _ws_inline_action($form);
    }

    return $actions;
}

# Short-lived inventory cache so progressive poll_inventory batches do not re-scan disk.
sub _ws_inventory_cache_path {
    my ($instance_id) = @_;
    $instance_id =~ s/[^a-zA-Z0-9_-]//g;
    return '' if $instance_id eq '' || !$config_directory;
    return "$config_directory/.ws_inv_cache_$instance_id.json";
}

sub _ws_inventory_cache_load {
    my ($instance_id) = @_;
    my $path = _ws_inventory_cache_path($instance_id);
    return undef unless $path ne '' && -f $path;
    open(my $fh, '<:encoding(UTF-8)', $path) or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return undef unless defined $raw && $raw =~ /\S/;
    my $data = eval {
        require JSON::PP;
        JSON::PP->new->utf8(0)->decode($raw);
    };
    return undef unless ref($data) eq 'HASH';
    my $ts = int($data->{'ts'} // 0);
    return undef if $ts < 1 || (time() - $ts) > 90;
    return $data;
}

sub _ws_inventory_cache_save {
    my ($instance_id, $data) = @_;
    my $path = _ws_inventory_cache_path($instance_id);
    return 0 unless $path ne '' && ref($data) eq 'HASH';
    $data->{'ts'} = time();
    my $json = eval {
        require JSON::PP;
        JSON::PP->new->utf8(0)->canonical(1)->encode($data);
    };
    return 0 unless defined $json && $json =~ /\S/;
    open(my $fh, '>:encoding(UTF-8)', $path) or return 0;
    print $fh $json;
    close $fh;
    chmod 0600, $path;
    return 1;
}

sub _ws_inventory_preamble_html {
    my ($unix_user, $script_name, $server_dir, $pz_ver) = @_;
    my $html = '';
    my ($ini_ok, $ini_path) = &pz_workshop_resolve_ini_path($unix_user, $script_name);
    if ($ini_ok) {
        $html .= "<p><small>" . &html_escape($text{'workshop_ini_path'} || 'INI')
            . ": " . &html_escape($ini_path)
            . (-f $ini_path ? '' : ' (' . &html_escape($text{'workshop_ini_not_created'} || 'not created yet') . ')')
            . "</small></p>\n";
    }
    if (($pz_ver // '') ne '') {
        $html .= "<p><small>" . &html_escape($text{'workshop_server_pz_version'} || 'Detected PZ version')
            . ": " . &html_escape($pz_ver)
            . " — " . &html_escape($text{'workshop_mod_version_hint'}
                || 'Subscribe auto-selects at most one matching Mod ID; others stay off until enabled manually.')
            . "</small></p>\n";
    } else {
        $html .= "<p><small class=\"text-warning\">"
            . &html_escape($text{'workshop_server_pz_version_unknown'}
                || 'PZ version unknown — subscribe will not auto-select Mod IDs. Enable Mod IDs manually.')
            . "</small></p>\n";
    }
    return $html;
}

# Paginate inventory rows (same shape as MC mods: page/per_page → slice,total,pages).
sub _ws_paginate_inventory {
    my ($rows, $page, $per_page) = @_;
    $rows = [] unless ref($rows) eq 'ARRAY';
    $per_page = 50 unless defined $per_page && $per_page =~ /^\d+$/ && $per_page > 0;
    $per_page = 100 if $per_page > 100;
    my $total = scalar(@$rows);
    my $pages = $total > 0 ? int(($total + $per_page - 1) / $per_page) : 1;
    $pages = 1 if $pages < 1;
    $page = 1 unless defined $page && $page =~ /^\d+$/ && $page > 0;
    $page = $pages if $page > $pages;
    my $start = ($page - 1) * $per_page;
    my @slice;
    if ($total > 0 && $start < $total) {
        my $last = $start + $per_page - 1;
        $last = $total - 1 if $last > $total - 1;
        @slice = @$rows[$start .. $last];
    }
    return (\@slice, $total, $pages, $page);
}

# Prev/Next + "Page N of M" — links reload workshop shell with inv_page=.
sub _ws_inventory_pager_html {
    my ($instance_id, $page, $pages, $total) = @_;
    $page  = int($page  // 1);
    $pages = int($pages // 1);
    $total = int($total // 0);
    my $html = "<p><small>" . &html_escape(sprintf(
        $text{'workshop_page_info'} || $text{'mc_mods_page_page_info'}
            || 'Page %d of %d (%d entries).',
        $page, $pages, $total
    )) . "</small></p>\n";
    return $html if $pages <= 1;

    $html .= "<div style='text-align:right;margin:4px 0 12px 0'>\n";
    if ($page > 1) {
        my $prev = _ws_page_url($instance_id, inv_page => $page - 1);
        $html .= _ws_inline_action(
            "<a class=\"btn btn-default\" href=\"" . &html_escape($prev) . "\">"
            . &html_escape($text{'workshop_page_prev'} || $text{'mc_mods_page_prev'} || 'Previous')
            . "</a>"
        );
    }
    if ($page < $pages) {
        my $next = _ws_page_url($instance_id, inv_page => $page + 1);
        $html .= _ws_inline_action(
            "<a class=\"btn btn-default\" href=\"" . &html_escape($next) . "\">"
            . &html_escape($text{'workshop_page_next'} || $text{'mc_mods_page_next'} || 'Next')
            . "</a>"
        );
    }
    $html .= "</div>\n";
    return $html;
}

# Lazy inventory payload: disk scan once (cached), one page of rows + Steam titles.
# Opts: page (default 1), per_page (default 50, max 100).
# Always done=1 (page-sized response; no progressive offset batches).
sub _ws_build_inventory_payload {
    my ($instance_id, $unix_user, $script_name, $server_dir, $api_key, %opts) = @_;
    my $page = int($opts{'page'} // 1);
    $page = 1 if $page < 1;
    my $per_page = int($opts{'per_page'} // 50);
    $per_page = 50 if $per_page < 1;
    $per_page = 100 if $per_page > 100;

    my $cached = _ws_inventory_cache_load($instance_id);
    my @inventory_rows;
    my $pz_ver = '';
    if (ref($cached) eq 'HASH' && ref($cached->{'rows'}) eq 'ARRAY') {
        @inventory_rows = @{ $cached->{'rows'} };
        $pz_ver = $cached->{'pz_ver'} // '';
    }
    else {
        my $inventory = &pz_workshop_list_inventory($unix_user, $script_name, $server_dir);
        @inventory_rows = ref($inventory) eq 'ARRAY' ? @$inventory : ();
        $pz_ver = &pz_workshop_detect_server_version($unix_user, $server_dir);
        _ws_inventory_cache_save($instance_id, {
            rows   => \@inventory_rows,
            pz_ver => $pz_ver,
        });
    }

    my ($slice, $total, $pages, $page_clamped)
        = _ws_paginate_inventory(\@inventory_rows, $page, $per_page);
    $page = $page_clamped;

    if ($total < 1) {
        my $pre = _ws_inventory_preamble_html($unix_user, $script_name, $server_dir, $pz_ver);
        my $empty = "<p><i>" . &html_escape($text{'workshop_none_installed'}
            || 'No workshop items on disk or in the INI yet.') . "</i></p>\n";
        return {
            ok              => 1,
            count           => 0,
            page            => 1,
            pages           => 1,
            offset          => 0,
            next_offset     => 0,
            done            => 1,
            preamble_html   => $pre,
            table_head_html => '',
            rows_html       => $empty,
            table_foot_html => '',
            html            => $pre . $empty,
        };
    }

    my @slice_rows = @$slice;
    my $steam_details = {};
    if (($api_key // '') =~ /\S/ && @slice_rows) {
        my @steam_ids = map { $_->{'workshop_id'} // '' } @slice_rows;
        $steam_details = &pz_workshop_steam_details(\@steam_ids);
        $steam_details = {} unless ref($steam_details) eq 'HASH';
    }

    my @rows;
    for my $row (@slice_rows) {
        next unless ref($row) eq 'HASH';
        my $wid = $row->{'workshop_id'} // '';
        my $steam = $steam_details->{$wid};
        push @rows, [
            _ws_render_item_cell($row, $steam),
            _ws_render_mod_infos($instance_id, $wid, $row->{'mod_infos'}),
            _ws_render_pz_version_cell($row->{'mod_infos'}, $pz_ver),
            &html_escape(_ws_status_label($row->{'status'} // '')),
            _ws_render_row_actions($instance_id, $row),
        ];
    }

    my $preamble = _ws_inventory_preamble_html($unix_user, $script_name, $server_dir, $pz_ver);
    my $table = &ui_columns_table(
        [
            $text{'workshop_col_item'} || 'Item',
            $text{'workshop_col_mods'} || 'Mods',
            $text{'workshop_col_pz_version'} || 'PZ version',
            $text{'workshop_col_status'} || 'Status',
            $text{'workshop_col_actions'} || 'Actions',
        ],
        '100%',
        \@rows,
    );
    my $after = _ws_inventory_pager_html($instance_id, $page, $pages, $total);
    $after .= "<p><small>" . &html_escape($text{'workshop_restart_hint'}
        || 'Restart the server after changing workshop mods for changes to take effect.')
        . "</small></p>\n";

    return {
        ok              => 1,
        count           => $total,
        page            => $page,
        pages           => $pages,
        offset          => 0,
        next_offset     => scalar(@slice_rows),
        done            => 1,
        html            => $preamble . $table . $after,
    };
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

if ($action ne '' && $action !~ /^(?:search|subscribe|enable|disable|delete|enable_mod|disable_mod|start|stop|restart|monitor|poll_monitor|poll_runtime|poll_job|poll_inventory|start_log_panel)$/) {
    &error($text{'err_invalid_action'} || 'Invalid action');
}
if ($action ne '' && $action !~ /^(?:search|monitor|poll_monitor|poll_runtime|poll_job|poll_inventory|start_log_panel)$/ && &user_is_readonly($instance_id)) {
    &error($text{'err_readonly'} || 'This server is read-only for your account');
}

if ($action eq 'start' || $action eq 'stop' || $action eq 'restart') {
    &user_can_operate($instance_id)
        or &error($text{'err_acl_admin_only'} || 'Access denied');
    _ws_redirect_if_job_running($instance_id, $action);

    my ($script_path, $sn, $sdir) = _ws_parse_script_info($inst);
    $script_name = $sn if $sn ne '';
    $server_dir = $sdir if $sdir ne '';

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
        $job_id = _ws_launch_background_job(
            $instance_id, $action, $unix_user,
            sub {
                my ($jid) = @_;
                my $job_dir = _shell_safe_job_dir($jid);
                return _ws_steamcmd_worker_cmd($action, $job_dir, $unix_user, $server_dir);
            },
        );
    } else {
        my $exec_script = &instance_executable_script($server_dir, $script_path);
        $job_id = _ws_launch_background_job(
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
    $job_id or _ws_launch_failed();
    if ($action eq 'stop') {
        &set_monitor_paused($server_dir, $config_directory, $instance_id);
    }
    _ws_rebuild_monitor_cron();
    my $next_status = &job_next_instance_status($action);
    # Embedded silent poll on workshop page (like manage) — no job_live redirect.
    _ws_redirect_silent_job(
        $job_id, $instance_id,
        next_status   => $next_status,
        notice_action => $action,
    );
}

if ($action eq 'poll_monitor') {
    my $source = &instance_effective_source($inst);
    my $payload = server_log_monitor_poll_payload(
        server_dir  => $server_dir,
        script_name => $script_name,
        source      => $source,
        minecraft   => 0,
        log_file    => $in{'log_file'},
    );
    if (($payload->{started} // 0) && $server_dir ne '') {
        &set_monitor_ready_after_start($server_dir, $config_directory, $instance_id);
    }
    $main::headerprinted = 1;
    print "Content-type: application/json; charset=utf-8\n\n";
    print job_log_json_utf8($payload);
    exit;
}

if ($action eq 'poll_runtime') {
    my $rs = &instance_runtime_status($inst, light => 1);
    my $mon = &read_monitor_state($server_dir, $config_directory, $instance_id);
    my $job_inflight = 0;
    if (defined &find_running_job_for_instance) {
        $job_inflight = &find_running_job_for_instance($instance_id, 'start')
            || &find_running_job_for_instance($instance_id, 'restart') ? 1 : 0;
    }
    if (&monitor_heal_starting_if_ready(
            $server_dir, $config_directory, $instance_id, $rs,
            job_in_flight => $job_inflight))
    {
        $mon = &read_monitor_state($server_dir, $config_directory, $instance_id);
    }
    $rs = &monitor_runtime_display_status($rs, $mon);
    $main::headerprinted = 1;
    print "Content-type: application/json; charset=utf-8\n\n";
    print job_log_json_utf8({
        runtime_status => $rs,
        runtime_html   => _ws_runtime_badge_html($rs),
        starting       => ($rs eq 'starting') ? 1 : 0,
    });
    exit;
}

if ($action eq 'poll_inventory') {
    my $api_key = &steam_web_api_key();
    my $inv_page = int($in{'inv_page'} // $in{'page'} // 1);
    $inv_page = 1 if $inv_page < 1;
    my $per_page = int($in{'per_page'} // 50);
    my $payload = _ws_build_inventory_payload(
        $instance_id, $unix_user, $script_name, $server_dir, $api_key,
        page     => $inv_page,
        per_page => $per_page,
    );
    $main::headerprinted = 1;
    print "Content-type: application/json; charset=utf-8\n\n";
    print job_log_json_utf8($payload);
    exit;
}

if ($action eq 'start_log_panel') {
    unless (&server_log_start_log_should_show(\%in, $instance_id)) {
        $main::headerprinted = 1;
        print "Content-type: text/html; charset=utf-8\n\n";
        print '';
        exit;
    }
    my $mn = $module_name // $main::module_name // 'linuxgsm-webcore';
    $mn =~ s/[^a-zA-Z0-9_-]//g;
    $main::headerprinted = 1;
    print "Content-type: text/html; charset=utf-8\n\n";
    print &server_log_embed_html(
        instance_id   => $instance_id,
        server_dir    => $server_dir,
        script_name   => $script_name,
        source        => &instance_effective_source($inst),
        minecraft     => 0,
        poll_url_base => "/$mn/workshop.cgi?instance_id=" . &urlize($instance_id)
            . '&action=poll_monitor',
    );
    exit;
}

if ($action eq 'poll_job') {
    my $job_id = $in{'job'} // '';
    $job_id =~ s/[^0-9a-f]//g;
    $job_id = substr($job_id, 0, 16);
    my $next_status = $in{'next_status'} // '';
    $next_status =~ s/[^a-z_]//g;
    &timeout_check_job($job_id);
    &validate_job_for_instance($job_id, $instance_id)
        or &error($text{'err_not_found'});
    my $status = &get_job_status($job_id) // 'unknown';
    my $all_out = &get_job_output_display($job_id);

    if ($status eq 'ok') {
        my $apply = $next_status;
        unless ($apply) {
            my $meta = &get_job_meta($job_id);
            $apply = &job_next_instance_status($meta->{'action'} // '');
        }
        &set_instance_status($instance_id, $apply) if $apply;
    }
    if (($in{'mark_result'} // '') eq '1' && $status =~ /^(?:ok|failed|aborted)$/) {
        &module_config_flash_mark("jobres_$job_id") if defined &module_config_flash_mark;
    }

    my $notice_action = $in{'notice_action'} // '';
    $notice_action =~ s/[^a-z_]//g;
    unless ($notice_action) {
        my $meta = &get_job_meta($job_id);
        $notice_action = $meta->{'action'} // '';
        $notice_action =~ s/[^a-z_]//g;
    }

    my %payload = (
        status => $status,
        output => (defined $all_out ? $all_out : ''),
        done   => ($status ne 'running' ? 1 : 0),
    );
    if (($in{'silent'} // '') eq '1') {
        if ($status eq 'running' && $notice_action =~ /^(?:start|restart)$/) {
            $payload{runtime_status} = 'starting';
            $payload{runtime_html}   = _ws_runtime_badge_html('starting');
            $payload{starting}       = 1;
        }
        elsif ($status ne 'running') {
            $payload{notice_msg} = _ws_action_result_text($notice_action, $status);
            my $retries = 0;
            if ($status eq 'ok') {
                $retries = 5 if $notice_action =~ /^(?:start|restart)$/;
                $retries = 3 if $notice_action eq 'stop';
            }
            my $rs = &instance_runtime_status($inst, light => 1, retries => $retries);
            my $mon = &read_monitor_state($server_dir, $config_directory, $instance_id);
            if ($status eq 'ok' && $notice_action =~ /^(?:start|restart)$/) {
                &monitor_heal_starting_if_ready(
                    $server_dir, $config_directory, $instance_id, $rs,
                    job_in_flight => 0);
                $mon = &read_monitor_state($server_dir, $config_directory, $instance_id);
            }
            $rs = &monitor_runtime_display_status($rs, $mon);
            $payload{runtime_status} = $rs;
            $payload{runtime_html}   = _ws_runtime_badge_html($rs);
            $payload{starting}       = ($rs eq 'starting') ? 1 : 0;
        }
    }
    $main::headerprinted = 1;
    print "Content-type: application/json; charset=utf-8\n\n";
    print job_log_json_utf8(\%payload);
    exit;
}


if ($action eq 'monitor') {
    my $source = &instance_effective_source($inst);
    my $mn = $module_name // $main::module_name // 'linuxgsm-webcore';
    $mn =~ s/[^a-zA-Z0-9_-]//g;

    &header($text{'manage_monitor_title'} || 'Server log (live)', '');
    print &job_log_view_page_css();
    print &job_log_view_page_open('fill');
    print &job_log_live_page_js();
    &server_log_render_monitor_page(
        form_cgi       => 'workshop.cgi',
        instance_id    => $instance_id,
        server_dir     => $server_dir,
        script_name    => $script_name,
        source         => $source,
        minecraft      => 0,
        log_file_pick  => $in{'log_file'},
        auto_refresh   => $in{'auto_refresh'},
        poll_url_base  => "/$mn/workshop.cgi?instance_id=" . &urlize($instance_id)
            . '&action=poll_monitor',
        text_keys      => server_log_monitor_text_keys_manage(),
        back_forms     => [
            {
                cgi        => 'workshop.cgi',
                label_keys => ['workshop_monitor_back_btn'],
                default    => 'Back to workshop',
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

my $silent_job_id = $in{'silent_job'} // '';
$silent_job_id =~ s/[^0-9a-f]//g;
$silent_job_id = substr($silent_job_id, 0, 16);
my $silent_polling = ($silent_job_id ne '');
my $silent_notice_action = '';
if ($silent_polling) {
    my $na = $in{'notice_action'} // '';
    $na =~ s/[^a-z_]//g;
    unless ($na) {
        my $meta = &get_job_meta($silent_job_id);
        $na = $meta->{'action'} // '';
        $na =~ s/[^a-z_]//g;
    }
    $silent_notice_action = $na;
    my %silent_opts = (notice_action => $na);
    my $ns = $in{'next_status'} // '';
    $ns =~ s/[^a-z_]//g;
    $silent_opts{next_status} = $ns if $ns ne '';
    &_ws_render_silent_job_poll($instance_id, $silent_job_id, %silent_opts);
}

# Match manage/index: light = tmux/PID only. Full LGSM `details` is heavy and can
# false-positive "online" (broad STARTED/RUNNING match) while the instance page
# correctly shows offline after stop.
my $runtime_status = &instance_runtime_status($inst, light => 1);
my @ws_extra;
{
    &sync_monitor_job_pointers();
    my $mon_state = &read_monitor_state($server_dir, $config_directory, $instance_id);
    $runtime_status = &monitor_runtime_display_status($runtime_status, $mon_state);
    $runtime_status = 'starting'
        if (($silent_polling && $silent_notice_action =~ /^(?:start|restart)$/)
            || &server_log_start_log_should_show(\%in, $instance_id));
    my $mon_status_key = 'monitor_status_' . ($mon_state->{'status'} // 'disabled');
    my $mon_label = $text{$mon_status_key} || ($mon_state->{'status'} // 'disabled');
    push @ws_extra, &ui_instance_status_part($text{'monitor_col'} || 'Monitor',
        &html_escape($mon_label));
}
print &job_status_pulse_css();
print &server_control_bar_html(
    cgi                 => 'workshop.cgi',
    instance_id         => $instance_id,
    readonly            => (&user_is_readonly($instance_id) ? 1 : 0),
    runtime_status_html => _ws_runtime_badge_html($runtime_status),
    extra_status_parts  => \@ws_extra,
    back_cgi            => 'manage.cgi',
    back_label          => ($text{'workshop_back_manage'} || 'Back to instance'),
);
if ($runtime_status eq 'starting') {
    my $mn = $module_name // $main::module_name // 'linuxgsm-webcore';
    $mn =~ s/[^a-zA-Z0-9_-]//g;
    print &server_runtime_starting_poll_js(
        "/$mn/workshop.cgi?instance_id=" . &urlize($instance_id)
            . '&action=poll_runtime');
}

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
if (($in{'start_log_warn'} // '') eq '1' && &module_config_flash_consume('start_log_embed_warn')) {
    print "<div class='alert alert-warning'>"
        . &html_escape($text{'start_log_embed_unavailable'}
            || 'Start job is running, but the embedded start log could not be prepared.')
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

if (&server_log_start_log_should_show(\%in, $instance_id)) {
    my $mn = $module_name // $main::module_name // 'linuxgsm-webcore';
    $mn =~ s/[^a-zA-Z0-9_-]//g;
    print &server_log_embed_html(
        instance_id   => $instance_id,
        server_dir    => $server_dir,
        script_name   => $script_name,
        source        => &instance_effective_source($inst),
        minecraft     => 0,
        poll_url_base => "/$mn/workshop.cgi?instance_id=" . &urlize($instance_id)
            . '&action=poll_monitor',
    );
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

# Installed inventory — shell first; one lazy poll loads the current page (50/page).
my $inv_page = int($in{'inv_page'} // 1);
$inv_page = 1 if $inv_page < 1;
print &ui_collapsible_start($text{'workshop_installed_section'} || 'Installed',
    id => 'ws-installed', open => 1,
    badge => '…');
print "<div id=\"ws-inventory\">"
    . "<p class=\"lgsm-inv-loading-line\"><i>"
    . &html_escape($text{'workshop_inventory_loading'}
        || 'Loading installed workshop items…')
    . "</i> " . &ui_progressive_dots_html('ws-inv-init-dots') . "</p>"
    . "</div>\n";
print &ui_collapsible_end();
print &ui_progressive_table_loader_js(
    box_id     => 'ws-inventory',
    section_id => 'ws-installed',
    poll_url   => _ws_module_cgi_path(
        "workshop.cgi?instance_id=" . &urlize($instance_id)
        . "&action=poll_inventory&inv_page=" . &urlize($inv_page)),
    fail_msg   => ($text{'workshop_inventory_load_failed'}
        || 'Could not load workshop inventory.'),
    batch_size => 50,
);

print &ui_collapsible_state_script();
&footer();
