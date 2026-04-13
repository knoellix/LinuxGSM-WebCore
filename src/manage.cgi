#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/instance.pl';

our (%text, %config, %in);
&ReadParse(\%in);

my $instance_id = &sanitize_input($in{'instance_id'} || $in{'user'} || '');
my $inst = &get_instance($instance_id) or &error($text{'err_not_found'});
my $unix_user = $inst->{'user'};

if ($in{'action'}) {
    my $action = &sanitize_input($in{'action'});
    &run_server_action($unix_user, $action);
    &redirect("manage.cgi?instance_id=" . &html_escape($instance_id));
}

my $safe_id = &html_escape($instance_id);
&header("$text{'manage_title'}: $safe_id", '');

# Server-Info
print &ui_table_start($text{'manage_title'}, "width=100%", 2);
print &ui_table_row($text{'manage_game'},   &html_escape($inst->{'game'}));
print &ui_table_row($text{'manage_port'},   int($inst->{'port'}));
print &ui_table_row($text{'manage_status'}, &html_escape($inst->{'status'}));
print &ui_table_end();

# Steuerungs-Buttons
print "<p>\n";
foreach my $action (qw(start stop restart update)) {
    print &ui_form_start("manage.cgi", "post");
    print &ui_hidden("instance_id", $safe_id);
    print &ui_hidden("action",      $action);
    print &ui_submit($text{"manage_$action"});
    print &ui_form_end();
    print " ";
}
print "</p>\n";

&footer('index.cgi', $text{'index_title'});
