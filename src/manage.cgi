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
use File::Basename qw(dirname basename);
use File::Find ();

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
require './lib/provision.pl';
require './lib/monitor.pl';
require './lib/query.pl';

our (%text, %config, %in, %gconfig);
our ($module_root, $module_root_directory, $config_directory, $module_name);
our $current_lang;
$module_root ||= $module_root_directory;
$module_root ||= do { (my $d = __FILE__) =~ s{/[^/]+$}{}; $d };
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

# Percent-encode path for filemin query strings (same rules as config editor).
sub _filemin_path_urlencode {
    my ($s) = @_;
    $s =~ s/([^A-Za-z0-9\-_.~\/])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}

sub _write_file_as_user {
    my ($path, $content, $unix_user) = @_;
    (my $safe_path = $path) =~ s/'/'\\''/g;
    open(my $pipe, '|-', 'su', '-s', '/bin/bash', '-c', "cat > '$safe_path'", $unix_user)
        or &error("Cannot write $path as $unix_user: $!");
    print $pipe $content;
    close($pipe) or &error("Cannot write $path as $unix_user (pipe error): $!");
}

sub _parse_script_info {
    my ($inst) = @_;
    my $script_path = $inst->{'script'} // '';
    my ($script_name) = $script_path =~ m{/([^/]+)$};
    $script_name //= '';
    (my $server_dir = $script_path) =~ s{/[^/]+$}{};
    $script_name =~ s/[^a-zA-Z0-9_-]//g;
    return ($script_path, $script_name, $server_dir);
}

