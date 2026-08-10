#!/usr/bin/perl
# t/test_config_editor.pl — Tests for src/lib/config_editor.pl
use strict;
use warnings;
use Test::More tests => 48;
use File::Temp qw(tempdir tempfile);
use FindBin qw($Bin);
use lib "$Bin/..";

chdir "$Bin/.." or die "Cannot chdir to project root: $!";

require 't/stubs.pl';

our %text;
%text = (
    err_invalid_input => 'invalid input',
);

my $last_error = '';
sub error { $last_error = $_[0]; die "error\n" }

require 'src/lib/config_editor.pl';

my $tmpdir = tempdir(CLEANUP => 1);

# ------------------------------------------------------------------
# validate_config_target tests
# ------------------------------------------------------------------

# Test 1: valid common.cfg path accepted
{
    $last_error = '';
    my $tmp = tempdir(CLEANUP => 1);
    require File::Path;
    File::Path::make_path("$tmp/lgsm/config-lgsm");
    my $cfg = "$tmp/lgsm/config-lgsm/common.cfg";
    open my $fh, '>', $cfg or die $!;
    print $fh "port=\"27015\"\n";
    close $fh;
    my $resolved = eval { &validate_config_target($cfg); };
    ok($resolved && $resolved =~ /common\.cfg$/, 'validate_config_target: common.cfg accepted');
}

# Test 2: valid instance cfg accepted
{
    $last_error = '';
    my $tmp = tempdir(CLEANUP => 1);
    require File::Path;
    File::Path::make_path("$tmp/lgsm/config-lgsm/mcserver");
    my $cfg = "$tmp/lgsm/config-lgsm/mcserver/mcserver.cfg";
    open my $fh, '>', $cfg or die $!;
    print $fh "port=\"27015\"\n";
    close $fh;
    my $resolved = eval { &validate_config_target($cfg); };
    ok($resolved && $resolved =~ /mcserver\.cfg$/, 'validate_config_target: instance cfg accepted');
}

# Test 3: _default.cfg rejected
{
    $last_error = '';
    my $ok = eval { &validate_config_target('/home/mc/lgsm/config-default/config-lgsm/mcserver/_default.cfg'); 1 };
    ok(!$ok && $last_error eq 'invalid input', 'validate_config_target: _default.cfg rejected');
}

# Test 4: path outside lgsm/config-lgsm rejected
{
    $last_error = '';
    my $ok = eval { &validate_config_target('/home/mc/server.properties'); 1 };
    ok(!$ok && $last_error eq 'invalid input', 'validate_config_target: path outside lgsm/config-lgsm rejected');
}

# Test 5: relative path rejected
{
    $last_error = '';
    my $ok = eval { &validate_config_target('lgsm/config-lgsm/common.cfg'); 1 };
    ok(!$ok && $last_error eq 'invalid input', 'validate_config_target: relative path rejected');
}

# ------------------------------------------------------------------
# read_config_file tests
# ------------------------------------------------------------------

# Test 6: reads key=value pairs correctly
{
    my $cfg = "$tmpdir/test.cfg";
    open(my $fh, '>', $cfg) or die $!;
    print $fh "port=\"25565\"\n";
    print $fh "gamename=\"Minecraft\"\n";
    close $fh;

    my ($vals, $order, $raw) = &read_config_file($cfg);
    is($vals->{'port'}, '25565', 'read_config_file: port parsed correctly');
}

# Test 7: preserves key order
{
    my $cfg = "$tmpdir/order.cfg";
    open(my $fh, '>', $cfg) or die $!;
    print $fh "gamename=\"MC\"\n";
    print $fh "port=\"25565\"\n";
    close $fh;

    my ($vals, $order, $raw) = &read_config_file($cfg);
    is_deeply($order, ['gamename', 'port'], 'read_config_file: key order preserved');
}

# Test 8: returns empty refs for non-existent file
{
    my ($vals, $order, $raw) = &read_config_file("$tmpdir/nonexistent.cfg");
    ok(scalar(keys %$vals) == 0 && scalar(@$order) == 0 && $raw eq '',
        'read_config_file: returns empty refs for missing file');
}

# Test 9: skips comments and bash conditionals
{
    my $cfg = "$tmpdir/complex.cfg";
    open(my $fh, '>', $cfg) or die $!;
    print $fh "## section comment\n";
    print $fh "port=\"8211\"\n";
    print $fh "[ -n \"\${LGSM_VAR}\" ] && x=\"1\" || x=\"2\"\n";
    close $fh;

    my ($vals, $order, $raw) = &read_config_file($cfg);
    is($vals->{'port'}, '8211', 'read_config_file: skips bash conditionals');
    ok(!exists $vals->{'x'}, 'read_config_file: bash conditional key not parsed');
}

