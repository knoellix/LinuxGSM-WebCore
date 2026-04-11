#!/usr/bin/perl
# t/test_run_action.pl
use strict;
use warnings;
use Test::More tests => 5;

our ($module_root, $current_lang, $config_directory);
our (%text, %config, %gconfig);
$module_root = 't'; $current_lang = 'en';
%text = (err_invalid_input => 'Invalid input.', err_invalid_action => 'Invalid action.');

sub read_file { }

my $error_called = 0;
my $last_error;
sub error { $error_called = 1; $last_error = $_[0]; die "caught\n"; }

my @logged_commands;
sub system_logged { push @logged_commands, $_[0]; return 0; }

use lib '/mnt/Lager/github/LinuxGSM-WebCore/src/lib';
require '/mnt/Lager/github/LinuxGSM-WebCore/src/lib/core.pl';

# Test 1: 'start' ist eine gültige Aktion
@logged_commands = ();
eval { run_server_action('mc-survival', 'start'); };
like($logged_commands[0], qr/su -s \/bin\/bash -c "\.\/mc-survival start" mc-survival/, 'start executes correct su command');

# Test 2: 'stop' ist eine gültige Aktion
@logged_commands = ();
eval { run_server_action('mc-survival', 'stop'); };
like($logged_commands[0], qr/mc-survival stop/, 'stop executes correct command');

# Test 3: 'details' ist eine gültige Aktion
@logged_commands = ();
eval { run_server_action('mc-survival', 'details'); };
like($logged_commands[0], qr/details/, 'details is valid action');

# Test 4: ungültige Aktion triggert error()
$error_called = 0;
eval { run_server_action('mc-survival', 'rm -rf /') };
is($error_called, 1, 'invalid action triggers error()');

# Test 5: leerer User triggert error() (aus sanitize_input)
$error_called = 0;
eval { run_server_action('', 'start') };
is($error_called, 1, 'empty user triggers error()');
