#!/usr/bin/perl
# t/test_config_parse.pl
use strict;
use warnings;
use Test::More tests => 6;
use File::Temp qw(tempdir);

# Webmin-Stubs
our ($module_root, $current_lang, $config_directory);
our (%text, %config, %gconfig);
$module_root = 't'; $current_lang = 'en';
%text = ();

sub sanitize_input { my ($s) = @_; $s =~ s/[^a-zA-Z0-9_-]//g; return $s; }
sub error { die "error: $_[0]\n"; }
sub system_logged { return 0; }
sub firewall_status { return 0; }

use FindBin;
require "$FindBin::Bin/../src/lib/instance.pl";

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/lgsm";
mkdir "$dir/lgsm/config-lgsm";
mkdir "$dir/lgsm/config-lgsm/mcserver";

# common.cfg schreiben
open my $fh, '>', "$dir/lgsm/config-lgsm/common.cfg" or die;
print $fh "# common settings\n";
print $fh "port=\"27015\"\n";
print $fh "gamename=\"halflife\"\n";
print $fh "maxplayers='16'\n";
close $fh;

# game-specific cfg (überschreibt common)
open $fh, '>', "$dir/lgsm/config-lgsm/mcserver/mcserver.cfg" or die;
print $fh "port=\"25565\"\n";
print $fh "gamename=\"mcserver\"\n";
close $fh;

my %cfg = _parse_lgsm_config($dir, 'mcserver');

# Test 1: game-specific port überschreibt common
is($cfg{port}, '25565', 'game config overrides common port');

# Test 2: game-specific gamename überschreibt common
is($cfg{gamename}, 'mcserver', 'game config overrides common gamename');

# Test 3: value aus common.cfg (maxplayers nicht in game cfg)
is($cfg{maxplayers}, '16', 'value from common.cfg preserved');

# Test 4: Kommentarzeilen werden ignoriert
ok(!exists $cfg{'# common settings'}, 'comment lines ignored');

# Test 5: kein common.cfg — nur game cfg
my $dir2 = tempdir(CLEANUP => 1);
mkdir "$dir2/lgsm"; mkdir "$dir2/lgsm/config-lgsm"; mkdir "$dir2/lgsm/config-lgsm/cs";
open $fh, '>', "$dir2/lgsm/config-lgsm/cs/cs.cfg" or die;
print $fh "port=\"27015\"\n";
close $fh;
my %cfg2 = _parse_lgsm_config($dir2, 'cs');
is($cfg2{port}, '27015', 'works without common.cfg');

# Test 6: kein config dir — nur _has_user_config=0, keine game keys
my $dir3 = tempdir(CLEANUP => 1);
my %cfg3 = _parse_lgsm_config($dir3, 'unknown');
is($cfg3{_has_user_config}, 0, 'missing config dir -> _has_user_config is 0');
