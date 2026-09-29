#!/usr/bin/env perl
# pz_workshop_subscribe_helper.pl — resolve closure or patch INI for subscribe worker.
use strict;
use warnings;

my $cmd = shift @ARGV // '';
if ($cmd !~ /^(?:resolve|patch)$/) {
    print STDERR "Usage: pz_workshop_subscribe_helper.pl resolve <root_id>\n";
    print STDERR "       pz_workshop_subscribe_helper.pl patch <unix_user> <script_name> <root_id> <id:dir>...\n";
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

push @INC, "$module_root/lib";
require "$module_root/lib/module_config.pl";
require "$module_root/lib/games_meta.pl";
require "$module_root/lib/pz_workshop.pl";

our (%config, $module_config_file, $module_config_directory, $module_name);
module_config_bootstrap_standalone($module_root)
    or die "module config bootstrap failed (MODULE_ROOT=$module_root)\n";

if ($cmd eq 'resolve') {
    my $root_id = shift @ARGV // '';
    my ($ok, $res) = pz_workshop_subscribe_resolve_closure($root_id);
    $res = {} unless ref($res) eq 'HASH';

    if (($res->{warn} // '') eq 'api_key_missing') {
        print "WARN: steam_web_api_key missing; resolving Required items via Steam Workshop page scrape\n";
    }

    unless ($ok) {
        my $err = $res->{err} // 'resolve_failed';
        if ($err eq 'cap_exceeded') {
            print "ERROR: dependency cap exceeded (max 20 workshop items including root)\n";
            exit 1;
        }
        print "ERROR: dependency resolution failed ($err)\n";
        exit 1;
    }

    my @ids = @{ $res->{ids} // [] };
    unless (@ids) {
        print "ERROR: dependency resolution returned no ids\n";
        exit 1;
    }
    for my $id (@ids) {
        print "ID:$id\n";
    }
    exit 0;
}

# patch
my ($unix_user, $script_name, $root_id) = @ARGV;
if (!defined $unix_user || !defined $script_name || !defined $root_id) {
    print STDERR "Usage: pz_workshop_subscribe_helper.pl patch <unix_user> <script_name> <root_id> <id:dir>...\n";
    exit 2;
}
shift @ARGV; shift @ARGV; shift @ARGV;

my @ordered_ids;
my %content_dir_by_id;
for my $pair (@ARGV) {
    next unless defined $pair && $pair =~ /^(\d{5,20}):(.+)$/;
    my ($id, $dir) = ($1, $2);
    push @ordered_ids, $id unless grep { $_ eq $id } @ordered_ids;
    $content_dir_by_id{$id} = $dir;
}

unless (@ordered_ids) {
    print "ERROR: no content dirs for patch\n";
    exit 1;
}

my ($ok, $err, $info) = pz_workshop_subscribe_patch_ini(
    $unix_user, $script_name, $root_id, \@ordered_ids, \%content_dir_by_id,
    $ENV{WEBCORE_SERVER_DIR} // '',
);
unless ($ok) {
    print "ERROR: INI patch failed ($err)\n";
    exit 1;
}

$info = {} unless ref($info) eq 'HASH';
my $total = $info->{total} // scalar @ordered_ids;
my $deps = $info->{dep_count} // ($total > 0 ? $total - 1 : 0);
print "INI: ", ($info->{ini} // ''), "\n";
print "WorkshopItems=", ($info->{workshop} // ''), "\n";
print "Mods=", ($info->{mods} // ''), "\n";
if (($info->{server_ver} // '') ne '') {
    print "Server PZ version: $info->{server_ver}\n";
} else {
    print "WARN: could not detect server PZ version — no Mod IDs auto-enabled (enable manually)\n";
}
print "Auto-enabled Mod IDs: ", int($info->{mods_auto} // 0), "\n";
print "Installed $total items ($deps dependencies)\n";
print "INI patched OK\n";
exit 0;
