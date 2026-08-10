#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/module_config.pl';
require './lib/acl.pl';
require './lib/steam.pl';
require './lib/live_log.pl';
require './lib/instance.pl';
require './lib/logging.pl';

our (%text, %config, %in, %gconfig, $root_directory);
our ($module_root, $module_root_directory, $config_directory, $module_name);
our ($module_config_directory, $module_config_file);
our $current_lang;
$module_root ||= $module_root_directory;
$module_root ||= do { (my $d = __FILE__) =~ s{/[^/]+$}{}; $d };
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

&module_config_sync_in();

# Full integrations page is admin-only; operators may use Steam relogin/poll
# flows linked from manage.cgi for servers they manage.
sub _integrations_allow_request {
    my ($action) = @_;
    return 1 if &can_scan();
    return 0 unless &effective_role() eq 'operator';
    $action //= '';
    $action =~ s/[^a-z_]//g;
    return $action =~ /^(?:relogin_form|relogin|poll|submit_guard)$/ ? 1 : 0;
}

my $_req_action = $in{'action'} // '';
$_req_action =~ s/[^a-z_]//g;
&_integrations_allow_request($_req_action)
    or &error($text{'err_access_denied'});

sub _integrations_secret_placeholder {
    my ($val) = @_;
    return ($val // '') ne '' ? ($text{'integrations_secret_replace_hint'} // 'Neuen Key eingeben zum Ersetzen') : '';
}

# Visible indicator that a secret is stored (placeholder alone is easy to miss).
sub _integrations_secret_status {
    my ($val) = @_;
    return '' unless defined $val && $val ne '';
    my $label = $text{'integrations_secret_stored'} // 'Key hinterlegt';
    return '<br><span class="text-success">&#x2705; '
        . &html_escape($label) . ': <code>********</code></span>';
}

# External doc link under API fields (https only).
sub _integrations_help_link {
    my ($url, $label) = @_;
    return '' unless defined $url && $url =~ m{\Ahttps://[a-zA-Z0-9][-a-zA-Z0-9._]*(?:/[^\s"<>]*)?\z};
    $label //= $url;
    return '<br><small><a href="' . &html_escape($url) . '" target="_blank" rel="noopener noreferrer">'
        . &html_escape($label) . '</a></small>';
}

# API/secret inputs: text + autocomplete off so browsers do not inject saved logins.
sub _integrations_secret_input {
    my ($name, $value, $size, $placeholder) = @_;
    $name  //= '';
    $size  //= 50;
    $value //= '';
    $placeholder //= '';
    $name =~ s/[^a-zA-Z0-9_]//g;
    my $ph_attr = length($placeholder) ? " placeholder='" . &html_escape($placeholder) . "'" : '';
    return "<input type='text' name='" . &html_escape($name) . "' value='' size='$size'"
        . " autocomplete='off' autocapitalize='off' spellcheck='false' data-1p-ignore data-lpignore='true'"
        . $ph_attr . '>';
}

if ($ENV{REQUEST_METHOD} eq 'POST') {
    my $action = $in{'action'} // '';
    $action =~ s/[^a-z_]//g;

    if ($action eq 'patch_repos') {
        &patch_apt_sources('/etc/apt/sources.list');
        &redirect('integrations.cgi');
        exit;

    } elsif ($action eq 'install_steamcmd') {
        &install_steamcmd();
        &redirect('integrations.cgi');
        exit;

    } elsif ($action eq 'install_xterm') {
        &is_admin() or &error($text{'err_acl_admin_only'} || 'Access denied');
        my ($ok, $err) = &install_xterm_webmin_module();
        $ok or &error($text{'live_log_xterm_install_failed'} . ($err ? " ($err)" : ''));
        &module_config_flash_mark('xterm_installed')
            or &error($text{'live_log_xterm_install_failed'});
        &redirect('integrations.cgi?xterm_installed=1&xnavigation=1');
        exit;

    } elsif ($action eq 'install_live_log_deps') {
        &is_admin() or &error($text{'err_acl_admin_only'} || 'Access denied');
        &install_live_log_apt_packages() == 0
            or &error($text{'live_log_deps_install_failed'} || 'Live-log dependencies install failed.');
        &module_config_flash_mark('live_log_deps')
            or &error($text{'live_log_deps_install_failed'} || 'Live-log dependencies install failed.');
        &redirect('integrations.cgi?live_log_deps=1&xnavigation=1');
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
        $token or &error($text{'steam_login_start_failed'} || 'Steam-Login konnte nicht gestartet werden.');
        &redirect("integrations.cgi?action=poll&session=" . &html_escape($token) . "&username=" . &html_escape($username));
        exit;

    } elsif ($action eq 'remove_account') {
        my $username = $in{'steam_username'} // '';
        $username =~ s/[^a-zA-Z0-9_\-]//g;
        $username or &error($text{'err_invalid_input'});
        &remove_steam_account($username);
        &redirect('integrations.cgi');
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
        &redirect("integrations.cgi?action=poll&session=" . &html_escape($token) . "&username=" . &html_escape($username));
        exit;

    } elsif ($action eq 'save_settings') {
        &is_admin() or &error($text{'err_acl_admin_only'} || 'Access denied');

        $config{debug_logging} = &module_config_bool($in{'debug_logging'});
        $config{download_allow_custom_url} = &module_config_bool($in{'download_allow_custom_url'});
        $config{modpack_cf_auto_resume} = &module_config_bool($in{'modpack_cf_auto_resume'});

        my $mc = $in{'modrinth_contact'} // '';
        $mc =~ s/[\t\n\r]//g;
        $config{modrinth_contact} = substr($mc, 0, 200);

        my $hosts = $in{'download_custom_hosts'} // '';
        $hosts =~ s/[\t\n\r]//g;
        $config{download_custom_hosts} = substr($hosts, 0, 500);

        if (defined $in{'curseforge_api_key'} && $in{'curseforge_api_key'} ne '') {
            my $k = $in{'curseforge_api_key'};
            $k =~ s/[\t\n\r]//g;
            $k = substr($k, 0, 128);
            $config{curseforge_api_key} = $k if length $k;
        }
        if (defined $in{'hangar_api_token'} && $in{'hangar_api_token'} ne '') {
            my $t = $in{'hangar_api_token'};
            $t =~ s/[\t\n\r]//g;
            $t = substr($t, 0, 128);
            $config{hangar_api_token} = $t if length $t;
        }

        &module_config_save()
            or &error($text{'integrations_save_failed'} || 'Einstellungen konnten nicht gespeichert werden.');
        &module_config_flash_mark_ok()
            or &error($text{'integrations_save_failed'} || 'Einstellungen konnten nicht gespeichert werden.');
        &log_action('integrations_save', 'config', {}) if defined &log_action;
        &redirect('integrations.cgi?saved=1&xnavigation=1');
        exit;

    } elsif ($action eq 'relogin') {
        my $username = $in{'steam_username'} // '';
        my $password = $in{'steam_password'} // '';
        $username =~ s/[^a-zA-Z0-9_\-]//g;
        $username or &error($text{'err_invalid_input'});
        $password or &error($text{'err_invalid_input'});
        &update_steam_account_status($username, 'guard_pending');
        my $token = &start_login_session($username, $password);
        $token or &error($text{'steam_login_start_failed'} || 'Steam-Login konnte nicht gestartet werden.');
        &redirect("integrations.cgi?action=poll&session=" . &html_escape($token) . "&username=" . &html_escape($username));
        exit;
    }
}

my $get_action = $in{'action'} // '';
$get_action =~ s/[^a-z_]//g;

if ($get_action eq 'relogin_form') {
    my $username = $in{'instance'} // '';
    $username =~ s/[^a-zA-Z0-9_\-]//g;
    &header($text{'integrations_title'}, '');
    print "<h3>" . &html_escape($text{'steam_relogin_btn'}) . ": " . &html_escape($username) . "</h3>\n";
    print &ui_form_start('integrations.cgi', 'post');
    print &ui_hidden('action', 'relogin');
    print &ui_hidden('steam_username', &html_escape($username));
    print &ui_table_start('', undef, 2);
    print &ui_table_row(&html_escape($text{'steam_password_hint'}),
        "<input type='password' name='steam_password' size='30'"
        . " autocomplete='new-password' autocapitalize='off' data-1p-ignore data-lpignore='true'>");
    print &ui_table_end();
    print &ui_submit($text{'steam_login_start_btn'}, undef, undef, undef, 'btn-primary');
    print &ui_form_end();
    &footer('integrations.cgi', $text{'integrations_title'});
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
        print "<p><a href='integrations.cgi'>" . &html_escape($text{'integrations_title'}) . "</a></p>\n";
    } elsif ($status eq 'failed') {
        &update_steam_account_status($username, 'token_expired');
        &cleanup_session($token);
        print "<div class='alert alert-danger'>" . &html_escape($text{'steam_login_failed'}) . "</div>\n";
        print "<p><a href='integrations.cgi'>" . &html_escape($text{'integrations_title'}) . "</a></p>\n";
    } elsif ($status eq 'timeout') {
        &update_steam_account_status($username, 'token_expired');
        &cleanup_session($token);
        print "<div class='alert alert-warning'>" . &html_escape($text{'steam_login_timeout'}) . "</div>\n";
        print "<p><a href='integrations.cgi'>" . &html_escape($text{'integrations_title'}) . "</a></p>\n";
    } elsif ($status eq 'guard_required' || ($status eq 'connecting' && $guard_code_hint && !$mobile_confirm_hint)) {
        print "<p>" . &html_escape($text{'steam_guard_prompt'}) . "</p>\n";
        print &ui_form_start('integrations.cgi', 'post');
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
        print &job_log_view_page_css();
        print &job_log_view_page_open();
        print "<h4>" . &html_escape($text{'jobs_output_title'} || 'Ausgabe') . "</h4>\n";
        print &job_log_view_block($out_tail, id => 'steam_login_log');
        print &job_log_view_page_close();
    }

    &footer('', '');
    exit;
}

# Main page
&header($text{'integrations_title'}, '');

if (($in{'saved'} // '') eq '1' && &module_config_flash_consume_ok()) {
    print "<div class='alert alert-success'>"
        . &html_escape($text{'integrations_saved_ok'} // 'Einstellungen gespeichert.')
        . "</div>\n";
}
if (($in{'xterm_installed'} // '') eq '1' && &module_config_flash_consume('xterm_installed')) {
    print "<div class='alert alert-success'>"
        . &html_escape($text{'live_log_xterm_installed_ok'}) . "</div>\n";
}
if (($in{'live_log_deps'} // '') eq '1' && &module_config_flash_consume('live_log_deps')) {
    print "<div class='alert alert-success'>"
        . &html_escape($text{'live_log_deps_installed_ok'}) . "</div>\n";
}

# --- Live log / Webmin Terminal (xterm) ---
print "<h3 id=\"live_log\">" . &html_escape($text{'integrations_live_log_section'}) . "</h3>\n";
print "<p>" . &html_escape($text{'integrations_live_log_desc'}) . "</p>\n";

my $live_st = &live_log_status($root_directory);
print &ui_table_start('', undef, 2);

if ($live_st->{'xterm_module'}) {
    print &ui_table_row(&html_escape($text{'live_log_xterm_module'}),
        '&#x2705; ' . &html_escape($text{'live_log_status_ok'}));
} else {
    my $f = &ui_form_start('integrations.cgi', 'post');
    $f .= &ui_hidden('action', 'install_xterm');
    $f .= &ui_submit($text{'live_log_xterm_install_btn'}, undef, undef, undef, 'btn-primary');
    $f .= &ui_form_end();
    print &ui_table_row(&html_escape($text{'live_log_xterm_module'}),
        &html_escape($text{'live_log_xterm_missing'}) . '<br>' . $f);
}

if ($live_st->{'xterm_assets'}) {
    print &ui_table_row(&html_escape($text{'live_log_xterm_assets'}),
        '&#x2705; ' . &html_escape($text{'live_log_status_ok'}));
} else {
    print &ui_table_row(&html_escape($text{'live_log_xterm_assets'}),
        &html_escape($text{'live_log_xterm_assets_missing'}));
}

my @perl_miss = @{ $live_st->{'perl_missing'} // [] };
if (!@perl_miss) {
    print &ui_table_row(&html_escape($text{'live_log_perl_deps'}),
        '&#x2705; ' . &html_escape($text{'live_log_status_ok'}));
} else {
    my $miss_txt = &html_escape(join(', ', @perl_miss));
    my $f = &ui_form_start('integrations.cgi', 'post');
    $f .= &ui_hidden('action', 'install_live_log_deps');
    $f .= &ui_submit($text{'live_log_perl_install_btn'}, undef, undef, undef, 'btn-default');
    $f .= &ui_form_end();
    print &ui_table_row(&html_escape($text{'live_log_perl_deps'}),
        $miss_txt . '<br><small>' . &html_escape($text{'live_log_perl_install_hint'}) . '</small><br>' . $f);
}

if ($live_st->{'ready'}) {
    print &ui_table_row(&html_escape($text{'live_log_ready'}),
        '&#x2705; ' . &html_escape($text{'live_log_ready_ok'}));
} else {
    print &ui_table_row(&html_escape($text{'live_log_ready'}),
        '&#x26A0;&#xFE0F; ' . &html_escape($text{'live_log_ready_no'}));
}
print &ui_table_end();

print "<h3>" . &html_escape($text{'integrations_steam_section'}) . "</h3>\n";
print "<h4>" . &html_escape($text{'steam_system_title'}) . "</h4>\n";
my $steamcmd_path = &detect_steamcmd();
my $repos         = &check_apt_repos('/etc/apt/sources.list');

print &ui_table_start('', undef, 2);
if ($steamcmd_path) {
    print &ui_table_row(&html_escape($text{'steam_cmd_ok'}), &html_escape($steamcmd_path));
} else {
    my $f = &ui_form_start('integrations.cgi', 'post');
    $f .= &ui_hidden('action', 'install_steamcmd');
    $f .= &ui_submit($text{'steam_install_btn'}, undef, undef, undef, 'btn-primary');
    $f .= &ui_form_end();
    print &ui_table_row(&html_escape($text{'steam_cmd_missing'}), $f);
}

if ($repos->{'non_free'} && $repos->{'contrib'}) {
    print &ui_table_row(&html_escape($text{'steam_repos_ok'}), '&#x2705;');
} else {
    my $f = &ui_form_start('integrations.cgi', 'post');
    $f .= &ui_hidden('action', 'patch_repos');
    $f .= &ui_submit($text{'steam_repos_fix_btn'}, undef, undef, undef, 'btn-default');
    $f .= &ui_form_end();
    print &ui_table_row(&html_escape($text{'steam_repos_missing'}), $f);
}

if (!$repos->{'cdrom_active'}) {
    print &ui_table_row(&html_escape($text{'steam_cdrom_ok'}), '&#x2705;');
} else {
    my $f = &ui_form_start('integrations.cgi', 'post');
    $f .= &ui_hidden('action', 'patch_repos');
    $f .= &ui_submit($text{'steam_repos_fix_btn'}, undef, undef, undef, 'btn-default');
    $f .= &ui_form_end();
    print &ui_table_row(&html_escape($text{'steam_cdrom_warn'}), $f);
}
print &ui_table_end();

print "<h4>" . &html_escape($text{'steam_accounts_title'}) . "</h4>\n";
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
            $actions .= "<a href=\"integrations.cgi?action=relogin_form&instance=" . &html_escape($uname) . "\" class=\"btn btn-xs btn-warning\">" . &html_escape($text{'steam_relogin_btn'}) . "</a>";
        }
        $actions .= &ui_form_start('integrations.cgi', 'post');
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
print &ui_form_start('integrations.cgi', 'post');
print &ui_hidden('action', 'add_account');
print &ui_table_start('', undef, 2);
print &ui_table_row(&html_escape($text{'steam_display_name'}),
    &ui_textbox('steam_display_name', '', 30));
print &ui_table_row(&html_escape($text{'steam_username'}),
    "<input type='text' name='steam_username' size='30'"
    . " autocomplete='off' autocapitalize='off' spellcheck='false' data-1p-ignore>");
print &ui_table_row(&html_escape($text{'steam_password_hint'}),
    "<input type='password' name='steam_password' size='30'"
    . " autocomplete='new-password' autocapitalize='off' data-1p-ignore data-lpignore='true'>");
print &ui_table_end();
print &ui_submit($text{'steam_login_start_btn'}, undef, undef, undef, 'btn-primary');
print &ui_form_end();

if (&is_admin()) {
    print "<h3>" . &html_escape($text{'integrations_mc_download_section'}) . "</h3>\n";
    print "<p><span class=\"label label-info\">Minecraft</span> "
        . &html_escape($text{'integrations_mc_download_desc'}) . "</p>\n";
    print "<p><small><i>" . &html_escape($text{'integrations_admin_only'}) . "</i></small></p>\n";
    print &ui_form_start('integrations.cgi', 'post');
    print &ui_hidden('action', 'save_settings');
    print &ui_table_start('', undef, 2);

    print &ui_table_row(
        &html_escape($text{'integrations_modrinth_contact'}),
        "<input type='text' name='modrinth_contact' size='50'"
            . " value='" . &html_escape($config{modrinth_contact} // '') . "'"
            . " autocomplete='off' autocapitalize='off' spellcheck='false' data-1p-ignore>"
            . "<br><small>" . &html_escape($text{'integrations_modrinth_contact_hint'}) . "</small>"
            . &_integrations_help_link(
                'https://docs.modrinth.com/api/',
                $text{'integrations_modrinth_contact_link'}));

    my $cf_ph = &_integrations_secret_placeholder($config{curseforge_api_key});
    print &ui_table_row(
        &html_escape($text{'integrations_curseforge_api_key'}),
        &_integrations_secret_input('curseforge_api_key', '', 50, $cf_ph)
            . &_integrations_secret_status($config{curseforge_api_key})
            . "<br><small>" . &html_escape($text{'integrations_curseforge_api_key_hint'}) . "</small>"
            . &_integrations_help_link(
                'https://console.curseforge.com/',
                $text{'integrations_curseforge_api_key_link'}));

    my $hg_ph = &_integrations_secret_placeholder($config{hangar_api_token});
    print &ui_table_row(
        &html_escape($text{'integrations_hangar_token'}),
        &_integrations_secret_input('hangar_api_token', '', 50, $hg_ph)
            . &_integrations_secret_status($config{hangar_api_token})
            . "<br><small>" . &html_escape($text{'integrations_hangar_token_hint'}) . "</small>"
            . &_integrations_help_link(
                'https://hangar.papermc.io/api-docs',
                $text{'integrations_hangar_token_link'}));

    print &ui_table_row(
        &html_escape($text{'integrations_allow_custom_url'}),
        &ui_radio('download_allow_custom_url', &module_config_bool($config{download_allow_custom_url}) ? 1 : 0,
            [[1, ($text{'yes'} || 'Ja')], [0, ($text{'no'} || 'Nein')]]));

    print &ui_table_row(
        &html_escape($text{'integrations_custom_hosts'}),
        &ui_textbox('download_custom_hosts', $config{download_custom_hosts} // '', 50)
            . "<br><small>" . &html_escape($text{'integrations_custom_hosts_hint'}) . "</small>");

    my $auto_resume_default =
        (defined $config{modpack_cf_auto_resume} && $config{modpack_cf_auto_resume} =~ /\S/)
        ? (&module_config_bool($config{modpack_cf_auto_resume}) ? 1 : 0)
        : 1;
    print &ui_table_row(
        &html_escape($text{'integrations_modpack_cf_auto_resume'}),
        &ui_radio('modpack_cf_auto_resume', $auto_resume_default,
            [[1, ($text{'yes'} || 'Ja')], [0, ($text{'no'} || 'Nein')]])
            . "<br><small>" . &html_escape($text{'integrations_modpack_cf_auto_resume_hint'}) . "</small>");

    print &ui_table_end();

    print "<h4>" . &html_escape($text{'integrations_module_section'}) . "</h4>\n";
    print &ui_table_start('', undef, 2);
    print &ui_table_row(
        &html_escape($text{'config_debug_logging'} || 'Debug-Logging'),
        &ui_radio('debug_logging', &module_config_bool($config{debug_logging}) ? 1 : 0,
            [[1, ($text{'yes'} || 'Ja')], [0, ($text{'no'} || 'Nein')]]));
    print &ui_table_end();
    print "<p><small><i>" . &html_escape($text{'integrations_secrets_persist_hint'}) . "</i></small></p>\n";
    print &ui_submit($text{'acl_manage_save'} || 'Speichern', undef, undef, undef, 'btn-default');
    print &ui_form_end();
}

&footer('index.cgi', $text{'index_title'});
