#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 8;
use FindBin qw($Bin);

require "$Bin/stubs.pl";
require "$Bin/../src/lib/instance.pl";

ok(_instance_ipv4_usable('203.0.113.10'), 'usable public IPv4');
ok(!_instance_ipv4_usable('0.0.0.0'), '0.0.0.0 not usable');
ok(!_instance_ipv4_usable('127.0.0.1'), 'loopback not usable');

is(instance_resolve_connect_ip({ ip => '0.0.0.0', displayip => '203.0.113.5' }),
    '203.0.113.5', 'displayip preferred over bind ip');

is(instance_resolve_connect_ip({ ip => '198.51.100.2' }),
    '198.51.100.2', 'cfg ip used when set');

is(instance_direct_connect_endpoint({ ip => '203.0.113.5' }, 8211),
    '203.0.113.5:8211', 'endpoint combines ip and port');

{
    my $ep = instance_direct_connect_endpoint({ ip => '0.0.0.0' }, 8211);
    if ($ep eq '') {
        pass('0.0.0.0 cfg with no system ip yields no endpoint');
    } else {
        like($ep, qr/^\d{1,3}(?:\.\d{1,3}){3}:8211$/,
            '0.0.0.0 cfg falls back to usable system ip:port');
    }
}

is(instance_direct_connect_endpoint({ ip => '203.0.113.5' }, 0),
    '', 'no endpoint without port');
