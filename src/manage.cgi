#!/usr/bin/perl
# -------------------------------------------------------------------------
# LinuxGSM Webcore - Webmin Module
# Copyright (C) 2026 Christian Möllmann knoelliX 128321164+knoellix@users.noreply.github.com
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License.
# -------------------------------------------------------------------------
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
require './lib/steam.pl';
require './lib/jobs.pl';
require './lib/logging.pl';
require './lib/error_hints.pl';

our (%text, %config, %in, %gconfig);
our ($module_root, $module_root_directory, $config_directory, $module_name);
our $current_lang;
$module_root ||= $module_root_directory;
$module_root ||= do { (my $d = __FILE__) =~ s{/[^/]+$}{}; $d };
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

sub _parse_script_info {
    my ($inst) = @_;
    my $script_path = $inst->{'script'} // '';
    my ($script_name) = $script_path =~ m{/([^/]+)$};
    $script_name //= '';
    (my $server_dir = $script_path) =~ s{/[^/]+$}{};
    $script_name =~ s/[^a-zA-Z0-9_-]//g;
    return ($script_path, $script_name, $server_dir);
}

my $instance_id = &sanitize_input($in{'instance_id'} || $in{'user'} || '');
my $inst = &get_instance_flexible($instance_id) or &error($text{'err_not_found'});
my $unix_user = $inst->{'user'};
my $is_fresh  = ($inst->{'instance_status'} // 'installed') ne 'installed';

&user_can_manage($instance_id)
    or &error($text{'err_acl_admin_only'} || 'Access denied');

if ($in{'action'} && $in{'action'} !~ /^(?:poll_job|monitor)$/) {
    my $action = &sanitize_input($in{'action'});
    &log_debug("action=$action instance=$instance_id");
    if (&user_is_readonly($instance_id)) {
        &error($text{'err_readonly'} || 'This server is read-only for your account');
    }

    if ($action eq 'fw_open') {
        my $port = int($inst->{'port'});
        &firewall_open_port($port, 'tcp');
        &firewall_open_port($port, 'udp');
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'fw_close') {
        my $port = int($inst->{'port'});
        &firewall_close_port($port, 'tcp');
        &firewall_close_port($port, 'udp');
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
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

        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
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

        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
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
                my $fmt = &detect_game_config_format($cfg_path, $raw_base);
                if ($fmt eq 'properties') {
                    my ($prop_vals, $prop_order) = &parse_properties_file($raw_base);
                    for my $key (@$prop_order) {
                        $prop_vals->{$key} = $in{"field_$key"}
                            if exists $in{"field_$key"};
                    }
                    $new_content = &update_properties_file($raw_base, $prop_vals);
                } else {
                    # Default: Palworld-style OptionSettings INI
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

        &log_action('config_saved', $instance_id, {config_type => $cfg_file_key});
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) .
                  "&config_file=" . &html_escape($cfg_file_key) .
                  "&config_view=" . &html_escape($cfg_view_key) .
                  "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'delete_instance') {
        &is_admin() or &error($text{'err_acl_admin_only'} || 'Access denied');
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

        &redirect("index.cgi?xnavigation=1");
        exit;
    }
    elsif ($action eq 'create_instance_ftp_user') {
        &can_manage_ftp() or &error($text{'err_acl_admin_only'} || 'Access denied');
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
        &save_ftp_password($config_directory, $instance_id, $ftp_pass);
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'delete_instance_ftp_user') {
        &can_manage_ftp() or &error($text{'err_acl_admin_only'} || 'Access denied');
        my $ftp_user  = &sanitize_input($in{'ftp_user'});
        my %ftp_state = &discover_ftp_state();
        my $auth_file = $ftp_state{'auth_user_file'} || '/etc/proftpd/ftpd.passwd';
        &ftpasswd_delete_user(file => $auth_file, name => $ftp_user);
        &register_instance($instance_id, $unix_user, $inst->{'script'}, {
            sftp_user => '',
        });
        &delete_ftp_password($config_directory, $instance_id);
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'save_steam_account') {
        &can_create() or &error($text{'err_acl_admin_only'} || 'Access denied');
        my $sa = $in{'steam_account'} // '';
        $sa =~ s/[^a-zA-Z0-9_\-]//g;
        $sa = substr($sa, 0, 64);
        &register_instance($instance_id, $unix_user, $inst->{'script'}, {
            steam_account => $sa,
        });
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'setup_lgsm') {
        my $reg = &get_registered_instance($instance_id) or &error($text{'err_not_found'});
        my $script_path = $reg->{'script'} // '';
        my $script_name = (split('/', $script_path))[-1] // '';
        (my $server_dir = $script_path) =~ s|/[^/]+$||;
        $script_name =~ s/[^a-zA-Z0-9_-]//g;

        my $job_id = &create_job();
        my $worker = "$module_root/scripts/setup_lgsm.sh";
        write_job_meta($job_id, $instance_id, 'setup_lgsm', $unix_user);
        &log_action('job_started', $job_id, {instance_id => $instance_id, action => 'setup_lgsm'});
        &system_logged("setsid nohup bash '$worker' '$config_directory/jobs/$job_id' '$unix_user' '$server_dir' '$script_name' >/dev/null 2>&1 &");
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=poll_job&job=" . &html_escape($job_id) . "&next_status=lgsm_ready&xnavigation=1");
        exit;
    }
    elsif ($action eq 'install_game') {
        &can_create() or &error($text{'err_acl_admin_only'} || 'Access denied');
        my $reg = &get_registered_instance($instance_id) or &error($text{'err_not_found'});
        my $source = $reg->{'source'} // 'lgsm';
        my ($script_path, $script_name, $server_dir) = _parse_script_info($reg);

        my $job_id = &create_job();
        write_job_meta($job_id, $instance_id, 'install_game', $unix_user);
        &log_action('job_started', $job_id, {instance_id => $instance_id, action => 'install_game'});

        if ($source eq 'steamcmd') {
            my $app_id = $reg->{'steam_app_id'} // '';
            if (!$app_id) {
                my %gmeta = load_games_meta();
                my $game_key = $reg->{'cached_game'} || $script_name;
                $app_id = $gmeta{$game_key}{'steam_app_id'} // '';
            }
            $app_id =~ s/[^0-9]//g;
            my $steamcmd_path = &detect_steamcmd() // 'steamcmd';
            my $cmd = "MODULE_ROOT='$module_root' STEAMCMD_PATH='$steamcmd_path' setsid nohup bash '$module_root/scripts/steamcmd_install.sh' '$config_directory/jobs/$job_id' '$unix_user' '$server_dir' '$app_id' >/dev/null 2>&1 &";
            &log_debug("install_game steamcmd: module_root=$module_root steamcmd=$steamcmd_path server_dir=$server_dir app_id=$app_id cmd=$cmd");
            &system_logged($cmd);
        } else {
            my $cmd2 = "setsid nohup bash '$module_root/scripts/game_action.sh' '$config_directory/jobs/$job_id' '$unix_user' '$server_dir' '$script_name' install >/dev/null 2>&1 &";
            &log_debug("install_game lgsm: module_root=$module_root server_dir=$server_dir cmd=$cmd2");
            &system_logged($cmd2);
        }
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id)
            . "&action=poll_job&job=" . &html_escape($job_id)
            . "&next_status=installed&xnavigation=1");
        exit;
    }
    elsif ($action eq 'update') {
        my $source = $inst->{'source'} // 'lgsm';
        my ($script_path, $script_name, $server_dir) = _parse_script_info($inst);

        my $job_id = &create_job();
        write_job_meta($job_id, $instance_id, 'update', $unix_user);
        &log_action('job_started', $job_id, {instance_id => $instance_id, action => 'update'});

        if ($source eq 'steamcmd') {
            &system_logged("MODULE_ROOT='$module_root' setsid nohup bash '$module_root/scripts/steamcmd_control.sh' update '$config_directory/jobs/$job_id' '$unix_user' '$server_dir' >/dev/null 2>&1 &");
        } else {
            &system_logged("setsid nohup bash '$module_root/scripts/game_action.sh' '$config_directory/jobs/$job_id' '$unix_user' '$server_dir' '$script_name' update >/dev/null 2>&1 &");
        }
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=poll_job&job=" . &html_escape($job_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'validate') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        (my $server_dir = $inst->{'script'}) =~ s|/[^/]+$||;
        $script_name =~ s/[^a-zA-Z0-9_-]//g;

        my $job_id = &create_job();
        write_job_meta($job_id, $instance_id, 'validate', $unix_user);
        &log_action('job_started', $job_id, {instance_id => $instance_id, action => 'validate'});
        my $worker = "$module_root/scripts/game_action.sh";
        &system_logged("setsid nohup bash '$worker' '$config_directory/jobs/$job_id' '$unix_user' '$server_dir' '$script_name' validate >/dev/null 2>&1 &");
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=poll_job&job=" . &html_escape($job_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'reinstall') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        (my $server_dir = $inst->{'script'}) =~ s|/[^/]+$||;
        $script_name =~ s/[^a-zA-Z0-9_-]//g;

        my $job_id = &create_job();
        write_job_meta($job_id, $instance_id, 'reinstall', $unix_user);
        &log_action('job_started', $job_id, {instance_id => $instance_id, action => 'reinstall'});
        my $worker = "$module_root/scripts/game_action.sh";
        &system_logged("setsid nohup bash '$worker' '$config_directory/jobs/$job_id' '$unix_user' '$server_dir' '$script_name' reinstall >/dev/null 2>&1 &");
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=poll_job&job=" . &html_escape($job_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'abort_job') {
        my $job_id = $in{'job'} // '';
        $job_id =~ s/[^0-9a-f]//g;
        $job_id or &error($text{'err_invalid_input'});
        abort_job($job_id);
        &log_action('job_aborted', $job_id, {instance_id => $instance_id});
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
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
                  "&config_file=game&config_view=game&xnavigation=1");
        exit;
    }
    elsif ($action eq 'start' || $action eq 'stop') {
        my $source = $inst->{'source'} // 'lgsm';
        my ($script_path, $script_name, $server_dir) = _parse_script_info($inst);

        if ($source eq 'steamcmd') {
            my $job_id = &create_job();
            write_job_meta($job_id, $instance_id, $action, $unix_user);
            &log_action('job_started', $job_id, {instance_id => $instance_id, action => $action});
            &system_logged("MODULE_ROOT='$module_root' setsid nohup bash '$module_root/scripts/steamcmd_control.sh' '$action' '$config_directory/jobs/$job_id' '$unix_user' '$server_dir' >/dev/null 2>&1 &");
            &redirect("manage.cgi?instance_id=" . &html_escape($instance_id)
                . "&action=poll_job&job=" . &html_escape($job_id) . "&xnavigation=1");
            exit;
        } else {
            &run_server_action($unix_user, $action, $script_name, $server_dir);
            &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
            exit;
        }
    }
    else {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        my $script_dir  = $inst->{'script'};
        $script_dir =~ s|/[^/]+$||;
        &run_server_action($unix_user, $action, $script_name, $script_dir);
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
}

