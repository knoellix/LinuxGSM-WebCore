#!/usr/bin/perl
# Expand pack_meta.json after remote modpack download (called from mc_modpack_install.sh).
use strict;
use warnings;

my $job_dir     = $ARGV[0] // '';
my $server_dir  = $ARGV[1] // '';
if ($job_dir !~ /\S/ || $server_dir !~ /\S/) {
    print STDERR "Usage: mc_modpack_expand_meta.pl <job_dir> <server_dir>\n";
    exit 2;
}

our $module_root = $ENV{MODULE_ROOT} // '';
if ($module_root !~ /\S/) {
    (my $d = $0) =~ s{/[^/]+$}{};
    $module_root = "$d/..";
}
$module_root =~ s{/\./}{/}g;

$ENV{WEBCORE_JOB_DIR} = $job_dir
    if $job_dir =~ m{/jobs/[0-9a-f]{16}\z};

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

push @INC, $module_root;
require "$module_root/lib/module_config.pl";
require "$module_root/lib/mc_mods.pl";
require "$module_root/lib/mc_profile.pl";
require "$module_root/lib/mc_modpack.pl";

our (%config, $module_config_file, $module_config_directory, $module_name);
module_config_bootstrap_standalone($module_root)
    or die "module config bootstrap failed (MODULE_ROOT=$module_root)\n";

my $profile;
if (-f "$job_dir/pack_meta.json") {
    eval {
        require JSON::PP;
        open my $fh, '<', "$job_dir/pack_meta.json" or die $!;
        local $/; my $meta = JSON::PP::decode_json(<$fh>);
        close $fh;
        $profile = $meta->{profile} if ref($meta) eq 'HASH' && ref($meta->{profile}) eq 'HASH';
    };
}

print "=== Modpack: resolve and download ===\n";
STDOUT->autoflush(1) if -t STDOUT;

my ($ok, $err, $detail);
eval {
    ($ok, $err, $detail) = expand_remote_modpack_job_meta($job_dir, $server_dir);
    1;
} or do {
    my $die_err = $@ // 'unknown error';
    $die_err =~ s/\s+at\s+\S+\s+line\s+\d+[.\n]*\z//s;
    chomp $die_err;
    print "ERROR: Modpack prepare failed: $die_err\n";
    exit 1;
};
unless ($ok) {
    my $msg = mc_modpack_error_message($err, $detail, $profile);
    print "ERROR: $msg\n";
    print STDERR "ERROR: expand_remote_modpack_job_meta failed ($err): $msg\n";
    exit 1;
}
print "=== Modpack ready for install ===\n";
exit 0;
