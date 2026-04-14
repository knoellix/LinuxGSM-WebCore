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

our (%text, %config, %in, %gconfig);
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

        my $config_file = "$script_dir/lgsm/config-lgsm/common.cfg";
        my $default_cfg = "$script_dir/lgsm/config-default/config-lgsm/$script_name/_default.cfg";
        my $backup_cfg  = "$default_cfg.bak";

        &error("Invalid config path") unless
            $config_file =~ m|^/[a-zA-Z0-9_./()\-]+/lgsm/config-lgsm/common\.cfg$|;
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

        # Ensure lgsm/config-lgsm/ exists
        &system_logged("su -s /bin/bash -c \"mkdir -p \Q$script_dir\E/lgsm/config-lgsm\" $unix_user");

        open(my $fh, '>', $config_file) or &error("Cannot write config: $!");
        print $fh "$_\n" for @output_lines;
        close($fh);

        my @pw = getpwnam($unix_user);
        chown($pw[2], $pw[3], $config_file) if @pw;

        # Backup _default.cfg so LGSM regenerates it cleanly on next run
        rename($default_cfg, $backup_cfg) if -f $default_cfg;

        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id));
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

# Warnings section
my @warnings = @{$inst->{'warnings'} || []};
if (!$cfg{_has_user_config}) {
    push @warnings, $text{'manage_fix_config_warn'};
}

if (@warnings) {
    print "<h3>&#x26A0; $text{'health_warn_header'}</h3>\n";
    print "<ul>\n";
    for my $w (@warnings) {
        print "<li>" . &html_escape($w) . "</li>\n";
    }
    print "</ul>\n";
}

# Quick-Fix form (only if no user config)
if (!$cfg{_has_user_config}) {
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

&footer('index.cgi', $text{'index_title'});
