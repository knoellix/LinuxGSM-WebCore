#!/usr/bin/perl
# t/test_config_editor.pl — Tests for src/lib/config_editor.pl
use strict;
use warnings;
use Test::More tests => 101;
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

# Test 5b: instance cfg accepted when <script>/ parent is missing (Quick Fix create)
{
    $last_error = '';
    my $tmp = tempdir(CLEANUP => 1);
    require File::Path;
    File::Path::make_path("$tmp/lgsm/config-lgsm");
    my $cfg = "$tmp/lgsm/config-lgsm/pzserver/pzserver.cfg";
    ok(!-d "$tmp/lgsm/config-lgsm/pzserver", 'precondition: script config dir absent');
    my $resolved = eval { &validate_config_target($cfg); };
    ok($resolved && $resolved =~ m{/lgsm/config-lgsm/pzserver/pzserver\.cfg$},
        'validate_config_target: create path ok without script subdir');
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

# Test 48: check_game_config_path soft-rejects outside tree (no &error)
{
    $last_error = '';
    my $got = &check_game_config_path('/home/mc/srv', '/home/mc/Zomboid/Server/servertest.ini');
    ok(!defined $got && $last_error eq '',
        'check_game_config_path: outside tree returns undef without error');
}

# Test 49: manage.cgi uses soft check on GET render (not validate_game_config_path)
{
    open my $fh, '<', 'src/manage.cgi' or die $!;
    local $/;
    my $src = <$fh>;
    close $fh;
    like($src, qr/check_game_config_path\(\s*\$script_dir_for_cfg,\s*\$game_cfg_path/,
        'manage.cgi: GET render uses check_game_config_path');
    unlike($src, qr/eval\s*\{\s*\$game_cfg_path\s*=\s*&?validate_game_config_path/,
        'manage.cgi: GET render does not eval validate_game_config_path');
}

# Test 50: PZ home-based INI allowed when home root is passed
{
    $last_error = '';
    my $tmp = tempdir(CLEANUP => 1);
    my $home = "$tmp/gs_pz";
    my $server = "$home/pz-1";
    require File::Path;
    File::Path::make_path("$home/Zomboid/Server");
    File::Path::make_path($server);
    my $ini = "$home/Zomboid/Server/pzserver.ini";
    open my $fh, '>', $ini or die $!;
    print $fh "PublicName=Test\n";
    close $fh;
    my $got = &check_game_config_path($server, $ini, $home);
    ok($got && $got =~ /pzserver\.ini$/, 'check_game_config_path: PZ home INI allowed with home arg');
}

# Test 51: resolve home-based game_config_path for pzserver
{
    our ($module_root, $config_directory);
    $module_root = 'src';
    $config_directory = tempdir(CLEANUP => 1);
    require 'src/lib/games_meta.pl';
    &_reset_meta_cache() if defined &_reset_meta_cache;
    my $tmp = tempdir(CLEANUP => 1);
    my $home = "$tmp/gs_pz";
    my $server = "$home/pz-1";
    require File::Path;
    File::Path::make_path($server);
    is(&get_game_config_path_base('pzserver'), 'home', 'pzserver game_config_path_base is home');
    my $path = &resolve_game_server_config_path(
        $server, 'pzserver', {}, &get_game_config_path('pzserver'),
        { home => $home, selfname => 'pzserver' });
    like($path, qr{\Q$home\E/Zomboid/Server/pzserver\.ini$},
        'resolve: PZ game config under home');
}

# Test 52: ensure_pz_lgsm_startparameters wires adminpassword into startparameters
{
    our ($module_root, $config_directory);
    $module_root = 'src';
    $config_directory = tempdir(CLEANUP => 1);
    require 'src/lib/games_meta.pl';
    &_reset_meta_cache() if defined &_reset_meta_cache;
    my %v = (adminpassword => 's3cret');
    ok(&ensure_pz_lgsm_startparameters('pzserver', \%v), 'ensure_pz: mutates when password set');
    like($v{'startparameters'}, qr/-adminpassword/, 'ensure_pz: startparameters includes adminpassword');
    like($v{'startparameters'}, qr/\\"\$\{adminpassword\}\\"/,
        'ensure_pz: startparameters uses LGSM-escaped adminpassword ref');
    my %empty = (adminpassword => 'CHANGE_ME');
    ok(!&ensure_pz_lgsm_startparameters('pzserver', \%empty), 'ensure_pz: skips CHANGE_ME');
    my %qm = (querymode => '2');
    ok(&ensure_pz_lgsm_querymode('pzserver', \%qm), 'ensure_pz: sets querymode=1');
    is($qm{'querymode'}, '1', 'ensure_pz: querymode is session-only');
    ok(!&ensure_pz_lgsm_querymode('pzserver', \%qm), 'ensure_pz: querymode idempotent');
}

# Test 53: PZ key=value .ini resolves as properties (not Palworld OptionSettings)
{
    no warnings 'redefine';
    *main::get_game_config_format = sub { return 'properties' };
    my $raw = "PublicName=MyPZ\nMaxPlayers=32\nPassword=secret\nMods=Foo;Bar\n";
    is(&resolve_game_config_format('pzserver', '/home/u/Zomboid/Server/pzserver.ini', $raw),
        'properties', 'resolve: PZ .ini is properties');
    my ($vals, $order, $fmt) = &parse_game_config_values(
        'pzserver', '/home/u/Zomboid/Server/pzserver.ini', $raw);
    is($fmt, 'properties', 'parse: PZ format properties');
    is($vals->{'PublicName'}, 'MyPZ', 'parse: PZ PublicName');
    is($vals->{'MaxPlayers'}, '32', 'parse: PZ MaxPlayers');
    is(scalar(@$order), 4, 'parse: PZ all keys present');
}

# Test 54: comments with apostrophes must not break brace extract (real PZ files)
{
    my $raw = <<'LUA';
SandboxVars = {
    VERSION = 6,
    -- Changing this also sets the "Population Multiplier" option.
    Zombies = 4,
    -- How often events during the player's sleep occur.
    SleepingEvent = 1,
    -- If a piece of media hasn't been fully seen, show "???".
    MetaKnowledge = 3,
    Map = {
        -- If enabled, the world map can be accessed.
        AllowWorldMap = true,
    },
}
LUA
    my ($vals, $order) = &parse_sandboxvars_lua($raw);
    is($vals->{'VERSION'}, '6', 'sandbox apostrophe-comments: VERSION');
    is($vals->{'Zombies'}, '4', 'sandbox apostrophe-comments: Zombies');
    is($vals->{'SleepingEvent'}, '1', 'sandbox apostrophe-comments: SleepingEvent');
    is($vals->{'MetaKnowledge'}, '3', 'sandbox apostrophe-comments: MetaKnowledge');
    is($vals->{'Map.AllowWorldMap'}, 'true', 'sandbox apostrophe-comments: nested');
    ok(scalar(@$order) >= 5, 'sandbox apostrophe-comments: fields found');
}

# Test 55: parse_sandboxvars_lua flattens nested tables
{
    my $raw = <<'LUA';
SandboxVars = {
    VERSION = 5,
    Zombies = 4,
    ZombieLore = {
        Speed = 2,
        Strength = 3,
    },
    AllowExteriorGenerator = true,
}
LUA
    my ($vals, $order) = &parse_sandboxvars_lua($raw);
    is($vals->{'VERSION'}, '5', 'sandbox parse: VERSION');
    is($vals->{'Zombies'}, '4', 'sandbox parse: Zombies');
    is($vals->{'ZombieLore.Speed'}, '2', 'sandbox parse: nested Speed');
    is($vals->{'ZombieLore.Strength'}, '3', 'sandbox parse: nested Strength');
    is($vals->{'AllowExteriorGenerator'}, 'true', 'sandbox parse: bool true');
    ok(scalar(@$order) >= 5, 'sandbox parse: order has leaves');
}

# Test 55: update_sandboxvars_lua changes nested leaf and round-trips
{
    my $raw = <<'LUA';
SandboxVars = {
    Zombies = 4,
    ZombieLore = {
        Speed = 2,
    },
    AllowExteriorGenerator = false,
}
LUA
    my $out = &update_sandboxvars_lua($raw, {
        'ZombieLore.Speed' => '1',
        'AllowExteriorGenerator' => 'true',
        'Zombies' => '3',
    });
    my ($vals) = &parse_sandboxvars_lua($out);
    is($vals->{'ZombieLore.Speed'}, '1', 'sandbox update: nested Speed');
    is($vals->{'AllowExteriorGenerator'}, 'true', 'sandbox update: bool');
    is($vals->{'Zombies'}, '3', 'sandbox update: Zombies');
    like($out, qr/SandboxVars\s*=/, 'sandbox update: keeps SandboxVars assignment');
}

# Test 56: check_game_config_path allows *_SandboxVars.lua under home
{
    my $home = tempdir(CLEANUP => 1);
    my $server = "$home/pzserver";
    require File::Path;
    File::Path::make_path("$home/Zomboid/Server");
    File::Path::make_path($server);
    my $lua = "$home/Zomboid/Server/pzserver_SandboxVars.lua";
    open my $fh, '>', $lua or die $!;
    print $fh "SandboxVars = {\n    VERSION = 5,\n}\n";
    close $fh;
    my $got = &check_game_config_path($server, $lua, $home);
    ok($got && $got =~ /_SandboxVars\.lua$/,
        'check_game_config_path: SandboxVars under home allowed');
    my $bad = &check_game_config_path($server, "$home/evil_SandboxVars.lua", $home);
    ok(!defined $bad, 'check_game_config_path: SandboxVars outside Zomboid/Server rejected');
}

# Test 57: get_game_sandbox_path / manage sandbox tab wiring
{
    our ($module_root, $config_directory);
    $module_root = 'src';
    $config_directory = tempdir(CLEANUP => 1);
    require 'src/lib/games_meta.pl';
    &_reset_meta_cache() if defined &_reset_meta_cache;
    my $sp = &get_game_sandbox_path('pzserver');
    like($sp, qr/_SandboxVars\.lua$/, 'get_game_sandbox_path: pzserver');
    my $lab = &get_game_sandbox_label('pzserver', 'de');
    like($lab, qr/SandboxVars|Welt/i, 'get_game_sandbox_label: de');
    open my $mf, '<', 'src/manage.cgi' or die $!;
    local $/;
    my $src = <$mf>;
    close $mf;
    like($src, qr/cfg_btn_sandbox/, 'manage.cgi: sandbox tab button');
    like($src, qr/config_file", "sandbox"/, 'manage.cgi: sandbox save config_file');
    like($src, qr/parse_sandboxvars_lua/, 'manage.cgi: parses SandboxVars');
    like($src, qr/update_sandboxvars_lua/, 'manage.cgi: saves via update_sandboxvars_lua');
}

# Test 58: checkbox multi-value / "false true" heal
{
    is(&normalize_config_form_value("false\0true"), 'true',
        'normalize: Webmin false\\0true → true');
    is(&normalize_config_form_value("false"), 'false',
        'normalize: plain false');
    is(&normalize_config_form_value("false true"), 'true',
        'normalize: space-joined false true → true');
    my $raw = <<'LUA';
SandboxVars = {
    AllowExteriorGenerator = "false true",
    StarterKit = false,
}
LUA
    my $out = &update_sandboxvars_lua($raw, {
        'AllowExteriorGenerator' => "false\0true",
        'StarterKit' => 'true',
    });
    my ($vals) = &parse_sandboxvars_lua($out);
    is($vals->{'AllowExteriorGenerator'}, 'true', 'heal: AllowExteriorGenerator');
    is($vals->{'StarterKit'}, 'true', 'heal: StarterKit');
}

# Test 59: heal_sandboxvars_lua_text rewrites false\0true in raw Lua
{
    my $raw = "SandboxVars = {\n    Foo = false\0true,\n    Bar = \"false true\",\n    Ok = false,\n}\n";
    my $healed = &heal_sandboxvars_lua_text($raw);
    unlike($healed, qr/\0/, 'heal text: no NUL left');
    like($healed, qr/Foo = true,/, 'heal text: Foo → true');
    like($healed, qr/Bar = true,/, 'heal text: Bar → true');
    like($healed, qr/Ok = false,/, 'heal text: Ok unchanged');
}
