#!/usr/bin/perl
# Static layout guards: section order and collapsible bookkeeping in the CGIs.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $src = "$Bin/../src";

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "cannot read $path: $!";
    local $/;
    my $raw = <$fh>;
    close($fh);
    return $raw;
}

my %page = map { $_ => slurp("$src/$_.cgi") } qw(manage mods);

sub id_pos {
    my ($text, $id) = @_;
    return $text =~ /id\s*=>\s*'\Q$id\E'/ ? $-[0] : -1;
}

sub count_of {
    my ($text, $needle) = @_;
    my $n = 0;
    $n++ while $text =~ /\Q$needle\E/g;
    return $n;
}

for my $name (sort keys %page) {
    subtest "$name.cgi collapsible bookkeeping" => sub {
        my $text = $page{$name};
        my $starts = count_of($text, 'ui_collapsible_start');
        my $ends   = count_of($text, 'ui_collapsible_end');
        ok($starts > 0, "$name.cgi uses collapsible sections");
        is($ends, $starts, 'every opened section is closed');
        like($text, qr/ui_collapsible_state_script/, 'state script is emitted');

        my @ids = $text =~ /ui_collapsible_start\([^;]*?id\s*=>\s*'([a-z0-9_-]+)'/gs;
        ok(scalar(@ids) >= $starts - 1, 'sections carry ids for state and deep links');
        my %seen;
        my @dupes = grep { $seen{$_}++ } @ids;
        is_deeply(\@dupes, [], 'section ids are unique');
    };
}

subtest 'mods.cgi section order' => sub {
    my $text = $page{'mods'};
    my %at;
    for my $key (qw(jobs upgrade-check modpack mod-search installed-mods)) {
        my $pos = id_pos($text, $key);
        cmp_ok($pos, '>', -1, "section $key exists");
        $at{$key} = $pos;
    }
    cmp_ok($at{'jobs'}, '<', $at{'upgrade-check'}, 'jobs stay on top');
    cmp_ok($at{'upgrade-check'}, '<', $at{'modpack'},
        'upgrade check sits above modpack import');
    cmp_ok($at{'modpack'}, '<', $at{'mod-search'}, 'modpack import above mod search');
    cmp_ok($at{'mod-search'}, '<', $at{'installed-mods'}, 'installed mods last');
};

subtest 'mods.cgi modpack sources are nested collapsibles' => sub {
    my $text = $page{'mods'};
    for my $key (qw(modpack-search modpack-upload modpack-path)) {
        like($text, qr/id\s*=>\s*'\Q$key\E'/, "$key is collapsible");
    }
};

subtest 'manage.cgi section groups' => sub {
    my $text = $page{'manage'};
    my %at;
    for my $key (qw(controls monitoring upgrades access config danger)) {
        my $pos = id_pos($text, $key);
        cmp_ok($pos, '>', -1, "section $key exists");
        $at{$key} = $pos;
    }
    cmp_ok($at{'controls'}, '<', $at{'monitoring'}, 'controls first');
    cmp_ok($at{'monitoring'}, '<', $at{'upgrades'}, 'monitoring before upgrades');
    cmp_ok($at{'upgrades'}, '<', $at{'access'}, 'upgrades before access');
    cmp_ok($at{'access'}, '<', $at{'config'}, 'access before configuration');
    cmp_ok($at{'config'}, '<', $at{'danger'}, 'destructive actions last');
};

subtest 'upgrade blocks render from cache, not from a page-load fetch' => sub {
    my $text = $page{'manage'};
    unlike($text, qr/mc_upgrade_loader_upgrade_candidates\(\s*\$profile\s*\)\s*;/,
        'no unbounded loader fetch during page render');
    like($text, qr/no_fetch\s*=>\s*1/, 'render path asks the cache only');
    like($page{'mods'}, qr/no_fetch\s*=>\s*1/, 'mods page render path asks the cache only');
};

done_testing();