sub _effective_instance_source {
    my ($inst) = @_;
    my $src = $inst->{'source'} // '';
    return $src if $src eq 'steamcmd';
    my (undef, undef, $server_dir) = _parse_script_info($inst);
    return 'steamcmd' if $server_dir && -f "$server_dir/.steam_app_id";
    my $game_key = $inst->{'cached_game'} || $inst->{'game'} || '';
    return 'steamcmd' if $game_key && (&get_game_source($game_key) // '') eq 'steamcmd';
    return $src || 'lgsm';
}

sub _steamcmd_server_binary_exists {
    my ($server_dir) = @_;
    return 1 if -f "$server_dir/.steam_launch_cmd";
    return 1 if -x "$server_dir/steamcmd-start.sh";
    my $serverfiles = "$server_dir/serverfiles";
    return 0 unless -d $serverfiles;
    my $found = 0;
    File::Find::find(
        sub {
            return if $found;
            return unless -f $_;
            return unless -x _ || $_ =~ /\.exe$/i;
            if ($_ =~ /\.x86_64$/ || $_ =~ /Server\.sh$/ || $_ =~ /\.exe$/i) {
                $found = 1;
            }
        },
        $serverfiles
    );
    return $found;
}

# Collect every port-typed field for the instance from cfg+meta defaults.
# Returns an arrayref of { key, port, label } in field declaration order.
# Used for firewall open/close and the info table so multi-port games like
# Windrose (game/query/beacon) get treated as a port group, not a single value.
# Installs the monitor cron job if not already present.
# Called whenever monitoring is activated (server start / monitor reset).
sub _ensure_monitor_cron {
    my $cron_src  = "$module_root/scripts/linuxgsm-webcore-monitor.cron";
    my $cron_dest = "/etc/cron.d/linuxgsm-webcore-monitor";
    return if -f $cron_dest;
    return unless -f $cron_src;
    system("cp", $cron_src, $cron_dest);
    chmod(0644, $cron_dest);
}

sub _collect_instance_ports {
    my ($script_name, $cfg_ref) = @_;
    my @out;
    my @fields = &get_game_fields($script_name);
    my $lang   = $current_lang // 'en';
    for my $f (@fields) {
        my $type = $f->{'type'} // '';
        next unless $type eq 'port';
        my $key = $f->{'key'};
        my $val = $cfg_ref->{$key};
        if (!defined $val || $val eq '') {
            $val = $f->{'default'};
        }
        my $port = int($val // 0);
        next unless $port > 0;
        my $label = $lang eq 'de' ? ($f->{'label_de'} // $f->{'label_en'} // $key)
                                  : ($f->{'label_en'} // $f->{'label_de'} // $key);
        push @out, { key => $key, port => $port, label => $label };
    }
    # Legacy fallback for games without `port`-typed fields in games_meta:
    # use the registry/cfg "port" we already have.
    if (!@out) {
        my $val = $cfg_ref->{'port'};
        my $port = int($val // 0);
        push @out, { key => 'port', port => $port, label => $text{'manage_port'} } if $port > 0;
    }
    return \@out;
}

sub _runtime_status_badge_html {
    my ($status) = @_;
    # Vocabulary union: 'online'/'offline' from _detect_status* (instance.pl),
    # plus legacy 'running'/'stopped' callers, plus provisioning states.
    my %map = (
        online     => '&#x1F7E2; L&auml;uft',
        running    => '&#x1F7E2; L&auml;uft',
        offline    => '&#x1F534; Nicht gestartet',
        stopped    => '&#x1F534; Nicht gestartet',
        fresh      => '&#x1F7E1; Bereitstellung offen',
        lgsm_ready => '&#x1F7E1; Installation offen',
        unknown    => '&#x1F7E1; Unbekannt',
    );
    return $map{$status} || ('&#x1F7E1; ' . &html_escape($status));
}

sub _enqueue_install_game_job {
    my ($instance_id, $reg, $unix_user, $opts_ref) = @_;
    my %opts = %{ $opts_ref || {} };
    my $job_action = $opts{'job_action'} || 'install_game';
    my $preclean = $opts{'preclean'} ? 1 : 0;
    my $source = _effective_instance_source($reg);
    my (undef, $script_name, $server_dir) = _parse_script_info($reg);
    if ($source eq 'steamcmd' && ($reg->{'source'} // '') ne 'steamcmd') {
        &register_instance($instance_id, $reg->{'user'}, $reg->{'script'}, {
            source => 'steamcmd',
        });
    }
    my $job_id = &create_job($unix_user);
    my $job_dir = _shell_safe_job_dir($job_id);
    write_job_meta($job_id, $instance_id, $job_action, $unix_user);
    &log_action('job_started', $job_id, {instance_id => $instance_id, action => $job_action});

    if ($source eq 'steamcmd') {
        my $app_id = $reg->{'steam_app_id'} // '';
        if (!$app_id) {
            my %gmeta = load_games_meta();
            my $game_key = $reg->{'cached_game'} || $script_name;
            $app_id = $gmeta{$game_key}{'steam_app_id'} // '';
        }
        $app_id =~ s/[^0-9]//g;
        my $steamcmd_path = &detect_steamcmd() // 'steamcmd';
        my $prefix = $preclean ? "rm -rf '$server_dir/serverfiles' && " : '';
        my $cmd = "MODULE_ROOT='$module_root' STEAMCMD_PATH='$steamcmd_path' setsid nohup bash -lc \"$prefix" .
                  "bash '$module_root/scripts/steamcmd_install.sh' '$job_dir' '$unix_user' '$server_dir' '$app_id' '' '$script_name'\" >/dev/null 2>&1 &";
        &log_debug("$job_action steamcmd: module_root=$module_root steamcmd=$steamcmd_path server_dir=$server_dir app_id=$app_id preclean=$preclean cmd=$cmd");
        &system_logged($cmd);
    } else {
        my $cmd2 = "MODULE_ROOT='$module_root' setsid nohup bash '$module_root/scripts/game_action.sh' '$job_dir' '$unix_user' '$server_dir' '$script_name' install >/dev/null 2>&1 &";
        &log_debug("$job_action lgsm: module_root=$module_root server_dir=$server_dir cmd=$cmd2");
        &system_logged($cmd2);
    }

    return $job_id;
}

my $instance_id = &sanitize_input($in{'instance_id'} || $in{'user'} || '');
my $inst = &get_instance_flexible($instance_id) or &error($text{'err_not_found'});
my $unix_user = $inst->{'user'};
my $effective_source = _effective_instance_source($inst);
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
        # Open every port-typed field (game/query/beacon for UE5).
        my (undef, $sn_fw, $sd_fw) = _parse_script_info($inst);
        my %cfg_fw = $sn_fw && $sd_fw ? &_parse_lgsm_config($sd_fw, $sn_fw) : ();
        my $ports = _collect_instance_ports($sn_fw, \%cfg_fw);
        for my $p (@$ports) {
            &firewall_open_port($p->{port}, 'tcp');
            &firewall_open_port($p->{port}, 'udp');
        }
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'fw_close') {
        my (undef, $sn_fw, $sd_fw) = _parse_script_info($inst);
        my %cfg_fw = $sn_fw && $sd_fw ? &_parse_lgsm_config($sd_fw, $sn_fw) : ();
        my $ports = _collect_instance_ports($sn_fw, \%cfg_fw);
        for my $p (@$ports) {
            &firewall_close_port($p->{port}, 'tcp');
            &firewall_close_port($p->{port}, 'udp');
        }
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

        # Build form overrides from all games_meta fields.
        # Each field type drives validation; missing values fall back to games_meta defaults.
        my @fields_def  = &get_game_fields($script_name);
        unless (@fields_def) {
            # Legacy fallback: minimal port/gamename set.
            @fields_def = (
                {key => 'port',     type => 'port'},
                {key => 'gamename', type => 'text'},
            );
        }
        my %form_overrides;
        for my $f (@fields_def) {
            my $k   = $f->{'key'};
            my $raw = defined $in{$k} ? $in{$k} : ($f->{'default'} // '');
            my $t   = $f->{'type'} // 'text';
            if ($t eq 'port' || $t eq 'int') {
                my $n = int($raw || 0);
                # port/queryport/beaconport must be > 0; other ints can be 0.
                if ($t eq 'port') {
                    $n > 0 or &error($text{'err_invalid_input'});
                }
                $form_overrides{$k} = $n;
            } elsif ($t eq 'bool') {
                $form_overrides{$k} = $raw ? 1 : 0;
            } else {
                my $v = $raw // '';
                $v =~ s/[^a-zA-Z0-9 ._\-:\/]//g;
                $form_overrides{$k} = $v;
            }
        }
        # gamename always required (LGSM convention) when present in form.
        if (exists $form_overrides{'gamename'}) {
            length($form_overrides{'gamename'}) or &error($text{'err_invalid_input'});
        }

        # Read _default.cfg preserving section comments and all assignments.
        # Form values override whatever was in the file.
        my @output_lines;
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
        for my $k (sort keys %form_overrides) {
            push @output_lines, "$k=\"$form_overrides{$k}\"" unless $seen{$k};
        }

        # Ensure lgsm/config-lgsm/$script_name/ exists
        &system_logged("su -s /bin/bash -c \"mkdir -p \Q$script_dir\E/lgsm/config-lgsm/$script_name\" $unix_user");

        &_write_file_as_user($config_file, join("\n", @output_lines) . "\n", $unix_user);

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
        my $script_content = join('', map { exists $script_vals->{$_} ? "$_=\"$script_vals->{$_}\"\n" : () } @$script_order);
        &_write_file_as_user($script_path, $script_content, $unix_user);

        # Write back common.cfg; delete if nothing remains
        my @remaining = grep { exists $common_vals->{$_} } @$common_order;
        if (@remaining) {
            my $common_content = join('', map { "$_=\"$common_vals->{$_}\"\n" } @remaining);
            &_write_file_as_user($common_path, $common_content, $unix_user);
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
            my $hint    = &get_game_config_path($script_name);
            $cfg_path = &resolve_game_server_config_path($script_dir, $script_name, \%cfg_ctx, $hint);
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
                # LGSM games can be bootstrapped via a quick start/stop cycle.
                # Non-LGSM (steamcmd/wine) MUST NOT — that would launch wine in
                # the CGI foreground without a job/screen. The user gets a
                # clear error instead and starts the server normally.
                if ($effective_source eq 'steamcmd') {
                    &error($text{'config_editor_game_missing_steamcmd'}
                        || $text{'config_editor_game_missing'});
                }
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
                if ($fmt eq 'json') {
                    my ($jvals, $jorder) = &parse_json_config($raw_base);
                    my %updates;
                    for my $param (keys %in) {
                        next unless $param =~ /^field_(.+)$/;
                        my $key = $1;
                        my $val = $in{$param};
                        $val = '' unless defined $val;
                        # Browsers don't submit unchecked checkboxes; we rely
                        # on the server's existing JSON value type — anything
                        # present here is an updated value.
                        $updates{$key} = $val;
                    }
                    $new_content = &update_json_config($raw_base, \%updates);
                }
                elsif ($fmt eq 'properties') {
                    my ($prop_vals, $prop_order) = &parse_properties_file($raw_base);
                    for my $key (@$prop_order) {
                        $prop_vals->{$key} = $in{"field_$key"}
                            if exists $in{"field_$key"};
                    }
                    $new_content = &update_properties_file($raw_base, $prop_vals);
                } else {
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
            &_write_file_as_user($cfg_path, $new_content, $unix_user);
        } elsif (int($in{'raw_mode'} || 0)) {
            # Raw mode: filter content and write as game user
            my $raw_lines = &filter_raw_config($in{'config_raw'} // '');
            &_write_file_as_user($cfg_path, join("\n", @$raw_lines) . "\n", $unix_user);
        } else {
            # Form mode: read current file, apply field_* overrides, write back as game user
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

            my $form_content = join('', map { exists $cur_vals->{$_} ? "$_=\"$cur_vals->{$_}\"\n" : () } @$cur_order);
            &_write_file_as_user($cfg_path, $form_content, $unix_user);
        }

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
        my $safe_game_user = $game_user // '';
        $safe_game_user =~ s/[^a-zA-Z0-9_.-]//g;
        my @game_pw_before = $safe_game_user ne '' ? getpwnam($safe_game_user) : ();
        my $game_home_before = @game_pw_before ? ($game_pw_before[7] // '') : '';
        $game_home_before ||= "/home/$safe_game_user" if $safe_game_user ne '';

        my @all_before = &list_instances();
        my @other_for_user = grep {
            ($_->{'id'} // '') ne $instance_id && ($_->{'user'} // '') eq $game_user
        } @all_before;

        my $sftp_user = &resolve_instance_sftp_user($instance_id, $game_user);

        # Always remove instance directory; keep guardrails for destructive paths.
        if ($script_dir =~ m|^/| && $script_dir ne '/' && $script_dir =~ m|^/home/|) {
            my $safe_script_dir = _shell_sq($script_dir);
            &system_logged("rm -rf $safe_script_dir");
        }

        # Remove panel registration entry (if tracked)
        &unregister_instance($instance_id);

        # FTP/SFTP cleanup is mandatory for instance deletion.
        # Virtual ftpasswd users have no /etc/passwd entry — try that first.
        # Only fall back to a real Unix-account decommission if ftpasswd
        # didn't own the user.
        my @sftp_leftovers;
        if ($sftp_user && $sftp_user ne $game_user) {
            my %ftp_state = &discover_ftp_state();
            my $auth_file = $ftp_state{'auth_user_file'} || '/etc/proftpd/ftpd.passwd';
            my $rc = &ftpasswd_delete_user(
                file => $auth_file,
                name => $sftp_user,
            );
            if ($rc != 0) {
                my $sftp_res = &decommission_unix_user($sftp_user);
                push @sftp_leftovers, @{ $sftp_res->{'leftovers'} } if !$sftp_res->{'ok'};
                &log_debug("sftp decommission: " . join(' | ', @{ $sftp_res->{'log'} }));
            }
        }

        # Remove game unix user only if this was the last instance for that user
        my @user_leftovers;
        if (!@other_for_user && $safe_game_user ne '') {
            my $game_res = &decommission_unix_user($safe_game_user);
            push @user_leftovers, @{ $game_res->{'leftovers'} } if !$game_res->{'ok'};
            &log_debug("game decommission: " . join(' | ', @{ $game_res->{'log'} }));
        }

        # Verify hard-delete actually removed artifacts.
        my @leftovers;
        push @leftovers, $script_dir
            if $script_dir =~ m|^/| && -d $script_dir;
        push @leftovers, @user_leftovers, @sftp_leftovers;
        if (@leftovers) {
            my $msg = join(', ', @leftovers);
            &error(($text{'err_delete_incomplete'} || 'Löschen unvollständig') . ": $msg");
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

        my $job_id = &create_job($unix_user);
        my $job_dir = _shell_safe_job_dir($job_id);
        my $worker = "$module_root/scripts/setup_lgsm.sh";
        write_job_meta($job_id, $instance_id, 'setup_lgsm', $unix_user);
        &log_action('job_started', $job_id, {instance_id => $instance_id, action => 'setup_lgsm'});
        &system_logged("setsid nohup bash '$worker' '$job_dir' '$unix_user' '$server_dir' '$script_name' >/dev/null 2>&1 &");
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=poll_job&job=" . &html_escape($job_id) . "&next_status=lgsm_ready&xnavigation=1");
        exit;
    }
    elsif ($action eq 'install_game') {
        &can_create() or &error($text{'err_acl_admin_only'} || 'Access denied');
        my $reg = &get_registered_instance($instance_id) or &error($text{'err_not_found'});
        my $job_id = _enqueue_install_game_job($instance_id, $reg, $unix_user);
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id)
            . "&action=poll_job&job=" . &html_escape($job_id)
            . "&next_status=installed&xnavigation=1");
        exit;
    }
    elsif ($action eq 'update') {
        my $source = $effective_source;
        my ($script_path, $script_name, $server_dir) = _parse_script_info($inst);

        my $job_id = &create_job($unix_user);
        my $job_dir = _shell_safe_job_dir($job_id);
        write_job_meta($job_id, $instance_id, 'update', $unix_user);
        &log_action('job_started', $job_id, {instance_id => $instance_id, action => 'update'});

        if ($source eq 'steamcmd') {
            my $steamcmd_path = &detect_steamcmd() // 'steamcmd';
            &system_logged("MODULE_ROOT='$module_root' STEAMCMD_PATH='$steamcmd_path' setsid nohup bash '$module_root/scripts/steamcmd_control.sh' update '$job_dir' '$unix_user' '$server_dir' >/dev/null 2>&1 &");
        } else {
            &system_logged("MODULE_ROOT='$module_root' setsid nohup bash '$module_root/scripts/game_action.sh' '$job_dir' '$unix_user' '$server_dir' '$script_name' update >/dev/null 2>&1 &");
        }
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=poll_job&job=" . &html_escape($job_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'validate') {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        (my $server_dir = $inst->{'script'}) =~ s|/[^/]+$||;
        $script_name =~ s/[^a-zA-Z0-9_-]//g;

        my $job_id = &create_job($unix_user);
        my $job_dir = _shell_safe_job_dir($job_id);
        write_job_meta($job_id, $instance_id, 'validate', $unix_user);
        &log_action('job_started', $job_id, {instance_id => $instance_id, action => 'validate'});
        my $worker = "$module_root/scripts/game_action.sh";
        &system_logged("MODULE_ROOT='$module_root' setsid nohup bash '$worker' '$job_dir' '$unix_user' '$server_dir' '$script_name' validate >/dev/null 2>&1 &");
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&action=poll_job&job=" . &html_escape($job_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'reinstall') {
        my $source = $effective_source;
        my $job_id;
        if ($source eq 'steamcmd') {
            $job_id = _enqueue_install_game_job($instance_id, $inst, $unix_user, {
                job_action => 'reinstall',
                preclean   => 1,
            });
        } else {
            my $script_name = (split('/', $inst->{'script'}))[-1];
            (my $server_dir = $inst->{'script'}) =~ s|/[^/]+$||;
            $script_name =~ s/[^a-zA-Z0-9_-]//g;
            $job_id = &create_job($unix_user);
            my $job_dir = _shell_safe_job_dir($job_id);
            write_job_meta($job_id, $instance_id, 'reinstall', $unix_user);
            &log_action('job_started', $job_id, {instance_id => $instance_id, action => 'reinstall'});
            my $worker = "$module_root/scripts/game_action.sh";
            &system_logged("MODULE_ROOT='$module_root' setsid nohup bash '$worker' '$job_dir' '$unix_user' '$server_dir' '$script_name' reinstall >/dev/null 2>&1 &");
        }
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
        my %cfg_ctx  = &_parse_lgsm_config($script_dir, $script_name);
        my $hint     = &get_game_config_path($script_name);
        my $cfg_path = &resolve_game_server_config_path($script_dir, $script_name, \%cfg_ctx, $hint);

        # Bootstrap is only safe for LGSM scripts (which return immediately).
        # For SteamCMD/Wine games './<script> start' would launch wine in the
        # CGI foreground without monitoring — refuse and tell the user to use
        # the normal Start button (which dispatches via steamcmd_control.sh).
        if ($effective_source eq 'steamcmd') {
            &error($text{'config_editor_game_missing_steamcmd'}
                || $text{'config_editor_game_missing'});
        }

        unless (-f $cfg_path) {
            &run_server_action($unix_user, 'start', $script_name, $script_dir);
            sleep 2;
            &run_server_action($unix_user, 'stop', $script_name, $script_dir);
        }

        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) .
                  "&config_file=game&config_view=game&xnavigation=1");
        exit;
    }
    elsif ($action eq 'restart' && $effective_source eq 'steamcmd') {
        # Restart must not fork stop+start in parallel — RocksDB/Wine need a clean teardown first.
        # steamcmd_control.sh has no combined restart action; run stop synchronously, then start detached.
        my (undef, undef, $server_dir) = _parse_script_info($inst);
        unless (_steamcmd_server_binary_exists($server_dir)) {
            &error($text{'err_invalid_action'});
        }
        my $jid_stop = &create_job($unix_user);
        my $job_dir_stop = _shell_safe_job_dir($jid_stop);
        write_job_meta($jid_stop, $instance_id, 'stop', $unix_user);
        &log_action('job_started', $jid_stop, {instance_id => $instance_id, action => 'stop'});
        &system_logged("MODULE_ROOT='$module_root' bash '$module_root/scripts/steamcmd_control.sh' stop '$job_dir_stop' '$unix_user' '$server_dir' >/dev/null 2>&1");
        sleep 5;
        my $jid_start = &create_job($unix_user);
        my $job_dir_start = _shell_safe_job_dir($jid_start);
        write_job_meta($jid_start, $instance_id, 'start', $unix_user);
        &log_action('job_started', $jid_start, {instance_id => $instance_id, action => 'start'});
        &system_logged("MODULE_ROOT='$module_root' setsid nohup bash '$module_root/scripts/steamcmd_control.sh' start '$job_dir_start' '$unix_user' '$server_dir' >/dev/null 2>&1 &");
        &_ensure_monitor_cron();
        &set_monitor_running($server_dir, $config_directory, $instance_id);
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'start' || $action eq 'stop') {
        my $source = $effective_source;
        my ($script_path, $script_name, $server_dir) = _parse_script_info($inst);

        if ($source eq 'steamcmd') {
            if ($action eq 'start' && !_steamcmd_server_binary_exists($server_dir)) {
                my $job_id = _enqueue_install_game_job($instance_id, $inst, $unix_user);
                &redirect("manage.cgi?instance_id=" . &html_escape($instance_id)
                    . "&action=poll_job&job=" . &html_escape($job_id)
                    . "&next_status=installed&next_action=start&xnavigation=1");
                exit;
            }
            my $job_id = &create_job($unix_user);
            my $job_dir = _shell_safe_job_dir($job_id);
            write_job_meta($job_id, $instance_id, $action, $unix_user);
            &log_action('job_started', $job_id, {instance_id => $instance_id, action => $action});
            &system_logged("MODULE_ROOT='$module_root' setsid nohup bash '$module_root/scripts/steamcmd_control.sh' '$action' '$job_dir' '$unix_user' '$server_dir' >/dev/null 2>&1 &");
            if ($action eq 'stop') {
                &set_monitor_paused($server_dir, $config_directory, $instance_id);
            } else {
                &_ensure_monitor_cron();
                &set_monitor_running($server_dir, $config_directory, $instance_id);
            }
            &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
            exit;
        } else {
            &run_server_action($unix_user, $action, $script_name, $server_dir);
            if ($action eq 'stop') {
                &set_monitor_paused($server_dir, $config_directory, $instance_id);
            } else {
                &_ensure_monitor_cron();
                &set_monitor_running($server_dir, $config_directory, $instance_id);
            }
            &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
            exit;
        }
    }
    elsif ($action eq 'monitor_reset') {
        my (undef, undef, $server_dir) = _parse_script_info($inst);
        &_ensure_monitor_cron();
        &set_monitor_running($server_dir, $config_directory, $instance_id);
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    elsif ($action eq 'monitor_disable') {
        my (undef, undef, $server_dir) = _parse_script_info($inst);
        &set_monitor_disabled($server_dir, $config_directory, $instance_id);
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id) . "&xnavigation=1");
        exit;
    }
    else {
        my $script_name = (split('/', $inst->{'script'}))[-1];
        my $script_dir  = $inst->{'script'};
        $script_dir =~ s|/[^/]+$||;
        # SteamCMD/Wine games: any action that would shell './<script> $action'
        # is forbidden. The wrapper would launch wine in the CGI foreground and
        # never escape the request lifetime cleanly. Force users through the
        # explicit start/stop dispatch (which uses steamcmd_control.sh).
        if ($effective_source eq 'steamcmd') {
            &error($text{'err_invalid_action'} . " ($action)");
        }
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
    my $next_action = $in{'next_action'} // '';
    $next_action =~ s/[^a-z_]//g;

    &timeout_check_job($job_id);
    my $status = &get_job_status($job_id) // 'unknown';
    my ($all_out, undef) = &get_job_output($job_id, 0);  # always read all output from start

    if ($status eq 'ok' && $next_status) {
        &set_instance_status($instance_id, $next_status);
    }
    if ($status eq 'ok' && $next_action eq 'start') {
        my $inst_now = &get_instance_flexible($instance_id) || $inst;
        my $source = _effective_instance_source($inst_now);
        my (undef, $script_name, $server_dir) = _parse_script_info($inst_now);
        if ($source eq 'steamcmd') {
            my $start_job = &create_job($unix_user);
            my $start_job_dir = _shell_safe_job_dir($start_job);
            write_job_meta($start_job, $instance_id, 'start', $unix_user);
            &log_action('job_started', $start_job, {instance_id => $instance_id, action => 'start'});
            &system_logged("MODULE_ROOT='$module_root' setsid nohup bash '$module_root/scripts/steamcmd_control.sh' start '$start_job_dir' '$unix_user' '$server_dir' >/dev/null 2>&1 &");
            &redirect("manage.cgi?instance_id=" . &html_escape($instance_id)
                . "&action=poll_job&job=" . &html_escape($start_job) . "&xnavigation=1");
            exit;
        } else {
            &run_server_action($unix_user, 'start', $script_name, $server_dir);
        }
    }

    &header($text{'job_output_title'}, '');
    print "<h3>" . &html_escape($text{'job_output_title'}) . "</h3>\n";

    if ($status eq 'running') {
        my $poll_url = "manage.cgi?instance_id=" . &html_escape($instance_id)
            . "&action=poll_job&job=" . &html_escape($job_id)
            . "&next_status=" . &html_escape($next_status)
            . "&next_action=" . &html_escape($next_action)
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
    my $source = _effective_instance_source($inst);

    # SteamCMD/Wine: games_meta `live_log_path` first (Windrose: R5.log), then
    # wrapper/UE fallbacks; LGSM log/console paths last (often stale for steamcmd).
    my @log_candidates;
    if ($source eq 'steamcmd') {
        my @raw;
        my $rel_live = &get_game_live_log_path($script_name);
        if ($rel_live ne '') {
            (my $abs_live = "$script_dir/$rel_live") =~ s{//+}{/}g;
            push @raw, $abs_live;
        }
        my $logs_dir = "$script_dir/serverfiles/R5/Saved/Logs";
        my $newest_ue = '';
        if (-d $logs_dir && opendir(my $dh, $logs_dir)) {
            my @logs = grep { /\.log$/i } readdir($dh);
            closedir($dh);
            if (@logs) {
                my @sorted = sort { (stat("$logs_dir/$b"))[9] <=> (stat("$logs_dir/$a"))[9] }
                             map  { "$logs_dir/$_" } @logs;
                $newest_ue = $sorted[0];
            }
        }
        push @raw,
            "$script_dir/server.log",
            "$script_dir/windrose-debug.log",
            "$script_dir/serverfiles/server.log",
            "$script_dir/serverfiles/R5/Saved/Logs/R5.log",
            "$script_dir/serverfiles/R5/Saved/Logs/WindroseServer.log",
            "$script_dir/serverfiles/R5/Saved/Logs/Windrose.log";
        push @raw, $newest_ue if $newest_ue;
        push @raw,
            "$script_dir/log/console/${script_name}-console.log",
            "$script_dir/log/script/${script_name}.log",
            "$script_dir/log/${script_name}.log";
        my %seen;
        @log_candidates = grep { !$seen{$_}++ } @raw;
    } else {
        @log_candidates = (
            "$script_dir/log/console/${script_name}-console.log",
            "$script_dir/log/script/${script_name}.log",
            "$script_dir/log/${script_name}.log",
        );
    }
    my ($log_file) = grep { -f $_ } @log_candidates;
    my $auto_refresh = (($in{'auto_refresh'} // '') eq '1' && ($in{'manual'} // '') eq '1') ? 1 : 0;

    &header($text{'manage_monitor_title'}, '');
    print "<h3>" . &html_escape($text{'manage_monitor_title'}) . "</h3>\n";
    print &ui_form_start('manage.cgi', 'get');
    print &ui_hidden('instance_id', &html_escape($instance_id));
    print &ui_hidden('action', 'monitor');
    print &ui_hidden('xnavigation', '1');
    print &ui_hidden('manual', '1');
    print &ui_checkbox('auto_refresh', 1, $text{'manage_monitor_auto_label'}, $auto_refresh);
    print " ";
    print &ui_submit($text{'manage_monitor_refresh_btn'}, undef, undef, undef, 'btn-default');
    print &ui_form_end();

    if (!$log_file) {
        print "<p>" . &html_escape($text{'manage_monitor_no_log'}) . "</p>\n";
    } else {
        # filemin index.cgi expects path = directory only; use edit_file / download for files.
        my $log_dir  = dirname($log_file);
        my $log_base = basename($log_file);
        my $enc_dir  = _filemin_path_urlencode($log_dir);
        my $enc_file = _filemin_path_urlencode($log_base);
        my $href_edit = "/filemin/edit_file.cgi?path=$enc_dir&file=$enc_file";
        my $href_dl   = "/filemin/download.cgi?path=$enc_dir&file=$enc_file";
        my $href_dir  = "/filemin/?path=$enc_dir";
        my $hint = $text{'manage_monitor_filemin_hint'}
            || 'Open folder lists the log directory; use Download for very large files.';
        print "<p><small>" . &html_escape($text{'manage_monitor_shown_file'} || 'Logdatei')
            . ": <code>" . &html_escape($log_file) . "</code><br>\n";
        print "<a href=\"" . &html_escape($href_edit)
            . "\" target=\"_blank\" rel=\"noopener noreferrer\">"
            . &html_escape($text{'manage_monitor_log_edit'} || 'View in file manager')
            . "</a> \x{b7} ";
        print "<a href=\"" . &html_escape($href_dl)
            . "\" target=\"_blank\" rel=\"noopener noreferrer\">"
            . &html_escape($text{'manage_monitor_log_download'} || 'Download full log')
            . "</a> \x{b7} ";
        print "<a href=\"" . &html_escape($href_dir)
            . "\" target=\"_blank\" rel=\"noopener noreferrer\">"
            . &html_escape($text{'manage_monitor_log_folder'} || 'Open log folder')
            . "</a><br>\n";
        print &html_escape($hint) . "</small></p>\n";
        open(my $f, '<', $log_file) or do { print "<p>Logdatei nicht lesbar.</p>\n"; &footer('',''); exit; };
        my $content = do { local $/; <$f> };
        close($f);
        $content //= '';
        my $len  = length($content);
        my $tail = $len > 8192 ? substr($content, $len - 8192) : $content;
        my $refresh_url = "manage.cgi?instance_id=" . &html_escape($instance_id)
            . "&action=monitor&xnavigation=1&auto_refresh=1&manual=1";
        if ($auto_refresh) {
            print "<meta http-equiv=\"refresh\" content=\"2;url=$refresh_url\">\n";
        }
        print "<pre style='background:#111;color:#eee;padding:8px;height:500px;overflow:auto'>"
            . &html_escape($tail) . "</pre>\n";
    }
    &footer('', '');
    exit;
}

# Setup-Phase for fresh/lgsm_ready instances
if ($is_fresh) {
    my $istatus = $inst->{'instance_status'} // 'fresh';
    my $source  = _effective_instance_source($inst);
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
my $source_for_status = $effective_source;
my $runtime_status = $source_for_status eq 'steamcmd'
    ? &_detect_status_steamcmd($script_dir_for_cfg)
    : (($inst->{'instance_status'} && $inst->{'instance_status'} ne 'installed')
        ? $inst->{'instance_status'}
        : ($inst->{'status'} // 'unknown'));

# Server-Info table
print &ui_table_start($text{'manage_title'}, "width=100%", 2);
print &ui_table_row($text{'manage_game'},   &html_escape($inst->{'game'}));
# Show every port-typed field so the user sees the full game/query/beacon set
# for multi-port games (UE5). Single-port games still render as one row.
my $info_ports = _collect_instance_ports($script_name_for_cfg, \%cfg);
if (@$info_ports == 1) {
    print &ui_table_row($text{'manage_port'}, $info_ports->[0]{port});
} else {
    for my $p (@$info_ports) {
        print &ui_table_row(&html_escape($p->{label}), $p->{port});
    }
}
print &ui_table_row($text{'manage_status'}, _runtime_status_badge_html($runtime_status));
my $mon_state = &read_monitor_state($script_dir_for_cfg, $config_directory, $instance_id);
my $mon_status_key = 'monitor_status_' . ($mon_state->{'status'} // 'running');
my $mon_label = $text{$mon_status_key} || $mon_state->{'status'};
print &ui_table_row($text{'monitor_col'}, &html_escape($mon_label));

if ($runtime_status eq 'online' || $runtime_status eq 'running') {
    my $qfield = &get_game_query_port_field($script_name_for_cfg);
    if ($qfield) {
        my $qport = int($cfg{$qfield} // 0);
        if ($qport > 0) {
            my $qdata = &a2s_query('127.0.0.1', $qport, 2);
            if ($qdata) {
                print &ui_table_row(
                    $text{'monitor_players'},
                    &html_escape("$qdata->{players} / $qdata->{max}")
                );
            }
        }
    }
}
print &ui_table_row($text{'manage_script'}, &html_escape($inst->{'script'}));
print &ui_table_end();

# Firewall section — show open/closed status per port. Use AND semantics:
# the toggle button reflects "are *all* ports open?" so a single click can re-open
# a partially closed set.
my $all_open = 1;
for my $p (@$info_ports) {
    $all_open = 0 unless &firewall_status($p->{port});
}
my $fw_open = $all_open;
my $port = $info_ports->[0]{port}; # legacy compat for downstream code paths
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
if ($effective_source eq 'steamcmd' && $script_name_for_cfg eq 'windrose') {
    print "<p><small>" . &html_escape($text{'manage_fw_windrose_ephemeral_hint'}) . "</small></p>\n";
}

if (&is_admin()) {
    my $mon_s = $mon_state->{'status'} // 'running';
    if ($mon_s eq 'failed' || $mon_s eq 'paused') {
        print &ui_form_start('manage.cgi', 'post');
        print &ui_hidden('instance_id', $safe_id);
        print &ui_hidden('action', 'monitor_reset');
        print &ui_submit($text{'monitor_reset_btn'}, undef, undef, undef, 'btn-success');
        print &ui_form_end();
    }
    if ($mon_s ne 'disabled') {
        print &ui_form_start('manage.cgi', 'post');
        print &ui_hidden('instance_id', $safe_id);
        print &ui_hidden('action', 'monitor_disable');
        print &ui_submit($text{'monitor_disable_btn'}, undef, undef, undef, 'btn-default');
        print &ui_form_end();
    }
    if ($mon_s eq 'disabled') {
        print &ui_form_start('manage.cgi', 'post');
        print &ui_hidden('instance_id', $safe_id);
        print &ui_hidden('action', 'monitor_reset');
        print &ui_submit($text{'monitor_reset_btn'}, undef, undef, undef, 'btn-success');
        print &ui_form_end();
    }
}

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

# Quick-Fix form (only if no real instance config).
# Renders all fields from games_meta.json so multi-port games (UE: port/queryport/beaconport)
# are configurable from a single form. Defaults come from games_meta; user-edited values win.
if (!$cfg{_has_instance_config}) {
    my @qf_fields = &get_game_fields($script_name_for_cfg);
    # Fallback minimal set when no fields are defined (legacy/unknown scripts).
    unless (@qf_fields) {
        @qf_fields = (
            {key => 'port',     type => 'port', label_de => $text{'manage_port'}, label_en => $text{'manage_port'}, default => ''},
            {key => 'gamename', type => 'text', label_de => $text{'manage_game'}, label_en => $text{'manage_game'}, default => ''},
        );
    }
    my $qf_lang = $current_lang // 'en';
    print &ui_form_start("manage.cgi", "post");
    print &ui_hidden("instance_id", $safe_id);
    print &ui_hidden("action", "fix_config");
    print &ui_table_start($text{'manage_fix_config_btn'}, undef, 2);
    for my $f (@qf_fields) {
        my $type = $f->{'type'} // 'text';
        next if $type eq 'bool';
        my $key = $f->{'key'};
        my $label = $qf_lang eq 'de' ? ($f->{'label_de'} // $f->{'label_en'} // $key)
                                     : ($f->{'label_en'} // $f->{'label_de'} // $key);
        # Prefill priority: existing cfg value > inst struct (for port/game) > games_meta default.
        my $val = $cfg{$key};
        if (!defined $val || $val eq '') {
            if ($key eq 'port')          { $val = int($inst->{'port'}) || ($f->{'default'} // ''); }
            elsif ($key eq 'gamename')   { $val = (($inst->{'game'} // 'unknown') eq 'unknown') ? ($f->{'default'} // '') : $inst->{'game'}; }
            else                         { $val = $f->{'default'} // ''; }
        }
        print &ui_table_row(&html_escape($label), &ui_textbox($key, $val, 30));
    }
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
    my $game_cfg_hint = &get_game_config_path($script_name_for_cfg);
    my $game_cfg_path = &resolve_game_server_config_path(
        $script_dir_for_cfg, $script_name_for_cfg, \%cfg, $game_cfg_hint);
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
    my $inst_hints = &get_game_field_hints($script_name_for_cfg);
    for my $f (@$inst_editable) {
        my $key   = $f->{'key'};
        my $label = (($lang eq 'de') ? $f->{'label_de'} : $f->{'label_en'}) // $key;
        my $val   = exists $inst_vals->{$key} ? $inst_vals->{$key} : ($f->{'default'} // '');
        my $type  = $f->{'type'} // 'text';
        my $hint  = $inst_hints->{$key};
        if ($hint) {
            my $tip = &html_escape(($lang eq 'de' ? $hint->{'de'} : $hint->{'en'}) // '');
            $label = "<abbr title='$tip' style='cursor:help;text-decoration:underline dotted'>"
                   . &html_escape($label) . "</abbr>";
        } else {
            $label = &html_escape($label);
        }
        my $widget;
        if ($type eq 'bool') {
            my $yes = $text{'yes'} || 'Ja';
            my $no  = $text{'no'}  || 'Nein';
            $widget = &ui_radio("field_$key", ($val && $val ne '0') ? 1 : 0,
                                [[1, $yes], [0, $no]]);
        } else {
            my $width = ($type eq 'port' || $type eq 'int') ? 10 : 40;
            $widget = &ui_textbox("field_$key", &html_escape($val), $width);
        }
        print &ui_table_row($label, $widget);
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
        my $missing_text = ($effective_source eq 'steamcmd'
            ? ($text{'config_editor_game_missing_steamcmd'} || $text{'config_editor_game_missing'})
            : $text{'config_editor_game_missing'});
        print "<p><b>" . &html_escape($missing_text) . "</b></p>\n";
        if ($effective_source ne 'steamcmd') {
            print &ui_form_start("manage.cgi", "post");
            print &ui_hidden("instance_id", $safe_id);
            print &ui_hidden("action", "init_game_config");
            print &ui_submit($text{'config_editor_game_create_btn'});
            print &ui_form_end();
        }
    } else {
        # Choose parser based on file format. Prefer the explicit games_meta
        # hint over content sniffing — the JSON heuristic in particular needs
        # to win over the .properties fallback for files that legitimately
        # contain "key=value" lines elsewhere.
        my $game_fmt = &get_game_config_format($script_name_for_cfg)
                    || &detect_game_config_format($game_cfg_path, $game_raw);
        my ($game_vals, $game_order);
        if ($game_fmt eq 'json') {
            ($game_vals, $game_order) = &parse_json_config($game_raw);
        }
        elsif ($game_fmt eq 'properties') {
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
                my $type  = $f->{'type'} // 'text';
                my $val   = exists $game_vals->{$key} ? $game_vals->{$key} : '';
                my $width = ($type eq 'port' || $type eq 'int') ? 10 : 40;
                my $widget;
                if ($type eq 'bool') {
                    # Hidden zero-marker so an unchecked box still submits a value
                    # (browsers omit unchecked checkboxes entirely otherwise).
                    my $is_true = ($val =~ /^\s*(?:1|true|on|yes|ja)\s*$/i) ? 1 : 0;
                    $widget = "<input type='hidden' name='field_$key' value='false'>"
                            . "<input type='checkbox' name='field_$key' value='true'"
                            . ($is_true ? " checked='checked'" : '') . ">";
                }
                elsif ($type eq 'password') {
                    $widget = &ui_password("field_$key", &html_escape($val), $width);
                }
                else {
                    $widget = &ui_textbox("field_$key", &html_escape($val), $width);
                }
                print &ui_table_row(&html_escape($label), $widget);
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
        my %job_action_labels = (
            install_game    => $text{'jobs_action_install_game'}    || 'Spiel installieren',
            setup_lgsm      => $text{'jobs_action_setup_lgsm'}      || 'LGSM einrichten',
            update          => $text{'jobs_action_update'}         || 'Update',
            validate        => $text{'jobs_action_validate'}       || 'Dateien prüfen',
            reinstall       => $text{'jobs_action_reinstall'}      || 'Neu installieren',
            start           => $text{'jobs_action_start'}         || 'Starten',
            stop            => $text{'jobs_action_stop'}          || 'Stoppen',
            monitor_restart => $text{'jobs_action_monitor_restart'} || 'Neustart (Monitoring)',
        );
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
            } elsif ($status eq 'ok' || $status eq 'failed' || $status eq 'aborted') {
                # Successful jobs used to show only "—" here, so fast SteamCMD updates
                # looked like they produced no log. output/ is kept until auto-cleanup.
                $out_cell = "<a href='jobs.cgi?action=view_output&amp;job_id="
                    . &html_escape($jid) . "'>Log</a>";
            }
            my $act_label = $job_action_labels{ $job->{action} // '' }
                // $job->{action} // '—';
            push @rows, [
                &html_escape($act_label),
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
