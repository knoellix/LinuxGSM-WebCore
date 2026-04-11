#!/usr/bin/perl
use strict;
use warnings;

require './lib/core.pl';
require './lib/instance.pl';
require './lib/firewall.pl';

our (%text, %config, %in);
&ReadParse(\%in);

# Firewall-Aktionen verarbeiten (vor Header, da redirect möglich)
if ($in{'action'} && $in{'user'}) {
    &error_if_root();
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
    }
    &redirect("index.cgi?expand=$user");
}

&header($text{'index_title'}, '');
print "<p>$text{'index_desc'}</p>\n";

my @instances = &list_instances();

if (!@instances) {
    print "<p>$text{'index_no_instances'}</p>\n";
} else {
    my $expand = $in{'expand'} ? &sanitize_input($in{'expand'}) : '';

    print "<table class='ui_table'>\n";
    print "<tr>";
    for my $col (qw(index_col_user index_col_game index_col_port index_col_status index_col_health index_col_details)) {
        print "<th>$text{$col}</th>";
    }
    print "</tr>\n";

    foreach my $inst (@instances) {
        my $user      = $inst->{'user'};
        my $status    = $inst->{'status'};
        my $warnings  = $inst->{'warnings'};
        my $expanding = ($expand eq $user);

        my $status_color = $status eq 'online'  ? 'green'
                         : $status eq 'offline' ? 'red'
                         :                        'gray';
        my $status_text = $text{"status_$status"} // $status;
        my $health_icon = @$warnings
            ? "&#9888; (" . scalar(@$warnings) . ")"
            : "&#10003;";
        my $toggle_url  = $expanding
            ? "index.cgi"
            : "index.cgi?expand=$user";
        my $toggle_char = $expanding ? "&#9650;" : "&#9660;";

        print "<tr>";
        print "<td>$user</td>";
        print "<td>$inst->{'game'}</td>";
        print "<td>$inst->{'port'}</td>";
        print "<td style='color:$status_color'>$status_text</td>";
        print "<td>$health_icon</td>";
        print "<td><a href='$toggle_url'>$toggle_char</a></td>";
        print "</tr>\n";

        if ($expanding) {
            my $port    = $inst->{'port'};
            my $fw_open = $inst->{'fw_open'};
            my $fw_icon = $fw_open
                ? "&#10003; $text{fw_status_open}"
                : "&#10007; $text{fw_status_closed}";
            my $fw_action = $fw_open ? 'fw_close' : 'fw_open';
            my $fw_btn    = $fw_open ? $text{fw_close_btn} : $text{fw_open_btn};

            print "<tr><td colspan='6' style='padding:8px;background:#f9f9f9'>\n";
            print "<table>\n";
            print "<tr><td><b>$text{detail_port}</b></td><td>$port</td></tr>\n";
            print "<tr><td><b>$text{detail_firewall}</b></td><td>$fw_icon &nbsp;";
            print "<form method='post' action='index.cgi' style='display:inline'>";
            print "<input type='hidden' name='action' value='$fw_action'>";
            print "<input type='hidden' name='user' value='$user'>";
            print "<input type='hidden' name='expand' value='$user'>";
            print "<input type='submit' value=\"$fw_btn\">";
            print "</form></td></tr>\n";
            print "</table>\n";

            print "<p>";
            foreach my $action (qw(start stop restart update)) {
                print "<form method='post' action='manage.cgi' style='display:inline;margin-right:4px'>";
                print "<input type='hidden' name='user' value='$user'>";
                print "<input type='hidden' name='action' value='$action'>";
                print "<input type='submit' value=\"$text{'manage_$action'}\">";
                print "</form>";
            }
            print "</p>\n";

            if (@$warnings) {
                print "<p><b>&#9888; Warnungen:</b></p><ul>\n";
                for my $w (@$warnings) {
                    my $safe_w = $w;
                    $safe_w =~ s/&/&amp;/g;
                    $safe_w =~ s/</&lt;/g;
                    print "<li>$safe_w</li>\n";
                }
                print "</ul>\n";
            }

            print "</td></tr>\n";
        }
    }
    print "</table>\n";
}

&footer('', '');
