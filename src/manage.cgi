#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/instance.pl';
require './lib/firewall.pl';
require './lib/acl.pl';
require './lib/games_meta.pl';
require './lib/config_editor.pl';
require './lib/ftp_proftpd.pl';

our (%text, %config, %in, %gconfig);
our $current_lang;
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

my $instance_id = &sanitize_input($in{'instance_id'} || $in{'user'} || '');
my $inst = &get_instance($instance_id) or &error($text{'err_not_found'});
my $unix_user = $inst->{'user'};

if ($in{'action'}) {
    my $action = &sanitize_input($in{'action'});

    if ($action eq 'fw_open') {
        my $port = int($inst->{'port'});
        &firewall_open_port($port, 'tcp');
        &firewall_open_port($port, 'udp');
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id));
    }
    elsif ($action eq 'fw_close') {
        my $port = int($inst->{'port'});
        &firewall_close_port($port, 'tcp');
        &firewall_close_port($port, 'udp');
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id));
    }
    elsif ($action eq 'fix_config') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        my $script_dir  = $inst->{'script'};
        $script_dir =~ s|/[^/]+$||;

        my $config_file = "$script_dir/lgsm/config-lgsm/$script_name/$script_name.cfg";
        my $default_cfg = "$script_dir/lgsm/config-default/config-lgsm/$script_name/_default.cfg";
        my $backup_cfg  = "$default_cfg.bak";

        &error("Invalid config path") unless
            $config_file =~ m|^/[a-zA-Z0-9_./()\-]+/lgsm/config-lgsm/[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+\.cfg$|;
        &error("Invalid default path") unless
            $default_cfg =~ m|^/[a-zA-Z0-9_./()\-]+/lgsm/config-default/config-lgsm/[a-zA-Z0-9_-]+/_default\.cfg$|;

        # Form values always win for port/gamename
        my $safe_port = int($in{'port'} || $inst->{'port'} || 0);
        my $safe_game = $in{'gamename'} // $inst->{'game'} // '';
        $safe_game =~ s/[^a-zA-Z0-9 _-]//g;
        $safe_port > 0     or &error($text{'err_invalid_input'});
        length($safe_game) or &error($text{'err_invalid_input'});

        # Read _default.cfg preserving section comments and all assignments.
        # Form values (port, gamename) override whatever was in the file.
        my @output_lines;
        my %form_overrides = (port => $safe_port, gamename => $safe_game);
        my %seen;
        if (-f $default_cfg) {
            open(my $src, '<', $default_cfg) or &error("Cannot read default config: $!");
            while (<$src>) {
                chomp;
                next if /^\s*$/;            # blank lines
                next if /^\[/;              # bash conditionals
                if (/^\s*#/) {
                    push @output_lines, $_;  # section comment
                } elsif (/^\s*(\w+)\s*=\s*["']?([^"'\n]*)["']?\s*$/) {
                    my ($k, $v) = ($1, $2);
                    $v = $form_overrides{$k} if exists $form_overrides{$k};
                    push @output_lines, "$k=\"$v\"";
                    $seen{$k} = 1;
                }
            }
            close($src);
        }
        # Append any form values not found in _default.cfg
        for my $k (qw(port gamename)) {
            push @output_lines, "$k=\"$form_overrides{$k}\"" unless $seen{$k};
        }

        # Ensure lgsm/config-lgsm/$script_name/ exists
        &system_logged("su -s /bin/bash -c \"mkdir -p \Q$script_dir\E/lgsm/config-lgsm/$script_name\" $unix_user");

        open(my $fh, '>', $config_file) or &error("Cannot write config: $!");
        print $fh "$_\n" for @output_lines;
        close($fh);

        my @pw = getpwnam($unix_user);
        chown($pw[2], $pw[3], $config_file) if @pw;

        # Backup _default.cfg so LGSM regenerates it cleanly on next run
        rename($default_cfg, $backup_cfg) if -f $default_cfg;

        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id));
    }
    elsif ($action eq 'migrate_config') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        my $script_dir  = $inst->{'script'};
        $script_dir =~ s|/[^/]+$||;

        my $common_path = "$script_dir/lgsm/config-lgsm/common.cfg";
        my $script_path = "$script_dir/lgsm/config-lgsm/$script_name/$script_name.cfg";

        &validate_config_target($common_path);
        &validate_config_target($script_path);

        my ($common_vals, $common_order, undef) = &read_config_file($common_path);
        my ($script_vals, $script_order, undef) = &read_config_file($script_path);

        # Move known game fields from common.cfg → $script.cfg
        # Script-side value wins if the key already exists there.
        my @gfields = &get_game_fields($script_name);
        my %gkeys   = map { $_->{'key'} => 1 } @gfields;
        for my $key (keys %gkeys) {
            if (exists $common_vals->{$key} && !exists $script_vals->{$key}) {
                $script_vals->{$key} = $common_vals->{$key};
                push @$script_order, $key;
            }
            delete $common_vals->{$key};  # remove from common regardless
        }

        # Ensure $script subdir exists
        &system_logged("su -s /bin/bash -c \"mkdir -p \Q$script_dir\E/lgsm/config-lgsm/$script_name\" $unix_user");

        # Write $script.cfg
        open(my $fh, '>', $script_path) or &error("Cannot write config: $!");
        for my $k (@$script_order) {
            print $fh "$k=\"$script_vals->{$k}\"\n" if exists $script_vals->{$k};
        }
        close($fh);

        my @pw = getpwnam($unix_user);
        chown($pw[2], $pw[3], $script_path) if @pw;

        # Write back common.cfg; delete if nothing remains
        my @remaining = grep { exists $common_vals->{$_} } @$common_order;
        if (@remaining) {
            open($fh, '>', $common_path) or &error("Cannot write common config: $!");
            print $fh "$_=\"$common_vals->{$_}\"\n" for @remaining;
            close($fh);
            chown($pw[2], $pw[3], $common_path) if @pw;
        } else {
            unlink $common_path;
        }

        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id));
    }
    elsif ($action eq 'save_config') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        my $script_dir  = $inst->{'script'};
        $script_dir =~ s|/[^/]+$||;

        my $cfg_file_key = $in{'config_file'} // '';
        $cfg_file_key = ($cfg_file_key eq 'instance' || $cfg_file_key eq 'common' || $cfg_file_key eq 'game')
            ? $cfg_file_key : 'common';
        my $cfg_view_key = $in{'config_view'} // '';
        $cfg_view_key = ($cfg_view_key eq 'instance' || $cfg_view_key eq 'common' || $cfg_view_key eq 'game')
            ? $cfg_view_key : $cfg_file_key;
        my $cfg_path;
        if ($cfg_file_key eq 'instance') {
            $cfg_path = "$script_dir/lgsm/config-lgsm/$script_name/$script_name.cfg";
        } elsif ($cfg_file_key eq 'game') {
            my %cfg_ctx = &_parse_lgsm_config($script_dir, $script_name);
            $cfg_path = &resolve_game_server_config_path($script_dir, $script_name, \%cfg_ctx);
            &error("Invalid game config path") unless $cfg_path =~ m|^\Q$script_dir\E/|;
        } else {
            $cfg_path = "$script_dir/lgsm/config-lgsm/common.cfg";
        }
        &validate_config_target($cfg_path) unless $cfg_file_key eq 'game';

        # Ensure the parent directory exists
        (my $cfg_dir = $cfg_path) =~ s|/[^/]+$||;
        &system_logged("su -s /bin/bash -c \"mkdir -p \Q$cfg_dir\E\" $unix_user");

        if ($cfg_file_key eq 'game') {
            unless (-f $cfg_path) {
                &run_server_action($unix_user, 'start', $script_name, $script_dir);
                sleep 2;
                &run_server_action($unix_user, 'stop', $script_name, $script_dir);
            }
            -f $cfg_path or &error($text{'config_editor_game_missing'});
            my $new_content;
            if (int($in{'raw_mode'} || 0)) {
                $new_content = $in{'game_config_raw'} // '';
            } else {
                my $raw_base = $in{'game_config_original'} // '';
                my ($opt_vals, $opt_order) = &parse_option_settings_from_ini($raw_base);
                for my $param (keys %in) {
                    next unless $param =~ /^field_(\w+)$/;
                    my $key = $1;
                    my $val = $in{$param} // '';
                    $opt_vals->{$key} = $val;
                    push @$opt_order, $key unless grep { $_ eq $key } @$opt_order;
                }
                $new_content = &update_option_settings_in_ini($raw_base, $opt_vals, $opt_order);
            }
            eval { &write_file_exact($cfg_path, $new_content); 1 }
                or &error("Cannot write config: $!");
        } elsif (int($in{'raw_mode'} || 0)) {
            # Raw mode: filter content and write
            my $raw_lines = &filter_raw_config($in{'config_raw'} // '');
            open(my $fh, '>', $cfg_path) or &error("Cannot write config: $!");
            print $fh "$_\n" for @$raw_lines;
            close($fh);
        } else {
            # Form mode: read current file, apply field_* overrides, write back
            my ($cur_vals, $cur_order, undef) = &read_config_file($cfg_path);

            # Apply form fields (field_<key> params)
            for my $param (keys %in) {
                next unless $param =~ /^field_(\w+)$/;
                my $key = $1;
                my $val = $in{$param} // '';
                $val =~ s/[<>"\\]//g;   # basic sanitize
                $cur_vals->{$key} = $val;
                push @$cur_order, $key unless grep { $_ eq $key } @$cur_order;
            }

            open(my $fh, '>', $cfg_path) or &error("Cannot write config: $!");
            for my $key (@$cur_order) {
                print $fh "$key=\"$cur_vals->{$key}\"\n" if exists $cur_vals->{$key};
            }
            close($fh);
        }

        my @pw = getpwnam($unix_user);
        chown($pw[2], $pw[3], $cfg_path) if @pw;

        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) .
                  "&config_file=" . &html_escape($cfg_file_key) .
                  "&config_view=" . &html_escape($cfg_view_key));
    }
    elsif ($action eq 'delete_instance') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        my $script_dir  = $inst->{'script'};
        $script_dir =~ s|/[^/]+$||;
        my $game_user = $inst->{'user'};

        my @all_before = &list_instances();
        my @other_for_user = grep {
            ($_->{'id'} // '') ne $instance_id && ($_->{'user'} // '') eq $game_user
        } @all_before;

        my $sftp_user = &resolve_instance_sftp_user($instance_id, $game_user);

        # Always remove instance directory
        &system_logged("rm -rf \"\Q$script_dir\E\"");

        # Remove panel registration entry (if tracked)
        &unregister_instance($instance_id);

        # FTP/SFTP cleanup is mandatory for instance deletion
        if ($sftp_user && $sftp_user ne $game_user) {
            my %ftp_state = &discover_ftp_state();
            my $auth_file = $ftp_state{'auth_user_file'} || '/etc/proftpd/ftpd.passwd';
            my $rc = &ftpasswd_delete_user(
                file => $auth_file,
                name => $sftp_user,
            );
            if ($rc != 0) {
                # Fallback for classic system users
                &system_logged("userdel -r $sftp_user");
            }
        }

        # Remove game unix user only if this was the last instance for that user
        if (!@other_for_user) {
            &system_logged("userdel -r $game_user");
        }

        &redirect("index.cgi");
    }
    elsif ($action eq 'create_instance_ftp_user') {
        my %ftp_state  = &discover_ftp_state();
        my $auth_file  = $ftp_state{'auth_user_file'} || '/etc/proftpd/ftpd.passwd';
        my $ftp_user   = 'ftp_' . $unix_user;
        my $ftp_pass   = $in{'ftp_pass'} // '';
        length($ftp_pass) or &error($text{'err_invalid_input'});
        my @pw = getpwnam($unix_user);
        my $uid = @pw ? $pw[2] : 33;
        my $gid = @pw ? $pw[3] : 33;
        my $home = @pw ? $pw[7] : "/home/$unix_user";
        &ftpasswd_create_user(
            file     => $auth_file,
            name     => $ftp_user,
            password => $ftp_pass,
            uid      => $uid,
            gid      => $gid,
            home     => $home,
            shell    => '/bin/false',
        ) == 0 or &error("Failed creating FTP user");
        &register_instance($instance_id, $unix_user, $inst->{'script'}, {
            sftp_user => $ftp_user,
        });
        our $config_directory;
        &save_ftp_password($config_directory, $instance_id, $ftp_pass);
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id));
    }
    elsif ($action eq 'delete_instance_ftp_user') {
        my $ftp_user  = &sanitize_input($in{'ftp_user'});
        my %ftp_state = &discover_ftp_state();
        my $auth_file = $ftp_state{'auth_user_file'} || '/etc/proftpd/ftpd.passwd';
        &ftpasswd_delete_user(file => $auth_file, name => $ftp_user);
        &register_instance($instance_id, $unix_user, $inst->{'script'}, {
            sftp_user => '',
        });
        our $config_directory;
        &delete_ftp_password($config_directory, $instance_id);
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id));
    }
    elsif ($action eq 'init_game_config') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        my $script_dir  = $inst->{'script'};
        $script_dir =~ s|/[^/]+$||;
        my %cfg_ctx = &_parse_lgsm_config($script_dir, $script_name);
        my $cfg_path = &resolve_game_server_config_path($script_dir, $script_name, \%cfg_ctx);

        unless (-f $cfg_path) {
            &run_server_action($unix_user, 'start', $script_name, $script_dir);
            sleep 2;
            &run_server_action($unix_user, 'stop', $script_name, $script_dir);
        }

        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) .
                  "&config_file=game&config_view=game");
    }
    else {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        my $script_dir  = $inst->{'script'};
        $script_dir =~ s|/[^/]+$||;
        &run_server_action($unix_user, $action, $script_name, $script_dir);
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id));
    }
}