# ------------------------------------------------------------------
# filter_raw_config tests
# ------------------------------------------------------------------

# Test 11: valid key=value lines pass through
{
    my $content = "port=\"25565\"\ngamename=\"Minecraft\"\n";
    my $lines = &filter_raw_config($content);
    is(scalar @$lines, 2, 'filter_raw_config: valid lines pass through');
}

# Test 12: bash constructs filtered out
{
    my $content = "port=\"25565\"\n[ -n \"\$VAR\" ] && logdir=\"x\" || logdir=\"y\"\ngamename=\"MC\"\nif [ -f x ]; then\nfi\n";
    my $lines = &filter_raw_config($content);
    my @non_comment = grep { !/^\s*#/ } @$lines;
    my @keys = map { /^\s*(\w+)\s*=/ ? $1 : () } @non_comment;
    my %key_set = map { $_ => 1 } @keys;
    ok($key_set{'port'} && $key_set{'gamename'} && !$key_set{'logdir'},
        'filter_raw_config: bash constructs removed, valid lines kept');
}

# ------------------------------------------------------------------
# split_editor_fields tests
# ------------------------------------------------------------------

# Test 13: instance view keeps game fields editable
{
    my @gfields = ({ key => 'port' }, { key => 'gamename' });
    my %vals = (port => '25565', gamename => 'MC', webhook => 'https://x');
    my @order = qw(port gamename webhook);
    my ($editable, $unknown, $known) = &split_editor_fields('instance', \@gfields, \%vals, \@order);
    is(scalar(@$editable), 2, 'split_editor_fields: instance view keeps game fields');
}

# Test 14: common view hides game fields from editable list
{
    my @gfields = ({ key => 'port' }, { key => 'gamename' });
    my %vals = (port => '25565', gamename => 'MC', webhook => 'https://x');
    my @order = qw(port gamename webhook);
    my ($editable, $unknown, $known) = &split_editor_fields('common', \@gfields, \%vals, \@order);
    is(scalar(@$editable), 0, 'split_editor_fields: common view has no editable game fields');
}

# Test 15: common view keeps only non-game keys as additional fields
{
    my @gfields = ({ key => 'port' }, { key => 'gamename' });
    my %vals = (port => '25565', gamename => 'MC', webhook => 'https://x');
    my @order = qw(port gamename webhook);
    my ($editable, $unknown, $known) = &split_editor_fields('common', \@gfields, \%vals, \@order);
    is_deeply($unknown, ['webhook'], 'split_editor_fields: common unknown keys exclude game keys');
}

# Test 16: game view keeps game fields editable
{
    my @gfields = ({ key => 'port' }, { key => 'gamename' });
    my %vals = (port => '25565', gamename => 'MC', webhook => 'https://x');
    my @order = qw(port gamename webhook);
    my ($editable, $unknown, $known) = &split_editor_fields('game', \@gfields, \%vals, \@order);
    is(scalar(@$editable), 2, 'split_editor_fields: game view keeps game fields editable');
}

# Test 17: game view hides unknown keys from game-only editor
{
    my @gfields = ({ key => 'port' }, { key => 'gamename' });
    my %vals = (port => '25565', gamename => 'MC', webhook => 'https://x');
    my @order = qw(port gamename webhook);
    my ($editable, $unknown, $known) = &split_editor_fields('game', \@gfields, \%vals, \@order);
    is_deeply($unknown, [], 'split_editor_fields: game view hides unknown keys');
}

# Test 18: resolve_game_server_config_path expands servercfgfullpath
{
    my %cfg = (
        serverfiles => '/home/kekks/palworld/serverfiles',
        servercfgfullpath => '${serverfiles}/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini',
    );
    my $path = &resolve_game_server_config_path('/home/kekks/palworld', 'pwserver', \%cfg);
    is($path, '/home/kekks/palworld/serverfiles/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini',
        'resolve_game_server_config_path: expands servercfgfullpath');
}

# Test 19: resolve_game_server_config_path falls back to servercfgdir/servercfg
{
    my %cfg = (
        serverfiles => '/home/kekks/palworld/serverfiles',
        servercfgdir => '${serverfiles}/Pal/Saved/Config/LinuxServer',
        servercfg => 'PalWorldSettings.ini',
    );
    my $path = &resolve_game_server_config_path('/home/kekks/palworld', 'pwserver', \%cfg);
    is($path, '/home/kekks/palworld/serverfiles/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini',
        'resolve_game_server_config_path: falls back to servercfgdir + servercfg');
}

# Test 20a: static hint (relative) wins over LGSM config
{
    my %cfg = (
        servercfgfullpath => '/should/be/ignored.ini',
    );
    my $path = &resolve_game_server_config_path(
        '/home/gs_windrose/windrose_knoellix', 'windrose', \%cfg,
        'serverfiles/R5/ServerDescription.json');
    is($path, '/home/gs_windrose/windrose_knoellix/serverfiles/R5/ServerDescription.json',
        'resolve_game_server_config_path: relative static hint resolves under script_dir');
}

# Test 20b: absolute static hint outside server tree is rejected (I12)
{
    my %cfg = ();
    my $path = &resolve_game_server_config_path(
        '/home/foo/bar', 'fooserver', \%cfg,
        '/etc/fooserver/config.json');
    is($path, '', 'resolve_game_server_config_path: absolute hint outside server rejected');
}

# Test 20b2: absolute static hint under script_dir is accepted
{
    my $tmp = tempdir(CLEANUP => 1);
    my $server = "$tmp/pw-1";
    require File::Path;
    File::Path::make_path("$server/serverfiles/cfg");
    my $cfg_file = "$server/serverfiles/cfg/game.json";
    open my $fh, '>', $cfg_file or die $!;
    print $fh "{}\n";
    close $fh;
    my %cfg = ();
    my $path = &resolve_game_server_config_path(
        $server, 'pwserver', \%cfg, $cfg_file);
    is($path, $cfg_file, 'resolve_game_server_config_path: absolute hint under server ok');
}

# Test 20c: empty hint falls through to LGSM resolution
{
    my %cfg = (
        serverfiles       => '/home/kekks/palworld/serverfiles',
        servercfgfullpath => '${serverfiles}/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini',
    );
    my $path = &resolve_game_server_config_path(
        '/home/kekks/palworld', 'pwserver', \%cfg, '');
    is($path, '/home/kekks/palworld/serverfiles/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini',
        'resolve_game_server_config_path: empty static hint falls through to LGSM logic');
}

# Test 20: write_file_exact preserves content byte-by-byte
{
    my $file = "$tmpdir/exact.ini";
    my $content = "[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(A=1,B=2)";
    &write_file_exact($file, $content);
    open(my $fh, '<:raw', $file) or die $!;
    local $/;
    my $got = <$fh>;
    close $fh;
    is($got, $content, 'write_file_exact: content preserved exactly');
}

# Test 21: write_file_exact keeps content without trailing newline
{
    my $file = "$tmpdir/exact-nonewline.ini";
    my $content = "OptionSettings=(Difficulty=None)";
    &write_file_exact($file, $content);
    open(my $fh, '<:raw', $file) or die $!;
    local $/;
    my $got = <$fh>;
    close $fh;
    ok($got eq $content && $got !~ /\n\z/, 'write_file_exact: no newline appended');
}

# Test 22: parse_option_settings_from_ini extracts key/value pairs
{
    my $raw = "[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(Difficulty=None,ServerName=\"My Server\",PublicPort=8211)\n";
    my ($vals, $order) = &parse_option_settings_from_ini($raw);
    is($vals->{'Difficulty'}, 'None', 'parse_option_settings_from_ini: unquoted value parsed');
    is_deeply($order, ['Difficulty', 'ServerName', 'PublicPort'],
        'parse_option_settings_from_ini: field order preserved');
}

# Test 23: update_option_settings_in_ini replaces option line and preserves sections
{
    my $raw = "[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(Difficulty=None,PublicPort=8211)\n[/Other]\nX=1\n";
    my %vals = (Difficulty => 'Hard', PublicPort => '9000');
    my @order = qw(Difficulty PublicPort);
    my $out = &update_option_settings_in_ini($raw, \%vals, \@order);
    like($out, qr/OptionSettings=\(Difficulty=Hard,PublicPort=9000\)/,
        'update_option_settings_in_ini: option settings updated');
}

# Test 28: Palworld INI section header is not mistaken for JSON
{
    my $raw = "[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(Difficulty=None,PublicPort=8211)\n";
    is(&detect_game_config_format(undef, $raw), 'ini_option_settings',
        'detect_game_config_format: Palworld INI not detected as JSON');
}

# Test 29: .ini path hint selects ini_option_settings even when empty
{
    is(&detect_game_config_format('/game/PalWorldSettings.ini', ''), 'ini_option_settings',
        'detect_game_config_format: .ini path hint');
}

# Test 30: parse long single-line OptionSettings (Palworld production shape)
{
    my $raw = "[/Script/Pal.PalGameWorldSettings]\n"
        . "OptionSettings=(Difficulty=None,ServerName=\"Default Palworld Server\",PublicPort=8211,BanListURL=\"https://api.palworldgame.com/api/banlist.txt\")\n";
    my ($vals, $order) = &parse_option_settings_from_ini($raw);
    is($vals->{'ServerName'}, 'Default Palworld Server', 'parse_option_settings: quoted ServerName');
    is($vals->{'PublicPort'}, '8211', 'parse_option_settings: PublicPort');
    is($vals->{'BanListURL'}, 'https://api.palworldgame.com/api/banlist.txt',
        'parse_option_settings: URL value preserved');
    ok((grep { $_ eq 'Difficulty' } @$order), 'parse_option_settings: order includes Difficulty');
}

# Test 31: resolve_game_config_format prefers OptionSettings over wrong meta hint
{
    require './src/lib/games_meta.pl';
    no warnings 'redefine';
    *main::get_game_config_format = sub { return 'properties' };
    my $raw = "[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(ServerName=\"PW\",PublicPort=8211)\n";
    is(&resolve_game_config_format('pwserver', '/x/PalWorldSettings.ini', $raw),
        'ini_option_settings', 'resolve: OptionSettings content wins over properties meta');
}

# Test 32: parse_game_config_values fills Palworld fields when mis-tagged properties
{
    no warnings 'redefine';
    *main::get_game_config_format = sub { return 'properties' };
    my $raw = "[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(ServerName=\"PW\",PublicPort=8211)\n";
    my ($vals, $order, $fmt) = &parse_game_config_values('pwserver', '/x/PalWorldSettings.ini', $raw);
    is($fmt, 'ini_option_settings', 'parse_game_config_values: resolved ini');
    is($vals->{'ServerName'}, 'PW', 'parse_game_config_values: ServerName from OptionSettings');
    is($vals->{'PublicPort'}, '8211', 'parse_game_config_values: PublicPort');
}

# Test 33: read_game_config_raw normalizes BOM + CRLF
{
    my $file = "$tmpdir/bom.ini";
    my $content = "\x{FEFF}[/Script/Pal.PalGameWorldSettings]\r\nOptionSettings=(ServerName=\"X\",PublicPort=8211)\r\n";
    open(my $fh, '>:raw', $file) or die $!;
    print {$fh} $content;
    close($fh);
    my $raw = &read_game_config_raw($file);
    like($raw, qr/OptionSettings=\(ServerName="X",PublicPort=8211\)/, 'read_game_config_raw: BOM/CRLF stripped');
    my ($vals, $order) = &parse_option_settings_from_ini($raw);
    is($vals->{'ServerName'}, 'X', 'read_game_config_raw: parse after normalize');
}

# Test 40: truncated OptionSettings (missing closing paren) still parses known keys
{
    my $raw = "[/Script/Pal.PalGameWorldSettings]\n"
        . "OptionSettings=(Difficulty=None,ServerName=Keks,ServerPassword=pepega,PublicPort=8211,RCONEnabled=false,BanListURL=https:\n";
    my ($vals, $order, $fmt) = &parse_game_config_values('pwserver', '/x/PalWorldSettings.ini', $raw);
    is($fmt, 'ini_option_settings', 'truncated: format detected');
    is($vals->{'ServerName'}, 'Keks', 'truncated: ServerName');
    is($vals->{'ServerPassword'}, 'pepega', 'truncated: ServerPassword');
    is($vals->{'PublicPort'}, '8211', 'truncated: PublicPort');
}

# Test 44: fix_config must not mutate LGSM _default.cfg (C2 regression)
{
    open my $fh, '<', 'src/manage.cgi' or die $!;
    local $/;
    my $src = <$fh>;
    close $fh;
    ok($src !~ /rename\s*\(\s*\$default_cfg/, 'fix_config: no rename of _default.cfg');
    like($src, qr/elsif \(\$action eq 'fix_config'\).*validate_config_target\(\$config_file\)/s,
        'fix_config: validate_config_target before write');
}

# Test 46: validate_game_config_path rejects path outside server tree
{
    $last_error = '';
    my $ok = eval {
        &validate_game_config_path('/home/mc/srv', '/etc/passwd');
        1;
    };
    ok(!$ok && $last_error eq 'invalid input', 'validate_game_config_path: outside tree rejected');
}

# Test 47: validate_game_config_path accepts path under server dir
{
    $last_error = '';
    my $tmp = tempdir(CLEANUP => 1);
    my $server = "$tmp/pw-1";
    require File::Path;
    File::Path::make_path("$server/serverfiles/Pal/Saved/Config/LinuxServer");
    my $ini = "$server/serverfiles/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini";
    open my $fh, '>', $ini or die $!;
    print $fh "[/Script/Pal.PalGameWorldSettings]\n";
    close $fh;
    my $resolved = eval { &validate_game_config_path($server, $ini); };
    ok($resolved && $resolved =~ /PalWorldSettings\.ini$/, 'validate_game_config_path: ini under server ok');
}
