#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 7;

chdir "$ENV{PWD}" if defined $ENV{PWD};
chdir '/mnt/Lager/github/LinuxGSM-WebCore' if -d '/mnt/Lager/github/LinuxGSM-WebCore';

open my $fh, '<', 'src/job_live.cgi' or die "Cannot read src/job_live.cgi: $!";
local $/;
my $src = <$fh>;
close $fh;

sub _extract_sub {
    my ($name) = @_;
    my ($code) = $src =~ /(sub\s+\Q$name\E\s*\{.*?^})/ms;
    die "Missing sub $name in src/job_live.cgi\n" unless $code;
    return $code;
}

my $eval_src = join "\n\n",
    _extract_sub('_job_live_query_urlencode'),
    _extract_sub('_job_live_safe_return_param'),
    _extract_sub('_job_live_safe_return_query');

my $ok = eval $eval_src;
die "Failed to eval extracted subs: $@" if $@;

my $base = _job_live_safe_return_query(
    'mods.cgi?instance_id=mc1&xnavigation=1',
    'mc1'
);
is($base, 'mods.cgi?instance_id=mc1&xnavigation=1',
    'accepts same-instance base return');

my $stateful = _job_live_safe_return_query(
    'mods.cgi?instance_id=mc1&q=atm10&status=enabled&sort=status&dir=desc&page=3&mod_q=jei&pack_q=all the',
    'mc1'
);
is($stateful,
    'mods.cgi?instance_id=mc1&q=atm10&status=enabled&sort=status&dir=desc&page=3&mod_q=jei&pack_q=all%20the&xnavigation=1',
    'accepts allowlisted state params and preserves them');

is(_job_live_safe_return_query('mods.cgi?instance_id=mc2&q=test', 'mc1'),
    '', 'rejects foreign instance id');

is(_job_live_safe_return_query('manage.cgi?instance_id=mc1', 'mc1'),
    '', 'rejects non-mods return target');

is(_job_live_safe_return_query('mods.cgi?instance_id=mc1&evil=1', 'mc1'),
    '', 'rejects unknown query key');

my $sanitized = _job_live_safe_return_query(
    'mods.cgi?instance_id=mc1&q=<script>&status=bogus&sort=bogus&dir=bogus&page=0',
    'mc1'
);
is($sanitized,
    'mods.cgi?instance_id=mc1&q=script&status=all&sort=name&dir=asc&page=1&xnavigation=1',
    'sanitizes unsafe values and normalizes enums');

my $dupe = _job_live_safe_return_query(
    'mods.cgi?instance_id=mc1&q=first&q=second',
    'mc1'
);
is($dupe,
    'mods.cgi?instance_id=mc1&q=first&xnavigation=1',
    'ignores duplicated keys after first value');
