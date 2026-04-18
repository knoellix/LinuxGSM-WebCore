#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 6;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

require "$Bin/stubs.pl";

# Patch config_directory to temp dir
our $config_directory;
my $tmpdir = tempdir(CLEANUP => 1);
$config_directory = $tmpdir;

# Mock getpwnam so get_instance doesn't fail
BEGIN {
    *CORE::GLOBAL::getpwnam = sub {
        return ('testuser','x',1001,1001,'','','/home/testuser','/usr/sbin/nologin') if $_[0] eq 'testuser';
        return ();
    };
}

require "$Bin/../src/lib/instance.pl";

# Write a test registry file with 7 columns
open(my $fh, '>', "$tmpdir/instances") or die $!;
print $fh "myserver\ttestuser\t/home/testuser/myserver\tmanual\t\t\tmysteamaccount\n";
close($fh);

# Test 1: _load_registered reads steam_account
my %reg = _load_registered();
ok(exists $reg{'myserver'}, 'instance loaded');
is($reg{'myserver'}{'steam_account'}, 'mysteamaccount', 'steam_account read from column 7');

# Test 2: _save_registered writes steam_account
$reg{'myserver'}{'steam_account'} = 'newsteamuser';
_save_registered(\%reg);
open($fh, '<', "$tmpdir/instances") or die $!;
my $line = <$fh>; chomp $line;
close($fh);
my @cols = split(/\t/, $line);
is($cols[6], 'newsteamuser', 'steam_account written as column 7');

# Test 3: register_instance with steam_account
register_instance('srv2', 'testuser', '/home/testuser/srv2', { steam_account => 'acc2' });
my %reg2 = _load_registered();
is($reg2{'srv2'}{'steam_account'}, 'acc2', 'register_instance saves steam_account');

# Test 4: register_instance without steam_account preserves existing
register_instance('srv2', 'testuser', '/home/testuser/srv2', {});
my %reg3 = _load_registered();
is($reg3{'srv2'}{'steam_account'}, 'acc2', 'register_instance preserves steam_account when not provided');

# Test 5: empty steam_account for legacy 6-column format
open($fh, '>', "$tmpdir/instances") or die $!;
print $fh "legacy\ttestuser\t/home/testuser/legacy\tmanual\t\t\n";
close($fh);
my %reg4 = _load_registered();
is($reg4{'legacy'}{'steam_account'} // '', '', 'legacy 6-column format: steam_account defaults to empty');
