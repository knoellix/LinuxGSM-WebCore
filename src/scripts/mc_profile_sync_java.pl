#!/usr/bin/env perl
# mc_profile_sync_java.pl — Align profile java_major/java_home to MC version.
# Runs as the game user (or root with su via write_mc_profile).
# Usage: mc_profile_sync_java.pl <server_dir> <unix_user>
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin";

my ($server_dir, $unix_user) = @ARGV;
if (!defined $server_dir || !defined $unix_user || $server_dir eq '' || $unix_user eq '') {
    print STDERR "Usage: mc_profile_sync_java.pl <server_dir> <unix_user>\n";
    exit 2;
}

our $module_root = $ENV{'MODULE_ROOT'} // "$FindBin::Bin/..";
require "$module_root/lib/mc_loader.pl";
require "$module_root/lib/mc_profile.pl";

my $profile = read_mc_profile($server_dir);
exit 0 unless ref($profile) eq 'HASH';
exit 0 unless mc_profile_java_needs_sync($profile);

my $synced = mc_profile_sync_java_fields($profile);
write_mc_profile($server_dir, $unix_user, $synced) or do {
    print STDERR "ERROR: could not write synced java profile\n";
    exit 1;
};
printf "profile java synced: major=%s home=%s (mc=%s)\n",
    $synced->{'java_major'}, $synced->{'java_home'}, $synced->{'mc_version'} // '';
exit 0;
