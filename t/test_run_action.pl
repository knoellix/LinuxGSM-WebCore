#!/usr/bin/perl
# t/test_run_action.pl
use strict;
use warnings;
use Test::More tests => 5;

our ($module_root, $current_lang, $config_directory);
our (%text, %config, %gconfig);
$module_root = 't'; $current_lang = 'en';
%text = (err_invalid_input => 'Invalid input.', err_invalid_action => 'Invalid action.', err_not_found => 'User not found.');

sub read_file { }

my $error_called = 0;
my $last_error;
sub error { $error_called = 1; $last_error = $_[0]; die "caught\n"; }

my @logged_commands;
sub system_logged { push @logged_commands, $_[0]; return 0; }

# Mock getpwnam to return a fake home directory
BEGIN {
    *CORE::GLOBAL::getpwnam = sub {
        my ($user) = @_;
        return ($user, 'x', 1000, 1000, '', '', "/home/$user") if $user =~ /^[a-z0-9_-]+$/;
        return ();
    };
}

use FindBin;
use lib "$FindBin::Bin/../src/lib";
require "$FindBin::Bin/../src/lib/core.pl";

# Test 1: 'start' ist eine gültige Aktion mit script_name und script_dir
@logged_commands = ();
eval { run_server_action('mc-survival', 'start', 'mcserver', '/home/mc-survival'); };
like($logged_commands[0], qr/cd.*home.*mc.*survival.*mcserver start/, 'start executes correct su command');

# Test 2: 'stop' ist eine gültige Aktion
@logged_commands = ();
eval { run_server_action('mc-survival', 'stop', 'mcserver', '/home/mc-survival'); };
like($logged_commands[0], qr/stop/, 'stop executes correct command');

# Test 3: 'details' ist eine gültige Aktion
@logged_commands = ();
eval { run_server_action('mc-survival', 'details', 'mcserver', '/home/mc-survival'); };
like($logged_commands[0], qr/details/, 'details is valid action');

# Test 4: ungültige Aktion triggert error()
$error_called = 0;
eval { run_server_action('mc-survival', 'rm -rf /') };
is($error_called, 1, 'invalid action triggers error()');

# Test 5: leerer User triggert error() (aus sanitize_input)
$error_called = 0;
eval { run_server_action('', 'start') };
is($error_called, 1, 'empty user triggers error()');
