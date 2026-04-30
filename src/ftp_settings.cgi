#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/acl.pl';
require './lib/instance.pl';
require './lib/ftp_proftpd.pl';

our (%text, %in);
&ReadParse(\%in);

&can_manage_ftp() or &error($text{'err_acl_admin_only'} || 'Access denied');

my %state = &discover_ftp_state();
# Determine the auth file: prefer value from config, fall back to common default.
# Track whether the path came from config so the UI can indicate this clearly.
my $auth_file_from_config = ($state{'auth_user_file'} // '') ne '';
my $auth_file = $auth_file_from_config
    ? $state{'auth_user_file'}
    : '/etc/proftpd/ftpd.passwd';

if ($ENV{REQUEST_METHOD} eq 'POST') {
    my $action = &sanitize_input($in{'action'} || '');

    if ($action eq 'apply_baseline') {
        my $rc = &apply_secure_ftp_baseline();
        $rc == 0 or &error("Failed applying FTP baseline");
        &redirect('ftp_settings.cgi');
    }
    elsif ($action eq 'create_ftp_user') {
        my $instance_id = &sanitize_input($in{'instance_id'});
        my $ftp_user = &sanitize_input($in{'ftp_user'});
        my $ftp_pass = $in{'ftp_pass'} // '';
        length($ftp_pass) or &error($text{'err_invalid_input'});
        my $inst = &get_instance($instance_id) or &error($text{'err_not_found'});
        my $home = $inst->{'home'};
        my @pw = getpwnam($inst->{'user'});
        my $uid = @pw ? $pw[2] : 33;
        my $gid = @pw ? $pw[3] : 33;

        &ftpasswd_create_user(
            file     => $auth_file,
            name     => $ftp_user,
            password => $ftp_pass,
            uid      => $uid,
            gid      => $gid,
            home     => $home,
            shell    => '/bin/false',
        ) == 0 or &error("Failed creating FTP user");

        &register_instance($instance_id, $inst->{'user'}, $inst->{'script'}, {
            sftp_user => $ftp_user,
        });
        &redirect('ftp_settings.cgi');
    }
    elsif ($action eq 'change_ftp_pass') {
        my $ftp_user = &sanitize_input($in{'ftp_user'});
        my $ftp_pass = $in{'ftp_pass'} // '';
        length($ftp_pass) or &error($text{'err_invalid_input'});
        &ftpasswd_change_password(
            file     => $auth_file,
            name     => $ftp_user,
            password => $ftp_pass,
        ) == 0 or &error("Failed changing FTP password");
        &redirect('ftp_settings.cgi');
    }
    elsif ($action eq 'delete_ftp_user') {
        my $ftp_user = &sanitize_input($in{'ftp_user'});
        &ftpasswd_delete_user(
            file => $auth_file,
            name => $ftp_user,
        ) == 0 or &error("Failed deleting FTP user");
        &redirect('ftp_settings.cgi');
    }
    elsif ($action eq 'assign_ftp_user') {
        my $ftp_user    = &sanitize_input($in{'ftp_user'});
        my $instance_id = &sanitize_input($in{'instance_id'});
        my $inst = &get_instance($instance_id) or &error($text{'err_not_found'});
        &register_instance($instance_id, $inst->{'user'}, $inst->{'script'}, {
            sftp_user => $ftp_user,
        });
        &redirect('ftp_settings.cgi');
    }
}

&header($text{'ftp_title'}, '');

print "<h3>$text{'ftp_audit_title'}</h3>\n";
print "<p><b>" . &html_escape($text{'ftp_main_config'}) . "</b> <code>" .
      &html_escape($state{'main_config'} || $text{'ftp_not_detected'}) . "</code></p>\n";
print "<p><b>" . &html_escape($text{'ftp_loaded_configs'}) . "</b></p>\n";
if (@{$state{'files'} || []}) {
    print "<ul>\n";
    for my $f (@{$state{'files'}}) {
        print "<li><code>" . &html_escape($f) . "</code></li>\n";
    }
    print "</ul>\n";
} else {
    print "<p><i>" . &html_escape($text{'ftp_no_loaded_configs'}) . "</i></p>\n";
}
if (@{$state{'warnings'} || []}) {
    print "<ul>\n";
    for my $w (@{$state{'warnings'}}) {
        print "<li>" . &html_escape($w) . "</li>\n";
    }
    print "</ul>\n";
} else {
    print "<p>&#x2705; " . &html_escape($text{'ftp_audit_ok'}) . "</p>\n";
}

print &ui_form_start('ftp_settings.cgi', 'post');
print &ui_hidden('action', 'apply_baseline');
print &ui_submit($text{'ftp_apply_baseline_btn'});
print &ui_form_end();

print "<h3>$text{'ftp_users_title'}</h3>\n";
if ($auth_file_from_config) {
    print "<p><code>" . &html_escape($auth_file) . "</code></p>\n";
} else {
    print "<p><i>" . &html_escape($text{'ftp_authfile_fallback'}) . "</i> <code>" . &html_escape($auth_file) . "</code></p>\n";
}
my @ftp_users = &parse_ftpd_passwd($auth_file);
unless (&is_admin()) {
    my @visible = &allowed_ftp_users(map { $_->{'name'} } @ftp_users);
    my %vis = map { $_ => 1 } @visible;
    @ftp_users = grep { $vis{$_->{'name'}} } @ftp_users;
}
if (@ftp_users) {
    # Build lookup: ftp_username -> instance_id
    my @all_instances = &list_instances();
    my %ftp_to_inst;
    for my $inst (@all_instances) {
        my $su = $inst->{'sftp_user'} // '';
        $ftp_to_inst{$su} = $inst->{'id'} if $su ne '';
    }
    my @inst_opts = map { [$_->{'id'}, "$_->{'id'} ($_->{'user'})"] } @all_instances;

    my @rows;
    for my $u (@ftp_users) {
        my $assigned_id = $ftp_to_inst{$u->{'name'}};
        my $inst_cell;
        if ($assigned_id) {
            $inst_cell = &html_escape($assigned_id);
        } else {
            $inst_cell = &ui_form_start('ftp_settings.cgi', 'post')
                       . &ui_hidden('action', 'assign_ftp_user')
                       . &ui_hidden('ftp_user', $u->{'name'})
                       . &ui_select('instance_id', '', \@inst_opts)
                       . ' '
                       . &ui_submit($text{'ftp_assign_btn'}, undef, 0, undef, 'btn-default')
                       . &ui_form_end();
        }

        my $del = &ui_form_start('ftp_settings.cgi', 'post')
                . &ui_hidden('action', 'delete_ftp_user')
                . &ui_hidden('ftp_user', $u->{'name'})
                . &ui_submit($text{'ftp_delete_btn'}, undef, 0, undef, 'btn-danger')
                . &ui_form_end();

        my $chpw = &ui_form_start('ftp_settings.cgi', 'post')
                 . &ui_hidden('action', 'change_ftp_pass')
                 . &ui_hidden('ftp_user', $u->{'name'})
                 . &ui_password('ftp_pass', '', 18)
                 . ' '
                 . &ui_submit($text{'ftp_change_pass_btn'}, undef, 0, undef, 'btn-default')
                 . &ui_form_end();

        push @rows, [
            &html_escape($u->{'name'}),
            &html_escape($u->{'home'} // ''),
            $inst_cell,
            $del . $chpw,
        ];
    }
    print &ui_columns_table(
        [$text{'ftp_col_user'}, $text{'ftp_col_home'}, $text{'ftp_col_instance'}, $text{'ftp_col_actions'}],
        100,
        \@rows,
        undef, 1,
    );
} else {
    print "<p><i>" . &html_escape($text{'ftp_no_users'}) . "</i></p>\n";
}

print "<h3>$text{'ftp_instance_user_title'}</h3>\n";
my @instances = &list_instances();
my @inst_opts = map { [$_->{'id'}, "$_->{'id'} ($_->{'user'})"] } @instances;
print &ui_form_start('ftp_settings.cgi', 'post');
print &ui_hidden('action', 'create_ftp_user');
print &ui_table_start('', undef, 2);
print &ui_table_row($text{'ftp_instance'}, &ui_select('instance_id', '', \@inst_opts));
print &ui_table_row($text{'ftp_user'}, &ui_textbox('ftp_user', '', 24));
print &ui_table_row($text{'ftp_pass'}, &ui_password('ftp_pass', '', 24));
print &ui_table_end();
print &ui_submit($text{'ftp_create_btn'});
print &ui_form_end();

&footer('index.cgi', $text{'index_title'});
