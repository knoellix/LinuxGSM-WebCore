# Shared Start / Stop / Restart / Log / Back control bar (mods, workshop, …).
# Game-agnostic: callers supply status HTML and handle monitor enable/disable.
use strict;
use warnings;

our (%text);

# Inline form wrapper (same pattern as mods.cgi / manage.cgi toolbars).
sub server_control_bar_inline_btn {
    my ($html) = @_;
    $html //= '';
    $html =~ s/<form(\s)/<form style="display:inline-block;margin:0;vertical-align:middle"$1/i;
    return "<span style='display:inline-block;margin:0 8px 6px 0;vertical-align:middle'>$html</span>";
}

# opts:
#   cgi                 => form action CGI (required for useful markup)
#   instance_id         => instance id
#   readonly            => bool — hide start/stop/restart
#   runtime_status_html => pre-rendered status badge HTML
#   extra_status_parts  => arrayref of ui_instance_status_part strings
#   after_status_html   => HTML inserted between status line and action buttons
#   actions             => list among start stop restart log back (default all)
#   back_cgi            => default manage.cgi
#   back_label          => optional override for Back button label
#   readonly_hint       => optional override for readonly message
sub server_control_bar_html {
    my (%opts) = @_;
    my $cgi = $opts{'cgi'} // '';
    $cgi =~ s/[^a-zA-Z0-9_.-]//g;
    $cgi = 'manage.cgi' if $cgi eq '';

    my $instance_id = $opts{'instance_id'} // '';
    $instance_id =~ s/[^a-zA-Z0-9_-]//g;
    my $safe_id = &html_escape($instance_id);

    my $readonly = $opts{'readonly'} ? 1 : 0;
    my $runtime_html = $opts{'runtime_status_html'} // '';
    my $extra = $opts{'extra_status_parts'};
    $extra = [] unless ref($extra) eq 'ARRAY';

    my $actions = $opts{'actions'};
    if (!defined $actions) {
        $actions = [qw(start stop restart log back)];
    }
    elsif (ref($actions) ne 'ARRAY') {
        $actions = [ grep { length } split /\s+/, "$actions" ];
    }
    my %want = map { $_ => 1 } @$actions;

    my $back_cgi = $opts{'back_cgi'} // 'manage.cgi';
    $back_cgi =~ s/[^a-zA-Z0-9_.-]//g;
    $back_cgi = 'manage.cgi' if $back_cgi eq '';

    my $back_label = $opts{'back_label'}
        // $text{'mc_mods_page_back_manage'}
        // 'Back to manage';
    my $readonly_hint = $opts{'readonly_hint'}
        // $text{'mc_mods_page_readonly_hint'}
        // 'Read-only mode: Start/Stop actions are disabled.';

    my $start_label = $text{'mc_mods_page_start_btn'} || 'Start';
    my $stop_label  = $text{'mc_mods_page_stop_btn'}  || 'Stop';
    my $restart_label = $text{'jobs_action_restart'}
        || $text{'mc_mods_page_restart_btn'}
        || 'Restart';
    my $log_label = $text{'mc_mods_page_log_btn'} || 'Log';

    my $inst_label = $text{'mc_mods_page_instance_label'} || 'Instance';
    my $stat_label = $text{'mc_mods_page_status_label'}
        || $text{'manage_status'}
        || 'Status';

    my @parts;
    push @parts, &ui_instance_status_part($inst_label, $safe_id) if $safe_id ne '';
    push @parts, &ui_instance_status_part($stat_label, $runtime_html)
        if defined $runtime_html && $runtime_html =~ /\S/;
    push @parts, grep { defined && /\S/ } @$extra;

    my $html = '';
    $html .= &ui_instance_status_line(@parts) if @parts;

    my $after = $opts{'after_status_html'} // '';
    $html .= $after if $after ne '';

    $html .= "<div style='margin:4px 0 12px 0'>\n";

    my $mutates = ($want{'start'} || $want{'stop'} || $want{'restart'}) ? 1 : 0;
    if ($readonly && $mutates) {
        $html .= "<p>" . &html_escape($readonly_hint) . "</p>\n";
    }
    elsif (!$readonly) {
        if ($want{'start'}) {
            my $form = &ui_form_start($cgi, 'post');
            $form .= &ui_hidden('instance_id', $safe_id);
            $form .= &ui_hidden('xnavigation', '1');
            $form .= &ui_hidden('action', 'start');
            $form .= &ui_submit($start_label, undef, undef, undef, 'btn-success');
            $form .= &ui_form_end();
            $html .= server_control_bar_inline_btn($form);
        }
        if ($want{'stop'}) {
            my $form = &ui_form_start($cgi, 'post');
            $form .= &ui_hidden('instance_id', $safe_id);
            $form .= &ui_hidden('xnavigation', '1');
            $form .= &ui_hidden('action', 'stop');
            $form .= &ui_submit($stop_label, undef, undef, undef, 'btn-default');
            $form .= &ui_form_end();
            $html .= server_control_bar_inline_btn($form);
        }
        if ($want{'restart'}) {
            my $form = &ui_form_start($cgi, 'post');
            $form .= &ui_hidden('instance_id', $safe_id);
            $form .= &ui_hidden('xnavigation', '1');
            $form .= &ui_hidden('action', 'restart');
            $form .= &ui_submit($restart_label, undef, undef, undef, 'btn-default');
            $form .= &ui_form_end();
            $html .= server_control_bar_inline_btn($form);
        }
    }

    if ($want{'log'}) {
        my $form = &ui_form_start($cgi, 'get');
        $form .= &ui_hidden('instance_id', $safe_id);
        $form .= &ui_hidden('action', 'monitor');
        $form .= &ui_hidden('xnavigation', '1');
        $form .= &ui_submit($log_label, undef, undef, undef, 'btn-default');
        $form .= &ui_form_end();
        $html .= server_control_bar_inline_btn($form);
    }
    if ($want{'back'}) {
        my $form = &ui_form_start($back_cgi, 'get');
        $form .= &ui_hidden('instance_id', $safe_id);
        $form .= &ui_hidden('xnavigation', '1');
        $form .= &ui_submit($back_label, undef, undef, undef, 'btn-default');
        $form .= &ui_form_end();
        $html .= server_control_bar_inline_btn($form);
    }

    $html .= "</div>\n";
    return $html;
}

1;
