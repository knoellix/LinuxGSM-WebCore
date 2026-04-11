#!/usr/bin/perl
# t/test_sanitize.pl
use strict;
use warnings;
use Test::More tests => 6;

# Webmin-Stubs (vor require core.pl setzen)
our ($module_root, $current_lang, $config_directory);
our (%text, %config, %gconfig);
$module_root = 't'; $current_lang = 'en';
%text = (err_invalid_input => 'Invalid input.');

sub read_file { }
sub system_logged { return system($_[0]); }

# error() fangen statt sterben lassen
my $error_called = 0;
my $last_error;
sub error { $error_called = 1; $last_error = $_[0]; die "caught\n"; }

use FindBin;
require "$FindBin::Bin/../src/lib/core.pl";

# Test 1: gültiger Username bleibt erhalten
is(sanitize_input('mc-survival'), 'mc-survival', 'valid username preserved');

# Test 2: gültiger Username mit Underscore
is(sanitize_input('cs_server'), 'cs_server', 'underscore allowed');

# Test 3: Leerzeichen werden entfernt
is(sanitize_input('mc server'), 'mcserver', 'spaces stripped');

# Test 4: Gefährliche Zeichen entfernt (Bindestrich ist erlaubt)
is(sanitize_input('mc;rm -rf /'), 'mcrm-rf', 'dangerous chars stripped');

# Test 5: Leere Eingabe triggert error()
$error_called = 0;
eval { sanitize_input('') };
is($error_called, 1, 'empty string triggers error()');

# Test 6: Eingabe die nach Sanitize leer ist triggert error()
$error_called = 0;
eval { sanitize_input(';;;') };
is($error_called, 1, 'all-special input triggers error()');
