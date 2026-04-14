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

# --- POST handler ---
if ($ENV{REQUEST_METHOD} eq 'POST') {
    my $action = &sanitize_input($in{'action'} || 'assign');

    if ($action eq 'assign') {
        my $instance_id = &sanitize_input($in{'instance_id'});
        my $webmin_user = &sanitize_input($in{'webmin_user'});

        $instance_id or &error($text{'err_invalid_input'});
        $webmin_user or &error($text{'err_invalid_input'});

        &get_instance($instance_id) or &error($text{'err_not_found'});
        my %valid = map { $_ => 1 } &list_webmin_users();
        $valid{$webmin_user} or &error($text{'err_invalid_input'});

        &grant_server_access($webmin_user, $instance_id);
        &redirect('scan.cgi');
    }

    if ($action eq 'register') {
        my $reg_user   = &sanitize_input($in{'reg_user'});
        my $reg_script = $in{'reg_script'} // '';
        $reg_script =~ s|[^a-zA-Z0-9_./()\-]||g;
        my $reg_wbuser = $in{'reg_webmin_user'} // '';
        $reg_wbuser = &sanitize_input($reg_wbuser) if $reg_wbuser ne '';
        my $reg_sftp_user = $in{'reg_sftp_user'} // '';
        $reg_sftp_user =~ s/[^a-zA-Z0-9_\-]//g;

        $reg_user   or &error($text{'err_invalid_input'});
        $reg_script or &error($text{'err_invalid_input'});

        getpwnam($reg_user) or &error($text{'err_not_found'});
        -f $reg_script      or &error($text{'err_script_not_found'});
        getpwnam($reg_sftp_user) or &error($text{'err_not_found'}) if $reg_sftp_user;

        my $script_id = (split('/', $reg_script))[-1];
        &register_instance($script_id, $reg_user, $reg_script, {
            source    => 'manual',
            sftp_user => $reg_sftp_user,
        });
        &grant_server_access($reg_wbuser, $script_id) if $reg_wbuser;
        &redirect('scan.cgi');
    }

    if ($action eq 'untrack_manual') {
        my $instance_id = &sanitize_input($in{'instance_id'});
        my $meta = &get_registered_instance($instance_id);
        $meta or &error($text{'err_not_found'});
        ($meta->{'source'} // '') eq 'manual' or &error($text{'err_invalid_action'});
        &unregister_instance($instance_id);
        &redirect('scan.cgi');
    }
}

# --- GET: show all instances + registration form ---
&header($text{'scan_title'}, '');

my @instances    = &list_instances();
my @webmin_users = &list_webmin_users();
my @wbm_opts     = map { [$_, $_] } @webmin_users;
my @sftp_users = _list_sftp_users();
my @sftp_opts = map { [$_, $_] } @sftp_users;

print &ui_columns_header([
    $text{'index_col_user'},
    $text{'scan_col_script'},
    $text{'scan_col_ftp'},
    $text{'index_col_game'},
    $text{'index_col_port'},
    $text{'scan_col_owner'},
    $text{'scan_assign'},
]);

foreach my $inst (@instances) {
    my $id   = $inst->{'id'};
    my $user = $inst->{'user'};

    my $script_cell = &html_escape($inst->{'script'});

    my $sftp      = &resolve_instance_sftp_user($id, $user);
    my $sftp_cell = $sftp ? &html_escape($sftp) : "<i>$text{'scan_no_ftp'}</i>";

    my @owners = &get_server_owners($id);
    my $owner_cell = @owners
        ? '<ul style="margin:0;padding-left:1.2em">' .
          join('', map { '<li>' . &html_escape($_) . '</li>' } @owners) .
          '</ul>'
        : "<i>$text{'scan_unowned'}</i>";

    my $assign_cell = &ui_form_start('scan.cgi', 'post');
    $assign_cell .= &ui_hidden('action',      'assign');
    $assign_cell .= &ui_hidden('instance_id', &html_escape($id));
    $assign_cell .= &ui_select('webmin_user', '', \@wbm_opts);
    $assign_cell .= ' ';
    $assign_cell .= &ui_submit($text{'scan_assign'});
    $assign_cell .= &ui_form_end();
    if (($inst->{'registration_source'} // '') eq 'manual') {
        $assign_cell .= &ui_form_start('scan.cgi', 'post');
        $assign_cell .= &ui_hidden('action', 'untrack_manual');
        $assign_cell .= &ui_hidden('instance_id', &html_escape($id));
        $assign_cell .= &ui_submit($text{'scan_remove_panel_btn'});
        $assign_cell .= &ui_form_end();
    }

    print &ui_columns_row([
        &html_escape($user),
        $script_cell,
        $sftp_cell,
        &html_escape($inst->{'game'}),
        int($inst->{'port'}),
        $owner_cell,
        $assign_cell,
    ]);
}

print &ui_columns_end();

# --- Manual registration form ---
print "<h3>$text{'scan_register_title'}</h3>\n";

my @sys_users = &list_system_users();
my @sys_opts  = map { [$_, $_] } @sys_users;

print &ui_form_start('scan.cgi', 'post');
print &ui_hidden('action', 'register');
print &ui_table_start('', undef, 2);
print &ui_table_row($text{'scan_reg_user'},
    &ui_select('reg_user', '', \@sys_opts));
print &ui_table_row($text{'scan_reg_script'},
    &ui_textbox('reg_script', '', 50));
print &ui_table_row($text{'scan_reg_owner'},
    &ui_select('reg_webmin_user', '', [['', '---'], @wbm_opts]));
print &ui_table_row($text{'scan_reg_sftp_user'},
    &ui_select('reg_sftp_user', '', [['', '---'], @sftp_opts]));
print &ui_table_end();
print &ui_submit($text{'scan_reg_submit'});
print &ui_form_end();

&footer('', '');

sub _list_sftp_users {
    my @out;
    open(my $fh, '<', '/etc/passwd') or return ();
    while (<$fh>) {
        chomp;
        my ($user) = split(':', $_);
        push @out, $user if $user =~ /^ftp[_-]/;
    }
    close($fh);
    return sort @out;
}
