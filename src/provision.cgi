#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/provision.pl';

our (%text, %config, %in);
&ReadParse(\%in);
&header($text{'provision_title'}, '');

if ($in{'submit'}) {
    my $user  = &sanitize_input($in{'user'});
    my $game  = &sanitize_input($in{'game'});
    my $port  = int($in{'port'});
    my $err   = &validate_provision($user, $game, $port);
    if ($err) {
        &error($err);
    }
    my $result = &provision_server($user, $game, $port);
    if (!$result || !$result->{'ok'}) {
        &error($result->{'err'} // $text{'provision_failed'} // 'Provisioning failed.');
    }
    &redirect('index.cgi?xnavigation=1');
    exit;
} else {
    print &ui_form_start("provision.cgi", "post");
    print &ui_table_start($text{'provision_title'}, "width=100%", 2);
    print &ui_table_row($text{'provision_game'}, &ui_textbox("game", "", 30));
    print &ui_table_row($text{'provision_user'}, &ui_textbox("user", "", 30));
    print &ui_table_row($text{'provision_port'}, &ui_textbox("port", "27015", 10));
    print &ui_table_end();
    print &ui_submit($text{'provision_submit'}, "submit");
    print &ui_form_end();
}

&footer('index.cgi', $text{'index_title'});
