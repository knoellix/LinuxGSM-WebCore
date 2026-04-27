#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
use File::Temp qw(tempdir);
chdir "$Bin/.." or die "Cannot chdir: $!";

sub pass { print "ok - $_[0]\n" }
sub fail { print "not ok - $_[0]\n" }
sub error { die "error: $_[0]\n" }

require 't/stubs.pl';
our $stub_acl_dir = tempdir(CLEANUP => 1);
our $module_name  = 'linuxgsm-webcore';
our (%access, $remote_user, $config_directory, $_effective_role_cache);
$remote_user      = 'testuser';
$config_directory = '/nonexistent';  # no real ACL files in tests

sub list_instances {
    return (
        { id => 'gs_mc_srv', user => 'gs_mc', game => 'Minecraft', port => 25565 },
        { id => 'gs_tf2',    user => 'gs_tf2', game => 'TF2',       port => 27015 },
    );
}

require 'src/lib/acl.pl';

print "1..18\n";

# --- effective_role ---

# 1. Keine ACL gesetzt (leeres %access) → operator (sicherer Default)
{
    $_effective_role_cache = undef;
    %access = ();
    effective_role() eq 'operator'
        ? pass('effective_role: leer → operator (sicherer Default)')
        : fail('effective_role: leer → operator (got: ' . effective_role() . ')');
}

# 2. role=operator → 'operator'
{
    $_effective_role_cache = undef;
    %access = (role => 'operator');
    effective_role() eq 'operator'
        ? pass('effective_role: role=operator → operator')
        : fail('effective_role: role=operator → operator');
}

# 3. role=viewer → 'viewer'
{
    $_effective_role_cache = undef;
    %access = (role => 'viewer');
    effective_role() eq 'viewer'
        ? pass('effective_role: role=viewer → viewer')
        : fail('effective_role: role=viewer → viewer');
}

# 4. Legacy: kein role-Feld, servers=* → 'admin'
{
    $_effective_role_cache = undef;
    %access = (servers => '*');
    effective_role() eq 'admin'
        ? pass('effective_role: legacy servers=* → admin')
        : fail('effective_role: legacy servers=* → admin (got: ' . effective_role() . ')');
}

# 5. Legacy: kein role-Feld, servers eingeschränkt → 'operator'
{
    $_effective_role_cache = undef;
    %access = (servers => 'gs_mc_srv');
    effective_role() eq 'operator'
        ? pass('effective_role: legacy restricted servers → operator')
        : fail('effective_role: legacy restricted servers → operator (got: ' . effective_role() . ')');
}

# --- is_admin ---

# 6. Admin-Rolle → is_admin true
{
    $_effective_role_cache = undef;
    %access = (role => 'admin');
    is_admin()
        ? pass('is_admin true for admin role')
        : fail('is_admin true for admin role');
}

# 7. Operator → is_admin false
{
    $_effective_role_cache = undef;
    %access = (role => 'operator');
    !is_admin()
        ? pass('is_admin false for operator')
        : fail('is_admin false for operator');
}

# --- can_create ---

# 8. Admin → can_create true
{
    $_effective_role_cache = undef;
    %access = (role => 'admin');
    can_create()
        ? pass('can_create true for admin')
        : fail('can_create true for admin');
}

# 9. Operator → can_create false
{
    $_effective_role_cache = undef;
    %access = (role => 'operator');
    !can_create()
        ? pass('can_create false for operator')
        : fail('can_create false for operator');
}

# --- can_scan ---

# 10. Admin → can_scan true
{
    $_effective_role_cache = undef;
    %access = (role => 'admin');
    can_scan()
        ? pass('can_scan true for admin')
        : fail('can_scan true for admin');
}

# 11. Operator → can_scan false
{
    $_effective_role_cache = undef;
    %access = (role => 'operator');
    !can_scan()
        ? pass('can_scan false for operator')
        : fail('can_scan false for operator');
}

# --- can_manage_ftp ---

# 12. Admin → can_manage_ftp true immer
{
    $_effective_role_cache = undef;
    %access = (role => 'admin', can_manage_ftp => 0);
    can_manage_ftp()
        ? pass('can_manage_ftp true for admin ignoring flag')
        : fail('can_manage_ftp true for admin ignoring flag');
}

# 13. Operator + can_manage_ftp=1 → true
{
    $_effective_role_cache = undef;
    %access = (role => 'operator', can_manage_ftp => 1);
    can_manage_ftp()
        ? pass('can_manage_ftp true for operator with flag')
        : fail('can_manage_ftp true for operator with flag');
}

# 14. Viewer + can_manage_ftp=1 → true
{
    $_effective_role_cache = undef;
    %access = (role => 'viewer', can_manage_ftp => 1, servers => 'gs_mc_srv');
    can_manage_ftp()
        ? pass('can_manage_ftp true for viewer with flag')
        : fail('can_manage_ftp true for viewer with flag');
}

# 15. Operator + can_manage_ftp=0 → false
{
    $_effective_role_cache = undef;
    %access = (role => 'operator', can_manage_ftp => 0);
    !can_manage_ftp()
        ? pass('can_manage_ftp false for operator without flag')
        : fail('can_manage_ftp false for operator without flag');
}

# --- user_is_readonly ---

# 16. Viewer mit zugewiesenem Server → readonly
{
    $_effective_role_cache = undef;
    %access = (role => 'viewer', servers => 'gs_mc_srv');
    user_is_readonly('gs_mc_srv')
        ? pass('user_is_readonly true for viewer with access')
        : fail('user_is_readonly true for viewer with access');
}

# 17. Operator → niemals readonly
{
    $_effective_role_cache = undef;
    %access = (role => 'operator', servers => 'gs_mc_srv');
    !user_is_readonly('gs_mc_srv')
        ? pass('user_is_readonly false for operator')
        : fail('user_is_readonly false for operator');
}

# 18. Viewer ohne Zugriff auf diesen Server → user_is_readonly 0
{
    $_effective_role_cache = undef;
    %access = (role => 'viewer', servers => 'gs_tf2');
    !user_is_readonly('gs_mc_srv')
        ? pass('user_is_readonly false for viewer without access to this server')
        : fail('user_is_readonly false for viewer without access to this server');
}
