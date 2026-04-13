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

# Override config_directory to a real tempdir so _instances_file() works
our $config_directory = tempdir(CLEANUP => 1);

# Minimal stubs needed by instance.pl
sub sanitize_input {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/[^a-z0-9_\-]//g;
    return $s;
}
sub firewall_status   { return 0 }
sub firewall_open_port  { }
sub firewall_close_port { }

require 'src/lib/instance.pl';

print "1..5\n";

# 1. register_instance: schreibt korrekt ins File
{
    &register_instance('mcserver', 'minecraft', '/home/minecraft/mcserver');
    my $file = &_instances_file();
    my $found = 0;
    open(my $fh, '<', $file) or die "Cannot read instances file: $!";
    while (<$fh>) { $found = 1 if /^mcserver=minecraft:\/home\/minecraft\/mcserver$/ }
    close($fh);
    $found
        ? pass('register_instance writes correct entry')
        : fail('register_instance writes correct entry');
}

# 2. _load_registered: liest Eintrag zurück
{
    my %reg = &_load_registered();
    (exists $reg{'mcserver'} &&
     $reg{'mcserver'}{'user'}   eq 'minecraft' &&
     $reg{'mcserver'}{'script'} eq '/home/minecraft/mcserver')
        ? pass('_load_registered reads entry back')
        : fail('_load_registered reads entry back');
}

# 3. register_instance: zweiter Aufruf kein Duplikat
{
    &register_instance('mcserver', 'minecraft', '/home/minecraft/mcserver');
    my %reg = &_load_registered();
    my $count = scalar grep { $_ eq 'mcserver' } keys %reg;
    $count == 1
        ? pass('register_instance no duplicate on second call')
        : fail("register_instance no duplicate (got $count entries)");
}

# 4. register_instance + unregister_instance
{
    &register_instance('valheimserver', 'valheim', '/home/valheim/valheimserver');
    &unregister_instance('valheimserver');
    my %reg = &_load_registered();
    !exists $reg{'valheimserver'}
        ? pass('unregister_instance removes entry')
        : fail('unregister_instance removes entry');
}

# 5. unregister_instance belässt andere Einträge
{
    my %reg = &_load_registered();
    exists $reg{'mcserver'}
        ? pass('unregister_instance leaves other entries intact')
        : fail('unregister_instance leaves other entries intact');
}
