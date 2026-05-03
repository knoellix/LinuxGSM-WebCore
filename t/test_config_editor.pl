#!/usr/bin/perl
# t/test_config_editor.pl — Tests for src/lib/config_editor.pl
use strict;
use warnings;
use Test::More tests => 27;
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
    my $ok = eval { &validate_config_target('/home/mc/lgsm/config-lgsm/common.cfg'); 1 };
    ok($ok, 'validate_config_target: common.cfg accepted');
}

# Test 2: valid instance cfg accepted
{
    $last_error = '';
    my $ok = eval { &validate_config_target('/home/mc/lgsm/config-lgsm/mcserver/mcserver.cfg'); 1 };
    ok($ok, 'validate_config_target: instance cfg accepted');
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

# Test 20b: static hint (absolute) is returned verbatim
{
    my %cfg = ();
    my $path = &resolve_game_server_config_path(
        '/home/foo/bar', 'fooserver', \%cfg,
        '/etc/fooserver/config.json');
    is($path, '/etc/fooserver/config.json',
        'resolve_game_server_config_path: absolute static hint preserved');
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
