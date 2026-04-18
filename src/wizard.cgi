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

our (%text, %in, %access);
&ReadParse(\%in);

&can_create() or &error($text{'err_access_denied'});

my $step = int($in{'step'} || 1);

# --- POST: validate and advance step ---
if ($ENV{REQUEST_METHOD} eq 'POST') {

    if ($step == 1) {
        my $game     = &sanitize_input($in{'game'});
        my $username = &sanitize_input($in{'username'});
        my $port     = int($in{'port'} || 0);
        my $sftp     = $in{'sftp'} ? 1 : 0;

        $game     or &error($text{'err_invalid_input'});
        $username or &error($text{'err_invalid_input'});
        $port > 0  or &error($text{'err_invalid_input'});
        &port_in_use($port) and &error($text{'err_port_in_use'});

        # Advance to step 2
        &header($text{'wizard_title'}, '');
        _step2_form($game, $username, $port, $sftp);
        &footer('', '');
        exit;
    }

    if ($step == 2) {
        my $game          = &sanitize_input($in{'game'});
        my $username      = &sanitize_input($in{'username'});
        my $port          = int($in{'port'} || 0);
        my $sftp          = int($in{'sftp'} || 0);
        my $webmin_user   = &sanitize_input($in{'webmin_user'});
        my $steam_account = $in{'steam_account'} // '';

        # Advance to step 3 (confirmation)
        &header($text{'wizard_title'}, '');
        _step3_form($game, $username, $port, $sftp, $webmin_user, $steam_account);
        &footer('', '');
        exit;
    }

    if ($step == 3) {
        my $game        = &sanitize_input($in{'game'});
        my $username    = &sanitize_input($in{'username'});
        my $port        = int($in{'port'} || 0);
        my $sftp        = int($in{'sftp'} || 0);
        my $webmin_user = &sanitize_input($in{'webmin_user'});
        my $steam_account = $in{'steam_account'} // '';

        # Re-validate port — another process may have claimed it since step 1
        &port_in_use($port) and &error($text{'err_port_in_use'});

        &header($text{'wizard_title'}, '');
        print "<h3>$text{'wizard_step3'}</h3>\n";
        print "<pre>\n";

        # Provision
        my $ok = eval { &provision_server($username, $game, $port); 1 };
        if (!$ok) {
            print &html_escape("Error: $@");
        } else {
            # Register instance so it appears in index/manage even with bash shell
            my @pw = getpwnam($username);
            my $home = $pw[7] // "/home/$username";
            my %reg_extra = (source => 'provisioned');
            if (&game_requires_steam($game) && $steam_account =~ /\S/) {
                my $sa = $steam_account;
                $sa =~ s/[^a-zA-Z0-9_\-]//g;
                $sa = substr($sa, 0, 64);
                $reg_extra{'steam_account'} = $sa if length $sa;
            }
            &register_instance($username, $username, "$home/$username", \%reg_extra);

            # SFTP user setup — roll back the game user on failure
            if ($sftp) {
                require './lib/sftp.pl';
                my $sftp_ok = eval { &setup_sftp_user($username); 1 };
                if (!$sftp_ok) {
                    my $sftp_err = $@;
                    &system_logged("userdel -r $username");
                    &unregister_instance($username);
                    print &html_escape("SFTP setup failed: $sftp_err — provisioning rolled back\n");
                    print "</pre>\n";
                    &footer('', '');
                    exit;
                }
            }
            # Assign owner
            &grant_server_access($webmin_user, $username) if $webmin_user;
            print &html_escape("OK: $username\n");
        }

        print "</pre>\n";
        print "<p>$text{'wizard_done'}</p>\n";
        print "<p><a href='index.cgi'>$text{'wizard_back_to_list'}</a></p>\n";
        &footer('', '');
        exit;
    }
}

# --- GET: show step 1 ---
&header($text{'wizard_title'}, '');
_step1_form();
&footer('', '');

# ----------------------------- helpers ------------------------------