my $safe_id = &html_escape($instance_id);
&header("$text{'manage_title'}: $safe_id", '');

# Parse LGSM config to check _has_user_config
my $script_dir_for_cfg = $inst->{'script'};
$script_dir_for_cfg =~ s|/[^/]+$||;
my $script_name_for_cfg = (split('/', $inst->{'script'}))[-1];
my %cfg = &_parse_lgsm_config($script_dir_for_cfg, $script_name_for_cfg);

# Server-Info table
print &ui_table_start($text{'manage_title'}, "width=100%", 2);
print &ui_table_row($text{'manage_game'},   &html_escape($inst->{'game'}));
print &ui_table_row($text{'manage_port'},   int($inst->{'port'}));
print &ui_table_row($text{'manage_status'}, &html_escape($inst->{'status'}));
print &ui_table_row($text{'manage_script'}, &html_escape($inst->{'script'}));
print &ui_table_end();

# Firewall section
my $port = int($inst->{'port'});
my $fw_open = &firewall_status($port);
my ($fw_status_icon, $fw_btn_action, $fw_btn_label);
if ($fw_open) {
    $fw_status_icon = "&#x2705; offen";
    $fw_btn_action  = 'fw_close';
    $fw_btn_label   = $text{'fw_close_btn'};
} else {
    $fw_status_icon = "&#x274C; geschlossen";
    $fw_btn_action  = 'fw_open';
    $fw_btn_label   = $text{'fw_open_btn'};
}

