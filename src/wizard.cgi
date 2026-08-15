#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/acl.pl';
require './lib/games.pl';
require './lib/instance.pl';
require './lib/provision.pl';
require './lib/games_meta.pl';
require './lib/games.pl';
require './lib/mc_profile.pl';
require './lib/mc_loader.pl';
require './lib/module_config.pl';
require './lib/mc_mods.pl';
require './lib/mc_modpack.pl';
require './lib/monitor.pl';
require './lib/steam.pl';
require './lib/logging.pl';

our (%text, %in, %access, %gconfig, $config_directory, $module_root, $module_root_directory, $current_lang);
$module_root ||= $module_root_directory;
$module_root ||= do { (my $d = __FILE__) =~ s{/[^/]+$}{}; $d };
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

&can_create() or &error($text{'err_access_denied'});

my $step = int($in{'step'} || 1);

if ($ENV{REQUEST_METHOD} eq 'POST') {

    if ($step == 2) {
        my $game = &sanitize_input($in{'game'} // '');
        $game or &error($text{'err_invalid_input'});
        &header($text{'wizard_title'}, '');
        _step2_form($game);
        &footer('', '');
        exit;
    }

    if ($step == 3) {
        my $game       = &sanitize_input($in{'game'} // '');
        my $unix_user  = &sanitize_input($in{'unix_user'} // '');
        my $servername = $in{'servername'} // '';
        $servername    =~ s/[^a-zA-Z0-9_-]//g;
        $servername    = substr($servername, 0, 64);
        my $is_shared  = ($in{'user_strategy'} // '') eq 'shared' ? 1 : 0;

        $game or &error($text{'err_invalid_input'});
        $unix_user =~ /^[a-z][a-z0-9_-]{0,30}$/ or &error($text{'err_invalid_input'});
        length($servername) >= 1 or &error($text{'err_invalid_input'});

        my $err = &validate_provision_fast($unix_user, $servername, $is_shared);
        &error($err) if $err;

        &header($text{'wizard_title'}, '');
        _step3_form($game, $unix_user, $servername, $is_shared);
        &footer('', '');
        exit;
    }

    if ($step == 4) {
        my $game          = &sanitize_input($in{'game'} // '');
        my $unix_user     = &sanitize_input($in{'unix_user'} // '');
        my $servername    = $in{'servername'} // '';
        $servername       =~ s/[^a-zA-Z0-9_-]//g;
        $servername       = substr($servername, 0, 64);
        my $is_shared     = ($in{'user_strategy'} // '') eq 'shared' ? 1 : 0;
        my $port          = int($in{'port'} || 0);
        my $sftp          = $in{'sftp'} ? 1 : 0;
        my $webmin_user   = &sanitize_input($in{'webmin_user'} // '');
        my $steam_account = $in{'steam_account'} // '';
        $steam_account    =~ s/[^a-zA-Z0-9_\-]//g;
        $steam_account    = substr($steam_account, 0, 64);

        my %ctx = (
            game          => $game,
            unix_user     => $unix_user,
            servername    => $servername,
            is_shared     => $is_shared,
            port          => $port,
            sftp          => $sftp,
            webmin_user   => $webmin_user,
            steam_account => $steam_account,
        );
        &header($text{'wizard_title'}, '');
        _step4_form(\%ctx, undef, undef, undef, undef);
        &footer('', '');
        exit;
    }

    if ($step == 35) {
        my %ctx = _wizard_parse_provision_context();
        my ($mc_loader, $mc_version) = _parse_mc_wizard_fields();

        &header($text{'wizard_title'}, '');
        if ($in{'mc_pack_search'} || $in{'pack_apply'} || !$mc_loader || !$mc_version) {
            _step35_mc_form(\%ctx);
        } else {
            my $mc_eula = ($in{'mc_eula_accept'} // '') eq '1' ? 1 : 0;
            &error($text{'mc_eula_required'} || 'Die Minecraft EULA muss bestätigt werden.') unless $mc_eula;
            $ctx{'mc_eula'} = $mc_eula;
            if (&mc_loader_is_modded($mc_loader)) {
                _step36_mc_loader_version_form(\%ctx, $mc_loader, $mc_version, undef);
            } else {
                _step4_form(\%ctx, $mc_loader, $mc_version, $mc_eula, undef);
            }
        }
        &footer('', '');
        exit;
    }

    if ($step == 36) {
        my %ctx = _wizard_parse_provision_context();
        my ($mc_loader, $mc_version, $mc_loader_version) = _parse_mc_wizard_fields();
        my $mc_eula = ($in{'mc_eula_accept'} // '') eq '1' ? 1 : 0;
        &error($text{'mc_eula_required'} || 'Die Minecraft EULA muss bestätigt werden.') unless $mc_eula;
        &error($text{'mc_profile_invalid'} || 'Ungültiges Minecraft-Profil.')
            unless $mc_loader && $mc_version && &mc_loader_is_modded($mc_loader);
        if ($mc_loader_version) {
            my $pin_err = &mc_validate_loader_version_pin($mc_loader, $mc_version, $mc_loader_version);
            &error($text{'mc_loader_version_invalid'} || 'Die gewählte Loader-Version ist für diese MC-Version nicht verfügbar.')
                if $pin_err;
        }

        &header($text{'wizard_title'}, '');
        _step4_form(\%ctx, $mc_loader, $mc_version, $mc_eula, $mc_loader_version);
        &footer('', '');
        exit;
    }

    if ($step == 5) {
        my %ctx = _wizard_parse_provision_context();
        my ($mc_loader, $mc_version, $mc_loader_version) = _parse_mc_wizard_fields();
        my $game          = $ctx{'game'};
        my $unix_user     = $ctx{'unix_user'};
        my $servername    = $ctx{'servername'};
        my $is_shared     = $ctx{'is_shared'};
        my $port          = $ctx{'port'};
        my $webmin_user   = $ctx{'webmin_user'};
        my $steam_account = $ctx{'steam_account'};

        my $err = &validate_provision_fast($unix_user, $servername, $is_shared);
        &error($err) if $err;
        &port_in_use($port) and &error($text{'err_port_in_use'});

        my $mc_profile;
        if (&is_minecraft_game($game)) {
            my $mc_eula = ($in{'mc_eula_accept'} // '') eq '1' ? 1 : 0;
            &error($text{'mc_eula_required'} || 'Die Minecraft EULA muss bestätigt werden.') unless $mc_eula;
            if ($mc_loader_version && &mc_loader_is_modded($mc_loader)) {
                my $pin_err = &mc_validate_loader_version_pin($mc_loader, $mc_version, $mc_loader_version);
                &error($text{'mc_loader_version_invalid'} || 'Die gewählte Loader-Version ist für diese MC-Version nicht verfügbar.')
                    if $pin_err;
            }
            $mc_profile = &build_mc_profile($mc_loader, $mc_version,
                { loader_version => $mc_loader_version });
            &error($text{'mc_profile_invalid'} || 'Ungültiges Minecraft-Profil.') unless $mc_profile;
            require POSIX;
            $mc_profile->{'eula_accepted'}    = 1;
            $mc_profile->{'eula_accepted_at'}  = POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time()));
        }

        my $result = eval { &provision_fast($unix_user, $servername) };
        &error("Fehler: $@") if $@;

        my $instance_id  = "${unix_user}_${servername}";
        # Wizard step 1 uses LGSM CSV shortnames (pw, csgo); the executable LGSM
        # script on disk is the script column (pwserver, csgoserver).
        my $lgsm_script  = $mc_profile
            ? $mc_profile->{'lgsm_script'}
            : &resolve_lgsm_game_script($game);
        my $script_path  = $result->{'server_dir'} . "/$lgsm_script";
        my $game_source  = &get_game_source($lgsm_script);
        my $reg_source   = ($game_source eq 'lgsm') ? 'provisioned' : $game_source;

        if ($mc_profile) {
            &write_mc_profile($result->{'server_dir'}, $unix_user, $mc_profile)
                or &error($text{'mc_profile_write_failed'} || 'Minecraft-Profil konnte nicht gespeichert werden.');
        }

        &register_instance($instance_id, $unix_user, $script_path, {
            source          => $reg_source,
            sftp_user       => '',
            owners          => $webmin_user,
            steam_account   => $steam_account,
            instance_status => 'fresh',
            game            => $lgsm_script,
            cached_game     => $game,
            port            => $port,
        }) or &error($text{'wizard_register_failed'} || 'Instanz konnte nicht registriert werden.');

        if ($webmin_user) {
            &grant_server_access($webmin_user, $instance_id)
                or &error($text{'wizard_acl_failed'} || 'Server-Zuweisung konnte nicht gespeichert werden.');
        }

        &log_action('server_provisioned', $instance_id, {user => $webmin_user, game => $lgsm_script});

        # Modpack-first: hand the chosen pack to manage.cgi's import dispatch.
        if ($mc_profile && ($in{'pack_import'} // '') eq '1') {
            my $psrc = $in{'pack_source'} // '';
            $psrc =~ s/[^a-z]//g;
            my $ppid = $in{'pack_project_id'} // '';
            my $pfid = $in{'pack_file_id'} // '';
            $pfid =~ s/\D//g;
            my $pvid = $in{'pack_version_id'} // '';
            $pvid =~ s/[^a-zA-Z0-9_-]//g;
            my $ptit = $in{'pack_title'} // '';
            $ptit =~ s/[\t\n\r\0]//g;
            $ptit = substr($ptit, 0, 128);
            if ($psrc eq 'curseforge') {
                $ppid =~ s/\D//g;
            } else {
                $ppid =~ s/[^a-zA-Z0-9_-]//g;
            }
            if ($psrc && $ppid ne '') {
                # Run the one-time ROOT dependency bootstrap first; the pack is
                # stashed and auto-starts once deps are ready (then=modpack).
                &redirect("manage.cgi?instance_id=" . &urlize($instance_id)
                    . "&action=provision_deps&then=modpack&xnavigation=1"
                    . "&pack_adopt=1"
                    . "&pack_source=" . &urlize($psrc)
                    . "&pack_project_id=" . &urlize($ppid)
                    . "&pack_file_id=" . &urlize($pfid)
                    . "&pack_version_id=" . &urlize($pvid)
                    . "&pack_title=" . &urlize($ptit));
                exit;
            }
        }

        # Standard flow: install system dependencies once (root), then land on
        # the instance setup page for the user-native install steps.
        &redirect("manage.cgi?instance_id=" . &urlize($instance_id)
            . "&action=provision_deps&xnavigation=1");
        exit;
    }
}

# GET: Schritt 1
&header($text{'wizard_title'}, '');
_step1_form();
&footer('', '');

# -------------------------------- helpers --------------------------------

sub _wizard_parse_provision_context {
    my $game          = &sanitize_input($in{'game'} // '');
    my $unix_user     = &sanitize_input($in{'unix_user'} // '');
    my $servername    = $in{'servername'} // '';
    $servername       =~ s/[^a-zA-Z0-9_-]//g;
    $servername       = substr($servername, 0, 64);
    my $is_shared     = ($in{'user_strategy'} // '') eq 'shared' ? 1 : 0;
    my $port          = int($in{'port'} || 0);
    my $sftp          = $in{'sftp'} ? 1 : 0;
    my $webmin_user   = &sanitize_input($in{'webmin_user'} // '');
    my $steam_account = $in{'steam_account'} // '';
    $steam_account    =~ s/[^a-zA-Z0-9_\-]//g;
    $steam_account    = substr($steam_account, 0, 64);
    return (
        game          => $game,
        unix_user     => $unix_user,
        servername    => $servername,
        is_shared     => $is_shared,
        port          => $port,
        sftp          => $sftp,
        webmin_user   => $webmin_user,
        steam_account => $steam_account,
    );
}

sub _wizard_print_provision_hiddens {
    my ($ctx) = @_;
    print &ui_hidden('game',          &html_escape($ctx->{'game'}));
    print &ui_hidden('unix_user',     &html_escape($ctx->{'unix_user'}));
    print &ui_hidden('servername',    &html_escape($ctx->{'servername'}));
    print &ui_hidden('user_strategy', $ctx->{'is_shared'} ? 'shared' : 'dedicated');
    print &ui_hidden('port',          $ctx->{'port'});
    print &ui_hidden('sftp',          $ctx->{'sftp'});
    print &ui_hidden('webmin_user',   &html_escape($ctx->{'webmin_user'}));
    print &ui_hidden('steam_account', &html_escape($ctx->{'steam_account'}));
    # Carry an optionally chosen modpack (modpack-first flow) through all steps.
    for my $pk (qw(pack_source pack_project_id pack_file_id pack_version_id pack_title pack_import)) {
        my $pv = $in{$pk};
        next unless defined $pv && $pv ne '';
        print &ui_hidden($pk, &html_escape($pv));
    }
}

sub _parse_mc_wizard_fields {
    my $loader = $in{'mc_loader'} // '';
    my $mc_version = $in{'mc_version'} // '';
    my $loader_version = $in{'mc_loader_version'} // '';
    my $custom = $in{'mc_loader_version_custom'} // '';
    $loader     =~ s/[^a-z]//g;
    $mc_version =~ s/[^0-9.]//g;
    $custom =~ s/[^0-9.]//g if $custom ne '';
    if ($custom ne '') {
        $loader_version = &mc_sanitize_loader_version_pin($loader, $custom);
    } else {
        $loader_version = &mc_sanitize_loader_version_pin($loader, $loader_version);
    }
    return ($loader, $mc_version, $loader_version);
}

sub _step35_mc_form {
    my ($ctx) = @_;
    my $game = $ctx->{'game'};
    print "<h3>" . &html_escape($text{'wizard_mc_step_title'}) . "</h3>\n";

    my $default_loader = &mc_loader_from_game($game) // 'vanilla';
    my $sel_loader = ($in{'mc_loader'} // '') =~ s/[^a-z]//gr;
    $sel_loader = $default_loader unless $sel_loader =~ /^[a-z]+$/;
    # Live Mojang list (+ cache / mc_compat fallback) — never a hardcoded allowlist.
    my @versions = &mc_list_mc_versions();
    &error($text{'mc_profile_invalid'} || 'Ungültiges Minecraft-Profil.')
        unless @versions;
    my $sel_mc_version = ($in{'mc_version'} // '') =~ s/[^0-9.]//gr;
    # Prefer posted version if still in effective list; else newest (first) entry.
    unless ($sel_mc_version =~ /^[0-9.]+$/
        && grep { $_ eq $sel_mc_version } @versions)
    {
        $sel_mc_version = $versions[0];
    }
    my @loaders = &mc_list_loaders();
    my @loader_opts = map {
        [ $_, &html_escape(&mc_loader_label($_, $current_lang // 'de')) ]
    } @loaders;
    my @ver_opts = map { [ $_, $_ ] } @versions;
    my $java_hint = &resolve_java_major($sel_mc_version);

    my $pack_applied = (($in{'pack_import'} // '') eq '1'
        && ($in{'pack_title'} // '') =~ /\S/) ? 1 : 0;

    print &ui_form_start('wizard.cgi', 'post');
    print &ui_hidden('step', '35');
    _wizard_print_provision_hiddens($ctx);
    print &ui_table_start('', undef, 2);
    if ($pack_applied) {
        print &ui_table_row('',
            "<div class='alert alert-info' style='margin:0'>"
            . &html_escape($text{'wizard_mc_pack_applied'} || 'Aus Modpack übernommen:')
            . ' <strong>' . &html_escape($in{'pack_title'}) . "</strong></div>");
    }
    print &ui_table_row($text{'mc_profile_loader'},
        &ui_select('mc_loader', $sel_loader, \@loader_opts));
    print &ui_table_row($text{'mc_profile_version'},
        &ui_select('mc_version', $sel_mc_version, \@ver_opts));
    print &ui_table_row($text{'mc_profile_java'},
        "<span id=\"mc-java-hint\">Java $java_hint</span> <small>" . &html_escape($text{'mc_profile_java_hint'}) . "</small>");
    my $eula_label = &html_escape($text{'mc_eula_accept'})
        . ' (<a href="https://aka.ms/MinecraftEULA" target="_blank" rel="noopener">'
        . &html_escape($text{'mc_eula_link'}) . '</a>)';
    my $eula_checked = ($in{'mc_eula_accept'} // '') eq '1' ? 1 : 0;
    print &ui_table_row($text{'mc_eula_title'},
        &ui_checkbox('mc_eula_accept', '1', $eula_label, $eula_checked));
    if (&mc_loader_is_modded($sel_loader)) {
        print &ui_table_row('',
            '<small>' . &html_escape($text{'wizard_mc_step36_hint'} || '') . '</small>');
    }
    print &ui_table_end();
    print &ui_submit($text{'wizard_next_btn'}, undef, undef, undef, 'btn-primary');
    print &ui_form_end();

    _step35_modpack_section($ctx);
}

# Optional modpack-first search: pick a modpack, adopt its MC version + loader.
sub _step35_modpack_section {
    my ($ctx) = @_;
    my $pack_q = $in{'pack_q'} // '';
    $pack_q =~ s/[\t\n\r]//g;
    $pack_q = substr($pack_q, 0, 100);
    my $searched = ($in{'mc_pack_search'} && length($pack_q) >= 2) ? 1 : 0;
    my $open = ($searched || ($in{'pack_apply'} // '')) ? ' open' : '';

    print "<details class=\"lgsm-mc-pack-picker\"$open><summary>"
        . &html_escape($text{'wizard_mc_pack_section'} || 'Optional: Modpack zuerst wählen')
        . "</summary>\n";
    print "<p><small>"
        . &html_escape($text{'wizard_mc_pack_hint'}
            || 'Modpack suchen — Loader und MC-Version werden daraus übernommen.')
        . "</small></p>\n";

    print &ui_form_start('wizard.cgi', 'post');
    print &ui_hidden('step', '35');
    _wizard_print_provision_hiddens($ctx);
    print &ui_hidden('mc_pack_search', '1');
    print &ui_table_start('', undef, 2);
    print &ui_table_row($text{'mc_modpack_search_label'} || 'Modpack',
        &ui_textbox('pack_q', $pack_q, 40, 0, undef,
            'placeholder="' . &html_escape($text{'mc_modpack_search_placeholder'} || '') . '"'));
    print &ui_table_end();
    print &ui_submit($text{'wizard_mc_pack_search_btn'} || 'Modpack suchen',
        undef, undef, undef, 'btn-default');
    print &ui_form_end();

    if ($searched) {
        &module_config_sync_in() if defined &module_config_sync_in;
        my $res = &mc_modpack_search_open($pack_q);
        $res = { ok => 0, results => [], errors => [] } unless ref($res) eq 'HASH';
        for my $code (@{ $res->{'errors'} // [] }) {
            print "<p><em>" . &html_escape($text{'mc_mods_cf_key_hint'} || '') . "</em></p>\n"
                if $code eq 'curseforge_key_missing';
        }
        my $results = $res->{'results'} // [];
        if (!@$results) {
            print "<p>" . &html_escape($text{'wizard_mc_pack_none'}
                || 'Keine passenden Modpacks gefunden.') . "</p>\n";
        } else {
            my @rows;
            for my $r (@$results) {
                next unless ref($r) eq 'HASH';
                my $src   = $r->{'source'} // '';
                my $title = &html_escape($r->{'title'} // '?');
                my $desc  = &html_escape(substr($r->{'description'} // '', 0, 110));
                my $mc    = &html_escape($r->{'pack_mc'} // '');
                my $ldr   = &html_escape($r->{'loader_label'} // $r->{'loader'} // '');
                my $src_label = &html_escape($text{"mc_mods_source_$src"} // $src);

                my $f = &ui_form_start('wizard.cgi', 'post');
                $f .= &ui_hidden('step', '35');
                # Provision context only — NOT the previous pack hiddens.
                $f .= &ui_hidden('game',          &html_escape($ctx->{'game'}));
                $f .= &ui_hidden('unix_user',     &html_escape($ctx->{'unix_user'}));
                $f .= &ui_hidden('servername',    &html_escape($ctx->{'servername'}));
                $f .= &ui_hidden('user_strategy', $ctx->{'is_shared'} ? 'shared' : 'dedicated');
                $f .= &ui_hidden('port',          $ctx->{'port'});
                $f .= &ui_hidden('sftp',          $ctx->{'sftp'});
                $f .= &ui_hidden('webmin_user',   &html_escape($ctx->{'webmin_user'}));
                $f .= &ui_hidden('steam_account', &html_escape($ctx->{'steam_account'}));
                $f .= &ui_hidden('pack_apply', '1');
                $f .= &ui_hidden('pack_import', '1');
                $f .= &ui_hidden('mc_loader',  &html_escape($r->{'loader'} // ''));
                $f .= &ui_hidden('mc_version', &html_escape($r->{'pack_mc'} // ''));
                $f .= &ui_hidden('pack_source',     &html_escape($src));
                $f .= &ui_hidden('pack_project_id', &html_escape($r->{'project_id'} // ''));
                $f .= &ui_hidden('pack_file_id',    &html_escape($r->{'file_id'} // ''));
                $f .= &ui_hidden('pack_version_id', &html_escape($r->{'version_id'} // ''));
                $f .= &ui_hidden('pack_title',      &html_escape($r->{'title'} // ''));
                $f .= &ui_submit($text{'wizard_mc_pack_apply_btn'} || 'Übernehmen',
                    undef, undef, undef, 'btn-primary');
                $f .= &ui_form_end();

                push @rows, [
                    "$title<br><small>$desc</small>",
                    "$mc &middot; $ldr",
                    $src_label,
                    $f,
                ];
            }
            print &ui_columns_table(
                [
                    $text{'wizard_mc_pack_col_pack'}   || 'Modpack',
                    $text{'wizard_mc_pack_col_target'} || 'Version',
                    $text{'mc_mods_col_source'}        || 'Quelle',
                    $text{'mc_modpack_col_import'}     || 'Aktion',
                ],
                '100%',
                \@rows,
            );
        }
    }
    print "</details>\n";
}

sub _step36_mc_loader_version_form {
    my ($ctx, $mc_loader, $mc_version, $sel_loader_version) = @_;
    print "<h3>" . &html_escape($text{'wizard_mc_step36_title'}) . "</h3>\n";
    print "<p>" . &html_escape($text{'wizard_mc_step36_intro'} || '') . "</p>\n";

    my @loader_vers = &mc_fetch_loader_versions($mc_loader, $mc_version);
    my @lv_opts = ( [ '', &html_escape($text{'mc_loader_version_auto'} || 'Automatisch (neueste stabile)') ] );
    push @lv_opts, map { [ $_, $_ ] } @loader_vers;
    my $lv_default = $sel_loader_version // ($in{'mc_loader_version'} // '');
    $lv_default = '' unless grep { $_->[0] eq $lv_default } @lv_opts;

    print &ui_form_start('wizard.cgi', 'post');
    print &ui_hidden('step', '36');
    _wizard_print_provision_hiddens($ctx);
    print &ui_hidden('mc_loader', &html_escape($mc_loader));
    print &ui_hidden('mc_version', &html_escape($mc_version));
    print &ui_hidden('mc_eula_accept', '1');
    print &ui_table_start('', undef, 2);
    print &ui_table_row($text{'mc_profile_loader'},
        &html_escape(&mc_loader_label($mc_loader, $current_lang // 'de')));
    print &ui_table_row($text{'mc_profile_version'}, &html_escape($mc_version));
    print &ui_table_row($text{'mc_profile_loader_version'},
        &ui_select('mc_loader_version', $lv_default, \@lv_opts));
    print &ui_table_row($text{'mc_loader_version_custom'},
        &ui_textbox('mc_loader_version_custom', $in{'mc_loader_version_custom'} // '', 20)
        . '<br><small>' . &html_escape($text{'mc_loader_version_custom_hint'} || '') . '</small>');
    if (!@loader_vers) {
        print &ui_table_row('',
            '<small>' . &html_escape($text{'mc_loader_versions_unavailable'} || '') . '</small>');
    }
    print &ui_table_end();
    print &ui_submit($text{'wizard_next_btn'}, undef, undef, undef, 'btn-primary');
    print &ui_form_end();
}

sub _wizard_game_display_name {
    my ($game) = @_;
    my $display = &get_game_display_name($game);
    return $display if $display ne $game;
    for my $g (&get_game_list()) {
        if (($g->{'shortname'} // '') eq $game) {
            return $g->{'name'} // $game;
        }
    }
    return $game;
}

sub _step1_form {
    print "<h3>" . &html_escape($text{'wizard_step1_title'}) . "</h3>\n";
    my @lgsm_games   = &get_game_list();
    my @custom_games = &get_custom_game_list();

    my @opts;
    push @opts, map { [$_->{'shortname'}, &html_escape("$_->{'name'} ($_->{'shortname'})") ] } @lgsm_games;
    if (@custom_games) {
        push @opts, ['', '─── ' . ($text{'wizard_custom_games'} || 'Weitere Spiele') . ' ───'];
        push @opts, map { [$_->{'shortname'}, &html_escape("$_->{'name'} ($_->{'source'})") ] } @custom_games;
    }

    print &ui_form_start('wizard.cgi', 'post');
    print &ui_hidden('step', '2');
    print &ui_table_start('', undef, 2);
    print &ui_table_row($text{'wizard_game'}, &ui_select('game', '', \@opts));
    print &ui_table_end();
    print &ui_submit($text{'wizard_next_btn'}, undef, undef, undef, 'btn-primary');
    print &ui_form_end();
}

sub _step2_form {
    my ($game) = @_;
    print "<h3>" . &html_escape($text{'wizard_step2_title'}) . "</h3>\n";

    print &ui_form_start('wizard.cgi', 'post');
    print &ui_hidden('step', '3');
    print &ui_hidden('game', &html_escape($game));
    print &ui_table_start('', undef, 2);

    print &ui_table_row($text{'wizard_user_strategy'},
        &ui_radio('user_strategy', 'dedicated', [
            ['dedicated', &html_escape($text{'wizard_dedicated_user'})],
            ['shared',    &html_escape($text{'wizard_shared_user'})],
        ])
    );
    print &ui_table_row($text{'wizard_username'},
        &ui_textbox('unix_user', "gs_$game", 30));
    print &ui_table_row('',
        "<small>" . &html_escape($text{'wizard_user_hint'}) . "</small>");
    print &ui_table_row($text{'wizard_server_name'},
        &ui_textbox('servername', $game . "-1", 30));
    print &ui_table_row('',
        "<small>" . &html_escape($text{'wizard_server_name_hint'}) . "</small>");

    print &ui_table_end();
    print &ui_submit($text{'wizard_next_btn'}, undef, undef, undef, 'btn-primary');
    print &ui_form_end();
}

sub _step3_form {
    my ($game, $unix_user, $servername, $is_shared) = @_;
    print "<h3>" . &html_escape($text{'wizard_step3_title'}) . "</h3>\n";

    my $default_port = &get_game_default_port($game);
    my @webmin_users = &list_webmin_users();
    my @owner_opts   = map { [$_, $_] } @webmin_users;

    print &ui_form_start('wizard.cgi', 'post');
    my $next_step = &is_minecraft_game($game) ? 35 : 4;
    print &ui_hidden('step', $next_step);
    print &ui_hidden('game',         &html_escape($game));
    print &ui_hidden('unix_user',    &html_escape($unix_user));
    print &ui_hidden('servername',   &html_escape($servername));
    print &ui_hidden('user_strategy', $is_shared ? 'shared' : 'dedicated');
    print &ui_table_start('', undef, 2);

    print &ui_table_row($text{'wizard_port'},
        &ui_textbox('port', $default_port, 10));
    print &ui_table_row($text{'wizard_sftp'},
        &ui_checkbox('sftp', '1', &html_escape($text{'wizard_sftp_label'}), 0));
    print &ui_table_row($text{'wizard_owner'},
        &ui_select('webmin_user', '', \@owner_opts));

    {
        my $requires = &game_requires_steam($game);
        my $accounts = &load_steam_accounts();
        my @ok       = grep { $_->{'status'} eq 'ok' } @$accounts;
        if (@ok) {
            my @sopts = map { [$_->{'username'}, &html_escape($_->{'display_name'} || $_->{'username'})] } @ok;
            unshift @sopts, ['', '— ' . &html_escape($text{'steam_no_account_opt'} || 'Kein Account') . ' —'] unless $requires;
            my $label = $requires ? $text{'steam_account_label'} : ($text{'steam_account_label'} . ' (' . ($text{'optional'} || 'optional') . ')');
            print &ui_table_row(&html_escape($label), &ui_select('steam_account', '', \@sopts));
        } elsif ($requires) {
            print &ui_table_row($text{'steam_account_label'},
                &html_escape($text{'steam_no_accounts'}) . ' <a href="integrations.cgi">' . &html_escape($text{'integrations_btn'}) . '</a>');
        } else {
            my $hint = &html_escape($text{'steam_no_accounts'}) . ' (<a href="integrations.cgi">' . &html_escape($text{'integrations_btn'}) . '</a>)';
            print &ui_table_row(&html_escape($text{'steam_account_label'} . ' (optional)'), $hint);
        }
    }

    print &ui_table_end();
    print &ui_submit($text{'wizard_next_btn'}, undef, undef, undef, 'btn-primary');
    print &ui_form_end();
}

sub _step4_form {
    my ($ctx, $mc_loader, $mc_version, $mc_eula, $mc_loader_version) = @_;
    my $game          = $ctx->{'game'};
    my $unix_user     = $ctx->{'unix_user'};
    my $servername    = $ctx->{'servername'};
    my $is_shared     = $ctx->{'is_shared'};
    my $port          = $ctx->{'port'};
    my $sftp          = $ctx->{'sftp'};
    my $webmin_user   = $ctx->{'webmin_user'};
    my $steam_account = $ctx->{'steam_account'};
    $mc_loader   //= '';
    $mc_version  //= '';
    $mc_eula     //= 0;
    $mc_loader_version //= '';
    print "<h3>" . &html_escape($text{'wizard_step4_title'}) . "</h3>\n";

    my @pw   = getpwnam($unix_user);
    my $home = @pw ? $pw[7] : "/home/$unix_user";

    print &ui_table_start('', undef, 2);
    print &ui_table_row($text{'wizard_game'},          &html_escape(_wizard_game_display_name($game)));
    print &ui_table_row($text{'wizard_user_strategy'}, $is_shared
        ? &html_escape($text{'wizard_shared_user'})
        : &html_escape($text{'wizard_dedicated_user'}));
    print &ui_table_row($text{'wizard_username'},      &html_escape($unix_user));
    if (@pw) {
        print &ui_table_row('', "<small>" . &html_escape($text{'wizard_user_exists_hint'}) . "</small>");
    }
    print &ui_table_row($text{'wizard_server_name'},  &html_escape($servername));
    print &ui_table_row($text{'wizard_server_dir'},   &html_escape("$home/$servername/"));
    print &ui_table_row($text{'wizard_port'},         $port);
    print &ui_table_row($text{'wizard_sftp'},         $sftp ? ($text{'yes'} // 'Ja') : ($text{'no'} // 'Nein'));
    print &ui_table_row($text{'wizard_owner'},        &html_escape($webmin_user));
    if ($steam_account) {
        print &ui_table_row($text{'steam_account_label'}, &html_escape($steam_account));
    }
    if ($mc_loader && $mc_version) {
        print &ui_table_row($text{'mc_profile_loader'},
            &html_escape(&mc_loader_label($mc_loader, $current_lang // 'de')));
        print &ui_table_row($text{'mc_profile_version'}, &html_escape($mc_version));
        if ($mc_loader_version && &mc_loader_is_modded($mc_loader)) {
            print &ui_table_row($text{'mc_profile_loader_version'}, &html_escape($mc_loader_version));
        } elsif (&mc_loader_is_modded($mc_loader)) {
            print &ui_table_row($text{'mc_profile_loader_version'},
                &html_escape($text{'mc_loader_version_auto'} || 'Automatisch (neueste stabile)'));
        }
        my $java_m = &resolve_java_major($mc_version);
        print &ui_table_row($text{'mc_profile_java'}, "Java $java_m");
        if (!&mc_loader_phase1_ready($mc_loader)) {
            print &ui_table_row('',
                "<small>" . &html_escape($text{'mc_profile_modded_hint'}) . "</small>");
        }
        if ($mc_eula) {
            print &ui_table_row($text{'mc_eula_title'}, &html_escape($text{'yes'} // 'Ja'));
        }
    }
    print &ui_table_end();

    print &ui_form_start('wizard.cgi', 'post');
    print &ui_hidden('step',          '5');
    print &ui_hidden('game',          &html_escape($game));
    print &ui_hidden('unix_user',     &html_escape($unix_user));
    print &ui_hidden('servername',    &html_escape($servername));
    print &ui_hidden('user_strategy', $is_shared ? 'shared' : 'dedicated');
    print &ui_hidden('port',          $port);
    print &ui_hidden('sftp',          $sftp);
    print &ui_hidden('webmin_user',   &html_escape($webmin_user));
    print &ui_hidden('steam_account', &html_escape($steam_account));
    print &ui_hidden('mc_loader', &html_escape($mc_loader)) if $mc_loader;
    print &ui_hidden('mc_version', &html_escape($mc_version)) if $mc_version;
    print &ui_hidden('mc_loader_version', &html_escape($mc_loader_version))
        if $mc_loader_version && &mc_loader_is_modded($mc_loader);
    print &ui_hidden('mc_eula_accept', '1') if $mc_eula;
    print &ui_submit($text{'wizard_create_btn'}, undef, undef, undef, 'btn-success');
    print &ui_form_end();
}

1;