# GET: poll_job
if (($in{'action'} // '') eq 'poll_job') {
    my $job_id = $in{'job'} // '';
    $job_id =~ s/[^0-9a-f]//g;
    $job_id = substr($job_id, 0, 16);
    my $next_status = $in{'next_status'} // '';
    $next_status =~ s/[^a-z_]//g;

    &timeout_check_job($job_id);
    my $status = &get_job_status($job_id) // 'unknown';
    my ($all_out, undef) = &get_job_output($job_id, 0);  # always read all output from start

    if ($status eq 'ok' && $next_status) {
        &set_instance_status($instance_id, $next_status);
    }

    &header($text{'job_output_title'}, '');
    print "<h3>" . &html_escape($text{'job_output_title'}) . "</h3>\n";

    if ($status eq 'running') {
        my $poll_url = "manage.cgi?instance_id=" . &html_escape($instance_id)
            . "&action=poll_job&job=" . &html_escape($job_id)
            . "&next_status=" . &html_escape($next_status)
            . "&xnavigation=1";
        print "<meta http-equiv=\"refresh\" content=\"3;url=$poll_url\">\n";
        print "<p>" . &html_escape($text{'job_running'}) . "</p>\n";
        print &ui_form_start('manage.cgi', 'post', undef,
            "onsubmit=\"return confirm('" . &html_escape($text{'jobs_abort_confirm'} || 'Abbrechen?') . "')\"");
        print &ui_hidden('instance_id', &html_escape($instance_id));
        print &ui_hidden('action', 'abort_job');
        print &ui_hidden('job', &html_escape($job_id));
        print &ui_submit($text{'jobs_abort_btn'} || 'Abbrechen', undef, undef, undef, 'btn-danger');
        print &ui_form_end();
    } elsif ($status eq 'ok') {
        print "<p style='color:green'>" . &html_escape($text{'job_ok'}) . "</p>\n";
        print "<p><a href=\"manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1\">&larr; Zur&uuml;ck</a></p>\n";
    } else {
        my $hint_key = &get_job_error_hint($job_id);
        print "<p style='color:red'>" . &html_escape($text{'job_failed'}) . "</p>\n";
        if ($hint_key) {
            print "<p><strong>" . &html_escape($text{'job_hint_title'}) . ":</strong> "
                . &html_escape($text{$hint_key} // $hint_key) . "</p>\n";
        }
        print "<p><a href=\"manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1\">&larr; Zur&uuml;ck</a></p>\n";
    }

    print "<h3>" . &html_escape($text{'job_output_title'} || 'Ausgabe') . "</h3>\n";
    if (defined $all_out && $all_out ne '') {
        print "<pre id='job_out' style='background:#111;color:#eee;padding:8px;overflow:auto;max-height:500px'>"
            . &html_escape($all_out) . "</pre>\n";
        print "<script>var p=document.getElementById('job_out');if(p)p.scrollTop=p.scrollHeight;</script>\n";
    } elsif ($status eq 'running') {
        print "<p style='color:gray'><i>Warte auf Worker-Ausgabe…</i></p>\n";
    }
    &footer('', '');
    exit;
}

# GET: monitor
if (($in{'action'} // '') eq 'monitor') {
    my $script_name = (split('/', $inst->{'script'}))[-1] // '';
    (my $script_dir = $inst->{'script'}) =~ s|/[^/]+$||;

    my @log_candidates = (
        "$script_dir/log/console/${script_name}-console.log",
        "$script_dir/log/script/${script_name}.log",
        "$script_dir/log/${script_name}.log",
    );
    my ($log_file) = grep { -f $_ } @log_candidates;

    &header($text{'manage_monitor_title'}, '');
    print "<h3>" . &html_escape($text{'manage_monitor_title'}) . "</h3>\n";

    if (!$log_file) {
        print "<p>" . &html_escape($text{'manage_monitor_no_log'}) . "</p>\n";
    } else {
        open(my $f, '<', $log_file) or do { print "<p>Logdatei nicht lesbar.</p>\n"; &footer('',''); exit; };
        my $content = do { local $/; <$f> };
        close($f);
        $content //= '';
        my $len  = length($content);
        my $tail = $len > 8192 ? substr($content, $len - 8192) : $content;
        my $refresh_url = "manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=monitor&xnavigation=1";
        print "<meta http-equiv=\"refresh\" content=\"2;url=$refresh_url\">\n";
        print "<pre style='background:#111;color:#eee;padding:8px;height:500px;overflow:auto'>"
            . &html_escape($tail) . "</pre>\n";
    }
    &footer('', '');
    exit;
}

# Setup-Phase for fresh/lgsm_ready instances
if ($is_fresh) {
    my $istatus = $inst->{'instance_status'} // 'fresh';
    my $source  = $inst->{'source'} // 'provisioned';
    &header($text{'setup_phase_title'}, '');
    print "<h3>" . &html_escape($text{'setup_phase_title'}) . "</h3>\n";

    if ($source eq 'steamcmd') {
        # steamcmd games skip LGSM setup — install directly via SteamCMD
        print &ui_form_start('manage.cgi', 'post');
        print &ui_hidden('instance_id', &html_escape($instance_id));
        print &ui_hidden('action', 'install_game');
        print &ui_submit($text{'setup_install_game_btn'} || 'Spiel installieren', undef, undef, undef, 'btn-primary');
        print &ui_form_end();
    } elsif ($istatus eq 'fresh') {
        print &ui_form_start('manage.cgi', 'post');
        print &ui_hidden('instance_id', &html_escape($instance_id));
        print &ui_hidden('action', 'setup_lgsm');
        print &ui_submit($text{'setup_install_lgsm_btn'}, undef, undef, undef, 'btn-primary');
        print &ui_form_end();
    } elsif ($istatus eq 'lgsm_ready') {
        print "<p style='color:green'>&#x2705; LGSM installiert.</p>\n";
        print &ui_form_start('manage.cgi', 'post');
        print &ui_hidden('instance_id', &html_escape($instance_id));
        print &ui_hidden('action', 'install_game');
        print &ui_submit($text{'setup_install_game_btn'}, undef, undef, undef, 'btn-primary');
        print &ui_form_end();
    }

    &footer('', '');
    exit;
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
foreach my $action (qw(start stop restart)) {
    print &ui_form_start("manage.cgi", "post");
    print &ui_hidden("instance_id", $safe_id);
    print &ui_hidden("action",      $action);
    print &ui_submit($text{"manage_$action"});
    print &ui_form_end();
    print " ";
}
print "</p>\n";

# Update/Validate
print &ui_form_start('manage.cgi', 'post');
print &ui_hidden('instance_id', $safe_id);
print &ui_hidden('action', 'update');
print &ui_submit($text{'manage_update_btn'}, undef, undef, undef, 'btn-default');
print &ui_form_end();

print &ui_form_start('manage.cgi', 'post');
print &ui_hidden('instance_id', $safe_id);
print &ui_hidden('action', 'validate');
print &ui_submit($text{'manage_validate_btn'}, undef, undef, undef, 'btn-default');
print &ui_form_end();

# Monitor link
print "<a href=\"manage.cgi?instance_id=" . $safe_id . "&action=monitor\" class=\"btn btn-default\">"
    . &html_escape($text{'manage_monitor_btn'}) . "</a>\n";

# Reinstall (destructive)
print &ui_form_start('manage.cgi', 'post');
print &ui_hidden('instance_id', $safe_id);
print &ui_hidden('action', 'reinstall');
print &ui_submit($text{'manage_reinstall_btn'}, undef, undef, undef, 'btn-danger');
print &ui_form_end();

print "<p>\n";
print &ui_form_start("manage.cgi", "post");
print &ui_hidden("instance_id", $safe_id);
print &ui_hidden("action", "delete_instance");
print &ui_submit($text{'manage_delete_btn'}, undef, 0, undef, 'btn-danger');
print &ui_form_end();
print "</p>\n";

# FTP section
{
    my $cur_ftp_user = &resolve_instance_sftp_user($instance_id, $unix_user);
    print "<h3>FTP</h3>\n";
    if ($cur_ftp_user && $cur_ftp_user ne $unix_user) {
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

# Steam account section — shown for all servers
{
    my $sa        = $inst->{'steam_account'} // '';
    my $sa_status = $sa ? (&get_steam_account_status($sa) // '') : '';
    my $accounts  = &load_steam_accounts();
    my @ok        = grep { $_->{'status'} eq 'ok' } @$accounts;

    print "<h3>" . &html_escape($text{'steam_manage_section'}) . "</h3>\n";
    print &ui_table_start(undef, undef, 2);

    if ($sa) {
        my $badge = $sa_status eq 'ok'            ? '&#x2705; ' . &html_escape($text{'steam_status_ok'})
                  : $sa_status eq 'token_expired' ? '&#x26A0;&#xFE0F; ' . &html_escape($text{'steam_status_expired'})
                  :                                 '&#x23F3; ' . &html_escape($text{'steam_status_pending'});
        print &ui_table_row(&html_escape($text{'steam_account_label'}), &html_escape($sa) . " \x{2014} " . $badge);
    } else {
        print &ui_table_row(&html_escape($text{'steam_account_label'}), &html_escape($text{'steam_manage_no_account'}));
    }
    print &ui_table_end();

    if (@ok) {
        my @sopts = (['', '— ' . &html_escape($text{'steam_no_account_opt'} || 'Kein Account') . ' —'],
                     map { [$_->{'username'}, &html_escape($_->{'display_name'} || $_->{'username'})] } @ok);
        print &ui_form_start('manage.cgi', 'post');
        print &ui_hidden('action',      'save_steam_account');
        print &ui_hidden('instance_id', &html_escape($instance_id));
        print &ui_select('steam_account', $sa, \@sopts);
        print " ";
        print &ui_submit($text{'acl_manage_save'} || 'Speichern', undef, undef, undef, 'btn-default');
        print &ui_form_end();
    }

    if ($sa && $sa_status ne 'ok') {
        print &ui_form_start('steam_settings.cgi', 'get');
        print &ui_hidden('action',   'relogin_form');
        print &ui_hidden('instance', &html_escape($instance_id));
        print &ui_submit($text{'steam_relogin_btn'}, undef, undef, undef, 'btn-warning');
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
        # Choose parser based on file format
        my $game_fmt = &detect_game_config_format($game_cfg_path, $game_raw)
                    || &get_game_config_format($script_name_for_cfg);
        my ($game_vals, $game_order);
        if ($game_fmt eq 'properties') {
            ($game_vals, $game_order) = &parse_properties_file($game_raw);
        } else {
            ($game_vals, $game_order) = &parse_option_settings_from_ini($game_raw);
        }
        # Known fields from games_meta (game config section) for labelled display
        my @gcf = &get_game_config_fields($script_name_for_cfg);
        my %gcf_map = map { $_->{'key'} => $_ } @gcf;
        my @known_shown = @gcf ? @gcf : ();
        my %known_keys  = map { $_->{'key'} => 1 } @gcf;
        # Unknown keys: present in file but not in game_config_fields
        my @extra_keys  = @gcf ? (grep { !$known_keys{$_} } @$game_order) : @$game_order;

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
        if (@known_shown || @extra_keys) {
            # Labelled known fields first
            for my $f (@known_shown) {
                my $key   = $f->{'key'};
                my $label = (($lang eq 'de') ? $f->{'label_de'} : $f->{'label_en'}) // $key;
                my $val   = exists $game_vals->{$key} ? $game_vals->{$key} : '';
                my $width = ($f->{'type'} eq 'port' || $f->{'type'} eq 'int') ? 10 : 40;
                print &ui_table_row(&html_escape($label),
                                    &ui_textbox("field_$key", &html_escape($val), $width));
            }
            # Remaining / unlabelled keys
            if (@extra_keys) {
                print &ui_table_row("<b>$text{'config_editor_unknown_fields'}</b>", "")
                    if @known_shown;
                for my $key (@extra_keys) {
                    my $val = $game_vals->{$key} // '';
                    print &ui_table_row(&html_escape($key),
                                        &ui_textbox("field_$key", &html_escape($val), 40));
                }
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

# Per-instance job list (operators and admins only)
unless (&user_is_readonly($instance_id)) {
    my @inst_jobs = grep { ($_->{instance_id} // '') eq $instance_id }
                    get_all_jobs();
    @inst_jobs = @inst_jobs[0..4] if @inst_jobs > 5;

    if (@inst_jobs) {
        print "<h3>" . &html_escape($text{'jobs_title'} || 'Jobs') . "</h3>\n";
        my %status_icons = (
            running => '&#x23F3;',
            ok      => '&#x2705;',
            failed  => '&#x1F534;',
            aborted => '&#x1F6AB;',
        );
        my @rows;
        for my $job (@inst_jobs) {
            my $jid    = $job->{job_id};
            my $status = $job->{status};
            my $ts     = $job->{started_at} || 0;
            my @lt     = localtime($ts);
            my $ts_str = $ts ? sprintf('%02d:%02d', $lt[2], $lt[1]) : '—';
            my $st_icon = $status_icons{$status} // '';
            my $out_cell = '—';
            if ($status eq 'running') {
                $out_cell = "<a href='manage.cgi?instance_id=" . &html_escape($instance_id)
                    . "&amp;action=poll_job&amp;job=" . &html_escape($jid) . "'>Live</a>";
            } elsif ($status eq 'failed' || $status eq 'aborted') {
                $out_cell = "<a href='jobs.cgi?action=view_output&amp;job_id="
                    . &html_escape($jid) . "'>Log</a>";
            }
            push @rows, [
                &html_escape($job->{action} || '—'),
                $ts_str,
                "$st_icon " . &html_escape($status),
                $out_cell,
            ];
        }
        print &ui_columns_table(
            [
                $text{'jobs_col_action'}  || 'Aktion',
                $text{'jobs_col_started'} || 'Gestartet',
                $text{'jobs_col_status'}  || 'Status',
                $text{'jobs_col_output'}  || 'Ausgabe',
            ],
            "100%",
            \@rows,
        );
    }
}

&footer('index.cgi', $text{'index_title'});