sub _step1_form {
    print "<h3>$text{'wizard_step1'}</h3>\n";
    my @games = &get_game_list();
    my @opts = map { [$_->{'shortname'}, "$_->{'name'} ($_->{'shortname'})"] } @games;

    print &ui_form_start('wizard.cgi', 'post');
    print &ui_hidden('step', '2');
    print &ui_table_start('', undef, 2);
    print &ui_table_row($text{'wizard_game'},
        &ui_select('game', '', \@opts));
    print &ui_table_row($text{'wizard_username'},
        &ui_textbox('username', '', 20));
    print &ui_table_row($text{'wizard_port'},
        &ui_textbox('port', '27015', 10));
    print &ui_table_row($text{'wizard_sftp'},
        &ui_checkbox('sftp', '1', '', 0));
    print &ui_table_end();
    print &ui_submit($text{'wizard_install'});
    print &ui_form_end();
}

sub _step2_form {
    my ($game, $username, $port, $sftp) = @_;
    print "<h3>$text{'wizard_step2'}</h3>\n";
    my @users = &list_webmin_users();
    my @opts  = map { [$_, $_] } @users;

    print &ui_form_start('wizard.cgi', 'post');
    print &ui_hidden('step',     '3');
    print &ui_hidden('game',     &html_escape($game));
    print &ui_hidden('username', &html_escape($username));
    print &ui_hidden('port',     $port);
    print &ui_hidden('sftp',     $sftp);
    print &ui_table_start('', undef, 2);
    print &ui_table_row($text{'wizard_owner'},
        &ui_select('webmin_user', '', \@opts));
    print &ui_table_row('',
        "<small>$text{'wizard_owner_note'}</small>");

    if (&game_requires_steam($game)) {
        my $accounts = &load_steam_accounts();
        my @ok_accounts = grep { $_->{'status'} eq 'ok' } @$accounts;
        if (@ok_accounts) {
            my @sa_opts = map { [$_->{'username'}, &html_escape($_->{'display_name'} || $_->{'username'})] } @ok_accounts;
            print &ui_table_row(
                $text{'steam_account_label'},
                &ui_select('steam_account', $in{'steam_account'} // $sa_opts[0][0], \@sa_opts)
            );
        } else {
            print &ui_table_row(
                $text{'steam_account_label'},
                $text{'steam_no_accounts'} . " " .
                "<a href=\"steam_settings.cgi\">" . &html_escape($text{'steam_btn'}) . "</a>"
            );
        }
    }

    print &ui_table_end();
    print &ui_submit($text{'wizard_install'});
    print &ui_form_end();
}

sub _step3_form {
    my ($game, $username, $port, $sftp, $webmin_user, $steam_account) = @_;
    $steam_account //= '';
    print "<h3>$text{'wizard_step3'}</h3>\n";
    print "<h4>$text{'wizard_summary'}</h4>\n";

    print &ui_table_start('', undef, 2);
    print &ui_table_row($text{'wizard_game'},     &html_escape($game));
    print &ui_table_row($text{'wizard_username'}, &html_escape($username));
    print &ui_table_row($text{'wizard_port'},     $port);
    print &ui_table_row($text{'wizard_sftp'},     $sftp ? 'ja' : 'nein');
    print &ui_table_row($text{'wizard_owner'},    &html_escape($webmin_user));
    if (&game_requires_steam($game) && $steam_account =~ /\S/) {
        print &ui_table_row($text{'steam_account_label'}, &html_escape($steam_account));
    }
    print &ui_table_end();

    print &ui_form_start('wizard.cgi', 'post');
    print &ui_hidden('step',          '3');
    print &ui_hidden('game',          &html_escape($game));
    print &ui_hidden('username',      &html_escape($username));
    print &ui_hidden('port',          $port);
    print &ui_hidden('sftp',          $sftp);
    print &ui_hidden('webmin_user',   &html_escape($webmin_user));
    if (&game_requires_steam($game) && $steam_account =~ /\S/) {
        print &ui_hidden('steam_account', &html_escape($steam_account));
    }
    print &ui_submit($text{'wizard_install'});
    print &ui_form_end();
}
