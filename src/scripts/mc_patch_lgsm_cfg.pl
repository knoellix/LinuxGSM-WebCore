#!/usr/bin/env perl
# Patch LGSM instance.cfg from .mcprofile.json (used by mc_java_install_user.sh).
use strict;
use warnings;
use FindBin qw($Bin);

our $module_root = "$Bin/..";
require "$Bin/../lib/mc_profile.pl";

my ($cfg_file, $profile_file, $server_dir) = @ARGV;
die "usage: mc_patch_lgsm_cfg.pl <cfg> <profile.json> <server_dir>\n" unless @ARGV == 3;

open(my $pf, '<', $profile_file) or die "cannot read profile: $profile_file: $!\n";
local $/;
require JSON::PP;
my $profile = JSON::PP::decode_json(<$pf>);
close($pf);

my $content = '';
if (-f $cfg_file) {
    open(my $cf, '<', $cfg_file) or die "cannot read cfg: $cfg_file: $!\n";
    $content = do { local $/; <$cf> };
    close($cf);
}

print patch_lgsm_mc_cfg_content($content, $profile, $server_dir);
