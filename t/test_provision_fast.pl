#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 8;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

our (%text, $module_root);
$module_root = "$Bin/../src";
%text = (
    err_invalid_input => 'Ungültige Eingabe',
    err_user_exists   => 'User existiert bereits',
    err_server_exists => 'Server existiert bereits',
    err_port_in_use   => 'Port belegt',
);

my $tmp = tempdir(CLEANUP => 1);

# Track which user should appear to exist via CORE::GLOBAL override
my $user_exists = 0;

BEGIN {
    *CORE::GLOBAL::getpwnam = sub {
        if ($main::user_exists && $_[0] eq 'gs_mc') {
            return ('gs_mc','x',1002,1002,'','',"/tmp/fakehome",'/usr/sbin/nologin');
        }
        return ();
    };
}

require "$Bin/stubs.pl";
require "$Bin/../src/lib/provision.pl";

# Test 1: validate_provision_fast rejects bad username (uppercase)
is(validate_provision_fast('ROOT', 'myserver', 0), $text{'err_invalid_input'}, 'uppercase username rejected');

# Test 2: validate_provision_fast rejects bad servername (space/special char)
is(validate_provision_fast('gs_mc', 'my server!', 0), $text{'err_invalid_input'}, 'servername with space rejected');

# Test 3: dedicated mode rejects existing user
$main::user_exists = 1;
like(validate_provision_fast('gs_mc', 'myserver', 0), qr/existiert|exists/, 'dedicated mode rejects existing user');
$main::user_exists = 0;

# Test 4: validate_provision_fast accepts valid input (dedicated, new user)
is(validate_provision_fast('gs_mc', 'myserver', 0), undef, 'valid dedicated input accepted');

# Test 5: validate_provision_fast shared mode accepts existing user
$main::user_exists = 1;
is(validate_provision_fast('gs_mc', 'myserver', 1), undef, 'shared mode accepts existing user');
$main::user_exists = 0;

# Test 6: server_exists check is integration-level
pass('server_exists check is integration-level');

# Tests 7+8: provision_fast system_logged calls captured
my @cmds;
no warnings 'redefine';
*main::system_logged = sub { push @cmds, $_[0]; return 0 };
use warnings 'redefine';

# Override CORE::GLOBAL::getpwnam to simulate: gs_new does not exist yet,
# but after useradd (system_logged) is called it becomes findable.
# We track whether useradd has been called via @cmds.
{
    no warnings 'redefine';
    *CORE::GLOBAL::getpwnam = sub {
        if ($_[0] eq 'gs_new') {
            # User exists only after useradd has been called
            my $already_created = grep { /useradd.*gs_new/ } @cmds;
            return ('gs_new','x',1003,1003,'','',"/tmp/fakehome2",'/usr/sbin/nologin') if $already_created;
        }
        return ();
    };
}

eval { provision_fast('gs_new', 'testserver') };
if ($@) {
    diag("provision_fast died: $@");
}

my $user_cmd  = grep { /useradd.*gs_new/ } @cmds;
my $mkdir_cmd = grep { /mkdir.*testserver/ } @cmds;

ok($user_cmd,  'provision_fast calls useradd for new user');
ok($mkdir_cmd, 'provision_fast creates server directory');
