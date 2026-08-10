#!/usr/bin/perl
# mc_modpack_adopt.pl — Adopt the instance profile from a downloaded modpack
# manifest (loader / loader_version / mc_version). Runs AS THE GAME USER inside
# the modpack import job (write_mc_profile writes directly when euid==user).
# Usage: mc_modpack_adopt.pl <job_dir> <server_dir> <unix_user>
use strict;
use warnings;

my $job_dir    = $ARGV[0] // '';
my $server_dir = $ARGV[1] // '';
my $unix_user  = $ARGV[2] // '';
if ($job_dir !~ /\S/ || $server_dir !~ /\S/ || $unix_user !~ /\S/) {
    print STDERR "Usage: mc_modpack_adopt.pl <job_dir> <server_dir> <unix_user>\n";
    exit 2;
}

our $module_root = $ENV{MODULE_ROOT} // '';
if ($module_root !~ /\S/) {
    (my $d = $0) =~ s{/[^/]+$}{};
    $module_root = "$d/..";
}
$module_root =~ s{/\./}{/}g;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

push @INC, $module_root;
require "$module_root/lib/mc_loader.pl";
require "$module_root/lib/mc_profile.pl";
require "$module_root/lib/mc_modpack.pl";

my ($ok, $code, $detail) = modpack_adopt_profile_from_meta($job_dir, $server_dir, $unix_user);
if (!$ok) {
    print STDERR "adopt profile failed: $code\n";
    exit 1;
}
if ($code eq 'adopted') {
    my $lv = ($detail && $detail->{'loader_version'}) ? $detail->{'loader_version'} : '';
    printf "profile adopted from pack: loader=%s mc=%s loader_version=%s\n",
        ($detail->{'loader'} // '?'), ($detail->{'mc_version'} // '?'),
        ($lv ne '' ? $lv : '(latest)');
}
exit 0;
