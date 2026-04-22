#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 8;
use FindBin qw($Bin);

require "$Bin/stubs.pl";
our %text;
%text = (
    hint_package_not_found => 'PACKAGE_NOT_FOUND',
    hint_lib_missing       => 'LIB_MISSING',
    hint_command_not_found => 'CMD_NOT_FOUND',
    hint_permission_denied => 'PERM_DENIED',
    hint_no_space          => 'NO_SPACE',
    hint_network_error     => 'NET_ERROR',
);

require "$Bin/../src/lib/error_hints.pl";

is(detect_error_hint('Unable to locate package libssl'),   'PACKAGE_NOT_FOUND', 'package not found');
is(detect_error_hint('libz.so.1: cannot open shared obj'), 'LIB_MISSING',       'lib missing');
is(detect_error_hint('bash: curl: command not found'),     'CMD_NOT_FOUND',     'command not found');
is(detect_error_hint('/home/gs/file: Permission denied'),  'PERM_DENIED',       'permission denied');
is(detect_error_hint('No space left on device'),           'NO_SPACE',          'no space');
is(detect_error_hint('curl: (6) Could not resolve host'),  'NET_ERROR',         'curl network error');
is(detect_error_hint('wget: unable to resolve host'),      'NET_ERROR',         'wget network error');
is(detect_error_hint('Everything went fine!'),             '',                  'no hint for clean output');
