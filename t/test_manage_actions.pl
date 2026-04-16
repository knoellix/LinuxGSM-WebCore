#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
chdir "$Bin/.." or die "Cannot chdir: $!";

print "1..6\n";

sub pass { print "ok - $_[0]\n" }
sub fail { print "not ok - $_[0]\n" }

# --- stubs ---
our (%text, %in, %access, $module_name);
$module_name = 'linuxgsm-webcore';
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
sub list_webmin_users { return ('admin', 'user1') }

require './src/lib/acl.pl';

# 1. can_create defaults to 1 when key absent (stale ACL)
{
    %access = ();
    can_create()
        ? pass('can_create defaults to 1 with absent key')
        : fail('can_create should default to 1');
}

# 2. can_create respects explicit 0
{
    %access = (can_create => 0);
    !can_create()
        ? pass('can_create returns 0 when explicitly set to 0')
        : fail('can_create should return 0');
}

# 3. can_scan defaults to 1 when key absent
{
    %access = ();
    can_scan()
        ? pass('can_scan defaults to 1 with absent key')
        : fail('can_scan should default to 1');
}

# 4. user_can_manage: wildcard grants access to any instance
{
    %access = (servers => '*');
    user_can_manage('anyserver')
        ? pass('user_can_manage: wildcard grants access')
        : fail('user_can_manage: wildcard should grant access');
}

# 5. user_can_manage: explicit list only grants access to listed instance
{
    %access = (servers => 'mcserver valheim');
    my $ok_mc  = user_can_manage('mcserver');
    my $ok_ark = user_can_manage('arkserver');
    ($ok_mc && !$ok_ark)
        ? pass('user_can_manage: explicit list grants correct access')
        : fail('user_can_manage: explicit list grants wrong access');
}

# 6. is_admin: false when specific servers listed
{
    %access = (servers => 'mcserver');
    !is_admin()
        ? pass('is_admin returns 0 for restricted user')
        : fail('is_admin should return 0 for restricted user');
}
