#!/usr/bin/perl
# -------------------------------------------------------------------------
# LinuxGSM Webcore - Webmin Module
# Copyright (C) 2026 Christian Möllmann knoellix 128321164+knoellix@users.noreply.github.com
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
require './lib/acl.pl';
require './lib/games_meta.pl';

our (%text, %in, $config_directory, $module_name, $module_root);
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

&is_admin() or &error($text{'err_acl_admin_only'} || 'Access denied');

my $action = $in{'action'} // '';
$action =~ s/[^a-zA-Z0-9_\-]//g;

# --- Delete ---
if ($action eq 'delete') {
    my $script = $in{'script'} // '';
    $script =~ s/[^a-z0-9_\-]//g;
    if ($script) {
        &delete_local_game_meta($script);
    }
    &redirect("games_admin.cgi");
    exit;
}

# --- Save new/edited game ---
if ($action eq 'save') {
    my $script  = lc($in{'script_name'} // '');
    $script =~ s/[^a-z0-9_\-]//g;
    $script = substr($script, 0, 32);

    my $name   = $in{'game_name'} // '';
    $name =~ s/[^\w\s\(\)\-\.\:]//g;
    $name = substr($name, 0, 80);

    my $app_id = $in{'steam_app_id'} // '';
    $app_id =~ s/[^0-9]//g;

    my $port = int($in{'default_port'} || 27015);
    $port = 27015 unless $port > 1024 && $port < 65536;

    ($script && $name && $app_id)
        or &error($text{'err_invalid_input'} || 'Pflichtfelder fehlen');

    &save_local_game_meta($script, {
        name         => $name,
        source       => 'steamcmd',
        steam_app_id => int($app_id),
        fields       => [
            { key => 'port', type => 'port',
              label_de => 'Port', label_en => 'Port',
              default  => "$port" },
        ],
    });
    &redirect("games_admin.cgi");
    exit;
}

# --- Add form ---
if ($action eq 'add') {
    &header($text{'games_admin_title'} || 'Spiele-Datenbank', '');
    _add_form();
    &footer('games_admin.cgi', $text{'games_admin_title'} || 'Zurück');
    exit;
}

# --- Overview ---
&header($text{'games_admin_title'} || 'Spiele-Datenbank', '');

my %all_meta  = &load_games_meta();
my @custom    = &get_custom_game_list();

# Add button
print &ui_form_start('games_admin.cgi', 'get');
print &ui_hidden('action', 'add');
print &ui_submit($text{'games_admin_add'} || 'Neues Spiel hinzufügen', undef, undef, undef, 'btn-success');
print &ui_form_end();

if (@custom) {
    my %local_scripts = map { $_ => 1 } &local_game_scripts();
    my @rows;
    for my $g (@custom) {
        my $sn   = $g->{'shortname'};
        my $meta = $all_meta{$sn} // {};
        my $app_id = $meta->{'steam_app_id'} // '—';
        my $port   = &get_game_default_port($sn);

        my $del_link = "<form method='post' action='games_admin.cgi' style='display:inline'>"
            . "<input type='hidden' name='action' value='delete'>"
            . "<input type='hidden' name='script' value='" . &html_escape($sn) . "'>"
            . "<input type='submit' value='" . ($text{'games_admin_delete'} || 'Löschen') . "'"
            . " class='btn btn-danger btn-xs'"
            . " onclick='return confirm(\"" . ($text{'games_admin_delete_confirm'} || 'Wirklich löschen?') . "\")'>"
            . "</form>";

        my $is_local = $local_scripts{$sn} ? 1 : 0;

        push @rows, [
            &html_escape($sn),
            &html_escape($g->{'name'}),
            &html_escape($app_id),
            $port,
            $is_local ? $del_link : ($text{'games_admin_builtin'} || 'Eingebaut'),
        ];
    }

    print &ui_columns_table(
        [
            $text{'games_admin_col_script'}  || 'Script-Name',
            $text{'games_admin_col_name'}    || 'Anzeigename',
            $text{'games_admin_col_app_id'}  || 'Steam App ID',
            $text{'games_admin_col_port'}    || 'Standard-Port',
            $text{'games_admin_col_actions'} || 'Aktionen',
        ],
        '100%',
        \@rows,
    );
} else {
    print "<p>" . ($text{'games_admin_none'} || 'Noch keine benutzerdefinierten Spiele.') . "</p>\n";
}

&footer('', '');

# ---- helpers ----

sub _add_form {
    print "<h3>" . ($text{'games_admin_add_title'} || 'Neues Spiel hinzufügen') . "</h3>\n";
    print &ui_form_start('games_admin.cgi', 'post');
    print &ui_hidden('action', 'save');
    print &ui_table_start('', undef, 2);

    print &ui_table_row(
        ($text{'games_admin_field_name'} || 'Anzeigename') . ' *',
        &ui_textbox('game_name', '', 40)
        . " <small>" . ($text{'games_admin_field_name_hint'} || 'z.B. Windrose Dedicated Server') . "</small>");

    print &ui_table_row(
        ($text{'games_admin_field_script'} || 'Script-Name (intern)') . ' *',
        &ui_textbox('script_name', '', 20)
        . " <small>" . ($text{'games_admin_field_script_hint'} || 'Kleinbuchstaben, keine Leerzeichen, z.B. windrose') . "</small>");

    print &ui_table_row(
        ($text{'games_admin_field_app_id'} || 'Steam App ID') . ' *',
        &ui_textbox('steam_app_id', '', 12)
        . " <small>" . ($text{'games_admin_field_app_id_hint'} || 'Zahl aus steamdb.info oder store.steampowered.com') . "</small>");

    print &ui_table_row(
        $text{'games_admin_field_port'} || 'Standard-Port',
        &ui_textbox('default_port', '27015', 8));

    print &ui_table_end();
    print &ui_submit($text{'games_admin_save'} || 'Speichern', undef, undef, undef, 'btn-primary');
    print " ";
    print "<a href='games_admin.cgi' class='btn btn-default'>" . ($text{'cancel'} || 'Abbrechen') . "</a>";
    print &ui_form_end();
}
