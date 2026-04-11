#!/usr/bin/perl
use strict;
use warnings;

require './lib/core.pl';
require './lib/instance.pl';

our (%text, %config, %in);
&ReadParse(\%in);
&error_if_root();

my $user = &sanitize_input($in{'user'});
my $inst = &get_instance($user) or &error($text{'err_not_found'});

if ($in{'action'}) {
    &check_referer(1);
    my $action = &sanitize_input($in{'action'});
    &run_server_action($user, $action);
    &redirect("manage.cgi?user=$user");
}

my $safe_user = &html_escape($user);
&header("$text{'manage_title'}: $safe_user", '');

print "<p>Game: " . &html_escape($inst->{'game'}) . " | Port: " . int($inst->{'port'}) . " | Status: " . &html_escape($inst->{'status'}) . "</p>\n";
foreach my $action (qw(start stop restart update)) {
    print "<form method='post' action='manage.cgi' style='display:inline'>\n";
    print "<input type='hidden' name='user' value='$safe_user'>\n";
    print "<input type='hidden' name='action' value='$action'>\n";
    print "<input type='submit' value=\"" . &html_escape($text{"manage_$action"}) . "\">\n";
    print "</form>\n";
}

&footer('index.cgi', $text{'index_title'});
