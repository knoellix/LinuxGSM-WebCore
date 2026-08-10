#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/module_config.pl';
require './lib/acl.pl';
require './lib/instance.pl';
require './lib/ftp_proftpd.pl';
require './lib/logging.pl';
require './lib/provision.pl';

our (%text, %in, %access, %gconfig);
our ($module_name, $config_directory, $module_config_directory);
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

&module_config_sync_in();

&can_scan() or &error($text{'err_access_denied'});

sub _scan_action_failed {
    &error($text{'scan_action_failed'} || 'Aktion konnte nicht abgeschlossen werden.');
}

sub _scan_redirect_success {
    my ($event, $extra_qs) = @_;
    $event =~ s/[^a-z_]//g;
    $event or _scan_action_failed();
    &module_config_flash_mark("scan_$event")
        or _scan_action_failed();
    my $url = "scan.cgi?ok=$event";
    if (defined $extra_qs && $extra_qs =~ /\S/) {
        $extra_qs =~ s/[^a-zA-Z0-9_=&\-]//g;
        $url .= "&$extra_qs" if $extra_qs =~ /=/;
    }
    $url .= '&xnavigation=1';
    &redirect($url);
    exit;
}

sub _scan_owner_in_registry {
    my ($instance_id, $webmin_user) = @_;
    my $reg = &get_registered_instance($instance_id);
    return 0 unless $reg;
    my @owners = grep { /\S/ } split /,/, ($reg->{'owners'} // '');
    return grep { $_ eq $webmin_user } @owners ? 1 : 0;
}

sub _scan_render_success_banner {
    my $ok = $in{'ok'} // '';
    $ok =~ s/[^a-z_]//g;
    return unless $ok;
    return unless &module_config_flash_consume("scan_$ok");
    my %msg_key = (
        assigned   => 'scan_assigned_ok',
        registered => 'scan_registered_ok',
        deleted    => 'scan_deleted_ok',
    );
    return unless $msg_key{$ok};
    print "<div class='alert alert-success'><b>"
        . &html_escape($text{$msg_key{$ok}}) . "</b></div>\n";
}

# --- POST handler ---
if ($ENV{REQUEST_METHOD} eq 'POST') {
    my $action = &sanitize_input($in{'action'} || 'assign');

    if ($action eq 'assign') {
        my $instance_id = &sanitize_input($in{'instance_id'});
        my $webmin_user = &sanitize_input($in{'webmin_user'});

        $instance_id or &error($text{'err_invalid_input'});
        $webmin_user or &error($text{'err_invalid_input'});
        # Basic format validation (independent of dynamic user list)
        $webmin_user =~ /^[a-zA-Z0-9_.\@\-]+$/ or &error($text{'err_invalid_input'});

        my $inst_check = &get_instance($instance_id) or &error($text{'err_not_found'});

        # Validate against known users only when the list is actually available
        my @valid_users = &list_webmin_users();
        if (@valid_users) {
            my %valid = map { $_ => 1 } @valid_users;
            $valid{$webmin_user} or &error($text{'err_invalid_input'});
        }

        # Persist owner in instance registry (comma-separated, deduplicated)
        my $reg = &get_registered_instance($instance_id);
        my $existing_owners = ($reg ? ($reg->{'owners'} // '') : '');
        my %seen_owners = map { $_ => 1 } grep { /\S/ } split /,/, $existing_owners;
        $seen_owners{$webmin_user} = 1;
        my $new_owners = join(',', sort keys %seen_owners);
        &register_instance($instance_id, $inst_check->{'user'}, $inst_check->{'script'}, {
            source    => ($reg ? ($reg->{'source'}    // 'manual') : 'manual'),
            sftp_user => ($reg ? ($reg->{'sftp_user'} // '')       : ''),
            owners    => $new_owners,
        }) or _scan_action_failed();

        &grant_server_access($webmin_user, $instance_id)
            or _scan_action_failed();
        &_scan_owner_in_registry($instance_id, $webmin_user)
            or _scan_action_failed();

        &log_action('scan_assign', $instance_id, {webmin_user => $webmin_user});
        &_scan_redirect_success('assigned');
    }
    elsif ($action eq 'quickregister') {
        my $instance_id = &sanitize_input($in{'instance_id'});
        my $reg_wbuser  = $in{'webmin_user'} // '';
        $reg_wbuser = &sanitize_input($reg_wbuser) if $reg_wbuser ne '';

        $instance_id or &error($text{'err_invalid_input'});

        # Find the auto-detected (not yet registered) instance
        my @all = &list_instances();
        my ($inst) = grep {
            $_->{'id'} eq $instance_id &&
            ($_->{'registration_source'} // '') eq 'auto'
        } @all;
        $inst or &error($text{'err_not_found'});

        &register_instance($instance_id, $inst->{'user'}, $inst->{'script'}, {
            source => 'manual',
        }) or _scan_action_failed();

        my $reg = &get_registered_instance($instance_id);
        ($reg->{'source'} // '') eq 'manual'
            or _scan_action_failed();

        if ($reg_wbuser) {
            &grant_server_access($reg_wbuser, $instance_id)
                or _scan_action_failed();
        }

        &log_action('scan_register', $instance_id, {webmin_user => $reg_wbuser});
        &_scan_redirect_success('registered', 'show_scan=1');
    }
    elsif ($action eq 'register') {
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

        # FTP user uniqueness: one FTP user may only belong to one server
        if ($reg_sftp_user) {
            for my $inst (&list_instances()) {
                my $sftp = &resolve_instance_sftp_user($inst->{'id'}, $inst->{'user'});
                &error($text{'scan_sftp_already_assigned'}) if ($sftp // '') eq $reg_sftp_user;
            }
            # UID check: FTP user should write with the game user's permissions
            my @game_pw   = getpwnam($reg_user);
            my %ftp_check = &discover_ftp_state();
            my $auth_file = $ftp_check{'auth_user_file'} // '';
            if (@game_pw && $auth_file && -f $auth_file) {
                for my $fu (&parse_ftpd_passwd($auth_file)) {
                    if ($fu->{'name'} eq $reg_sftp_user) {
                        int($fu->{'uid'}) == int($game_pw[2])
                            or &error($text{'scan_sftp_uid_mismatch'});
                        last;
                    }
                }
            }
        }

        my $script_id = (split('/', $reg_script))[-1];
        &register_instance($script_id, $reg_user, $reg_script, {
            source    => 'manual',
            sftp_user => $reg_sftp_user,
        }) or _scan_action_failed();

        my $reg = &get_registered_instance($script_id);
        $reg && ($reg->{'user'} // '') eq $reg_user
            && ($reg->{'script'} // '') eq $reg_script
            or _scan_action_failed();

        if ($reg_wbuser) {
            &grant_server_access($reg_wbuser, $script_id)
                or _scan_action_failed();
        }

        &log_action('scan_register', $script_id, {webmin_user => $reg_wbuser});
        &_scan_redirect_success('registered');
    }
    elsif ($action eq 'untrack_manual') {
        my $instance_id = &sanitize_input($in{'instance_id'});
        my $meta = &get_registered_instance($instance_id);
        $meta or &error($text{'err_not_found'});
        ($meta->{'source'} // '') eq 'manual' or &error($text{'err_invalid_action'});
        &unregister_instance($instance_id)
            or _scan_action_failed();
        &get_registered_instance($instance_id)
            and _scan_action_failed();
        &log_action('scan_untrack', $instance_id, {});
        &redirect('scan.cgi?xnavigation=1');
        exit;
    }
    elsif ($action eq 'delete') {
        &is_admin() or &error($text{'err_acl_admin_only'} || 'Access denied');
        my $instance_id = $in{'instance_id'} // '';
        $instance_id =~ s/[^a-zA-Z0-9_\-]//g;
        $instance_id or &error($text{'err_invalid_input'});

        my $inst = &get_instance_flexible($instance_id) or &error($text{'err_not_found'});
        my $unix_user  = $inst->{'user'} // '';
        my $script_path = $inst->{'script'} // '';
        (my $server_dir = $script_path) =~ s|/[^/]+$||;

        my $delete_opt = $in{'delete_opt'} // 'files';
        $delete_opt = 'files' unless $delete_opt =~ /^(files|user|user_ftp)$/;

        my $sftp_user = &resolve_instance_sftp_user($instance_id, $unix_user);

        my @all_inst = &list_instances();
        my @other_for_user = grep {
            ($_->{'id'} // '') ne $instance_id && ($_->{'user'} // '') eq $unix_user
        } @all_inst;

        # Remove server files if path looks safe
        if ($server_dir && $server_dir =~ m|^/[a-zA-Z0-9_./()\-]+$| && $server_dir ne '/') {
            if (-d $server_dir) {
                (my $safe_dir = $server_dir) =~ s/'/'\\''/g;
                my $rc = &system_logged("rm -rf '$safe_dir'");
                ($rc == 0 && !-d $server_dir)
                    or &error($text{'scan_delete_failed'} || 'Instanz-Dateien konnten nicht gelöscht werden.');
            }
        }

        &unregister_instance($instance_id)
            or _scan_action_failed();
        &get_registered_instance($instance_id)
            and _scan_action_failed();

        if ($delete_opt eq 'user_ftp' && $sftp_user && $sftp_user ne $unix_user) {
            my %ftp_state = &discover_ftp_state();
            my $auth_file = $ftp_state{'auth_user_file'} || '/etc/proftpd/ftpd.passwd';
            my $rc = &ftpasswd_delete_user(file => $auth_file, name => $sftp_user);
            ($rc == 0)
                or &error($text{'scan_delete_failed'} || 'Instanz-Dateien konnten nicht gelöscht werden.');
        }

        if (($delete_opt eq 'user' || $delete_opt eq 'user_ftp') && !@other_for_user && $unix_user) {
            my $res = &decommission_unix_user($unix_user);
            &log_debug("scan decommission: " . join(' | ', @{ $res->{'log'} }));
            if (!$res->{'ok'}) {
                &error(($text{'err_delete_incomplete'} || 'Löschen unvollständig') . ': '
                    . join(', ', @{ $res->{'leftovers'} }));
            }
        }

        &log_action('server_deleted', $instance_id, {unix_user => $unix_user, scope => $delete_opt});
        &_scan_redirect_success('deleted');
    }
}

# --- GET: delete confirmation ---
if (($in{'action'} // '') eq 'delete_confirm') {
    &is_admin() or &error($text{'err_acl_admin_only'} || 'Access denied');
    my $instance_id = $in{'instance_id'} // '';
    $instance_id =~ s/[^a-zA-Z0-9_\-]//g;
    $instance_id or &error($text{'err_invalid_input'});

    my $inst = &get_instance_flexible($instance_id) or &error($text{'err_not_found'});
    my $unix_user = $inst->{'user'} // '';

    my @all_inst = &list_instances();
    my @other_for_user = grep {
        ($_->{'id'} // '') ne $instance_id && ($_->{'user'} // '') eq $unix_user
    } @all_inst;

    my $sftp_user = &resolve_instance_sftp_user($instance_id, $unix_user);

    &header($text{'scan_delete_title'} || 'Instanz löschen', '');
    print "<h3>" . ($text{'scan_delete_title'} || 'Instanz löschen') . ": " . &html_escape($instance_id) . "</h3>\n";

    if (@other_for_user) {
        my $others = join(', ', map { &html_escape($_->{'id'}) } @other_for_user);
        print "<div class='alert alert-warning'><b>"
            . ($text{'scan_delete_warn_shared'} || 'Warnung') . ":</b> "
            . &html_escape("Unix-User '$unix_user' wird auch von: ")
            . $others . " " . ($text{'scan_delete_warn_shared_suffix'} || 'genutzt — nur Instanz-Dateien löschen empfohlen.')
            . "</div>\n";
    }

    my $default_opt = @other_for_user ? 'files' : ($sftp_user ? 'user_ftp' : 'user');
    my @radio_opts = (
        ['files',    $text{'scan_delete_opt_files'}    || 'Nur Instanz-Dateien + Registrierung löschen (Unix-User bleibt)'],
        ['user',     $text{'scan_delete_opt_user'}     || 'Instanz-Dateien + Unix-User löschen'],
    );
    push @radio_opts, ['user_ftp', $text{'scan_delete_opt_user_ftp'} || 'Instanz-Dateien + Unix-User + FTP-User löschen']
        if $sftp_user && $sftp_user ne $unix_user;

    print &ui_form_start('scan.cgi', 'post');
    print &ui_hidden('action',      'delete');
    print &ui_hidden('instance_id', &html_escape($instance_id));
    print &ui_table_start('', undef, 2);
    print &ui_table_row(
        $text{'scan_delete_options'} || 'Lösch-Umfang',
        &ui_radio('delete_opt', $default_opt, \@radio_opts)
    );
    print &ui_table_end();
    print &ui_submit($text{'scan_delete_confirm_btn'} || 'Jetzt löschen', undef, undef, undef, 'btn-danger');
    print " ";
    print "<a href='scan.cgi' class='btn btn-default'>" . ($text{'cancel'} || 'Abbrechen') . "</a>";
    print &ui_form_end();
    &footer('scan.cgi', $text{'scan_title'} || 'Zurück');
    exit;
}

# --- GET: show page ---
&header($text{'scan_title'}, '');

&_scan_render_success_banner();

my @instances    = &list_instances();
my @webmin_users = &list_webmin_users();
my @wbm_opts     = map { [$_, $_] } @webmin_users;

# Split: auto-detected (not yet in registry) vs. explicitly registered
my @auto       = grep { ($_->{'registration_source'} // '') eq 'auto'  } @instances;
my @registered = grep { ($_->{'registration_source'} // '') ne 'auto'  } @instances;

# Load virtual FTP users for the sftp_user dropdown
my @ftp_user_names = ();
{
    my %ftp_state = &discover_ftp_state();
    my $auth_file = $ftp_state{'auth_user_file'} // '';
    if ($auth_file && -f $auth_file) {
        push @ftp_user_names, $_->{'name'} for &parse_ftpd_passwd($auth_file);
    }
}
# Collect already-assigned FTP users so they can be excluded from the dropdown
my %assigned_ftp = ();
for my $inst (@instances) {
    my $sftp = &resolve_instance_sftp_user($inst->{'id'}, $inst->{'user'});
    $assigned_ftp{$sftp} = $inst->{'id'} if $sftp;
}
# Build dropdown: empty option + unassigned FTP users only
my @sftp_opts = (['', "($text{'scan_no_ftp'})"]);;
for my $name (sort @ftp_user_names) {
    next if $assigned_ftp{$name};
    push @sftp_opts, [$name, $name];
}

# --- Auto-Scan section ---
print &ui_form_start('scan.cgi', 'get');
print &ui_hidden('show_scan', '1');
print &ui_submit($text{'scan_btn_autoscan'}, undef, undef, undef, 'btn-default');
print &ui_form_end();

if ($in{'show_scan'}) {
    print "<h3>$text{'scan_autoscan_title'}</h3>\n";
    if (@auto) {
        my @auto_rows;
        for my $inst (@auto) {
            my $id = $inst->{'id'};
            my $quick_form = &ui_form_start('scan.cgi', 'post');
            $quick_form .= &ui_hidden('action',      'quickregister');
            $quick_form .= &ui_hidden('instance_id', &html_escape($id));
            $quick_form .= &ui_select('webmin_user', '', [['', '---'], @wbm_opts]);
            $quick_form .= ' ';
            $quick_form .= &ui_submit($text{'scan_register_quick_btn'}, undef, undef, undef, 'btn-primary');
            $quick_form .= &ui_form_end();
            push @auto_rows, [
                &html_escape($inst->{'user'}),
                &html_escape($inst->{'script'}),
                &html_escape($inst->{'game'}),
                int($inst->{'port'}),
                $quick_form,
            ];
        }
        print &ui_columns_table(
            [
                $text{'index_col_user'},
                $text{'scan_col_script'},
                $text{'index_col_game'},
                $text{'index_col_port'},
                $text{'index_col_manage'},
            ],
            "100%",
            \@auto_rows,
        );
    } else {
        print "<p><i>$text{'scan_autoscan_none'}</i></p>\n";
    }
}

# --- Registered instances section ---
print "<h3>$text{'scan_registered_title'}</h3>\n";

if (@registered) {
    my @rows;
    foreach my $inst (@registered) {
        my $id   = $inst->{'id'};
        my $user = $inst->{'user'};

        my $sftp      = &resolve_instance_sftp_user($id, $user);
        my $sftp_cell = $sftp ? &html_escape($sftp) : "<i>$text{'scan_no_ftp'}</i>";

        my @owners = grep { /\S/ } split /,/, ($inst->{'owners'} // '');
        my $owner_cell = @owners
            ? '<ul style="margin:0;padding-left:1.2em">' .
              join('', map { '<li>' . &html_escape($_) . '</li>' } @owners) .
              '</ul>'
            : "<i>$text{'scan_unowned'}</i>";

        my $actions_cell = &ui_form_start('scan.cgi', 'post');
        $actions_cell .= &ui_hidden('action',      'assign');
        $actions_cell .= &ui_hidden('instance_id', &html_escape($id));
        $actions_cell .= &ui_select('webmin_user', '', \@wbm_opts);
        $actions_cell .= ' ';
        $actions_cell .= &ui_submit($text{'scan_assign'}, undef, undef, undef, 'btn-default');
        $actions_cell .= &ui_form_end();
        if (($inst->{'registration_source'} // '') eq 'manual') {
            $actions_cell .= &ui_form_start('scan.cgi', 'post');
            $actions_cell .= &ui_hidden('action',      'untrack_manual');
            $actions_cell .= &ui_hidden('instance_id', &html_escape($id));
            $actions_cell .= &ui_submit($text{'scan_remove_panel_btn'}, undef, undef, undef, 'btn-danger');
            $actions_cell .= &ui_form_end();
        }

        if (&is_admin()) {
            $actions_cell .= " <a href='scan.cgi?action=delete_confirm&amp;instance_id="
                . &html_escape($id) . "' class='btn btn-danger btn-xs'>"
                . ($text{'scan_delete_btn'} || 'Löschen') . "</a>";
        }

        push @rows, [
            &html_escape($user),
            &html_escape($inst->{'script'}),
            $sftp_cell,
            &html_escape($inst->{'game'}),
            int($inst->{'port'}),
            $owner_cell,
            $actions_cell,
        ];
    }

    print &ui_columns_table(
        [
            $text{'index_col_user'},
            $text{'scan_col_script'},
            $text{'scan_col_ftp'},
            $text{'index_col_game'},
            $text{'index_col_port'},
            $text{'scan_col_owner'},
            $text{'scan_col_actions'},
        ],
        "100%",
        \@rows,
    );
} else {
    print "<p><i>$text{'scan_no_registered'}</i></p>\n";
}

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
    &ui_filebox('reg_script', '', 50));
print &ui_table_row($text{'scan_reg_owner'},
    &ui_select('reg_webmin_user', '', [['', '---'], @wbm_opts]));
print &ui_table_row($text{'scan_reg_sftp_user'},
    &ui_select('reg_sftp_user', '', \@sftp_opts) .
    " <small><i>$text{'scan_sftp_one_per_server'}</i></small>");
print &ui_table_end();
print &ui_submit($text{'scan_reg_submit'}, undef, undef, undef, 'btn-primary');
print &ui_form_end();

&footer('', '');
