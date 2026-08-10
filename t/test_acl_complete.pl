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

our ($module_name, $remote_user, $config_directory,
     $_effective_role_cache, $_module_acl_cache);
our %access;
$module_name = 'linuxgsm-webcore';
$remote_user = 'testuser';
$config_directory = '/nonexistent';

# Stub: get_instance — für allowed_ftp_users Tests
my %_inst_db = (
    'mc1' => { id => 'mc1', user => 'mcuser', sftp_user => 'mc-ftp' },
    'tf1' => { id => 'tf1', user => 'tfuser', sftp_user => ''       },
);
sub get_instance { return $_inst_db{$_[0]} }

require 'src/lib/acl.pl';

print "1..10\n";

# Test 1: user-Datei ohne role-Feld → role aus defaultacl (operator).
# Per-user ACLs go through Webmin's get_module_acl() — the test stub
# stores them at $stub_acl_dir/$module/$user. The defaultacl is read
# from $module_root/defaultacl as last-resort fallback.
{
    my $tmp_acl = tempdir(CLEANUP => 1);
    mkdir "$tmp_acl/$module_name";
    open(my $fh, '>', "$tmp_acl/$module_name/testuser") or die $!;
    print $fh "can_manage_ftp=1\n";   # hat Felder aber KEIN role
    close $fh;
    our $stub_acl_dir;
    $stub_acl_dir = $tmp_acl;

    my $tmp_root = tempdir(CLEANUP => 1);
    open(my $df, '>', "$tmp_root/defaultacl") or die $!;
    print $df "role=operator\nservers=\ncan_manage_ftp=1\n";
    close $df;
    our $module_root;
    $module_root = $tmp_root;

    $_effective_role_cache = undef;
    $_module_acl_cache     = undef;
    %access = ();

    effective_role() eq 'operator'
        ? pass('_compute_role merge: user-Datei ohne role → operator von defaultacl')
        : fail('_compute_role merge: user-Datei ohne role → operator von defaultacl (got: ' . (effective_role()//'undef') . ')');
    $module_root      = undef;
    $stub_acl_dir     = '/nonexistent';
}

# Test 2: user-Datei MIT role=operator hat Vorrang vor defaultacl
{
    my $tmp_acl = tempdir(CLEANUP => 1);
    mkdir "$tmp_acl/$module_name";
    open(my $fh, '>', "$tmp_acl/$module_name/testuser") or die $!;
    print $fh "role=operator\ncan_manage_ftp=0\n";
    close $fh;
    our $stub_acl_dir;
    $stub_acl_dir = $tmp_acl;

    my $tmp_root = tempdir(CLEANUP => 1);
    open(my $df, '>', "$tmp_root/defaultacl") or die $!;
    print $df "role=admin\n";
    close $df;
    our $module_root;
    $module_root = $tmp_root;

    $_effective_role_cache = undef;
    $_module_acl_cache     = undef;
    %access = ();

    effective_role() eq 'operator'
        ? pass('_compute_role: user-Datei mit role=operator hat Vorrang vor defaultacl')
        : fail('_compute_role: user-Datei mit role=operator hat Vorrang (got: ' . (effective_role()//'undef') . ')');
    $module_root      = undef;
    $stub_acl_dir     = '/nonexistent';
}

# Test 3: Admin sieht alle FTP-User
{
    $_effective_role_cache = undef;
    $_module_acl_cache     = undef;
    %access = (role => 'admin');
    my @r = allowed_ftp_users('mc-ftp', 'other-ftp', 'third-ftp');
    scalar(@r) == 3
        ? pass('allowed_ftp_users: admin bekommt alle 3 FTP-User')
        : fail('allowed_ftp_users: admin soll 3 bekommen, got ' . scalar(@r));
}

# Test 4: Operator mit Server mc1 (sftp_user=mc-ftp) → nur mc-ftp
{
    $_effective_role_cache = undef;
    $_module_acl_cache     = undef;
    %access = (role => 'operator', servers => 'mc1');
    my @r = allowed_ftp_users('mc-ftp', 'other-ftp');
    (scalar(@r) == 1 && $r[0] eq 'mc-ftp')
        ? pass('allowed_ftp_users: operator sieht nur FTP-User seines Servers')
        : fail('allowed_ftp_users: operator filter (got: ' . join(', ', @r) . ')');
}

# Test 5: Operator mit Server tf1 (sftp_user='') → leere Liste
{
    $_effective_role_cache = undef;
    $_module_acl_cache     = undef;
    %access = (role => 'operator', servers => 'tf1');
    my @r = allowed_ftp_users('mc-ftp', 'other-ftp');
    scalar(@r) == 0
        ? pass('allowed_ftp_users: operator ohne sftp_user sieht keine FTP-User')
        : fail('allowed_ftp_users: operator ohne sftp_user (got: ' . join(', ', @r) . ')');
}

# Test 6: Leerer Input → leere Liste
{
    $_effective_role_cache = undef;
    $_module_acl_cache     = undef;
    %access = (role => 'operator', servers => 'mc1');
    my @r = allowed_ftp_users();
    scalar(@r) == 0
        ? pass('allowed_ftp_users: leerer Input → leere Liste')
        : fail('allowed_ftp_users: leerer Input (got: ' . scalar(@r) . ')');
}

# Test 7: Operator mit wildcard servers ('*') → alle FTP-User
{
    $_effective_role_cache = undef;
    $_module_acl_cache     = undef;
    %access = (role => 'operator', servers => '*');
    my @r = allowed_ftp_users('mc-ftp', 'other-ftp');
    scalar(@r) == 2
        ? pass('allowed_ftp_users: operator mit servers=* sieht alle FTP-User')
        : fail('allowed_ftp_users: operator wildcard (got: ' . scalar(@r) . ')');
}

# Test 8: grant_server_access setzt role=operator wenn kein role vorhanden
{
    my $tmp_acl = tempdir(CLEANUP => 1);
    mkdir "$tmp_acl/$module_name";
    open(my $fh, '>', "$tmp_acl/$module_name/newuser") or die $!;
    print $fh "servers=\n";
    close $fh;
    our $stub_acl_dir;
    $stub_acl_dir = $tmp_acl;

    $_effective_role_cache = undef;
    $_module_acl_cache     = undef;

    grant_server_access('newuser', 'mc1');

    open(my $r, '<', "$tmp_acl/$module_name/newuser") or die "Can't read: $!";
    my %saved;
    while (<$r>) {
        chomp; next unless /=/;
        my ($k, $v) = split(/=/, $_, 2);
        $saved{$k} = $v if defined $k && defined $v;
    }
    close($r);

    (($saved{role} // '') eq 'operator' && ($saved{servers} // '') =~ /mc1/)
        ? pass('grant_server_access: setzt role=operator und fügt Server hinzu')
        : fail("grant_server_access: role=" . ($saved{role}//'undef') . " servers=" . ($saved{servers}//'undef'));

    $stub_acl_dir = '/nonexistent';
}

# Test 9: grant_server_access überschreibt bestehende role NICHT
{
    my $tmp_acl = tempdir(CLEANUP => 1);
    mkdir "$tmp_acl/$module_name";
    open(my $fh, '>', "$tmp_acl/$module_name/vieweruser") or die $!;
    print $fh "role=viewer\nservers=\n";
    close $fh;
    our $stub_acl_dir;
    $stub_acl_dir = $tmp_acl;

    $_effective_role_cache = undef;
    $_module_acl_cache     = undef;

    grant_server_access('vieweruser', 'mc1');

    open(my $r, '<', "$tmp_acl/$module_name/vieweruser") or die "Can't read: $!";
    my %saved;
    while (<$r>) {
        chomp; next unless /=/;
        my ($k, $v) = split(/=/, $_, 2);
        $saved{$k} = $v if defined $k && defined $v;
    }
    close($r);

    ($saved{role} // '') eq 'viewer'
        ? pass('grant_server_access: überschreibt bestehende role nicht')
        : fail("grant_server_access: role soll viewer bleiben, got '" . ($saved{role}//'undef') . "'");

    $stub_acl_dir = '/nonexistent';
}

# Test 10: shipped defaultacl must not grant admin to every user
{
    open(my $df, '<', 'src/defaultacl') or die "Cannot read src/defaultacl: $!";
    my %dflt;
    while (<$df>) {
        chomp; next unless /=/;
        my ($k, $v) = split(/=/, $_, 2);
        $dflt{$k} = $v if defined $k;
    }
    close $df;

    (($dflt{role} // '') ne 'admin')
        ? pass('shipped defaultacl: role is not admin')
        : fail('shipped defaultacl: role=admin grants admin to all users without explicit ACL');
}
