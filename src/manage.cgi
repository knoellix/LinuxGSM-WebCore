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
    my $action = &sanitize_input($in{'action'});
    &run_server_action($user, $action);
    &redirect("manage.cgi?user=$user");
}

&header("$text{'manage_title'}: $user", '');

print "<p>Game: $inst->{'game'} | Port: $inst->{'port'} | Status: $inst->{'status'}</p>\n";
foreach my $action (qw(start stop restart update)) {
    print "<form method='post' action='manage.cgi' style='display:inline'>\n";
    print "<input type='hidden' name='user' value='$user'>\n";
    print "<input type='hidden' name='action' value='$action'>\n";
    print "<input type='submit' value=\"$text{'manage_$action'}\">\n";
    print "</form>\n";
}

&footer('index.cgi', $text{'index_title'});