print "<p><b>$text{'manage_fw_status'}:</b> $fw_status_icon &nbsp;";
print &ui_form_start("manage.cgi", "post");
print &ui_hidden("instance_id", $safe_id);
print &ui_hidden("action", $fw_btn_action);
print &ui_submit($fw_btn_label);
print &ui_form_end();
print "</p>\n";

# Control buttons
print "<p>\n";
foreach my $action (qw(start stop restart update)) {
    print &ui_form_start("manage.cgi", "post");
    print &ui_hidden("instance_id", $safe_id);
    print &ui_hidden("action",      $action);
    print &ui_submit($text{"manage_$action"});
    print &ui_form_end();
    print " ";
}
print "</p>\n";

print "<p>\n";
print &ui_form_start("manage.cgi", "post");
print &ui_hidden("instance_id", $safe_id);
print &ui_hidden("action", "delete_instance");
print &ui_submit($text{'manage_delete_btn'});
print &ui_form_end();
print "</p>\n";

# FTP section
{
    my $cur_ftp_user = &resolve_instance_sftp_user($instance_id, $unix_user);
    print "<h3>FTP</h3>\n";
    if ($cur_ftp_user && $cur_ftp_user ne $unix_user) {
        our $config_directory;
        my $stored_pass = &read_ftp_password($config_directory, $instance_id);
        print &ui_table_start('', undef, 2);
        print &ui_table_row($text{'ftp_col_user'}, &html_escape($cur_ftp_user));
        if (defined $stored_pass && $stored_pass ne '') {
            print &ui_table_row($text{'ftp_pass'}, '<code>' . &html_escape($stored_pass) . '</code>');
        }
        print &ui_table_end();
        print &ui_form_start("manage.cgi", "post");
        print &ui_hidden("instance_id", $safe_id);
        print &ui_hidden("action", "delete_instance_ftp_user");
        print &ui_hidden("ftp_user", $cur_ftp_user);
        print &ui_submit($text{'ftp_delete_btn'}, undef, 0, undef, 'btn-danger');
        print &ui_form_end();
    } else {
        my $default_name = &html_escape('ftp_' . $unix_user);
        print &ui_form_start("manage.cgi", "post");
        print &ui_hidden("instance_id", $safe_id);
        print &ui_hidden("action", "create_instance_ftp_user");
        print &ui_table_start('', undef, 2);
        print &ui_table_row($text{'ftp_col_user'}, "<code>$default_name</code>");
        print &ui_table_row($text{'ftp_pass'}, &ui_password('ftp_pass', '', 24));
        print &ui_table_end();
        print &ui_submit($text{'ftp_create_btn'});
        print &ui_form_end();
    }
}

