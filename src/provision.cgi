#!/usr/bin/perl
use strict;
use warnings;

require './lib/core.pl';
require './lib/provision.pl';

our (%text, %config, %in);
&ReadParse(\%in);
&error_if_root();
&header($text{'provision_title'}, '');

if ($in{'submit'}) {
    my $user  = &sanitize_input($in{'user'});
    my $game  = &sanitize_input($in{'game'});
    my $port  = int($in{'port'});
    my $err   = &validate_provision($user, $game, $port);
    if ($err) {
        &error($err);
    } else {
        &provision_server($user, $game, $port);
        &redirect('index.cgi');
    }
} else {
    print "<form method='post' action='provision.cgi'>\n";
    print "<table>\n";
    print "<tr><td>$text{'provision_game'}</td><td><input name='game' type='text'></td></tr>\n";
    print "<tr><td>$text{'provision_user'}</td><td><input name='user' type='text'></td></tr>\n";
    print "<tr><td>$text{'provision_port'}</td><td><input name='port' type='number' value='27015'></td></tr>\n";
    print "</table>\n";
    print "<input type='submit' name='submit' value=\"$text{'provision_submit'}\">\n";
    print "</form>\n";
}

&footer('index.cgi', $text{'index_title'});
