#!/usr/bin/env perl
# auto_update_detect.pl — PZ auto-update detection for shell workers.
# Prints KEY=value lines for bash eval (NEED_GAME, NEED_WORKSHOP, MODS, PLAYERS, REASON, ERR).
use strict;
use warnings;

my ($unix_user, $server_dir, $script, $check_game, $check_workshop) = @ARGV;
unless (defined $unix_user && $unix_user =~ /\S/
    && defined $server_dir && $server_dir =~ m{^/}
    && defined $script && $script =~ /\S/)
{
    print STDERR "Usage: auto_update_detect.pl <unix_user> <server_dir> <script> [check_game] [check_workshop]\n";
    exit 2;
}

$check_game     = ($check_game     // '1') =~ /^(?:1|true|yes|on)$/i ? 1 : 0;
$check_workshop = ($check_workshop // '1') =~ /^(?:1|true|yes|on)$/i ? 1 : 0;

our $module_root = $ENV{MODULE_ROOT} // '';
if ($module_root !~ /\S/) {
    (my $d = $0) =~ s{/[^/]+$}{};
    $module_root = "$d/..";
}
$module_root =~ s{/\./}{/}g;

push @INC, "$module_root/lib";
require "$module_root/lib/module_config.pl";
require "$module_root/lib/games_meta.pl";
require "$module_root/lib/pz_workshop.pl";
require "$module_root/lib/query.pl";
require "$module_root/lib/steam.pl";
require "$module_root/lib/auto_update_pz.pl";

our (%config, $module_config_file, $module_config_directory, $module_name);
module_config_bootstrap_standalone($module_root)
    or die "module config bootstrap failed (MODULE_ROOT=$module_root)\n";
# Game-user cron cannot read /etc/webmin/.../config; overlay instance secrets
# written by rebuild_auto_update_cron / save_auto_update (root).
module_config_apply_auto_update_secrets($server_dir);

my $result = auto_update_pz_detect($unix_user, $server_dir, $script, {
    check_game     => $check_game,
    check_workshop => $check_workshop,
});
auto_update_pz_detect_print($result);
exit 0;
