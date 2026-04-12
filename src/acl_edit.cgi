#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/acl.pl';
require './lib/instance.pl';

our (%text, %in, %access, $module_name);
&ReadParse(\%in);

# Nur User mit can_create dürfen ACLs anderer User bearbeiten
&can_create() or &error($text{'err_access_denied'});

my $edit_user = &sanitize_input($in{'user'} // '');
$edit_user or &error($text{'err_invalid_input'});

if ($ENV{REQUEST_METHOD} eq 'POST') {
    &check_referer(1);

    my %acl;
    $acl{'can_create'} = $in{'can_create'} ? 1 : 0;
    $acl{'can_scan'}   = $in{'can_scan'}   ? 1 : 0;

    if ($in{'servers_all'}) {
        $acl{'servers'} = '*';
    } else {
        # ReadParse liefert bei mehreren gleichen Feldern ein Array-Ref
        my @sel = ref($in{'servers'}) eq 'ARRAY' ? @{$in{'servers'}}
                : defined($in{'servers'})         ? ($in{'servers'})
                :                                   ();
        # Nur gültige Unix-Usernamen durchlassen
        @sel = grep { /^\w[\w-]*$/ } @sel;
        $acl{'servers'} = join(' ', @sel);
    }

    save_module_acl(\%acl, $edit_user, $module_name);
    &redirect("../acl/edit_user.cgi?user=" . &urlize($edit_user));
}

# GET: Formular mit aktuellem ACL des Users anzeigen
&header($text{'acl_edit_title'}, '');

my %cur       = get_module_acl($edit_user, $module_name);
my @instances = &list_instances();
my $srv_val   = $cur{'servers'} // '';
my $all_chk   = $srv_val eq '*' ? 1 : 0;
my %srv_on    = map { $_ => 1 } split /\s+/, $srv_val;

print &ui_form_start('acl_edit.cgi', 'post');
print &ui_hidden('user', &html_escape($edit_user));
print &ui_table_start($text{'acl_edit_title'}, undef, 2);

print &ui_table_row($text{'acl_can_create'},
    &ui_checkbox('can_create', '1', '', $cur{'can_create'} ? 1 : 0));

print &ui_table_row($text{'acl_can_scan'},
    &ui_checkbox('can_scan', '1', '', $cur{'can_scan'} ? 1 : 0));

my $srv_html = &ui_checkbox('servers_all', '1', $text{'acl_servers_all'}, $all_chk) . '<br>';
for my $inst (@instances) {
    my $u = $inst->{'user'};
    $srv_html .= &ui_checkbox('servers', $u,
        &html_escape($u) . ' (' . &html_escape($inst->{'game'}) . ')',
        $srv_on{$u} ? 1 : 0) . '<br>';
}

print &ui_table_row($text{'acl_servers'}, $srv_html);
print &ui_table_end();
print &ui_submit($text{'acl_save'});
print &ui_form_end();
&footer('', '');
