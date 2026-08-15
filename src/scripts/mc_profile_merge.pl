#!/usr/bin/env perl
# Merge fields into .mcprofile.json (game-user write).
use strict;
use warnings;
use FindBin qw($Bin);

our $module_root = "$Bin/..";
require "$Bin/../lib/mc_profile.pl";

my ($profile_file, $unix_user, @fields) = @ARGV;
die "usage: mc_profile_merge.pl <profile.json> <unix_user> key=value [...]\n" unless @ARGV >= 3;

open(my $fh, '<', $profile_file) or die "read profile: $!\n";
local $/;
require JSON::PP;
my $profile = JSON::PP::decode_json(<$fh>);
close($fh);
die "invalid profile\n" unless ref($profile) eq 'HASH';

for my $pair (@fields) {
    next unless defined $pair && $pair =~ /^([a-z_]+)=(.*)$/s;
    my ($k, $v) = ($1, $2);
    $profile->{$k} = $v;
}

(my $server_dir = $profile_file) =~ s{/[^/]+$}{};
my $verr = validate_mc_profile($profile);
if ($verr) {
    print STDERR "ERROR: invalid profile after merge: $verr\n";
    exit 1;
}
write_mc_profile($server_dir, $unix_user, $profile) or do {
    print STDERR "ERROR: write_mc_profile failed for $server_dir\n";
    exit 1;
};
