#!/usr/bin/perl
# t/test_acl_namespace_bug.pl
#
# Reproduce the "operator sees all servers" bug.
#
# Webmin populates %main::access from /etc/webmin/<mod>/<user>, but our
# libs run in the module's package. `our %access` in acl.pl therefore
# reads an empty hash even though the ACL file is fully populated. The
# old `allowed_servers()` returned ('*') unless `defined $access{'servers'}`,
# i.e. an empty hash made every operator a de-facto admin.
use strict;
use warnings;
use Test::More tests => 14;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
chdir "$Bin/.." or die "cannot chdir: $!";
use lib '.';

# Mock acl::master_admin — never a native Webmin admin in this test
package acl;
sub master_admin { return 0 }
package main;

require 't/stubs.pl';

our (%access, $remote_user, $config_directory, $module_name);
our ($_effective_role_cache, $_module_acl_cache);
our $stub_acl_dir;

$remote_user = 'operator-bob';
$module_name = 'linuxgsm-webcore';
$config_directory = tempdir(CLEANUP => 1);

# Webmin writes per-user ACLs via save_module_acl(); the test stub puts
# them under $stub_acl_dir/$module/$user. Mirror that here so _module_acl
# can read them through the stubbed get_module_acl().
$stub_acl_dir = tempdir(CLEANUP => 1);
mkdir "$stub_acl_dir/$module_name";
open(my $fh, '>', "$stub_acl_dir/$module_name/$remote_user") or die $!;
print $fh "role=operator\n";
print $fh "servers=gs_mcserver\n";
print $fh "can_manage_ftp=0\n";
close $fh;

sub list_instances {
    return (
        { id => 'gs_mcserver', user => 'gs_mc',     game => 'Minecraft' },
        { id => 'gs_tf2',      user => 'gs_tf2',    game => 'TF2' },
        { id => 'gs_windrose', user => 'gs_windr',  game => 'Windrose' },
    );
}

require 'src/lib/acl.pl';

# Simulate Webmin's namespace mismatch: %access is empty even though the
# file is on disk.
sub reset_caches {
    $_effective_role_cache = undef;
    $_module_acl_cache     = undef;
    %access = ();
}

reset_caches();
is(effective_role(), 'operator',
    'effective_role: file fallback recovers operator role from on-disk ACL');

reset_caches();
my @allowed = allowed_servers();
is_deeply([sort @allowed], ['gs_mcserver'],
    'allowed_servers: file fallback restricts to assigned server (was returning *)');

reset_caches();
ok(user_can_manage('gs_mcserver'),
    'user_can_manage: assigned server is allowed');

reset_caches();
ok(!user_can_manage('gs_tf2'),
    'user_can_manage: unassigned server is denied');

reset_caches();
ok(!can_manage_ftp(),
    'can_manage_ftp: file fallback honors can_manage_ftp=0');

reset_caches();
my @managed = list_managed_instances();
is_deeply(
    [sort map { $_->{'id'} } @managed],
    ['gs_mcserver'],
    'list_managed_instances: operator only sees assigned server (was seeing all)',
);

# ------------------------------------------------------------------
# Admin recovery: when the admin user has NO per-user ACL file at all,
# acl.pl must still resolve them as admin via either:
#   (a) acl::master_admin returning true, OR
#   (b) a defaultacl that ships role=admin.
# Otherwise the admin lands on the safe 'operator' default and loses
# every admin button + every instance — exactly the regression we just
# saw in production.
# ------------------------------------------------------------------
{
    # (a) master_admin returns true → role admin even with empty %access
    no warnings 'redefine';
    *acl::master_admin = sub { return 1 };
    local $remote_user = 'root';   # Webmin master admin
    reset_caches();
    %access = ();
    is(effective_role(), 'admin',
        'effective_role: master_admin → admin even with empty %access');
    ok(is_admin(), 'is_admin: master_admin → true');
    *acl::master_admin = sub { return 0 };  # restore
}

{
    # (b) defaultacl shipped at $module_root/defaultacl says role=admin
    our $module_root;
    my $tmp_root = tempdir(CLEANUP => 1);
    open(my $fh, '>', "$tmp_root/defaultacl") or die $!;
    print $fh "role=admin\nservers=\ncan_manage_ftp=1\n";
    close $fh;

    local $module_root = $tmp_root;
    local $remote_user = 'admin-no-acl-file';
    local $config_directory = tempdir(CLEANUP => 1);  # empty

    reset_caches();
    %access = ();
    is(effective_role(), 'admin',
        'effective_role: defaultacl recovers admin role for users without per-user file');
    ok(is_admin(), 'is_admin: defaultacl admin → true');
    is_deeply([allowed_servers()], ['*'],
        'allowed_servers: admin → wildcard, never the defaultacl empty servers field');
}

# ------------------------------------------------------------------
# Bridge from %main::access — Webmin populates main::access in some
# init_config flows; our package-local %access stays empty. _ctx_access
# must transparently fall back to main::access.
# ------------------------------------------------------------------
{
    local $remote_user = 'bridge-user';
    local $config_directory = tempdir(CLEANUP => 1);  # no files
    no warnings 'redefine';
    *acl::master_admin = sub { return 0 };

    reset_caches();
    %access = ();
    %main::access = (role => 'operator', servers => 'gs_mcserver',
                     can_manage_ftp => 1);
    is(effective_role(), 'operator',
        'effective_role: bridges %main::access when module-package %access is empty');
    %main::access = ();   # reset
}

# ------------------------------------------------------------------
# Admin recovery via $module_root_directory (Webmin's own variable name).
# index.cgi does NOT alias $module_root_directory → $module_root the way
# manage.cgi does, so _ctx_module_root must also accept the longer name.
# Without this, every admin without a per-user ACL file lands on the
# 'operator' default — exactly the regression seen in production.
# ------------------------------------------------------------------
{
    our ($module_root, $module_root_directory);   # declare for `local`
    my $tmp_root = tempdir(CLEANUP => 1);
    open(my $fh, '>', "$tmp_root/defaultacl") or die $!;
    print $fh "role=admin\nservers=\ncan_manage_ftp=1\n";
    close $fh;

    local $module_root = undef;                 # not set by index.cgi
    local $module_root_directory = $tmp_root;   # what Webmin sets natively
    local $remote_user = 'admin-user';
    local $config_directory = tempdir(CLEANUP => 1);  # no per-user file

    no warnings 'redefine';
    *acl::master_admin = sub { return 0 };      # not a master admin

    reset_caches();
    %access = ();
    is(effective_role(), 'admin',
        'effective_role: defaultacl read via $module_root_directory (index.cgi case)');
    ok(is_admin(), 'is_admin: $module_root_directory fallback → true');
}
