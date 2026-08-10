#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 9;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
chdir "$Bin/.." or die "cannot chdir: $!";
use lib '.';

require 't/stubs.pl';

our ($config_directory, $module_name, $module_config_directory, $module_root, $stub_acl_dir);

$module_name = 'linuxgsm-webcore';
my $tmp = tempdir(CLEANUP => 1);
$config_directory = $tmp;
$module_config_directory = "$tmp/$module_name";
$module_root = 'src';
mkdir $module_config_directory;
$stub_acl_dir = tempdir(CLEANUP => 1);
mkdir "$stub_acl_dir/$module_name";

sub firewall_status   { return 0 }
sub firewall_open_port  { }
sub firewall_close_port { }

require 'src/lib/module_config.pl';
require 'src/lib/instance.pl';
require 'src/lib/acl.pl';

ok(&register_instance('mc1', 'mcuser', '/home/mcuser/mcserver', {
    source => 'manual', owners => 'alice',
}), 'register_instance returns 1 on success');

{
    my $reg = get_registered_instance('mc1');
    ok($reg && ($reg->{owners} // '') =~ /alice/, 'owners persisted in registry');
}

ok(&grant_server_access('alice', 'mc1'), 'grant_server_access returns 1');
{
    my %acl = get_module_acl('alice', $module_name);
    like($acl{servers} // '', qr/mc1/, 'grant_server_access persisted server id');
}

ok(&unregister_instance('mc1'), 'unregister_instance returns 1');
ok(!get_registered_instance('mc1'), 'instance removed from registry');

ok(&module_config_flash_mark('scan_assigned'), 'scan flash mark writes file');
ok(&module_config_flash_consume('scan_assigned'), 'scan flash consume on fresh mark');
ok(!module_config_flash_consume('scan_assigned'), 'scan flash not consumed twice');
