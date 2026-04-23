#!/usr/bin/perl
# -------------------------------------------------------------------------
# LinuxGSM Webcore - Webmin Module
# Copyright (C) 2026 Christian Möllmann knoellix 128321164+knoellix@users.noreply.github.com
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License.
# -------------------------------------------------------------------------
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/instance.pl';
require './lib/acl.pl';

our (%text, %config, %in, %gconfig, $module_name);
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

&is_admin() or &error($text{'err_acl_admin_only'} || 'Access denied — administrators only');

my $action = &sanitize_input($in{'action'} // '');

# --- Save action ---
if ($action eq 'save_acl') {
    my $target_user = &sanitize_input($in{'target_user'} // '');
    $target_user =~ /^[a-zA-Z0-9_.\@\-]+$/ or &error($text{'err_invalid_input'});

    my %acl = &get_module_acl($target_user, $module_name);

    my $role = $in{'role'} // 'operator';
    $role = 'operator' unless $role =~ /^(admin|operator|viewer)$/;
    $acl{'role'} = $role;

    my $servers = $in{'servers'} // '';
    $servers =~ s/[^a-z0-9A-Z_\- ]//g;
    $servers =~ s/\s+/ /g;
    $servers =~ s/^\s+|\s+$//g;
    $acl{'servers'} = $role eq 'admin' ? '' : $servers;
    $acl{'can_manage_ftp'} = ($role eq 'admin') ? 1
        : ($in{'can_manage_ftp'} ? 1 : 0);

    &save_module_acl(\%acl, $target_user, $module_name);
    &redirect("acl_manage.cgi");
}

# --- Edit form ---
if ($action eq 'edit') {
    my $target_user = &sanitize_input($in{'target_user'} // '');
    $target_user =~ /^[a-zA-Z0-9_.\@\-]+$/ or &error($text{'err_invalid_input'});

    my %acl = &get_module_acl($target_user, $module_name);
    my $role = $acl{'role'} // 'operator';

    my @all_instances = &list_instances();
    my @inst_ids = map { $_->{'id'} // $_->{'user'} // '' } @all_instances;
    my @inst_opts = map { [$_, $_] } @inst_ids;

    my @assigned = grep { /\S/ } split /\s+/, ($acl{'servers'} // '');

    &header($text{'acl_manage_title'}, '');

    print &ui_form_start("acl_manage.cgi", "post");
    print &ui_hidden("action", "save_acl");
    print &ui_hidden("target_user", &html_escape($target_user));

    print &ui_table_start($text{'acl_manage_title'} . ": " . &html_escape($target_user), "width=100%", 2);

    my $yes = $text{'yes'} || 'Yes';
    my $no  = $text{'no'}  || 'No';

    print &ui_table_row(
        $text{'acl_role'} || 'Role',
        &ui_select('role', $role, [
            [ 'admin',    $text{'acl_role_admin'}    || 'Administrator' ],
            [ 'operator', $text{'acl_role_operator'} || 'Operator'      ],
            [ 'viewer',   $text{'acl_role_viewer'}   || 'Viewer'        ],
        ]));

    print &ui_table_row(
        $text{'acl_servers'} || 'Servers',
        &ui_select('servers', \@assigned, \@inst_opts, scalar(@inst_ids), 1));

    print &ui_table_row(
        $text{'acl_can_manage_ftp'} || 'May manage FTP users',
        &ui_radio('can_manage_ftp', $acl{'can_manage_ftp'} ? 1 : 0,
            [ [1, $yes], [0, $no] ]));

    print &ui_table_end();
    print &ui_submit($text{'acl_manage_save'} || 'Save');
    print &ui_form_end();

    &footer("acl_manage.cgi", $text{'acl_manage_title'});
    exit;
}

# --- Overview ---
&header($text{'acl_manage_title'} || 'Manage server assignments', '');

my @wbm_users = &list_webmin_users();

sub _is_wbm_native_admin {
    my ($uname) = @_;
    my $result = 0;
    eval {
        foreign_require('acl', 'acl-lib.pl');
        $result = acl::master_admin($uname) ? 1 : 0;
    };
    return $result;
}

my @rows;
for my $uname (@wbm_users) {
    my %acl     = &get_module_acl($uname, $module_name);
    my $is_native_admin = _is_wbm_native_admin($uname);

    my $role = $is_native_admin ? 'admin'
        : ($acl{'role'} // (
            (defined $acl{'servers'} && $acl{'servers'} =~ /^\s*\*\s*$/) ? 'admin' : 'operator'
        ));

    my $role_label = {
        admin    => $text{'acl_role_admin'}    || 'Administrator',
        operator => $text{'acl_role_operator'} || 'Operator',
        viewer   => $text{'acl_role_viewer'}   || 'Viewer',
    }->{$role} // $role;

    $role_label .= " " . ($text{'acl_manage_webmin_admin'} || '(Webmin admin)')
        if $is_native_admin;

    my $servers_str = ($role eq 'admin') ? '&#x2014;'
        : &html_escape($acl{'servers'} // '');

    my $ftp_str = ($role eq 'admin' || $acl{'can_manage_ftp'}) ? '&#x2705;' : '&#x274C;';

    my $actions = $is_native_admin ? '&#x2014;'
        : "<a href='acl_manage.cgi?action=edit&amp;target_user="
          . &html_escape($uname) . "'>"
          . ($text{'acl_manage_edit'} || 'Edit') . "</a>";

    push @rows, [
        &html_escape($uname),
        $role_label,
        $servers_str,
        $ftp_str,
        $actions,
    ];
}

if (@rows) {
    print &ui_columns_table(
        [
            $text{'acl_manage_col_user'}    || 'Webmin user',
            $text{'acl_manage_col_role'}    || 'Role',
            $text{'acl_manage_col_servers'} || 'Assigned servers',
            $text{'acl_manage_col_ftp'}     || 'FTP',
            $text{'acl_manage_col_actions'} || 'Actions',
        ],
        "100%",
        \@rows,
    );
} else {
    print "<p>" . ($text{'index_no_instances'} || 'No users found.') . "</p>\n";
}

&footer('', '');
