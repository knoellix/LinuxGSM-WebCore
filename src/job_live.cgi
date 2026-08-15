#!/usr/bin/perl
# Live job log viewer — xterm.js terminal with JSON polling (reliable in Webmin iframe).
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/instance.pl';
require './lib/acl.pl';
require './lib/jobs.pl';
require './lib/live_log.pl';

our (%text, %in, %gconfig, $module_name, $module_root, $module_root_directory,
    $session_id, $remote_user, $config_directory, $root_directory);
$module_root ||= $module_root_directory;
$module_root ||= do { (my $d = __FILE__) =~ s{/[^/]+$}{}; $d };
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

my $instance_id = &sanitize_input($in{'instance_id'} // '');
my $job_id = $in{'job'} // '';
$job_id =~ s/[^0-9a-f]//g;
$job_id = substr($job_id, 0, 16);
my $next_status = $in{'next_status'} // '';
$next_status =~ s/[^a-z_]//g;
my $next_action = $in{'next_action'} // '';
$next_action =~ s/[^a-z_]//g;
my $return_raw = $in{'return'} // '';

sub _job_live_trim_search_param {
    my ($raw) = @_;
    $raw //= '';
    $raw =~ s/[\t\n\r\0]//g;
    $raw =~ s/^\s+|\s+$//g;
    return substr($raw, 0, 100);
}

sub _job_live_query_urlencode {
    my ($v) = @_;
    $v //= '';
    $v =~ s/([^A-Za-z0-9_\-.~])/sprintf('%%%02X', ord($1))/ge;
    return $v;
}

sub _job_live_safe_return_param {
    my ($key, $raw) = @_;
    $raw //= '';
    $raw =~ s/[\t\n\r\0]//g;
    $raw =~ s/^\s+|\s+$//g;

    if ($key eq 'instance_id') {
        $raw =~ s/[^A-Za-z0-9_.-]//g;
        $raw = substr($raw, 0, 64);
        return length($raw) ? $raw : undef;
    }
    if ($key eq 'q' || $key eq 'mod_q' || $key eq 'pack_q') {
        $raw =~ s/[^A-Za-z0-9 ._:+\-\/]//g;
        $raw = substr($raw, 0, 100);
        return $raw;
    }
    if ($key eq 'status') {
        $raw = lc($raw);
        return ($raw eq 'all' || $raw eq 'enabled' || $raw eq 'disabled') ? $raw : 'all';
    }
    if ($key eq 'sort') {
        $raw = lc($raw);
        return ($raw eq 'name' || $raw eq 'status') ? $raw : 'name';
    }
    if ($key eq 'dir') {
        $raw = lc($raw);
        return ($raw eq 'asc' || $raw eq 'desc') ? $raw : 'asc';
    }
    if ($key eq 'page') {
        return '1' unless $raw =~ /\A\d+\z/;
        my $page = int($raw);
        $page = 1 if $page < 1;
        $page = 9999 if $page > 9999;
        return "$page";
    }
    if ($key eq 'xnavigation') {
        return ($raw eq '1') ? '1' : undef;
    }
    return undef;
}

sub _job_live_safe_return_query {
    my ($raw, $instance_id) = @_;
    $raw //= '';
    $raw =~ s/[\t\n\r\0]//g;
    $raw =~ s/^\s+|\s+$//g;
    return '' unless length($raw) <= 600;
    return '' unless $raw =~ m{\Amods\.cgi\?(.+)\z};

    my $query = $1;
    my %allowed = map { $_ => 1 } qw(instance_id q status sort dir page mod_q pack_q xnavigation);
    my %vals;
    my %seen;
    for my $pair (split /&/, $query, -1) {
        next unless length($pair);
        my ($k, $v) = split(/=/, $pair, 2);
        $k //= '';
        $v //= '';
        return '' unless $k =~ /\A[A-Za-z0-9_]+\z/;
        return '' unless $allowed{$k};
        next if $seen{$k}++;
        my $safe = _job_live_safe_return_param($k, $v);
        return '' unless defined $safe;
        $vals{$k} = $safe;
    }

    my $ret_id = $vals{'instance_id'} // '';
    return '' unless defined $instance_id && $ret_id eq $instance_id;

    my @pairs = ("instance_id=" . _job_live_query_urlencode($ret_id));
    for my $k (qw(q status sort dir page mod_q pack_q)) {
        next unless exists $vals{$k};
        next unless length($vals{$k});
        push @pairs, $k . '=' . _job_live_query_urlencode($vals{$k});
    }
    push @pairs, 'xnavigation=1';
    return 'mods.cgi?' . join('&', @pairs);
}

sub _job_live_mc_search_url_suffix {
    my $suffix = '';
    my $pack_q = _job_live_trim_search_param($in{'pack_q'} // '');
    my $mod_q  = _job_live_trim_search_param($in{'mod_q'} // '');
    $suffix .= '&pack_q=' . _job_live_query_urlencode($pack_q) if length($pack_q) >= 2;
    $suffix .= '&mod_q=' . _job_live_query_urlencode($mod_q) if length($mod_q) >= 2;
    return $suffix;
}

my $mc_search_suffix = _job_live_mc_search_url_suffix();
my $return_query = _job_live_safe_return_query($return_raw, $instance_id);

$instance_id && $job_id or &error($text{'err_invalid_input'});
&validate_job_for_instance($job_id, $instance_id)
    or &error($text{'err_not_found'});
&user_can_manage($instance_id)
    or &error($text{'err_acl_admin_only'} || 'Access denied');

my $inst = &get_instance_flexible($instance_id) or &error($text{'err_not_found'});
my $output_file = &job_output_file($job_id);
&validate_job_output_path($output_file)
    or &error($text{'err_invalid_input'});

&timeout_check_job($job_id);
my $status = &get_job_status($job_id) // 'unknown';
my $initial_out = &get_job_output_display($job_id);
my $job_done = ($status eq 'ok' || $status eq 'failed' || $status eq 'aborted');

if ($job_done && $status eq 'ok') {
    my $apply_status = $next_status;
    unless ($apply_status) {
        my $meta = &get_job_meta($job_id);
        $apply_status = &job_next_instance_status($meta->{'action'});
    }
    &set_instance_status($instance_id, $apply_status) if $apply_status;
    require './lib/module_config.pl';
    &module_config_flash_mark("jobres_$job_id");
}

my $meta = &get_job_meta($job_id);
my $job_action = $meta->{'action'} // 'job';
my %job_action_labels = %{ &job_action_labels_hash(\%text) };
my $action_label = $job_action_labels{$job_action} // &job_action_label($job_action, \%text);

my $poll_q = "manage.cgi?instance_id=$instance_id&action=poll_job&job=$job_id&poll_format=json"
    . ($next_status ? "&next_status=$next_status" : '')
    . ($next_action ? "&next_action=$next_action" : '');
my $poll_path = "/$module_name/$poll_q";
my $return_path = "/$module_name/"
    . ($return_query ne ''
        ? $return_query
        : "manage.cgi?instance_id=$instance_id&xnavigation=1" . $mc_search_suffix);
$return_path .= "&action_result=$job_id" if ($return_query eq '' && $job_done && $status eq 'ok');

require JSON::PP;
my $fail_hint_key = '';
if ($job_done && $status eq 'failed') {
    $fail_hint_key = &get_job_error_hint($job_id) // '';
}

my $fail_hint_html = '';
if ($fail_hint_key ne '') {
    my $hint_text = $text{$fail_hint_key} // $fail_hint_key;
    $fail_hint_html = "<p><strong>" . &html_escape($text{'job_hint_title'})
        . ":</strong> " . &html_escape($hint_text) . "</p>\n";
}

my $manage_path_js = job_log_json_for_script({ url => $return_path });
my $copy_cfg_js    = job_log_json_for_script({
    failMsg => $text{'job_live_copy_fail'} || 'Kopieren fehlgeschlagen',
    waitMsg => $text{'job_waiting_output'} || 'Warte auf Worker-Ausgabe…',
});
my $action_label_e = &html_escape(&job_log_utf8_decode($action_label));

my $initial_display = $initial_out ne '' ? $initial_out : ($job_done ? '' : &job_log_utf8_decode($text{'job_waiting_output'} || 'Warte auf Worker-Ausgabe…'));

&header($text{'job_live_title'} || 'Live-Log', '', &job_log_view_page_css());

print &job_log_view_page_open('fill');
print &job_log_view_toolbar_open();
print "<h3 style=\"margin-top:0\">" . &html_escape($text{'job_live_title'} || 'Live-Log') . "</h3>\n";
print "<p id=\"job_live_status\">";
if ($job_done) {
    if ($status eq 'ok') {
        print "<span style=\"color:green\">" . &html_escape($text{'job_ok'}) . "</span>";
    } elsif ($status eq 'aborted') {
        print &html_escape($text{'job_aborted_ok'} || 'Job abgebrochen.');
    } else {
        print "<span style=\"color:red\">" . &html_escape($text{'job_failed'}) . "</span>";
    }
} else {
    print "<span class=\"lgsm-job-pulse\" aria-hidden=\"true\"></span>";
    print &html_escape($text{'job_running'});
}
print " — $action_label_e</p>\n";
print $fail_hint_html if $fail_hint_html ne '';

unless ($job_done) {
    print "<p id=\"job_poll_hint\"><small><i>"
        . &html_escape($text{'job_poll_updating'} || 'Ausgabe wird aktualisiert…')
        . "</i></small></p>\n";
}

my $back_target = $return_query ne '' ? 'mods.cgi' : 'manage.cgi';
print &ui_form_start($back_target, 'get');
print &ui_hidden('instance_id', &html_escape($instance_id));
print &ui_hidden('xnavigation', '1');
print &ui_submit($text{'job_back_to_instance'} || 'Zur Instanz', undef, undef, undef, 'btn-default');
print &ui_form_end();

unless ($job_done) {
    print &ui_form_start('manage.cgi', 'post', undef,
        "onsubmit=\"return confirm('" . &html_escape($text{'jobs_abort_confirm'} || 'Abbrechen?') . "')\"");
    print &ui_hidden('instance_id', &html_escape($instance_id));
    print &ui_hidden('xnavigation', '1');
    print &ui_hidden('action', 'abort_job');
    print &ui_hidden('job', &html_escape($job_id));
    print &ui_submit($text{'jobs_abort_btn'} || 'Abbrechen', undef, undef, undef, 'btn-danger');
    print &ui_form_end();
}

print "<p class=\"lgsm-job-live-actions\">"
    . "<button type=\"button\" id=\"job_live_copy_btn\" class=\"btn btn-default\">"
    . &html_escape($text{'job_live_copy_btn'} || 'Log kopieren')
    . "</button> "
    . "<span id=\"job_live_copy_ok\" style=\"display:none;color:green\">"
    . &html_escape($text{'job_live_copy_ok'} || 'In Zwischenablage kopiert')
    . "</span></p>\n";
print &job_log_view_toolbar_close();

print &job_log_view_block($initial_display, id => 'job_out', live => 1);
print &job_log_view_page_close();
print &job_log_live_page_js();

# Copy-to-clipboard: bound in all states (running, ok, failed, aborted).
print <<"EOF";
<script>
(function () {
  var C = $copy_cfg_js;
  var copyBtn = document.getElementById("job_live_copy_btn");
  if (!copyBtn) return;
  var outEl = document.getElementById("job_out");
  var copyOkEl = document.getElementById("job_live_copy_ok");
  var copyFailMsg = C.failMsg;
  var waitMsg = C.waitMsg;

  function logText() {
    if (!outEl) return "";
    var body = outEl.querySelector(".lgsm-job-log-body");
    return body ? body.textContent : outEl.textContent;
  }
  function showOk() {
    if (copyOkEl) {
      copyOkEl.style.display = "inline";
      window.setTimeout(function () { copyOkEl.style.display = "none"; }, 2500);
    }
  }
  function fallbackCopy(text) {
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.left = "-9999px";
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    var ok = false;
    try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    if (ok) showOk(); else window.alert(copyFailMsg);
  }
  copyBtn.addEventListener("click", function () {
    var text = logText();
    if (!text || text === waitMsg) return;
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(showOk).catch(function () {
        fallbackCopy(text);
      });
      return;
    }
    fallbackCopy(text);
  });
})();
</script>
EOF

unless ($job_done) {
    print &job_log_live_poll_client_js(
        poll_url        => $poll_path,
        manage_url      => $return_path,
        out_id          => 'job_out',
        status_id       => 'job_live_status',
        wait_msg        => $text{'job_waiting_output'} || 'Warte auf Worker-Ausgabe…',
        ok_msg          => $text{'job_ok'},
        fail_msg        => $text{'job_failed'},
        aborted_msg     => $text{'job_aborted_ok'} || 'Job abgebrochen.',
        running_msg     => $text{'job_running'},
        poll_fail_msg   => $text{'job_poll_error'} || 'Live-Aktualisierung fehlgeschlagen — Seite neu laden.',
        action_suffix   => " — $action_label",
        poll_interval   => 1500,
        redirect_delay  => 1500,
        use_done_field  => 1,
    );
} elsif ($status eq 'ok') {
    print <<"EOF";
<script>
(function () {
  var manageUrl = $manage_path_js;
    window.setTimeout(function () {
      window.location.replace(manageUrl.url);
    }, 1500);
})();
</script>
EOF
}

&footer('', '');
exit;