# Detect if common.cfg contains misplaced instance-specific fields
my $common_cfg_path = "$script_dir_for_cfg/lgsm/config-lgsm/common.cfg";
my ($common_chk, undef, undef) = &read_config_file($common_cfg_path);
my %gkeys_chk = map { $_->{'key'} => 1 } &get_game_fields($script_name_for_cfg);
my $has_misplaced = scalar grep { $gkeys_chk{$_} } keys %$common_chk;

# Warnings section
my @warnings = @{$inst->{'warnings'} || []};
if (!$cfg{_has_instance_config}) {
    push @warnings, $text{'manage_fix_config_warn'};
}
if ($has_misplaced) {
    push @warnings, $text{'manage_migrate_warn'};
}

if (@warnings) {
    print "<h3>&#x26A0; $text{'health_warn_header'}</h3>\n";
    print "<ul>\n";
    for my $w (@warnings) {
        print "<li>" . &html_escape($w) . "</li>\n";
    }
    print "</ul>\n";
}

# Migrate-Config form (if game fields are misplaced in common.cfg)
if ($has_misplaced) {
    print &ui_form_start("manage.cgi", "post");
    print &ui_hidden("instance_id", $safe_id);
    print &ui_hidden("action", "migrate_config");
    print &ui_submit($text{'manage_migrate_btn'});
    print &ui_form_end();
}

