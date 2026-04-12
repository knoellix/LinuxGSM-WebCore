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

# Temp-Verzeichnis für ACL-Dateien
our $stub_acl_dir = tempdir(CLEANUP => 1);
our $module_name  = 'linuxgsm-webcore';

# %access wird von init_config() befüllt — hier manuell gesetzt
our %access;

# list_instances() wird in list_managed_instances() genutzt
sub list_instances {
    return (
        { user => 'mc-test',  game => 'Minecraft',         port => 25565 },
        { user => 'tf2-test', game => 'Team Fortress 2',   port => 27015 },
    );
}

require 'src/lib/acl.pl';

print "1..12\n";

# 1. can_create: false by default
{
    %access = ();
    !&can_create()
        ? pass('can_create false by default')
        : fail('can_create false by default');
}

# 2. can_create: true when set
{
    %access = (can_create => 1);
    &can_create()
        ? pass('can_create true when set')
        : fail('can_create true when set');
}

# 3. can_scan: false by default
{
    %access = ();
    !&can_scan()
        ? pass('can_scan false by default')
        : fail('can_scan false by default');
}

# 4. can_scan: true when set
{
    %access = (can_scan => 1);
    &can_scan()
        ? pass('can_scan true when set')
        : fail('can_scan true when set');
}

# 5. allowed_servers: returns ('*') for wildcard
{
    %access = (servers => '*');
    my @s = &allowed_servers();
    ($s[0] // '') eq '*'
        ? pass('allowed_servers returns wildcard')
        : fail("allowed_servers returns wildcard (got: @s)");
}

# 6. allowed_servers: parses space-separated list
{
    %access = (servers => 'mc-test tf2-test');
    my @s = &allowed_servers();
    (scalar(@s) == 2 && $s[0] eq 'mc-test' && $s[1] eq 'tf2-test')
        ? pass('allowed_servers parses list')
        : fail("allowed_servers parses list (got: @s)");
}

# 7. user_can_manage: wildcard grants access to any server
{
    %access = (servers => '*');
    &user_can_manage('any-server')
        ? pass('user_can_manage true with wildcard')
        : fail('user_can_manage true with wildcard');
}

# 8. user_can_manage: listed server granted
{
    %access = (servers => 'mc-test');
    &user_can_manage('mc-test')
        ? pass('user_can_manage true for listed server')
        : fail('user_can_manage true for listed server');
}

# 9. user_can_manage: unlisted server denied
{
    %access = (servers => 'mc-test');
    !&user_can_manage('tf2-test')
        ? pass('user_can_manage false for unlisted server')
        : fail('user_can_manage false for unlisted server');
}

# 10. list_managed_instances: filters by servers
{
    %access = (servers => 'mc-test');
    my @inst = &list_managed_instances();
    (scalar(@inst) == 1 && $inst[0]{'user'} eq 'mc-test')
        ? pass('list_managed_instances filters correctly')
        : fail("list_managed_instances filters correctly (got " . scalar(@inst) . ")");
}

# 11. grant_server_access: schreibt Server in ACL, keine Duplikate
{
    &grant_server_access('alice', 'mc-test');
    &grant_server_access('alice', 'mc-test');  # zweites Mal — kein Duplikat
    my %acl = &get_module_acl('alice', 'linuxgsm-webcore');
    my @servers = split /\s+/, ($acl{'servers'} // '');
    my $count = scalar grep { $_ eq 'mc-test' } @servers;
    $count == 1
        ? pass('grant_server_access writes once, no duplicate')
        : fail("grant_server_access writes once, no duplicate (count=$count)");
}

# 12. list_managed_instances: wildcard gibt alle zurück
{
    %access = (servers => '*');
    my @inst = &list_managed_instances();
    scalar(@inst) == 2
        ? pass('list_managed_instances returns all with wildcard')
        : fail("list_managed_instances returns all with wildcard (got " . scalar(@inst) . ")");
}
