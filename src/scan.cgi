#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/acl.pl';
require './lib/instance.pl';

our (%text, %in, %access);
&ReadParse(\%in);

&can_scan() or &error($text{'err_access_denied'});

# --- POST: assign owner ---
if ($ENV{REQUEST_METHOD} eq 'POST') {
    &check_referer(1);
    my $game_user   = &sanitize_input($in{'game_user'});
    my $webmin_user = &sanitize_input($in{'webmin_user'});

    $game_user   or &error($text{'err_invalid_input'});
    $webmin_user or &error($text{'err_invalid_input'});

    # Validate both exist
    &get_instance($game_user) or &error($text{'err_not_found'});
    my %valid = map { $_ => 1 } &list_webmin_users();
    $valid{$webmin_user} or &error($text{'err_invalid_input'});

    &grant_server_access($webmin_user, $game_user);
    &redirect('scan.cgi');
}

# --- GET: show all instances with ownership info ---
&header($text{'scan_title'}, '');
print "<h3>$text{'scan_title'}</h3>\n";

my @instances = &list_instances();
my @webmin_users = &list_webmin_users();
my @wbm_opts = map { [$_, $_] } @webmin_users;

print &ui_columns_header([
    $text{'index_col_user'},
    $text{'index_col_game'},
    $text{'index_col_port'},
    $text{'scan_col_owner'},
    $text{'scan_assign'},
]);

foreach my $inst (@instances) {
    my $user  = $inst->{'user'};
    my @owners = &get_server_owners($user);

    my $owner_cell = @owners
        ? join(', ', map { &html_escape($_) } @owners)
        : "<i>$text{'scan_unowned'}</i>";

    my $assign_cell = '';
    unless (@owners) {
        $assign_cell .= &ui_form_start('scan.cgi', 'post');
        $assign_cell .= &ui_hidden('game_user', &html_escape($user));
        $assign_cell .= "$text{'scan_assign_label'} ";
        $assign_cell .= &ui_select('webmin_user', '', \@wbm_opts);
        $assign_cell .= ' ';
        $assign_cell .= &ui_submit($text{'scan_assign'});
        $assign_cell .= &ui_form_end();
    }

    print &ui_columns_row([
        &html_escape($user),
        &html_escape($inst->{'game'}),
        int($inst->{'port'}),
        $owner_cell,
        $assign_cell,
    ]);
}

print &ui_columns_end();
&footer('', '');
