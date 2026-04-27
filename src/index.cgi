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

our (%text, %config, %in, %access, %gconfig);
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

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
            $text{'index_col_manage'},
        ],
        "100%",
        \@rows,
    );
}

&footer('', '');
