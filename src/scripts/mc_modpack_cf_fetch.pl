#!/usr/bin/perl
# Resolve or download CurseForge mod files (game-user worker; reads $JOB_DIR/.worker_secrets).
use strict;
use warnings;

my $cmd = $ARGV[0] // '';

our $module_root = $ENV{MODULE_ROOT} // '';
if ($module_root !~ /\S/) {
    (my $d = $0) =~ s{/[^/]+$}{};
    $module_root = "$d/..";
}
$module_root =~ s{/\./}{/}g;

push @INC, $module_root;
require "$module_root/lib/module_config.pl";
require "$module_root/lib/mc_mods.pl";
require "$module_root/lib/mc_modpack.pl";

our (%config, $module_config_file, $module_config_directory, $module_name);
module_config_bootstrap_standalone($module_root)
    or die "module config bootstrap failed (MODULE_ROOT=$module_root)\n";

sub _cf_fail {
    my ($code, $msg) = @_;
    print STDERR "ERROR: $msg\n" if defined $msg && $msg =~ /\S/;
    exit($code // 1);
}

if ($cmd eq 'resolve') {
    my ($project_id, $file_id) = @ARGV[1, 2];
    $project_id =~ s/\D//g if defined $project_id;
    $file_id    =~ s/\D//g if defined $file_id;
    _cf_fail(2, 'usage: resolve <project_id> <file_id>')
        unless $project_id && $file_id;
    my $key = curseforge_api_key();
    _cf_fail(3, 'curseforge_key_missing') unless $key =~ /\S/;
    my $rec = curseforge_fetch_file_record($project_id, $file_id, $key, 120);
    _cf_fail(4, "curseforge_download_url_failed (" . ($rec->{'err'} // 'no_url') . ") project=$project_id file=$file_id")
        unless ref($rec) eq 'HASH' && $rec->{'url'};
    my $meta = ref($rec->{'meta'}) eq 'HASH' ? $rec->{'meta'} : {};
    my $fname = $meta->{'fileName'} // '';
    $fname =~ s/[^a-zA-Z0-9._-]//g;
    $fname = "mod-$project_id-$file_id.jar" unless $fname =~ /\S/;
    my $sha1 = '';
    my $norm = curseforge_normalize_hashes($meta->{'hashes'});
    $sha1 = $norm->{'sha1'} // '' if ref($norm) eq 'HASH';
    print "$rec->{'url'}\n$fname\n$sha1\n";
    exit 0;
}

if ($cmd eq 'download-url') {
    my ($url, $dest) = @ARGV[1, 2];
    $url = mc_download_url_normalize($url);
    _cf_fail(2, 'usage: download-url <url> <dest>')
        unless defined $url && $url =~ m{\Ahttps://}i && defined $dest && $dest =~ /\S/;
    unless (mc_download_url_allowed($url)) {
        _cf_fail(5, "download host blocked: $url");
    }
    if ($url =~ /forgecdn\.net/i && curseforge_api_key() !~ /\S/) {
        _cf_fail(3, 'curseforge_key_missing for forgecdn download');
    }
    mc_download_url_to_file($url, $dest, 600)
        or _cf_fail(6, "download failed: $url");
    exit 0;
}

if ($cmd eq 'download') {
    my ($project_id, $file_id, $dest) = @ARGV[1, 2, 3];
    $project_id =~ s/\D//g if defined $project_id;
    $file_id    =~ s/\D//g if defined $file_id;
    _cf_fail(2, 'usage: download <project_id> <file_id> <dest>')
        unless $project_id && $file_id && defined $dest && $dest =~ /\S/;
    my ($ok, $err) = curseforge_download_file_to_path($project_id, $file_id, $dest, 600);
    _cf_fail(6, "download failed project=$project_id file=$file_id ($err)")
        unless $ok;
    exit 0;
}

_cf_fail(2, 'unknown command (resolve|download|download-url)');
