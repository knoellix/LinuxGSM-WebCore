#!/usr/bin/perl
# acl_edit.cgi — Webmin module ACL editor
#
# Webmin bettet die Ausgabe dieser Datei in seine eigene Form ein.
# KEIN header()/footer(), KEIN ui_form_start/end, KEIN ui_submit.
# KEIN Permission-Check — Webmin's eigenes ACL-System schützt diesen Aufruf.
# Webmin speichert die Formularwerte automatisch via save_module_acl().
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/instance.pl';

our (%text, %in, $module_name);
&ReadParse(\%in);

my $edit_user = $in{'user'} // $in{'group'} // '';

# Aktuelles ACL des zu bearbeitenden Users lesen
my %cur = &get_module_acl($edit_user, $module_name);

# Nur Felder ausgeben — Webmin stellt Form, Speichern-Button und Rahmen bereit
print &ui_table_start($text{'acl_edit_title'}, undef, 2);

print &ui_table_row($text{'acl_can_create'},
    &ui_checkbox('can_create', '1', '', $cur{'can_create'} ? 1 : 0));

print &ui_table_row($text{'acl_can_scan'},
    &ui_checkbox('can_scan', '1', '', $cur{'can_scan'} ? 1 : 0));

# Server-Zugriff als Textfeld: '*' für alle, oder Leerzeichen-getrennte Unix-User
print &ui_table_row($text{'acl_servers'},
    &ui_textbox('servers', $cur{'servers'} // '', 40) .
    "&nbsp;<small>(" . $text{'acl_servers_all'} . " = *)</small>");

print &ui_table_end();