# Quick-Fix form (only if no real instance config)
if (!$cfg{_has_instance_config}) {
    my $cur_port = int($inst->{'port'}) || '';
    my $cur_game = ($inst->{'game'} // 'unknown') eq 'unknown' ? '' : &html_escape($inst->{'game'});
    print &ui_form_start("manage.cgi", "post");
    print &ui_hidden("instance_id", $safe_id);
    print &ui_hidden("action", "fix_config");
    print &ui_table_start($text{'manage_fix_config_btn'}, undef, 2);
    print &ui_table_row($text{'manage_port'}, &ui_textbox('port',     $cur_port, 10));
    print &ui_table_row($text{'manage_game'}, &ui_textbox('gamename', $cur_game, 30));
    print &ui_table_end();
    print &ui_submit($text{'manage_fix_config_btn'});
    print &ui_form_end();
}

# Config editor section
{
    my $cfg_file_key = $in{'config_file'} // '';
    $cfg_file_key = ($cfg_file_key eq 'common' || $cfg_file_key eq 'instance' || $cfg_file_key eq 'game')
        ? $cfg_file_key : 'common';
    my $cfg_view_key = $in{'config_view'} // '';
    if ($cfg_view_key ne 'common' && $cfg_view_key ne 'instance' && $cfg_view_key ne 'game') {
        $cfg_view_key = $cfg_file_key;
    }
    my $common_path   = "$script_dir_for_cfg/lgsm/config-lgsm/common.cfg";
    my $instance_path = "$script_dir_for_cfg/lgsm/config-lgsm/$script_name_for_cfg/$script_name_for_cfg.cfg";
    my $game_cfg_path = &resolve_game_server_config_path($script_dir_for_cfg, $script_name_for_cfg, \%cfg);
    my $server_root_path = $script_dir_for_cfg;
    my $fileman_path = $server_root_path;
    $fileman_path =~ s/([^A-Za-z0-9\-_.~\/])/sprintf("%%%02X", ord($1))/ge;
    my $fileman_url = "/filemin/?path=$fileman_path";
    my ($common_vals, $common_order, $common_raw) = &read_config_file($common_path);
    my ($inst_vals, $inst_order, $inst_raw) = &read_config_file($instance_path);
    my $game_raw = '';
    my $game_cfg_exists = 0;
    if ($game_cfg_path && -f $game_cfg_path) {
        $game_cfg_exists = 1;
        if (open(my $gfh, '<', $game_cfg_path)) {
            local $/;
            $game_raw = <$gfh>;
            close($gfh);
        }
    }
    my @game_fields = &get_game_fields($script_name_for_cfg);
    my $profile_name = &get_game_display_name($script_name_for_cfg);

    my $lang = $current_lang // 'en';
    # Open the <details> block when the user navigated to the editor
    my $open_attr = defined($in{'config_file'}) ? ' open' : '';

    print "<details$open_attr>\n";
    print "<summary><b>$text{'config_editor_title'}</b></summary>\n";
    print "<p>" . &html_escape($text{'config_editor_profile'}) . " <b>" .
          &html_escape($profile_name) . "</b> " .
          &html_escape($text{'config_editor_profile_source'}) .
          " <code>src/lib/games_meta.json</code></p>\n";
    print "<p><b>" . &html_escape($text{'config_editor_common_path'}) . "</b> <code>" .
          &html_escape($common_path) . "</code><br>\n";
    print "<b>" . &html_escape($text{'config_editor_instance_path'}) . "</b> <code>" .
          &html_escape($instance_path) . "</code><br>\n";
    print "<b>" . &html_escape($text{'config_editor_game_path'}) . "</b> <code>" .
          &html_escape($game_cfg_path) . "</code><br>\n";
    print "<b>" . &html_escape($text{'config_editor_server_root'}) . "</b> <code>" .
          &html_escape($server_root_path) . "</code> &nbsp;" .
          "<a href='" . &html_escape($fileman_url) . "'>" .
          &html_escape($text{'config_editor_open_fileman'}) . "</a></p>\n";

    print <<'JS';
<script>
function lgsmShowConfigView(view) {
    var views = ['common', 'instance', 'game'];
    for (var i = 0; i < views.length; i++) {
        var id = views[i];
        var panel = document.getElementById('cfg_panel_' + id);
        var btn = document.getElementById('cfg_btn_' + id);
        if (panel) panel.style.display = (id === view) ? 'block' : 'none';
        if (btn) btn.disabled = (id === view);
    }
}
function lgsmToggleRaw(view, cb) {
    var f = document.getElementById('cfg_form_div_' + view);
    var r = document.getElementById('cfg_raw_div_' + view);
    if (!f || !r) return;
    if (cb.checked) { f.style.display='none'; r.style.display='block'; }
    else            { f.style.display='block'; r.style.display='none'; }
}
</script>
JS

    print "<p>";
    print "<input type='button' class='ui_submit' id='cfg_btn_common' ".
          "onclick=\"lgsmShowConfigView('common')\" value='" .
          &html_escape($text{'config_editor_global_btn'}) . "'> ";
    print "<input type='button' class='ui_submit' id='cfg_btn_instance' ".
          "onclick=\"lgsmShowConfigView('instance')\" value='" .
          &html_escape($text{'config_editor_instance_btn'}) . "'> ";
    print "<input type='button' class='ui_submit' id='cfg_btn_game' ".
          "onclick=\"lgsmShowConfigView('game')\" value='" .
          &html_escape($text{'config_editor_game_btn'}) . "'>";
    print "</p>\n";

    # Common LGSM config panel
    my ($common_editable, $common_unknown, undef) =
        &split_editor_fields('common', \@game_fields, $common_vals, $common_order);
    print "<div id='cfg_panel_common' style='display:none'>\n";
    print "<p><b>" . &html_escape($text{'config_editor_common_notice'}) . "</b></p>\n";
    print &ui_form_start("manage.cgi", "post");
    print &ui_hidden("instance_id", $safe_id);
    print &ui_hidden("action",      "save_config");
    print &ui_hidden("config_file", "common");
    print &ui_hidden("config_view", "common");
    print "<p><label>";
    print "<input type='checkbox' id='raw_mode_cb_common' name='raw_mode' value='1' ";
    print "onchange=\"lgsmToggleRaw('common', this)\"> ";
    print "$text{'config_editor_raw_mode'}</label></p>\n";
    print "<div id='cfg_form_div_common'>\n";
    print &ui_table_start($text{'config_editor_common'}, "width=100%", 2);
    if (@$common_unknown) {
        for my $key (@$common_unknown) {
            my $val = $common_vals->{$key} // '';
            print &ui_table_row(&html_escape($key),
                                &ui_textbox("field_$key", &html_escape($val), 40));
        }
    } else {
        print &ui_table_row(&html_escape($text{'config_editor_unknown_fields'}), '-');
    }
    print &ui_table_end();
    print "</div>\n";
    print "<div id='cfg_raw_div_common' style='display:none'>\n";
    print &ui_textarea("config_raw", $common_raw, 20, 72);
    print "</div>\n";
    print &ui_submit($text{'config_editor_save'});
    print &ui_form_end();
    print "</div>\n";

    # Instance LGSM config panel
    my ($inst_editable, $inst_unknown, undef) =
        &split_editor_fields('instance', \@game_fields, $inst_vals, $inst_order);
    print "<div id='cfg_panel_instance' style='display:none'>\n";
    print &ui_form_start("manage.cgi", "post");
    print &ui_hidden("instance_id", $safe_id);
    print &ui_hidden("action",      "save_config");
    print &ui_hidden("config_file", "instance");
    print &ui_hidden("config_view", "instance");
    print "<p><label>";
    print "<input type='checkbox' id='raw_mode_cb_instance' name='raw_mode' value='1' ";
    print "onchange=\"lgsmToggleRaw('instance', this)\"> ";
    print "$text{'config_editor_raw_mode'}</label></p>\n";
    print "<div id='cfg_form_div_instance'>\n";
    print &ui_table_start($text{'config_editor_instance'}, "width=100%", 2);
    for my $f (@$inst_editable) {
        my $key   = $f->{'key'};
        my $label = (($lang eq 'de') ? $f->{'label_de'} : $f->{'label_en'}) // $key;
        my $val   = exists $inst_vals->{$key} ? $inst_vals->{$key} : ($f->{'default'} // '');
        my $width = ($f->{'type'} eq 'port' || $f->{'type'} eq 'int') ? 10 : 40;
        print &ui_table_row(&html_escape($label),
                            &ui_textbox("field_$key", &html_escape($val), $width));
    }
    if (@$inst_unknown) {
        print &ui_table_row("<b>$text{'config_editor_unknown_fields'}</b>", "");
        for my $key (@$inst_unknown) {
            my $val = $inst_vals->{$key} // '';
            print &ui_table_row(&html_escape($key),
                                &ui_textbox("field_$key", &html_escape($val), 40));
        }
    }
    print &ui_table_end();
    print "</div>\n";
    print "<div id='cfg_raw_div_instance' style='display:none'>\n";
    print &ui_textarea("config_raw", $inst_raw, 20, 72);
    print "</div>\n";
    print &ui_submit($text{'config_editor_save'});
    print &ui_form_end();
    print "</div>\n";

    # Game server config panel (game-specific fields on instance config)
    print "<div id='cfg_panel_game' style='display:none'>\n";
    if (!$game_cfg_exists) {
        print "<p><b>" . &html_escape($text{'config_editor_game_missing'}) . "</b></p>\n";
        print &ui_form_start("manage.cgi", "post");
        print &ui_hidden("instance_id", $safe_id);
        print &ui_hidden("action", "init_game_config");
        print &ui_submit($text{'config_editor_game_create_btn'});
        print &ui_form_end();
    } else {
        my ($game_vals, $game_order) = &parse_option_settings_from_ini($game_raw);
        print &ui_form_start("manage.cgi", "post");
        print &ui_hidden("instance_id", $safe_id);
        print &ui_hidden("action",      "save_config");
        print &ui_hidden("config_file", "game");
        print &ui_hidden("config_view", "game");
        print &ui_hidden("game_config_original", $game_raw);
        print "<p>" . &html_escape($text{'config_editor_game_notice'}) . "</p>\n";
        print "<p><label>";
        print "<input type='checkbox' id='raw_mode_cb_game' name='raw_mode' value='1' ";
        print "onchange=\"lgsmToggleRaw('game', this)\"> ";
        print "$text{'config_editor_raw_mode'}</label></p>\n";
        print "<div id='cfg_form_div_game'>\n";
        print &ui_table_start($text{'config_editor_game_btn'}, "width=100%", 2);
        if (@$game_order) {
            for my $key (@$game_order) {
                my $val = $game_vals->{$key} // '';
                print &ui_table_row(&html_escape($key),
                                    &ui_textbox("field_$key", &html_escape($val), 40));
            }
        } else {
            print &ui_table_row(&html_escape($text{'config_editor_game_no_fields'}), '-');
        }
        print &ui_table_end();
        print "</div>\n";
        print "<div id='cfg_raw_div_game' style='display:none'>\n";
        print &ui_textarea("game_config_raw", $game_raw, 22, 90);
        print "</div>\n";
        print &ui_submit($text{'config_editor_save'});
        print &ui_form_end();
    }
    print "</div>\n";

    print "<script>lgsmShowConfigView('" . &html_escape($cfg_view_key) . "');</script>\n";

    print "</details>\n";
}

&footer('index.cgi', $text{'index_title'});
