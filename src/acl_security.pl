#!/usr/bin/perl
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

    print &ui_table_row(
        $text{'acl_can_create'} || 'May create servers',
        &ui_radio('can_create', $maccess->{'can_create'} ? 1 : 0,
            [ [ 1, $yes ], [ 0, $no ] ]));

    print &ui_table_row(
        $text{'acl_can_scan'} || 'May scan servers',
        &ui_radio('can_scan', $maccess->{'can_scan'} ? 1 : 0,
            [ [ 1, $yes ], [ 0, $no ] ]));

    print &ui_table_row(
        $text{'acl_servers'} || 'Servers',
        &ui_textbox('servers', $maccess->{'servers'} // '*', 40) .
        " <small>(" . ($text{'acl_servers_all'} || '* = all') . ")</small>");
}

# acl_security_save(\%maccess, \%in)
# Read submitted POST values and populate the ACL hash for saving.
sub acl_security_save {
    my ($maccess, $in) = @_;

    $maccess->{'can_create'} = $in->{'can_create'} ? 1 : 0;
    $maccess->{'can_scan'}   = $in->{'can_scan'}   ? 1 : 0;

    # Sanitize servers field: allow alphanumeric, underscore, hyphen, space, *
    my $servers = $in->{'servers'} // '';
    $servers =~ s/[^a-z0-9_\- \*]//g;
    $servers =~ s/\s+/ /g;
    $servers = '*' if $servers eq '';
    $maccess->{'servers'} = $servers;
}

1;
