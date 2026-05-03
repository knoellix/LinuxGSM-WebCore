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

# Mock acl::master_admin — never a Webmin admin in these tests
package acl;
sub master_admin { return 0 }
package main;

require 't/stubs.pl';

our $stub_acl_dir = tempdir(CLEANUP => 1);
our $module_name  = 'linuxgsm-webcore';
our (%access, $remote_user, $config_directory,
     $_effective_role_cache, $_module_acl_cache);
$remote_user = 'testuser';
# Point ACL fallback at a non-existent dir so tests run purely from %access.
$config_directory = '/nonexistent';

# Reset all per-request caches between blocks. Without this each test
# sees the cached _module_acl from the previous block and cross-contaminates.
sub _r { $_effective_role_cache = undef; $_module_acl_cache = undef; }

sub list_instances {
    return (
        { id => 'mc-test',  user => 'mc-test',  game => 'Minecraft',       port => 25565 },
        { id => 'tf2-test', user => 'tf2-test',  game => 'Team Fortress 2', port => 27015 },
    );
}

require 'src/lib/acl.pl';

print "1..14\n";

# 1. can_create: false for operator (no role key = operator default)
{
    _r();
    %access = ();
    !can_create()
        ? pass('can_create false for operator (no role key)')
        : fail('can_create false for operator (no role key)');
}

# 2. can_create: true for explicit admin role
{
    _r();
    %access = (role => 'admin');
    can_create()
        ? pass('can_create true for admin role')
        : fail('can_create true for admin role');
}

# 3. can_scan: false for operator
{
    _r();
    %access = (role => 'operator');
    !can_scan()
        ? pass('can_scan false for operator')
        : fail('can_scan false for operator');
}

# 4. can_scan: true for admin
{
    _r();
    %access = (role => 'admin');
    can_scan()
        ? pass('can_scan true for admin')
        : fail('can_scan true for admin');
}

# 5. allowed_servers: admin → returns ('*')
{
    _r();
    %access = (role => 'admin');
    my @s = allowed_servers();
    ($s[0] // '') eq '*'
        ? pass('allowed_servers returns wildcard for admin')
        : fail("allowed_servers returns wildcard for admin (got: @s)");
}

# 6. allowed_servers: operator, parses space-separated list
{
    _r();
    %access = (role => 'operator', servers => 'mc-test tf2-test');
    my @s = allowed_servers();
    (scalar(@s) == 2 && $s[0] eq 'mc-test' && $s[1] eq 'tf2-test')
        ? pass('allowed_servers parses list for operator')
        : fail("allowed_servers parses list for operator (got: @s)");
}

# 7. user_can_manage: admin can manage any server
{
    _r();
    %access = (role => 'admin');
    user_can_manage('any-server')
        ? pass('user_can_manage true for admin')
        : fail('user_can_manage true for admin');
}

# 8. user_can_manage: operator with listed server
{
    _r();
    %access = (role => 'operator', servers => 'mc-test');
    user_can_manage('mc-test')
        ? pass('user_can_manage true for listed server')
        : fail('user_can_manage true for listed server');
}

# 9. user_can_manage: operator, unlisted server denied
{
    _r();
    %access = (role => 'operator', servers => 'mc-test');
    !user_can_manage('tf2-test')
        ? pass('user_can_manage false for unlisted server')
        : fail('user_can_manage false for unlisted server');
}

# 10. list_managed_instances: operator filtered by servers
{
    _r();
    %access = (role => 'operator', servers => 'mc-test');
    my @inst = list_managed_instances();
    (scalar(@inst) == 1 && $inst[0]{'id'} eq 'mc-test')
        ? pass('list_managed_instances filters correctly')
        : fail("list_managed_instances filters correctly (got " . scalar(@inst) . ")");
}

# 11. list_managed_instances: admin gets all
{
    _r();
    %access = (role => 'admin');
    my @inst = list_managed_instances();
    scalar(@inst) == 2
        ? pass('list_managed_instances returns all for admin')
        : fail("list_managed_instances returns all for admin (got " . scalar(@inst) . ")");
}

# 12. grant_server_access: schreibt Server in ACL, keine Duplikate
{
    grant_server_access('alice', 'mc-test');
    grant_server_access('alice', 'mc-test');
    my %acl = get_module_acl('alice', 'linuxgsm-webcore');
    my @servers = split /\s+/, ($acl{'servers'} // '');
    my $count = scalar grep { $_ eq 'mc-test' } @servers;
    $count == 1
        ? pass('grant_server_access writes once, no duplicate')
        : fail("grant_server_access writes once, no duplicate (count=$count)");
}

# 13. Legacy: servers=* without role → effective_role = admin
{
    _r();
    %access = (servers => '*');
    effective_role() eq 'admin'
        ? pass('legacy servers=* → effective_role admin')
        : fail('legacy servers=* → effective_role admin (got: ' . effective_role() . ')');
}

# 14. is_admin: legacy servers=* → true
{
    _r();
    %access = (servers => '*');
    is_admin()
        ? pass('is_admin true for legacy servers=*')
        : fail('is_admin true for legacy servers=*');
}
