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

&can_scan() or &error($text{'err_access_denied'});

my %state = &discover_ftp_state();
my $auth_file = $state{'auth_user_file'} || '/etc/proftpd/ftpd.passwd';

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
        my $uid = int($in{'ftp_uid'} || 33);
        my $gid = int($in{'ftp_gid'} || 33);

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
my @ftp_users = &parse_ftpd_passwd($auth_file);
if (@ftp_users) {
    print &ui_columns_header([
        $text{'ftp_col_user'},
        $text{'ftp_col_home'},
        $text{'ftp_col_actions'},
    ]);
    for my $u (@ftp_users) {
        my $actions = &ui_form_start('ftp_settings.cgi', 'post');
        $actions .= &ui_hidden('action', 'delete_ftp_user');
        $actions .= &ui_hidden('ftp_user', $u->{'name'});
        $actions .= &ui_submit($text{'ftp_delete_btn'});
        $actions .= &ui_form_end();

        $actions .= &ui_form_start('ftp_settings.cgi', 'post');
        $actions .= &ui_hidden('action', 'change_ftp_pass');
        $actions .= &ui_hidden('ftp_user', $u->{'name'});
        $actions .= &ui_password('ftp_pass', '', 18);
        $actions .= &ui_submit($text{'ftp_change_pass_btn'});
        $actions .= &ui_form_end();

        print &ui_columns_row([
            &html_escape($u->{'name'}),
            &html_escape($u->{'home'} // ''),
            $actions,
        ]);
    }
    print &ui_columns_end();
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
print &ui_table_row($text{'ftp_uid'}, &ui_textbox('ftp_uid', '33', 8));
print &ui_table_row($text{'ftp_gid'}, &ui_textbox('ftp_gid', '33', 8));
print &ui_table_end();
print &ui_submit($text{'ftp_create_btn'});
print &ui_form_end();

&footer('index.cgi', $text{'index_title'});
