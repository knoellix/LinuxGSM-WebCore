#!/usr/bin/perl
use strict;
use warnings;

require './lib/core.pl';
require './lib/instance.pl';

our (%text, %config, %in);
&ReadParse(\%in);
&header($text{'index_title'}, '');

print "<p>$text{'index_desc'}</p>\n";

my @instances = &list_instances();
if (@instances) {
    print "<table class='ui_table'>\n";
    print "<tr><th>User</th><th>Game</th><th>Port</th><th>Status</th><th>Actions</th></tr>\n";
    foreach my $inst (@instances) {
        print "<tr><td>$inst->{'user'}</td><td>$inst->{'game'}</td>";
        print "<td>$inst->{'port'}</td><td>$inst->{'status'}</td>";
        print "<td><a href='manage.cgi?user=$inst->{user}'>Manage</a></td></tr>\n";
    }
    print "</table>\n";
} else {
    print "<p>$text{'index_no_instances'}</p>\n";
}

&footer('', '');
