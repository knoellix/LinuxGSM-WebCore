#!/usr/bin/perl
# -------------------------------------------------------------------------
# LinuxGSM Webcore - Webmin Module
# Copyright (C) 2026 Christian Möllmann knoellix 128321164+knoellix@users.noreply.github.com
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License.
# -------------------------------------------------------------------------

# acl_security.pl — Module ACL form and save for linuxgsm-webcore
#
# Called by Webmin's acl/edit_acl.cgi via foreign_require/foreign_call.
# Imports all Webmin functions into this package via WebminCore.
# acl_security_form: called inside an already-open ui_table_start.
# acl_security_save: called by save_acl.cgi before save_module_acl.

BEGIN { push(@INC, ".."); }
use WebminCore;

# load_theme_library()
# Called by Webmin's edit_acl.cgi before acl_security_form. No-op.
sub load_theme_library { }

# acl_security_form(\%maccess)
# Output table rows for editing this module's per-user/group permissions.
sub acl_security_form {
    my ($maccess) = @_;

    my $yes = $text{'yes'} || 'Yes';
    my $no  = $text{'no'}  || 'No';

    my $role = $maccess->{'role'} // 'operator';

    # Role dropdown
    print &ui_table_row(
        $text{'acl_role'} || 'Role',
        &ui_select('role', $role, [
            [ 'admin',    $text{'acl_role_admin'}    || 'Administrator' ],
            [ 'operator', $text{'acl_role_operator'} || 'Operator'      ],
            [ 'viewer',   $text{'acl_role_viewer'}   || 'Viewer'        ],
        ]));

    # Servers field (always shown; ignored at save time when role=admin)
    print &ui_table_row(
        $text{'acl_servers'} || 'Servers',
        &ui_textbox('servers', $maccess->{'servers'} // '', 40) .
        " <small>(" . ($text{'acl_manage_servers_hint'} || 'Instance IDs, space-separated') . ")</small>");

    # FTP management toggle
    print &ui_table_row(
        $text{'acl_can_manage_ftp'} || 'May manage FTP users',
        &ui_radio('can_manage_ftp', $maccess->{'can_manage_ftp'} ? 1 : 0,
            [ [ 1, $yes ], [ 0, $no ] ]));
}

# acl_security_save(\%maccess, \%in)
# Read submitted POST values and populate the ACL hash for saving.
sub acl_security_save {
    my ($maccess, $in) = @_;

    my $role = $in->{'role'} // 'operator';
    $role = 'operator' unless $role =~ /^(admin|operator|viewer)$/;
    $maccess->{'role'} = $role;

    # Sanitize servers field: allow alphanumeric, underscore, hyphen, space
    my $servers = $in->{'servers'} // '';
    $servers =~ s/[^a-z0-9A-Z_\- ]//g;
    $servers =~ s/\s+/ /g;
    $servers =~ s/^\s+|\s+$//g;
    $maccess->{'servers'} = $role eq 'admin' ? '' : $servers;

    $maccess->{'can_manage_ftp'} = ($role eq 'admin') ? 1
        : ($in->{'can_manage_ftp'} ? 1 : 0);
}

1;
