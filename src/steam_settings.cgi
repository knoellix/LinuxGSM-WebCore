#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/acl.pl';
require './lib/steam.pl';
require './lib/instance.pl';
require './lib/logging.pl';

our (%text, %config, %in, %gconfig);
our ($module_root, $module_root_directory, $config_directory, $module_name);
our $current_lang;
$module_root ||= $module_root_directory;
$module_root ||= do { (my $d = __FILE__) =~ s{/[^/]+$}{}; $d };
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

&can_scan() or &error($text{'err_access_denied'});

if ($ENV{REQUEST_METHOD} eq 'POST') {
    my $action = $in{'action'} // '';
    $action =~ s/[^a-z_]//g;

    if ($action eq 'patch_repos') {
        &patch_apt_sources('/etc/apt/sources.list');
        &redirect('steam_settings.cgi');
        exit;

    } elsif ($action eq 'install_steamcmd') {
        &install_steamcmd();
        &redirect('steam_settings.cgi');
        exit;

    } elsif ($action eq 'add_account') {
        my $username     = $in{'steam_username'}     // '';
        my $display_name = $in{'steam_display_name'} // '';
        my $password     = $in{'steam_password'}     // '';
        $username =~ s/[^a-zA-Z0-9_\-]//g;
        $username = substr($username, 0, 64);
        $display_name =~ s/[\t\n\r]//g;
        $display_name = substr($display_name, 0, 80);
        $username or &error($text{'err_invalid_input'});
        $password or &error($text{'err_invalid_input'});
        &add_steam_account($username, $display_name);
        my $token = &start_login_session($username, $password);
        &redirect("steam_settings.cgi?action=poll&session=" . &html_escape($token) . "&username=" . &html_escape($username));
        exit;

    } elsif ($action eq 'remove_account') {
        my $username = $in{'steam_username'} // '';
        $username =~ s/[^a-zA-Z0-9_\-]//g;
        $username or &error($text{'err_invalid_input'});
        &remove_steam_account($username);
        &redirect('steam_settings.cgi');
        exit;

    } elsif ($action eq 'submit_guard') {
        my $token    = $in{'session'}    // '';
        my $username = $in{'username'}   // '';
        my $code     = $in{'guard_code'} // '';
        $token    =~ s/[^a-f0-9]//g;
        $username =~ s/[^a-zA-Z0-9_\-]//g;
        (my $clean_code = uc($code)) =~ s/[^A-Z0-9]//g;
        $code = substr($clean_code, 0, 5);
        $token or &error($text{'err_invalid_input'});
        $code  or &error($text{'err_invalid_input'});
        &submit_guard_code($token, $code);
        &redirect("steam_settings.cgi?action=poll&session=" . &html_escape($token) . "&username=" . &html_escape($username));
        exit;

    } elsif ($action eq 'save_settings') {
        &is_admin() or &error($text{'err_acl_admin_only'} || 'Access denied');
        $config{debug_logging} = $in{'debug_logging'} ? 1 : 0;
        &save_module_config(\%config);
        &redirect('steam_settings.cgi?xnavigation=1');
        exit;

    } elsif ($action eq 'relogin') {
        my $username = $in{'steam_username'} // '';
        my $password = $in{'steam_password'} // '';
        $username =~ s/[^a-zA-Z0-9_\-]//g;
        $username or &error($text{'err_invalid_input'});
        $password or &error($text{'err_invalid_input'});
        &update_steam_account_status($username, 'guard_pending');
        my $token = &start_login_session($username, $password);
        &redirect("steam_settings.cgi?action=poll&session=" . &html_escape($token) . "&username=" . &html_escape($username));
        exit;
    }
}

my $get_action = $in{'action'} // '';
$get_action =~ s/[^a-z_]//g;

if ($get_action eq 'relogin_form') {
    my $username = $in{'instance'} // '';
    $username =~ s/[^a-zA-Z0-9_\-]//g;
    &header($text{'steam_title'}, '');
    print "<h3>" . &html_escape($text{'steam_relogin_btn'}) . ": " . &html_escape($username) . "</h3>\n";
    print &ui_form_start('steam_settings.cgi', 'post');
    print &ui_hidden('action', 'relogin');
    print &ui_hidden('steam_username', &html_escape($username));
    print &ui_table_start('', undef, 2);
    print &ui_table_row(&html_escape($text{'steam_password_hint'}),
        "<input type='password' name='steam_password' size='30' autocomplete='new-password'>");
    print &ui_table_end();
    print &ui_submit($text{'steam_login_start_btn'}, undef, undef, undef, 'btn-primary');
    print &ui_form_end();
    &footer('steam_settings.cgi', $text{'steam_title'});
    exit;
}

