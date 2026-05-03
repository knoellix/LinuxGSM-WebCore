#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 13;

BEGIN { push @INC, '.'; }
require "./src/lib/config_editor.pl";

my $raw = <<'JSON';
{
        "Version": 1,
        "DeploymentId": "0.10.0.4.268-9d2ca277",
        "ServerDescription_Persistent":
        {
                "PersistentServerId": "7C6431624BAAC06B2DD96A8885B49094",
                "InviteCode": "c675abcd",
                "IsPasswordProtected": false,
                "Password": "",
                "ServerName": "knoelliX",
                "WorldIslandId": "8AF734C4D6E042B4CA8591C59B0FF122",
                "MaxPlayerCount": 8,
                "UserSelectedRegion": "",
                "P2pProxyAddress": "127.0.0.1",
                "UseDirectConnection": false,
                "DirectConnectionServerAddress": "",
                "DirectConnectionServerPort": -1,
                "DirectConnectionProxyAddress": "0.0.0.0"
        }
}
JSON

is( main::detect_game_config_format('ServerDescription.json', $raw), 'json',
    'detect_game_config_format honours .json extension');
is( main::detect_game_config_format(undef, $raw), 'json',
    'detect_game_config_format detects JSON by leading brace');

my ($vals, $order) = main::parse_json_config($raw);
is( $vals->{'ServerDescription_Persistent.ServerName'}, 'knoelliX', 'flatten string leaf');
is( $vals->{'ServerDescription_Persistent.MaxPlayerCount'}, '8',     'flatten int leaf');
is( $vals->{'ServerDescription_Persistent.IsPasswordProtected'}, 'false', 'flatten bool leaf');
is( $vals->{'Version'}, '1', 'flatten top-level int');

my %upd = (
    'ServerDescription_Persistent.ServerName'          => 'MeinTestServer',
    'ServerDescription_Persistent.MaxPlayerCount'      => '32',
    'ServerDescription_Persistent.IsPasswordProtected' => 'true',
    'ServerDescription_Persistent.Password'            => 'geheim "und" \\ wild',
    'ServerDescription_Persistent.UseDirectConnection' => '0',
);
my $new = main::update_json_config($raw, \%upd);

like( $new, qr/"ServerName":\s*"MeinTestServer"/, 'string value rewritten');
like( $new, qr/"MaxPlayerCount":\s*32/,            'int value rewritten');
like( $new, qr/"IsPasswordProtected":\s*true/,    'bool true rewritten');
like( $new, qr/"UseDirectConnection":\s*false/,   'bool false rewritten via "0" input');
like( $new, qr/"Password":\s*"geheim \\"und\\" \\\\ wild"/, 'special chars escaped');

# Untouched values stay verbatim
like( $new, qr/"PersistentServerId":\s*"7C6431624BAAC06B2DD96A8885B49094"/,
      'untouched key preserved');
like( $new, qr/"DirectConnectionServerPort":\s*-1/, 'negative int preserved');
