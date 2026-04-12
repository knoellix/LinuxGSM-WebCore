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

our (%text, %config, %in, %access);
&ReadParse(\%in);

# Firewall-Aktionen verarbeiten (vor Header, da redirect möglich)
if ($in{'action'} && $in{'user'}) {
    &check_referer(1);
    my $action = &sanitize_input($in{'action'});
    my $user   = &sanitize_input($in{'user'});
    my $inst   = &get_instance($user) or &error($text{'err_not_found'});
    my $port   = int($inst->{'port'});

    if ($action eq 'fw_open') {
        &firewall_open_port($port, 'tcp');
        &firewall_open_port($port, 'udp');
    } elsif ($action eq 'fw_close') {
        &firewall_close_port($port, 'tcp');
        &firewall_close_port($port, 'udp');
    } else {
        &error($text{'err_invalid_action'});
    }
    &redirect("index.cgi?expand=$user");
}

&header($text{'index_title'}, '');
print "<p>$text{'index_desc'}</p>\n";

if ($access{'can_create'} || $access{'can_scan'}) {
    if ($access{'can_create'}) {
        print &ui_form_start('wizard.cgi', 'get');
        print &ui_submit($text{'index_btn_new_server'});
        print &ui_form_end();
    }
    if ($access{'can_scan'}) {
        print &ui_form_start('scan.cgi', 'get');
        print &ui_submit($text{'index_btn_scan'});
        print &ui_form_end();
    }
}

my @instances = &list_managed_instances();

if (!@instances) {
    print "<p>$text{'index_no_instances'}</p>\n";
} else {
    my $expand = $in{'expand'} ? &sanitize_input($in{'expand'}) : '';

    print &ui_columns_header([
        $text{index_col_user},
        $text{index_col_game},
        $text{index_col_port},
        $text{index_col_status},
        $text{index_col_health},
        $text{index_col_details},
    ]);

    foreach my $inst (@instances) {
        my $user      = $inst->{'user'};
        my $status    = $inst->{'status'};
        my $warnings  = $inst->{'warnings'};
        my $expanding = ($expand eq $user);

        my $status_text = &html_escape($text{"status_$status"} // $status);
        my $health_icon = @$warnings
            ? "\x{26A0}\x{FE0F} (" . scalar(@$warnings) . ")"
            : "\x{2705}";
        my $safe_user   = &html_escape($user);
        my $toggle_url  = $expanding ? "index.cgi" : "index.cgi?expand=$safe_user";
        my $toggle_char = $expanding ? "&#9650;" : "&#9660;";

        print &ui_columns_row([
            $safe_user,
            &html_escape($inst->{'game'}),
            int($inst->{'port'}),
            $status_text,
            $health_icon,
            "<a href='$toggle_url'>$toggle_char</a>",
        ]);

        if ($expanding) {
            my $port    = int($inst->{'port'});
            my $fw_open = $inst->{'fw_open'};
            my $fw_icon = $fw_open
                ? "\x{2705} $text{fw_status_open}"
                : "\x{274C} $text{fw_status_closed}";
            my $fw_action = $fw_open ? 'fw_close' : 'fw_open';
            my $fw_btn    = $fw_open ? $text{fw_close_btn} : $text{fw_open_btn};

            my $detail = "";

            # Firewall-Status + Button
            $detail .= "<p><b>$text{detail_firewall}:</b> $fw_icon &nbsp;";
            $detail .= "<form method='post' action='index.cgi' style='display:inline'>";
            $detail .= "<input type='hidden' name='action' value='$fw_action'>";
            $detail .= "<input type='hidden' name='user' value='$safe_user'>";
            $detail .= "<input type='hidden' name='expand' value='$safe_user'>";
            $detail .= "<input type='submit' value=\"" . &html_escape($fw_btn) . "\">";
            $detail .= "</form></p>\n";

            # Steuerungs-Buttons
            $detail .= "<p>";
            foreach my $action (qw(start stop restart update)) {
                $detail .= "<form method='post' action='manage.cgi' style='display:inline;margin-right:4px'>";
                $detail .= "<input type='hidden' name='user' value='$safe_user'>";
                $detail .= "<input type='hidden' name='action' value='$action'>";
                $detail .= "<input type='submit' value=\"" . &html_escape($text{"manage_$action"}) . "\">";
                $detail .= "</form>";
            }
            $detail .= "</p>\n";

            # Health-Warnungen
            if (@$warnings) {
                $detail .= "<p><b>\x{26A0}\x{FE0F} $text{health_warn_header}</b></p><ul>\n";
                for my $w (@$warnings) {
                    $detail .= "<li>" . &html_escape($w) . "</li>\n";
                }
                $detail .= "</ul>\n";
            }

            print "<tr><td colspan='6'>$detail</td></tr>\n";
        }
    }

    print &ui_columns_end();
}

&footer('', '');
