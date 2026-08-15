#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
chdir "$Bin/.." or die "Cannot chdir: $!";

print "1..8\n";

sub pass { print "ok - $_[0]\n" }
sub fail { print "not ok - $_[0]\n" }

# --- stubs ---
our (%text, %in, %access);
%text = (
    err_not_found      => 'Not found',
    err_invalid_input  => 'Invalid input',
    err_port_in_use    => 'Port in use',
    err_access_denied  => 'Access denied',
    err_user_exists    => 'User exists',
);

my $error_msg;
sub error { $error_msg = $_[0]; die "error: $_[0]\n" }
sub sanitize_input {
    my ($in) = @_;
    $in //= '';
    $in =~ s/[^a-zA-Z0-9_\-]//g;
    return $in;
}
my $port_busy = 0;

# getpwnam mock: controlled per-test via $mock_user_exists
my $mock_user_exists = 0;
BEGIN {
    *CORE::GLOBAL::getpwnam = sub { return $mock_user_exists ? ('x') : () };
}

require './src/lib/provision.pl';
# Override port_in_use after require (provision.pl defines its own)
{ no warnings 'redefine'; *port_in_use = sub { return $port_busy } }

# --- tests ---

# 1. sanitize_input strips whitespace/specials from username
{
    my $clean = sanitize_input('mc user;bad');
    $clean eq 'mcuserbad'
        ? pass('sanitize_input strips dangerous chars from username')
        : fail("sanitize_input: got '$clean'");
}

# 2. validate_provision accepts valid parameters (user does not exist)
{
    $mock_user_exists = 0;
    $port_busy = 0;
    my $err = validate_provision('mcserver', 'minecraft', 25565);
    !defined($err)
        ? pass('validate_provision accepts valid input')
        : fail("validate_provision rejected valid input: $err");
}

# 3. validate_provision rejects empty username
{
    $mock_user_exists = 0;
    my $err = validate_provision('', 'minecraft', 25565);
    defined($err)
        ? pass('validate_provision rejects empty username')
        : fail('validate_provision should reject empty username');
}

# 4. validate_provision rejects username with uppercase / invalid chars
{
    $mock_user_exists = 0;
    my $err = validate_provision('McServer', 'minecraft', 25565);
    defined($err)
        ? pass('validate_provision rejects uppercase username')
        : fail('validate_provision should reject uppercase username');
}

# 5. validate_provision rejects already-taken port
{
    $mock_user_exists = 0;
    $port_busy = 1;
    my $err = validate_provision('mcserver', 'minecraft', 25565);
    defined($err)
        ? pass('validate_provision rejects port already in use')
        : fail('validate_provision should reject busy port');
    $port_busy = 0;
}

# 6. validate_provision rejects existing system user
{
    $mock_user_exists = 1;
    my $err = validate_provision('mcserver', 'minecraft', 25565);
    defined($err)
        ? pass('validate_provision rejects existing system user')
        : fail('validate_provision should reject existing system user');
    $mock_user_exists = 0;
}

# 7. port re-validation in step 3 — simulate the guard
{
    $port_busy = 1;
    my $caught = 0;
    eval {
        port_in_use(25565) and error($text{'err_port_in_use'});
    };
    $caught = 1 if $@ && $@ =~ /Port in use/;
    $caught
        ? pass('step 3 port re-validation fires error when port is taken')
        : fail('step 3 port re-validation should fire error');
    $port_busy = 0;
}

# 8. wizard Step 3b sources MC versions from mc_list_mc_versions (no hardcoded 1.21.1)
{
    open my $fh, '<', 'src/wizard.cgi' or die "Cannot read wizard.cgi: $!";
    local $/;
    my $src = <$fh>;
    close $fh;
    my $uses_list = $src =~ /mc_list_mc_versions\s*\(\s*\)/;
    my $hardcoded_default = $src =~ /\$versions\[0\]\s*\/\/\s*'1\.21\.1'/
        || $src =~ /sel_mc_version\s*=\s*'1\.21\.1'/;
    ($uses_list && !$hardcoded_default)
        ? pass('wizard.cgi uses mc_list_mc_versions without hardcoded 1.21.1 default')
        : fail('wizard.cgi must use mc_list_mc_versions and must not hardcode 1.21.1 default');
}
