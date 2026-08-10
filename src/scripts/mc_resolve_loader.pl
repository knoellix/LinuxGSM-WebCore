#!/usr/bin/env perl
# Resolve mod-loader installer URL + version for mc_loader_install_user.sh
# Usage: mc_resolve_loader.pl <fabric|forge|neoforge> <mc_version> [pinned_loader_version]
# Prints shell-safe assignments: installer_url=... loader_version=...
use strict;
use warnings;
use FindBin qw($Bin);

our $module_root = "$Bin/..";
require "$Bin/../lib/mc_loader.pl";

sub _fail {
    my ($msg) = @_;
    print STDERR "ERROR: $msg\n";
    exit 1;
}

sub _shell_quote {
    my ($v) = @_;
    $v //= '';
    $v =~ s/'/'\\''/g;
    return "'$v'";
}

sub _emit {
    my (%kv) = @_;
    for my $k (sort keys %kv) {
        next unless defined $kv{$k} && $kv{$k} =~ /\S/;
        print "$k=", _shell_quote($kv{$k}), "\n";
    }
    exit 0;
}

my ($loader, $mc_version, $pinned) = @ARGV;
_fail("usage: mc_resolve_loader.pl <fabric|forge|neoforge> <mc_version> [pinned_loader_version]")
    unless defined $loader && defined $mc_version;
$loader     =~ s/[^a-z]//g;
$mc_version =~ s/[^0-9.]//g;
$pinned     =~ s/[^0-9.]//g if defined $pinned && $pinned ne '';
_fail("invalid loader") unless mc_loader_is_modded($loader);
_fail("invalid mc_version") unless $mc_version =~ /^[0-9.]+$/;

print STDERR "=== Resolving $loader installer for Minecraft $mc_version"
    . ($pinned ? " (pin $pinned)" : '') . " ===\n";

my $spec = mc_resolve_loader_install($loader, $mc_version, $pinned)
    or _fail("could not resolve $loader installer for MC $mc_version"
        . ($pinned ? " (pinned $pinned)" : ''));
print STDERR "=== Resolved loader version $spec->{loader_version} ===\n";
_emit(%$spec);
