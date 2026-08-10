#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
use Test::More tests => 6;
chdir "$Bin/.." or die "Cannot chdir: $!";

# Mock acl::master_admin — never a Webmin master admin in these tests
package acl;
sub master_admin { return 0 }
package main;

# --- stubs ---
our (%text, %in, %access, $module_name, $remote_user, $config_directory,
     $_effective_role_cache, $_module_acl_cache);
$module_name       = 'linuxgsm-webcore';
$remote_user       = 'test_manage_actions';
$config_directory  = '/nonexistent';
%text = (
    err_invalid_input  => 'Invalid input',
    err_not_found      => 'Not found',
    err_invalid_action => 'Invalid action',
    err_access_denied  => 'Access denied',
);

my $error_msg;
sub error { $error_msg = $_[0]; die "error: $_[0]\n" }
sub sanitize_input {
    my ($in) = @_;
    $in //= '';
    $in =~ s/[^a-zA-Z0-9_\-]//g;
    return $in;
}
sub system_logged { return 0 }
sub html_escape {
    my ($s) = @_;
    $s //= '';
    $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g;
    return $s;
}
sub foreign_require { return 1 }
sub get_module_acl  { return () }
sub save_module_acl { return 1 }

require './src/lib/acl.pl';

# Reset per-request ACL caches between blocks (same pattern as t/test_acl.pl).
sub _acl_reset {
    $_effective_role_cache = undef;
    $_module_acl_cache     = undef;
}

# 1. can_create returns true for admin role
{
    _acl_reset();
    %access = (role => 'admin');
    ok( can_create(), 'can_create true for admin role' );
}

# 2. can_create returns false for operator (no role = operator default)
{
    _acl_reset();
    %access = ();
    ok( !can_create(), 'can_create false for operator (no role key)' );
}

# 3. can_scan returns true for admin role
{
    _acl_reset();
    %access = (role => 'admin');
    ok( can_scan(), 'can_scan true for admin role' );
}

# 4. user_can_manage: wildcard grants access to any instance
{
    _acl_reset();
    %access = (servers => '*');
    ok( user_can_manage('anyserver'), 'user_can_manage: wildcard grants access' );
}

# 5. user_can_manage: explicit list only grants access to listed instance
{
    _acl_reset();
    %access = (servers => 'mcserver valheim');
    my $ok_mc  = user_can_manage('mcserver');
    my $ok_ark = user_can_manage('arkserver');
    ok( $ok_mc && !$ok_ark, 'user_can_manage: explicit list grants correct access' );
}

# 6. is_admin: false when specific servers listed (operator)
{
    _acl_reset();
    %access = (servers => 'mcserver');
    ok( !is_admin(), 'is_admin returns 0 for restricted user' );
}
