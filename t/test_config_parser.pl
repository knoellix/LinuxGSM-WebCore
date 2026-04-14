#!/usr/bin/perl
# t/test_config_parser.pl
use strict;
use warnings;
use Test::More tests => 8;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/..";

sub sanitize_input { my ($s) = @_; $s =~ s/[^a-zA-Z0-9_-]//g; return $s; }
sub error          { die "error: $_[0]\n" }
sub system_logged  { return 0 }
sub firewall_status { return 0 }

our %text = ();

require 'src/lib/instance.pl';

# Real LGSM on-disk layout:
#   lgsm/config-default/config-lgsm/$scriptname/_default.cfg  <- game defaults
#   lgsm/config-lgsm/common.cfg                               <- user common
#   lgsm/config-lgsm/$scriptname/$scriptname.cfg              <- user per-instance

# Test 1-3: Only game default exists -> values read, _has_user_config = 0
{
    my $dir = tempdir(CLEANUP => 1);
    mkdir "$dir/lgsm";
    mkdir "$dir/lgsm/config-default";
    mkdir "$dir/lgsm/config-default/config-lgsm";
    mkdir "$dir/lgsm/config-default/config-lgsm/mcserver";

    open(my $fh, '>', "$dir/lgsm/config-default/config-lgsm/mcserver/_default.cfg") or die $!;
    print $fh "port=\"25565\"\n";
    print $fh "gamename=\"Minecraft\"\n";
    close($fh);

    my %cfg = _parse_lgsm_config($dir, 'mcserver');
    is($cfg{port},             '25565',    'default port read from config-default');
    is($cfg{gamename},         'Minecraft','default gamename read from config-default');
    is($cfg{_has_user_config}, 0,          'no user config -> _has_user_config is 0');
}

# Test 4-6: config-lgsm/common.cfg overrides default
{
    my $dir = tempdir(CLEANUP => 1);
    mkdir "$dir/lgsm";
    mkdir "$dir/lgsm/config-default";
    mkdir "$dir/lgsm/config-default/config-lgsm";
    mkdir "$dir/lgsm/config-default/config-lgsm/mcserver";
    mkdir "$dir/lgsm/config-lgsm";

    open(my $fh, '>', "$dir/lgsm/config-default/config-lgsm/mcserver/_default.cfg") or die $!;
    print $fh "port=\"25565\"\n";
    print $fh "gamename=\"Minecraft\"\n";
    close($fh);

    open($fh, '>', "$dir/lgsm/config-lgsm/common.cfg") or die $!;
    print $fh "port=\"9999\"\n";
    close($fh);

    my %cfg = _parse_lgsm_config($dir, 'mcserver');
    is($cfg{port},             '9999',     'common.cfg overrides default port');
    is($cfg{gamename},         'Minecraft','gamename still from default when not overridden');
    is($cfg{_has_user_config}, 1,          'common.cfg exists -> _has_user_config is 1');
}

# Test 7-8: bash conditionals and comments are skipped
{
    my $dir = tempdir(CLEANUP => 1);
    mkdir "$dir/lgsm";
    mkdir "$dir/lgsm/config-default";
    mkdir "$dir/lgsm/config-default/config-lgsm";
    mkdir "$dir/lgsm/config-default/config-lgsm/pwserver";

    open(my $fh, '>', "$dir/lgsm/config-default/config-lgsm/pwserver/_default.cfg") or die $!;
    print $fh "## Comment line\n";
    print $fh "port=\"8211\"\n";
    print $fh "gamename=\"Palworld\"\n";
    print $fh "[ -n \"\${LGSM_LOGDIR}\" ] && logdir=\"x\" || logdir=\"y\"\n";
    close($fh);

    my %cfg = _parse_lgsm_config($dir, 'pwserver');
    is($cfg{port},    '8211',    'Palworld port parsed correctly');
    is($cfg{gamename},'Palworld','Palworld gamename parsed correctly');
}
