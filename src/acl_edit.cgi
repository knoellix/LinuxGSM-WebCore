#!/usr/bin/perl
# -------------------------------------------------------------------------
# LinuxGSM Webcore - Webmin Module
# Copyright (C) 2026 Christian Möllmann knoellix 128321164+knoellix@users.noreply.github.com
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License.
# -------------------------------------------------------------------------

# acl_edit.cgi — Webmin module ACL editor
#
# Webmin `do`'t diese Datei direkt aus seinem ACL-Editor heraus.
# Kein package, kein strict — %in, %text, $module_name etc. sind
# bereits im aktuellen Package-Namespace vorhanden.
# Nur Felder ausgeben; Webmin stellt Form, Speichern-Button und Rahmen bereit.

my $edit_user = $in{'user'} // $in{'group'} // '';
my $mod       = $module_name || 'linuxgsm-webcore';

my %cur = get_module_acl($edit_user, $mod);

print ui_table_start($text{'acl_edit_title'} || 'Permissions', undef, 2);

print ui_table_row(
    $text{'acl_can_create'} || 'May create servers',
    ui_checkbox('can_create', '1', '', $cur{'can_create'} ? 1 : 0));

print ui_table_row(
    $text{'acl_can_scan'} || 'May scan servers',
    ui_checkbox('can_scan', '1', '', $cur{'can_scan'} ? 1 : 0));

print ui_table_row(
    $text{'acl_servers'} || 'Servers',
    ui_textbox('servers', $cur{'servers'} // '', 40) .
    " <small>(" . ($text{'acl_servers_all'} || '* = all') . ")</small>");

print ui_table_end();

1;
