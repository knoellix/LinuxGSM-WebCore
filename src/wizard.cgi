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
require './lib/steam.pl';
require './lib/logging.pl';

our (%text, %in, %access, $config_directory);
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

        &header($text{'wizard_title'}, '');
        _step4_form($game, $unix_user, $servername, $is_shared, $port, $sftp, $webmin_user, $steam_account);
        &footer('', '');
        exit;
    }

    if ($step == 5) {
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

        my $err = &validate_provision_fast($unix_user, $servername, $is_shared);
        &error($err) if $err;
        &port_in_use($port) and &error($text{'err_port_in_use'});

        my $result = eval { &provision_fast($unix_user, $servername) };
        &error("Fehler: $@") if $@;

        my $instance_id  = "${unix_user}_${servername}";
        my $script_path  = $result->{'server_dir'} . "/$game";
        my $game_source  = &get_game_source($game);
        my $reg_source   = ($game_source eq 'lgsm') ? 'provisioned' : $game_source;

        &register_instance($instance_id, $unix_user, $script_path, {
            source          => $reg_source,
            sftp_user       => '',
            owners          => $webmin_user,
            steam_account   => $steam_account,
            instance_status => 'fresh',
            game            => $game,
        });

        &grant_server_access($webmin_user, $instance_id) if $webmin_user;

        &log_action('server_provisioned', $instance_id, {user => $webmin_user, game => $game});
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id));
        exit;
    }
}

# GET: Schritt 1
&header($text{'wizard_title'}, '');
_step1_form();
&footer('', '');

# -------------------------------- helpers --------------------------------

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
    print &ui_hidden('step',         '4');
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
                &html_escape($text{'steam_no_accounts'}) . ' <a href="steam_settings.cgi">' . &html_escape($text{'steam_btn'}) . '</a>');
        } else {
            my $hint = &html_escape($text{'steam_no_accounts'}) . ' (<a href="steam_settings.cgi">' . &html_escape($text{'steam_btn'}) . '</a>)';
            print &ui_table_row(&html_escape($text{'steam_account_label'} . ' (optional)'), $hint);
        }
    }

    print &ui_table_end();
    print &ui_submit($text{'wizard_next_btn'}, undef, undef, undef, 'btn-primary');
    print &ui_form_end();
}

sub _step4_form {
    my ($game, $unix_user, $servername, $is_shared, $port, $sftp, $webmin_user, $steam_account) = @_;
    print "<h3>" . &html_escape($text{'wizard_step4_title'}) . "</h3>\n";

    my @pw   = getpwnam($unix_user);
    my $home = @pw ? $pw[7] : "/home/$unix_user";

    print &ui_table_start('', undef, 2);
    print &ui_table_row($text{'wizard_game'},          &html_escape(&get_game_display_name($game)));
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
    print &ui_submit($text{'wizard_create_btn'}, undef, undef, undef, 'btn-success');
    print &ui_form_end();
}

1;