if ($get_action eq 'poll') {
    my $token    = $in{'session'}  // '';
    my $username = $in{'username'} // '';
    $token    =~ s/[^a-f0-9]//g;
    $username =~ s/[^a-zA-Z0-9_\-]//g;

    &header($text{'steam_login_title'}, '');
    my $status = &read_session_status($token) // 'connecting';
    my $out    = &read_session_output($token);
    my $mobile_confirm_hint = ($out =~ /please confirm the login in the steam mobile app|waiting for confirmation/i) ? 1 : 0;
    my $guard_code_hint = ($out =~ /enter\W*(?:the\s+)?(?:current\s+)?code|steam\W*guard\W*code|email\W*code|invalid\W*(?:steam\W*guard\W*)?code|two-factor\W*code/i) ? 1 : 0;
    my @out_lines = split(/\n/, $out // '');
    @out_lines = @out_lines > 20 ? @out_lines[-20 .. -1] : @out_lines;
    my $out_tail = join("\n", @out_lines);

    if ($status eq 'ok') {
        &update_steam_account_status($username, 'ok');
        &cleanup_session($token);
        print "<div class='alert alert-success'>" . &html_escape($text{'steam_login_ok'}) . "</div>\n";
        print "<p><a href='steam_settings.cgi'>" . &html_escape($text{'steam_title'}) . "</a></p>\n";
    } elsif ($status eq 'failed') {
        &update_steam_account_status($username, 'token_expired');
        &cleanup_session($token);
        print "<div class='alert alert-danger'>" . &html_escape($text{'steam_login_failed'}) . "</div>\n";
        print "<p><a href='steam_settings.cgi'>" . &html_escape($text{'steam_title'}) . "</a></p>\n";
    } elsif ($status eq 'timeout') {
        &update_steam_account_status($username, 'token_expired');
        &cleanup_session($token);
        print "<div class='alert alert-warning'>" . &html_escape($text{'steam_login_timeout'}) . "</div>\n";
        print "<p><a href='steam_settings.cgi'>" . &html_escape($text{'steam_title'}) . "</a></p>\n";
    } elsif ($status eq 'guard_required' || ($status eq 'connecting' && $guard_code_hint && !$mobile_confirm_hint)) {
        print "<p>" . &html_escape($text{'steam_guard_prompt'}) . "</p>\n";
        print &ui_form_start('steam_settings.cgi', 'post');
        print &ui_hidden('action',   'submit_guard');
        print &ui_hidden('session',  &html_escape($token));
        print &ui_hidden('username', &html_escape($username));
        print &ui_table_start('', undef, 2);
        print &ui_table_row(&html_escape($text{'steam_guard_prompt'}),
            &ui_textbox('guard_code', '', 8));
        print &ui_table_end();
        print &ui_submit($text{'steam_guard_submit'}, undef, undef, undef, 'btn-primary');
        print &ui_form_end();
    } else {
        print "<meta http-equiv='refresh' content='3'>\n";
        print "<p>" . &html_escape($text{'steam_login_connecting'}) . "</p>\n";
        if ($mobile_confirm_hint) {
            print "<div class='alert alert-info'>Bestätige den Login in der Steam-App. Kein 5-stelliger Code erforderlich.</div>\n";
        } elsif ($guard_code_hint) {
            print "<div class='alert alert-warning'>Steam erwartet einen 5-stelligen Guard-Code. Das Eingabefeld erscheint automatisch.</div>\n";
        }
    }

    if (length $out_tail) {
        print "<h4>" . &html_escape($text{'jobs_output_title'} || 'Ausgabe') . "</h4>\n";
        print "<pre>" . &html_escape($out_tail) . "</pre>\n";
    }

    &footer('', '');
    exit;
}

# Main page
&header($text{'steam_title'}, '');

print "<h3>" . &html_escape($text{'steam_system_title'}) . "</h3>\n";
my $steamcmd_path = &detect_steamcmd();
my $repos         = &check_apt_repos('/etc/apt/sources.list');

print &ui_table_start('', undef, 2);
if ($steamcmd_path) {
    print &ui_table_row(&html_escape($text{'steam_cmd_ok'}), &html_escape($steamcmd_path));
} else {
    my $f = &ui_form_start('steam_settings.cgi', 'post');
    $f .= &ui_hidden('action', 'install_steamcmd');
    $f .= &ui_submit($text{'steam_install_btn'}, undef, undef, undef, 'btn-primary');
    $f .= &ui_form_end();
    print &ui_table_row(&html_escape($text{'steam_cmd_missing'}), $f);
}

if ($repos->{'non_free'} && $repos->{'contrib'}) {
    print &ui_table_row(&html_escape($text{'steam_repos_ok'}), '&#x2705;');
} else {
    my $f = &ui_form_start('steam_settings.cgi', 'post');
    $f .= &ui_hidden('action', 'patch_repos');
    $f .= &ui_submit($text{'steam_repos_fix_btn'}, undef, undef, undef, 'btn-default');
    $f .= &ui_form_end();
    print &ui_table_row(&html_escape($text{'steam_repos_missing'}), $f);
}

if (!$repos->{'cdrom_active'}) {
    print &ui_table_row(&html_escape($text{'steam_cdrom_ok'}), '&#x2705;');
} else {
    my $f = &ui_form_start('steam_settings.cgi', 'post');
    $f .= &ui_hidden('action', 'patch_repos');
    $f .= &ui_submit($text{'steam_repos_fix_btn'}, undef, undef, undef, 'btn-default');
    $f .= &ui_form_end();
    print &ui_table_row(&html_escape($text{'steam_cdrom_warn'}), $f);
}
print &ui_table_end();

print "<h3>" . &html_escape($text{'steam_accounts_title'}) . "</h3>\n";
my $accounts = &load_steam_accounts();
if (@$accounts) {
    my @rows;
    for my $acc (@$accounts) {
        my $uname        = &html_escape($acc->{'username'});
        my $dname        = &html_escape($acc->{'display_name'});
        my $status       = $acc->{'status'} // 'guard_pending';
        my $status_label = &html_escape($text{"steam_status_$status"} // $status);
        my $actions = '';
        if ($status eq 'token_expired') {
            $actions .= "<a href=\"steam_settings.cgi?action=relogin_form&instance=" . &html_escape($uname) . "\" class=\"btn btn-xs btn-warning\">" . &html_escape($text{'steam_relogin_btn'}) . "</a>";
        }
        $actions .= &ui_form_start('steam_settings.cgi', 'post');
        $actions .= &ui_hidden('action',         'remove_account');
        $actions .= &ui_hidden('steam_username', $uname);
        $actions .= &ui_submit($text{'steam_remove_btn'}, undef, undef, undef, 'btn-danger');
        $actions .= &ui_form_end();
        push @rows, [$uname, $dname, $status_label, $actions];
    }
    print &ui_columns_table(
        [$text{'steam_col_username'}, $text{'steam_col_display'}, $text{'steam_col_status'}, $text{'steam_col_actions'}],
        '100%',
        \@rows,
    );
} else {
    print "<p><i>" . &html_escape($text{'steam_no_accounts'}) . "</i></p>\n";
}

# Show which servers use each account
{
    my @instances = &list_instances();
    my %by_account;
    for my $inst (@instances) {
        my $sa = $inst->{'steam_account'} // '';
        next unless $sa;
        push @{ $by_account{$sa} }, $inst->{'id'};
    }
    if (%by_account) {
        print "<h4>" . &html_escape($text{'steam_linked_servers'} || 'Zugewiesene Server') . "</h4>\n";
        my @rows;
        for my $acc (sort keys %by_account) {
            push @rows, [&html_escape($acc), &html_escape(join(', ', @{ $by_account{$acc} }))];
        }
        print &ui_columns_table(
            [&html_escape($text{'steam_col_username'}), &html_escape($text{'steam_col_servers'} || 'Server')],
            '100%',
            \@rows,
        );
    }
}

print "<h4>" . &html_escape($text{'steam_add_account'}) . "</h4>\n";
print &ui_form_start('steam_settings.cgi', 'post');
print &ui_hidden('action', 'add_account');
print "<input type='text' name='_dummy_user' style='display:none' autocomplete='username'>\n";
print "<input type='password' name='_dummy_pass' style='display:none' autocomplete='current-password'>\n";
print &ui_table_start('', undef, 2);
print &ui_table_row(&html_escape($text{'steam_display_name'}),
    &ui_textbox('steam_display_name', '', 30));
print &ui_table_row(&html_escape($text{'steam_username'}),
    "<input type='text' name='steam_username' size='30' autocomplete='off'>");
print &ui_table_row(&html_escape($text{'steam_password_hint'}),
    "<input type='password' name='steam_password' size='30' autocomplete='new-password'>");
print &ui_table_end();
print &ui_submit($text{'steam_login_start_btn'}, undef, undef, undef, 'btn-primary');
print &ui_form_end();

if (&is_admin()) {
    print "<h3>" . &html_escape($text{'config_title'} || 'Einstellungen') . "</h3>\n";
    print &ui_form_start('steam_settings.cgi', 'post');
    print &ui_hidden('action', 'save_settings');
    print &ui_table_start('', undef, 2);
    print &ui_table_row(
        &html_escape($text{'config_debug_logging'} || 'Debug-Logging'),
        &ui_radio('debug_logging', $config{debug_logging} ? 1 : 0,
            [[1, ($text{'yes'} || 'Ja')], [0, ($text{'no'} || 'Nein')]]));
    print &ui_table_end();
    print &ui_submit($text{'acl_manage_save'} || 'Speichern', undef, undef, undef, 'btn-default');
    print &ui_form_end();
}

&footer('index.cgi', $text{'index_title'});
