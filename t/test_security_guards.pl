#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 4;

our (%text, %config, %gconfig);
%text = (
    err_invalid_input  => 'invalid input',
    err_invalid_action => 'invalid action',
    err_not_found      => 'not found',
);

my $last_error = '';
sub error { $last_error = $_[0]; die "error\n"; }

my @logged_commands;
sub system_logged {
    my ($cmd) = @_;
    push @logged_commands, $cmd;
    return 0;
}

{
    no warnings 'redefine';
    local *CORE::GLOBAL::getpwnam = sub {
        my ($user) = @_;
        return ('x') x 7, "/home/$user", '/usr/sbin/nologin';
    };

    require './src/lib/core.pl';

    my $sanitized = sanitize_input('mc server;rm');
    is($sanitized, 'mcserverrm', 'sanitize_input strips dangerous chars');

    @logged_commands = ();
    run_server_action('gamesrv', 'start', 'gamesrv', '/srv/game dir');
    like($logged_commands[0], qr/su -s \/bin\/bash -c/, 'run_server_action uses su boundary');
    like($logged_commands[0], qr/cd \\Q\/srv\/game dir\\E/, 'run_server_action quotes script dir for shell safety');

    $last_error = '';
    my $ok = eval { run_server_action('gamesrv', 'shutdown'); 1 };
    ok(!$ok && $last_error eq 'invalid action', 'run_server_action blocks non-whitelisted actions');
}
