#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/instance.pl';
require './lib/firewall.pl';
require './lib/acl.pl';
require './lib/monitor.pl';

our (%text, %config, %in, %access, %gconfig);
our $config_directory;
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

sub _effective_instance_source {
    my ($inst) = @_;
    my $src = $inst->{'source'} // '';
    return $src if $src eq 'steamcmd';
    my $script_path = $inst->{'script'} // '';
    (my $server_dir = $script_path) =~ s|/[^/]+$||;
    return 'steamcmd' if $server_dir && -f "$server_dir/.steam_app_id";
    return $src || 'lgsm';
}

sub _instance_status_badge {
    my ($inst) = @_;
    my $status = 'unknown';
    my $src = _effective_instance_source($inst);
    if ($src eq 'steamcmd') {
        my $script_path = $inst->{'script'} // '';
        (my $server_dir = $script_path) =~ s|/[^/]+$||;
        $status = &_detect_status_steamcmd($server_dir);
    } elsif (($inst->{'instance_status'} // 'installed') ne 'installed') {
        $status = $inst->{'instance_status'};
    } else {
        $status = $inst->{'status'} // 'unknown';
    }
    my %map = (
        online     => '&#x1F7E2; L&auml;uft',
        running    => '&#x1F7E2; L&auml;uft',
        offline    => '&#x1F534; Nicht gestartet',
        stopped    => '&#x1F534; Nicht gestartet',
        fresh      => '&#x1F7E1; Bereitstellung offen',
        lgsm_ready => '&#x1F7E1; Installation offen',
        unknown    => '&#x1F7E1; Unbekannt',
    );
    return $map{$status} || ('&#x1F7E1; ' . &html_escape($status));
}

sub _monitor_status_badge {
    my ($inst, $cfg_dir) = @_;
    my $id = $inst->{'id'};
    my $s = &read_monitor_state($cfg_dir, $id);
    my %map = (
        running    => '&#x1F7E2;',
        restarting => '&#x1F7E1; ' . ($text{'jobs_status_running'} || '...'),
        failed     => '&#x1F534; ' . ($text{'monitor_status_failed'}   || 'Fehlgeschlagen'),
        paused     => '&#x26AB; '  . ($text{'monitor_status_paused'}   || 'Pausiert'),
        disabled   => '&#x26AB; '  . ($text{'monitor_status_disabled'} || 'Deaktiviert'),
    );
    return $map{$s->{'status'}} // '&#x1F7E2;';
}

&header($text{'index_title'}, '');
print "<p>$text{'index_desc'}</p>\n";

if (&can_create()) {
    print &ui_form_start('wizard.cgi', 'get');
    print &ui_submit($text{'index_btn_new_server'});
    print &ui_form_end();
}
if (&can_scan()) {
    print &ui_form_start('scan.cgi', 'get');
    print &ui_submit($text{'index_btn_scan'});
    print &ui_form_end();

    print &ui_form_start('ftp_settings.cgi', 'get');
    print &ui_submit($text{'index_btn_ftp'});
    print &ui_form_end();

    print &ui_form_start('steam_settings.cgi', 'get');
    print &ui_submit($text{'steam_btn'}, undef, undef, undef, 'btn-default');
    print &ui_form_end();
}

if (&effective_role() ne 'viewer') {
    print &ui_form_start('jobs.cgi', 'get');
    print &ui_submit($text{'jobs_title'} || 'Job-Übersicht', undef, undef, undef, 'btn-default');
    print &ui_form_end();
}

if (&is_admin()) {
    print &ui_form_start('acl_manage.cgi', 'get');
    print &ui_submit($text{'acl_manage_btn'} || 'Manage permissions', undef, undef, undef, 'btn-default');
    print &ui_form_end();

    print &ui_form_start('games_admin.cgi', 'get');
    print &ui_submit($text{'games_admin_btn'} || 'Game Database', undef, undef, undef, 'btn-default');
    print &ui_form_end();
}

my @instances = &list_managed_instances();

if (!@instances) {
    print "<p>$text{'index_no_instances'}</p>\n";
} else {
    my @rows;
    foreach my $inst (@instances) {
        my $id         = $inst->{'id'};
        my $manage_url = "manage.cgi?instance_id=" . &html_escape($id);
        my $port_str   = $inst->{'port'} ? int($inst->{'port'}) : '—';

        push @rows, [
            &html_escape($inst->{'user'}),
            &html_escape($inst->{'game'}),
            $port_str,
            _instance_status_badge($inst),
            _monitor_status_badge($inst, $config_directory),
            (&user_is_readonly($id)
                ? "<a href='$manage_url'>$text{'index_btn_manage'}</a> <small>(" . ($text{'acl_role_viewer'} || 'Viewer') . ")</small>"
                : "<a href='$manage_url'>$text{'index_btn_manage'}</a>"),
        ];
    }

    print &ui_columns_table(
        [
            $text{'index_col_user'},
            $text{'index_col_game'},
            $text{'index_col_port'},
            ($text{'manage_status'} || 'Status'),
            ($text{'monitor_col'}   || 'Monitor'),
            $text{'index_col_manage'},
        ],
        "100%",
        \@rows,
    );
}

&footer('', '');
