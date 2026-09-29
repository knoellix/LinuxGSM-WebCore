#!/usr/bin/env perl
# Sync PZ LGSM instance.cfg: wire adminpassword into startparameters before start.
use strict;
use warnings;
use FindBin qw($Bin);

our $module_root = "$Bin/..";
require "$Bin/../lib/games_meta.pl";

my ($server_dir, $script_name) = @ARGV;
die "usage: pz_sync_lgsm_cfg.pl <server_dir> <script_name>\n" unless @ARGV == 2;

if (sync_pz_lgsm_instance_cfg($server_dir, $script_name)) {
    print "PZ LGSM config synced (startparameters/adminpassword/querymode)\n";
    exit 0;
}
exit 0;
