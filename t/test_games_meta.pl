#!/usr/bin/perl
# t/test_games_meta.pl — Tests for src/lib/games_meta.pl
use strict;
use warnings;
use Test::More tests => 9;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/..";

chdir "$Bin/.." or die "Cannot chdir to project root: $!";

require 't/stubs.pl';

sub error { die "error: $_[0]\n" }

# Point module_root at a temp dir with a lib/ subdir containing our JSON
our ($module_root, $config_directory);
my $tmpdir = tempdir(CLEANUP => 1);
$module_root      = $tmpdir;
$config_directory = $tmpdir;

# Create lib/ dir inside tmpdir
mkdir "$tmpdir/lib" or die "mkdir lib: $!";

# Helper: write JSON fixture to base file
sub write_base_json {
    my ($content) = @_;
    open(my $fh, '>', "$tmpdir/lib/games_meta.json") or die $!;
    print $fh $content;
    close $fh;
}

# Helper: write JSON fixture to local override file
sub write_local_json {
    my ($content) = @_;
    open(my $fh, '>', "$tmpdir/games_meta_local.json") or die $!;
    print $fh $content;
    close $fh;
}

require 'src/lib/games_meta.pl';

# ------------------------------------------------------------------
# Test 1: load_games_meta returns data from base file
# ------------------------------------------------------------------
write_base_json(<<'JSON');
{
  "mcserver": {
    "name": "Minecraft (Vanilla)",
    "fields": [
      {"key":"port","type":"port","label_de":"Port","label_en":"Port","default":"25565"},
      {"key":"gamename","type":"text","label_de":"Spielname","label_en":"Game name","default":"Minecraft"}
    ]
  }
}
JSON
&_reset_meta_cache();
my %meta = &load_games_meta();
ok(exists $meta{'mcserver'}, 'load_games_meta loads mcserver entry');

# ------------------------------------------------------------------
# Test 2: get_game_display_name returns correct name
# ------------------------------------------------------------------
&_reset_meta_cache();
my $name = &get_game_display_name('mcserver');
is($name, 'Minecraft (Vanilla)', 'get_game_display_name returns correct name');

# ------------------------------------------------------------------
# Test 3: get_game_fields returns correct fields
# ------------------------------------------------------------------
&_reset_meta_cache();
my @fields = &get_game_fields('mcserver');
is(scalar @fields, 2, 'get_game_fields returns 2 fields for mcserver');

# ------------------------------------------------------------------
# Test 4: get_game_fields returns correct field keys
# ------------------------------------------------------------------
&_reset_meta_cache();
@fields = &get_game_fields('mcserver');
my @keys = map { $_->{'key'} } @fields;
is_deeply(\@keys, ['port', 'gamename'], 'get_game_fields returns correct field keys');

# ------------------------------------------------------------------
# Test 5: get_game_fields returns empty list for unknown game
# ------------------------------------------------------------------
&_reset_meta_cache();
my @unknown = &get_game_fields('unknowngameXYZ');
is(scalar @unknown, 0, 'get_game_fields returns empty list for unknown game');

# ------------------------------------------------------------------
# Test 6: get_game_display_name falls back to script name
# ------------------------------------------------------------------
&_reset_meta_cache();
my $fallback = &get_game_display_name('unknowngameXYZ');
is($fallback, 'unknowngameXYZ', 'get_game_display_name falls back to script name');

# ------------------------------------------------------------------
# Test 7: local override file overrides base entry
# ------------------------------------------------------------------
write_local_json(<<'JSON');
{
  "mcserver": {
    "name": "Minecraft CUSTOM",
    "fields": [
      {"key":"port","type":"port","label_de":"Port","label_en":"Port","default":"19132"}
    ]
  }
}
JSON
&_reset_meta_cache();
my $custom_name = &get_game_display_name('mcserver');
is($custom_name, 'Minecraft CUSTOM', 'local override replaces base entry name');

# ------------------------------------------------------------------
# Test 8: local override also changes fields
# ------------------------------------------------------------------
&_reset_meta_cache();
my @custom_fields = &get_game_fields('mcserver');
is(scalar @custom_fields, 1, 'local override replaces fields');

# ------------------------------------------------------------------
# Test 9: base file entries not in local override remain accessible
# ------------------------------------------------------------------
write_base_json(<<'JSON');
{
  "mcserver":  {"name":"Minecraft","fields":[]},
  "vhserver":  {"name":"Valheim","fields":[{"key":"port","type":"port","label_de":"Port","label_en":"Port","default":"2456"}]}
}
JSON
write_local_json('{"mcserver":{"name":"Minecraft PATCHED","fields":[]}}');
&_reset_meta_cache();
my $vh_name = &get_game_display_name('vhserver');
is($vh_name, 'Valheim', 'base entries not in local override still accessible');
