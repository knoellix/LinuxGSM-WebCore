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
}

my @instances = &list_managed_instances();

if (!@instances) {
    print "<p>$text{'index_no_instances'}</p>\n";
} else {
    my @rows;
    foreach my $inst (@instances) {
        my $id       = $inst->{'id'};
        my $warnings = $inst->{'warnings'};
        my $status   = $inst->{'status'};

        my $status_cell = &html_escape($text{"status_$status"} // $status);
        my $health_cell = @$warnings
            ? "&#x26A0; (" . scalar(@$warnings) . ")"
            : "&#x2705;";
        my $manage_url  = "manage.cgi?instance_id=" . &html_escape($id);

        push @rows, [
            &html_escape($inst->{'user'}),
            &html_escape($inst->{'game'}),
            int($inst->{'port'}),
            $status_cell,
            $health_cell,
            "<a href='$manage_url'>$text{'index_btn_manage'}</a>",
        ];
    }

    print &ui_columns_table(
        [
            $text{'index_col_user'},
            $text{'index_col_game'},
            $text{'index_col_port'},
            $text{'index_col_status'},
            $text{'index_col_health'},
            $text{'index_col_manage'},
        ],
        "100%",
        \@rows,
    );
}

&footer('', '');
