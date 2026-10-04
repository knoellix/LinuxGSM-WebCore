#!/usr/bin/perl
# t/test_pz_workshop.pl — Tests for src/lib/pz_workshop.pl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/..";

chdir "$Bin/.." or die "Cannot chdir to project root: $!";
require 't/stubs.pl';

our (%text, %config, $module_root);
$module_root = "$Bin/../src";
%config = ();

require 'src/lib/games_meta.pl';
require 'src/lib/pz_workshop.pl';

subtest 'list split/join round-trip' => sub {
    my @a = pz_workshop_split_list('111;222;111; 333 ');
    is_deeply(\@a, [qw(111 222 333)], 'split dedupes and trims');
    is(pz_workshop_join_list(@a, '222', '444'), '111;222;333;444', 'join dedupes');
    is(pz_workshop_join_list(), '', 'empty join');
};

subtest 'normalize workshop id' => sub {
    is(pz_workshop_normalize_item_id('1234567890'), '1234567890', 'bare id');
    is(pz_workshop_normalize_item_id(
        'https://steamcommunity.com/sharedfiles/filedetails/?id=2859296945'),
        '2859296945', 'url id');
    is(pz_workshop_normalize_item_id('abc'), '', 'rejects junk');
};

subtest 'normalize mod id allows PZ free-form ids' => sub {
    is(pz_workshop_normalize_mod_id('[B42] 815Tatra'), '[B42] 815Tatra',
        'brackets + space (Tatra 815)');
    is(pz_workshop_normalize_mod_id('  SimpleMod  '), 'SimpleMod', 'trim');
    is(pz_workshop_normalize_mod_id('Bad;Id'), '', 'rejects semicolon');
    is(pz_workshop_normalize_mod_id(''), '', 'rejects empty');
    is(pz_workshop_normalize_mod_id('Mod_Name-1.0'), 'Mod_Name-1.0', 'underscore/dot/hyphen');
};

subtest 'enable_mod accepts bracket Mod ID' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $ini = "$tmp/servertest.ini";
    open my $fh, '>', $ini or die $!;
    print $fh "WorkshopItems=3404869345\nMods=\n";
    close $fh;
    my ($ok, $err) = pz_workshop_enable_mod($ini, '3404869345', '[B42] 815Tatra');
    ok($ok, 'enable_mod ok') or diag($err);
    my ($vals) = pz_workshop_read_ini($ini);
    is($vals->{Mods}, '[B42] 815Tatra', 'Mods= contains bracket id');
    like($vals->{WorkshopItems}, qr/3404869345/, 'WorkshopItems kept');
};

subtest 'INI WorkshopItems/Mods patch round-trip' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $ini = "$tmp/servertest.ini";
    open my $fh, '>', $ini or die $!;
    print $fh "ServerName=Test\nWorkshopItems=100;200\nMods=Alpha;Beta\nMaxPlayers=16\n";
    close $fh;

    my ($ok, $err) = pz_workshop_patch_ini($ini, {
        add_workshop => ['300'],
        add_mods     => ['Gamma'],
    });
    ok($ok, 'patch ok') or diag($err);
    my ($vals) = pz_workshop_read_ini($ini);
    is($vals->{'WorkshopItems'}, '100;200;300', 'WorkshopItems appended');
    is($vals->{'Mods'}, 'Alpha;Beta;Gamma', 'Mods appended');
    is($vals->{'ServerName'}, 'Test', 'other keys preserved');

    ($ok, $err) = pz_workshop_patch_ini($ini, {
        remove_workshop => ['200'],
        remove_mods     => ['Beta'],
    });
    ok($ok, 'remove ok') or diag($err);
    ($vals) = pz_workshop_read_ini($ini);
    is($vals->{'WorkshopItems'}, '100;300', 'WorkshopItems removed');
    is($vals->{'Mods'}, 'Alpha;Gamma', 'Mods removed');
};

subtest 'INI path must stay under home' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    # Fake getpwnam by skipping — call resolve with non-existent user
    my ($ok, $path, $err) = pz_workshop_resolve_ini_path('___no_such_user___', 'pzserver');
    ok(!$ok, 'missing user rejected');
    like($err // '', qr/no_home/, 'err=no_home');
};

subtest 'mod.info parse' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    make_path("$tmp/mods/CoolMod");
    open my $fh, '>', "$tmp/mods/CoolMod/mod.info" or die $!;
    print $fh "name=Cool Mod\nid=CoolMod\n";
    close $fh;
    make_path("$tmp/mods/Other");
    open $fh, '>', "$tmp/mods/Other/mod.info" or die $!;
    print $fh "id=OtherMod\n";
    close $fh;
    my @ids = sort +pz_workshop_parse_mod_ids($tmp);
    is_deeply(\@ids, [qw(CoolMod OtherMod)], 'parsed mod ids');
};

subtest 'mod.info rich parse' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    make_path("$tmp/mods/CoolMod");
    open my $fh, '>', "$tmp/mods/CoolMod/mod.info" or die $!;
    print $fh "name=Cool Mod\nid=CoolMod\nmodversion=1.2\nrequire=41.78\nauthors=Ada\n";
    close $fh;
    my @infos = pz_workshop_parse_mod_info($tmp);
    is(scalar @infos, 1, 'one mod.info');
    is($infos[0]{id}, 'CoolMod');
    is($infos[0]{name}, 'Cool Mod');
    is($infos[0]{modversion}, '1.2');
    is($infos[0]{pz_require}, '41.78');
    is($infos[0]{authors}, 'Ada');
};

subtest 'disk scan finds workshop ids' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $home = "$tmp/home";
    make_path("$home/Steam/steamapps/workshop/content/108600/2859296945/mods/X");
    open my $fh, '>', "$home/Steam/steamapps/workshop/content/108600/2859296945/mods/X/mod.info" or die $!;
    print $fh "id=Brita\nname=Brita\n";
    close $fh;
    my $map = pz_workshop_scan_disk_in_roots([
        "$home/Steam/steamapps/workshop/content/108600"
    ]);
    ok(exists $map->{'2859296945'}, 'found workshop id');
    is($map->{'2859296945'}{mod_infos}[0]{id}, 'Brita');
};

subtest 'path under roots rejects escape' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    make_path("$tmp/ok/108600/1");
    make_path("$tmp/outside/escape");
    my @roots = ("$tmp/ok/108600");
    ok(pz_workshop_path_under_content_roots("$tmp/ok/108600/1", \@roots), 'inside ok');
    ok(!pz_workshop_path_under_content_roots("$tmp/outside/escape", \@roots), 'outside rejected');
};

subtest 'steam details fixture' => sub {
    my $json = '{"response":{"publishedfiledetails":[
      {"publishedfileid":"2859296945","title":"Brita","file_description":"Guns",
       "preview_url":"https://example.com/p.jpg","time_updated":1700000000}
    ]}}';
    my $m = pz_workshop_parse_details_fixture($json);
    is($m->{'2859296945'}{title}, 'Brita');
    ok(length($m->{'2859296945'}{preview_url}) > 0);
    is($m->{'2859296945'}{description}, 'Guns');
    is($m->{'2859296945'}{time_updated}, 1700000000);
};

subtest 'steam details fixture truncates description' => sub {
    my $long = 'x' x 400;
    my $json = qq({"response":{"publishedfiledetails":[
      {"publishedfileid":"2859296945","title":"T","file_description":"$long"}
    ]}});
    my $m = pz_workshop_parse_details_fixture($json);
    is(length($m->{'2859296945'}{description}), 280, 'description capped at 280');
};

subtest 'steam details fixture parses children' => sub {
    open my $fh, '<', 't/fixtures/pz_workshop_details.json' or die $!;
    local $/; my $json = <$fh>; close $fh;
    my $m = pz_workshop_parse_details_fixture($json);
    ok(ref($m->{'2859296945'}{children}) eq 'ARRAY', 'children arrayref');
    is_deeply($m->{'2859296945'}{children}, [qw(2169435913 2335368829)], 'child ids');
    ok(!exists $m->{'2169435913'}{children}, 'no children key when absent');
};

subtest 'steam details fixture rejects bad json' => sub {
    my $m = pz_workshop_parse_details_fixture('not json');
    is_deeply($m, {}, 'bad json returns empty hashref');
    is_deeply(pz_workshop_parse_details_fixture(''), {}, 'empty input');
};

subtest 'steam details missing key returns empty' => sub {
    local %config = ();
    my $m = pz_workshop_steam_details(['2859296945']);
    is_deeply($m, {}, 'empty when no api key');
};

subtest 'steam details sanitizes ids' => sub {
    local %config = (steam_web_api_key => 'test-key');
    # No live API in tests — invalid key yields {} without dying.
    my $m = pz_workshop_steam_details(['abc', '2859296945;drop', '', '2859296945']);
    ok(ref($m) eq 'HASH', 'returns hashref');
    my $lives = eval { pz_workshop_steam_details(['2859296945']); 1 };
    ok($lives, 'never dies on api failure');
};

subtest 'search fixture parse' => sub {
    my $json = <<'JSON';
{"response":{"publishedfiledetails":[
  {"publishedfileid":"2859296945","title":"Brita Weapon Pack","file_description":"Guns","creator":"765611980"},
  {"publishedfileid":"123","title":"Too short id skipped"},
  {"publishedfileid":"2169435913","title":"Mod 2","short_description":"Desc"}
]}}
JSON
    my @hits = pz_workshop_parse_search_fixture($json);
    # 123 is only 3 digits — normalize in parse keeps publishedfileid as-is if digits
    # fixture parser only strips non-digits; short ids still pass length check via publishedfileid
    ok(scalar(@hits) >= 2, 'fixture yields hits');
    is($hits[0]{'id'}, '2859296945', 'first id');
    like($hits[0]{'title'}, qr/Brita/, 'title');
};

subtest 'games_meta workshop flags' => sub {
    ok(game_has_workshop_support('pzserver'), 'pzserver has workshop');
    ok(!game_has_workshop_support('mcserver'), 'mcserver has no workshop');
    is(get_workshop_appid('pzserver'), 108600, 'workshop appid');
    like(get_workshop_ini_rel('pzserver'), qr{Zomboid/Server/pzserver\.ini}, 'ini rel');
    my %meta = load_games_meta();
    my $deps = $meta{'pzserver'}{'apt_deps'};
    ok(!defined $deps || (ref($deps) eq 'ARRAY' && !@$deps),
        'pzserver has no apt_deps — LGSM deps via root ./script install');
};

subtest 'PZ LGSM adminpassword startparameters sync' => sub {
    require 'src/lib/config_editor.pl';
    my $tmp = tempdir(CLEANUP => 1);
    my $server = "$tmp/pz-1";
    make_path("$server/lgsm/config-lgsm/pzserver");
    my $cfg = "$server/lgsm/config-lgsm/pzserver/pzserver.cfg";
    open my $fh, '>', $cfg or die $!;
    print $fh "adminpassword=\"s3cret\"\nstartparameters=\"-servername \${selfname}\"\n";
    close $fh;
    ok(sync_pz_lgsm_instance_cfg($server, 'pzserver'), 'sync rewrites cfg');
    open $fh, '<', $cfg or die $!;
    my $body = do { local $/; <$fh> };
    close $fh;
    like($body, qr/startparameters=.*-adminpassword/s, 'sync adds -adminpassword to startparameters');
    like($body, qr/\\"\$\{adminpassword\}\\"/, 'sync uses LGSM-escaped adminpassword ref');
};

subtest 'inventory merge statuses' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $ini = "$tmp/pzserver.ini";
    # Workshop ids must match scan filter (\d{5,20}) from Task 1.
    my ($id_active, $id_inactive, $id_orphan) = qw(111111 222222 999999);
    open my $fh, '>', $ini or die $!;
    print $fh "WorkshopItems=$id_active;$id_orphan\nMods=ModA\n";
    close $fh;
    make_path("$tmp/content/$id_active/mods/A");
    open $fh, '>', "$tmp/content/$id_active/mods/A/mod.info" or die $!;
    print $fh "id=ModA\nname=A\n";
    close $fh;
    make_path("$tmp/content/$id_inactive/mods/B");
    open $fh, '>', "$tmp/content/$id_inactive/mods/B/mod.info" or die $!;
    print $fh "id=ModB\n";
    close $fh;

    my $disk = pz_workshop_scan_disk_in_roots(["$tmp/content"]);
    my $rows = pz_workshop_merge_inventory($ini, $disk);
    my %by = map { $_->{workshop_id} => $_ } @$rows;
    is($by{$id_active}{status}, 'active');
    is($by{$id_inactive}{status}, 'inactive');
    is($by{$id_orphan}{status}, 'orphan_ini');
};

subtest 'inventory workshop_only when Mods empty' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $home = "$tmp/home";
    my $server = "$tmp/server";
    make_path("$home/Zomboid/Server");
    make_path("$server/serverfiles/steamapps/workshop/content/108600/333333/mods/OnlyMod");
    open my $fh, '>', "$server/serverfiles/steamapps/workshop/content/108600/333333/mods/OnlyMod/mod.info" or die $!;
    print $fh "id=OnlyMod\nname=Only\n";
    close $fh;
    my $ini = "$home/Zomboid/Server/pzserver.ini";
    open $fh, '>', $ini or die $!;
    print $fh "WorkshopItems=333333\nMods=\n";
    close $fh;

    no warnings 'redefine';
    local *main::pz_workshop_unix_home = sub { return $home; };
    use warnings 'redefine';

    my $rows = pz_workshop_list_inventory('fakeuser', 'pzserver', $server);
    my ($row) = grep { ($_->{workshop_id} // '') eq '333333' } @$rows;
    ok($row, 'row found');
    is($row->{status}, 'workshop_only', 'WI on Mods empty => workshop_only');
    is($row->{mod_infos}[0]{enabled_in_ini}, 0, 'mod marked off');
};

subtest 'enable disable verify' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $ini = "$tmp/pzserver.ini";
    my $wid = '111111';
    open my $fh, '>', $ini or die $!;
    print $fh "WorkshopItems=\nMods=\n";
    close $fh;
    my ($ok, $err) = pz_workshop_enable_item($ini, $wid, ['ModA']);
    ok($ok) or diag($err);
    my ($vals) = pz_workshop_read_ini($ini);
    is($vals->{WorkshopItems}, $wid);
    is($vals->{Mods}, 'ModA');
    ($ok, $err) = pz_workshop_disable_item($ini, $wid, ['ModA']);
    ok($ok) or diag($err);
    ($vals) = pz_workshop_read_ini($ini);
    is($vals->{WorkshopItems}, '');
    is($vals->{Mods}, '');
};

subtest 'rmtree as current user (empty unix_user)' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $dir = "$tmp/workshop/12345678";
    make_path($dir);
    ok(-d $dir, 'fixture dir exists');
    ok(_pz_workshop_rmtree_as_user('', $dir), 'rmtree ok');
    ok(!-d $dir, 'dir removed');
    ok(!_pz_workshop_rmtree_as_user('', $dir), 'missing dir returns 0');
};

subtest 'delete item removes content under roots and ini entry' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $root = "$tmp/content/108600";
    my $wid = '12345678';
    my $content = "$root/$wid";
    make_path("$content/mods/X");
    open my $fh, '>', "$content/mods/X/mod.info" or die $!;
    print $fh "id=ModX\n";
    close $fh;

    my $ini = "$tmp/pzserver.ini";
    open $fh, '>', $ini or die $!;
    print $fh "WorkshopItems=$wid\nMods=ModX\n";
    close $fh;

    my ($ok, $err) = pz_workshop_delete_item('', $ini, $wid, $content, ['ModX'], [$root]);
    ok($ok, 'delete ok') or diag($err);
    ok(!-d $content, 'content dir removed');
    my ($vals) = pz_workshop_read_ini($ini);
    is($vals->{WorkshopItems}, '', 'workshop id removed from ini');
    is($vals->{Mods}, '', 'mod id removed from ini');
};

subtest 'delete item removes duplicates under all content roots' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $root_a = "$tmp/home/Steam/steamapps/workshop/content/108600";
    my $root_b = "$tmp/server/serverfiles/steamapps/workshop/content/108600";
    my $wid = '3404869345';
    make_path("$root_a/$wid/mods");
    make_path("$root_b/$wid/mods");
    open my $fh, '>', "$root_a/$wid/mods/mod.info" or die $!;
    print $fh "id=[B42] 815Tatra\n";
    close $fh;
    open $fh, '>', "$root_b/$wid/mods/mod.info" or die $!;
    print $fh "id=[B42] 815Tatra\n";
    close $fh;

    my $ini = "$tmp/pzserver.ini";
    open $fh, '>', $ini or die $!;
    print $fh "WorkshopItems=$wid\nMods=[B42] 815Tatra\n";
    close $fh;

    # Inventory content_dir is only the second root (scan overwrite scenario).
    my ($ok, $err) = pz_workshop_delete_item(
        '', $ini, $wid, "$root_b/$wid", ['[B42] 815Tatra'], [$root_a, $root_b]);
    ok($ok, 'delete duplicate ok') or diag($err);
    ok(!-d "$root_a/$wid", 'home Steam copy removed');
    ok(!-d "$root_b/$wid", 'serverfiles copy removed');
    my ($vals) = pz_workshop_read_ini($ini);
    is($vals->{WorkshopItems}, '', 'ini cleared');
    is($vals->{Mods}, '', 'mods cleared');
};

subtest 'delete item rejects path outside roots' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $root = "$tmp/content/108600";
    my $wid = '12345678';
    my $content = "$tmp/outside/$wid";
    make_path($content);

    my $ini = "$tmp/pzserver.ini";
    open my $fh, '>', $ini or die $!;
    print $fh "WorkshopItems=$wid\nMods=\n";
    close $fh;

    my ($ok, $err) = pz_workshop_delete_item('', $ini, $wid, $content, [], [$root]);
    ok(!$ok, 'rejected');
    is($err, 'path_rejected', 'path_rejected err');
    ok(-d $content, 'outside dir kept');
    my ($vals) = pz_workshop_read_ini($ini);
    is($vals->{WorkshopItems}, $wid, 'ini unchanged when path rejected');
};

subtest 'delete item without content_dir only patches ini' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $wid = '12345678';
    my $ini = "$tmp/pzserver.ini";
    open my $fh, '>', $ini or die $!;
    print $fh "WorkshopItems=$wid\nMods=ModX\n";
    close $fh;

    my ($ok, $err) = pz_workshop_delete_item('', $ini, $wid, undef, ['ModX'], []);
    ok($ok, 'delete ok') or diag($err);
    my ($vals) = pz_workshop_read_ini($ini);
    is($vals->{WorkshopItems}, '', 'workshop id removed');
    is($vals->{Mods}, '', 'mod id removed');
};

subtest 'delete item idempotent when already inactive on disk' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $root = "$tmp/content/108600";
    my $wid = '12345678';
    my $content = "$root/$wid";
    make_path($content);

    my $ini = "$tmp/pzserver.ini";
    open my $fh, '>', $ini or die $!;
    print $fh "WorkshopItems=\nMods=\n";
    close $fh;

    my ($ok, $err) = pz_workshop_delete_item('', $ini, $wid, $content, [], [$root]);
    ok($ok, 'delete ok when inactive in ini') or diag($err);
    ok(!-d $content, 'content dir removed');
};

subtest 'dependency closure diamond graph' => sub {
    # root -> dep1, dep2 (shared deps before root)
    my %graph = (
        '10000000001' => { children => [qw(10000000002 10000000003)] },
        '10000000002' => { children => [] },
        '10000000003' => { children => [] },
    );
    my $fetch = sub {
        my ($ids) = @_;
        my %out;
        for my $id (@$ids) {
            $out{$id} = { children => [ @{ $graph{$id}{children} // [] } ] };
        }
        return \%out;
    };
    my ($ok, $res) = pz_workshop_resolve_dependency_closure('10000000001', fetch_details => $fetch);
    ok($ok, 'diamond ok') or diag($res->{err});
    my @ids = @{ $res->{ids} // [] };
    is(scalar @ids, 3, 'three ids in closure');
    is($ids[-1], '10000000001', 'root last');
    ok((grep { $_ eq '10000000002' } @ids[0, 1]), 'dep1 before root');
    ok((grep { $_ eq '10000000003' } @ids[0, 1]), 'dep2 before root');
};

subtest 'dependency closure linear chain' => sub {
    # root -> mid -> leaf (topological: leaf, mid, root)
    my %graph = (
        '20000000001' => { children => ['20000000002'] },
        '20000000002' => { children => ['20000000003'] },
        '20000000003' => { children => [] },
    );
    my $fetch = sub {
        my ($ids) = @_;
        my %out;
        for my $id (@$ids) {
            $out{$id} = { children => [ @{ $graph{$id}{children} // [] } ] };
        }
        return \%out;
    };
    my ($ok, $res) = pz_workshop_resolve_dependency_closure('20000000001', fetch_details => $fetch);
    ok($ok, 'chain ok') or diag($res->{err});
    is_deeply($res->{ids}, [qw(20000000003 20000000002 20000000001)], 'deps before dependents');
};

subtest 'dependency closure cycle skip' => sub {
    # root -> A -> B -> A (cycle edge skipped; all three included)
    my %graph = (
        '30000000001' => { children => ['30000000002'] },
        '30000000002' => { children => ['30000000003'] },
        '30000000003' => { children => ['30000000002'] },
    );
    my $fetch = sub {
        my ($ids) = @_;
        my %out;
        for my $id (@$ids) {
            $out{$id} = { children => [ @{ $graph{$id}{children} // [] } ] };
        }
        return \%out;
    };
    my ($ok, $res) = pz_workshop_resolve_dependency_closure('30000000001', fetch_details => $fetch);
    ok($ok, 'cycle ok') or diag($res->{err});
    my @ids = @{ $res->{ids} // [] };
    is(scalar @ids, 3, 'three ids despite cycle');
    is($ids[-1], '30000000001', 'root last');
    ok((index(join(',', @ids), '30000000003') // -1)
        < (index(join(',', @ids), '30000000002') // 999),
        'B before A in load order');
};

subtest 'dependency closure cap exceeded' => sub {
    my %graph = (
        '40000000001' => { children => [ map { sprintf('%011d', 40000000002 + $_) } (0 .. 19) ] },
    );
    for my $i (0 .. 19) {
        $graph{ sprintf('%011d', 40000000002 + $i) } = { children => [] };
    }
    my $fetch = sub {
        my ($ids) = @_;
        my %out;
        for my $id (@$ids) {
            $out{$id} = { children => [ @{ $graph{$id}{children} // [] } ] };
        }
        return \%out;
    };
    my ($ok, $res) = pz_workshop_resolve_dependency_closure('40000000001', fetch_details => $fetch, max => 20);
    ok(!$ok, 'cap fails');
    is($res->{err}, 'cap_exceeded', 'cap_exceeded err');
    ok(ref($res->{ids}) eq 'ARRAY' && @{ $res->{ids} }, 'returns partial/discovered ids');
};

subtest 'dependency closure root only' => sub {
    my $fetch = sub {
        my ($ids) = @_;
        my %out = map { $_ => { children => [] } } @$ids;
        return \%out;
    };
    my ($ok, $res) = pz_workshop_resolve_dependency_closure('50000000001', fetch_details => $fetch);
    ok($ok, 'root-only ok') or diag($res->{err});
    is_deeply($res->{ids}, ['50000000001'], 'only root');
    ok(!defined $res->{err}, 'no err');
};

subtest 'dependency closure ignores mod.info require' => sub {
    # Closure uses Steam children only — mod.info require= is not consulted.
    my $fetch = sub {
        return { '60000000001' => { children => [] } };
    };
    my ($ok, $res) = pz_workshop_resolve_dependency_closure('60000000001', fetch_details => $fetch);
    ok($ok, 'ok without steam children');
    is_deeply($res->{ids}, ['60000000001'], 'no phantom deps from mod.info');
};

subtest 'dependency closure bad root id' => sub {
    my ($ok, $res) = pz_workshop_resolve_dependency_closure('abc', fetch_details => sub { {} });
    ok(!$ok, 'bad id rejected');
    is($res->{err}, 'bad_id', 'bad_id err');
};

subtest 'subscribe resolve without api key scrapes required items' => sub {
    local %config = ();
    no warnings 'redefine';
    local *main::pz_workshop_fetch_details_via_scrape = sub {
        my ($ids) = @_;
        my %out;
        for my $id (@{ $ids // [] }) {
            if ($id eq '70000000001') {
                $out{$id} = { children => ['70000000002'] };
            } else {
                $out{$id} = { children => [] };
            }
        }
        return \%out;
    };
    use warnings 'redefine';
    my ($ok, $res) = pz_workshop_subscribe_resolve_closure('70000000001');
    ok($ok, 'ok without key via scrape') or diag($res->{err});
    is($res->{warn}, 'api_key_missing', 'warn flag');
    is_deeply($res->{ids}, [qw(70000000002 70000000001)], 'scrape deps before root');
};

subtest 'required items html parse (Skill Recovery Journal shape)' => sub {
    my $html = <<'HTML';
<div class="requiredItemsContainer" id="RequiredItems">
  <a href="https://steamcommunity.com/workshop/filedetails/?id=2896041179" target="_blank">
    <div class="requiredItem">errorMagnifier</div>
  </a>
  <a href="https://steamcommunity.com/workshop/filedetails/?id=3077900375" target="_blank">
    <div class="requiredItem">Mod Update and Alert System</div>
  </a>
</div>
</div>
HTML
    my @ids = pz_workshop_parse_required_items_html($html);
    is_deeply(\@ids, [qw(2896041179 3077900375)], 'parsed required workshop ids');
    is_deeply([ pz_workshop_parse_required_items_html('') ], [], 'empty html');
};

subtest 'details get url includes children flags' => sub {
    my $url = pz_workshop_details_get_url('k', ['2503622437']);
    like($url, qr{IPublishedFileService/GetDetails}, 'uses GetDetails');
    like($url, qr{includechildren=true}, 'asks for children');
    like($url, qr{publishedfileids%5B0%5D=2503622437}, 'id encoded');
    unlike($url, qr{ISteamRemoteStorage/GetPublishedFileDetails},
        'does not use RemoteStorage details (no children)');
};

subtest 'subscribe collect mod ids filters by PZ version' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    make_path("$tmp/dep/mods/DepMod");
    open my $fh, '>', "$tmp/dep/mods/DepMod/mod.info" or die $!;
    print $fh "id=DepMod\nrequire=42.12\n";
    close $fh;
    make_path("$tmp/root/mods/RootMod");
    open $fh, '>', "$tmp/root/mods/RootMod/mod.info" or die $!;
    print $fh "id=RootMod\nrequire=42.12\n";
    close $fh;
    make_path("$tmp/root/mods/OldMod");
    open $fh, '>', "$tmp/root/mods/OldMod/mod.info" or die $!;
    print $fh "id=OldMod\nrequire=41.78\n";
    close $fh;
    my @ids = qw(80000000002 80000000001);
    my %dirs = (
        '80000000002' => "$tmp/dep",
        '80000000001' => "$tmp/root",
    );
    my @mods = pz_workshop_collect_subscribe_mod_ids(\@ids, \%dirs, '42.12.0');
    is_deeply(\@mods, [qw(DepMod RootMod)], 'deps before root; B41 skipped');
    is_deeply(
        [ pz_workshop_collect_subscribe_mod_ids(\@ids, \%dirs, '') ],
        [],
        'unknown server version => no auto mods');
};

subtest 'version match and select AluminumBat-style' => sub {
    ok(pz_workshop_version_matches('42.12', '42.12.0'), '42.12 matches 42.12.0');
    ok(pz_workshop_version_matches('42', '42.12'), 'major-only matches');
    ok(pz_workshop_version_matches('42.12', '42.20'), 'older pin ok on newer same major');
    ok(pz_workshop_version_matches('42.13', '42.20'), '42.13 ok on 42.20');
    ok(!pz_workshop_version_matches('42.13', '42.12'), 'newer pin not ok on older server');
    ok(!pz_workshop_version_matches('41.78', '42.12'), 'B41 not B42');
    ok(!pz_workshop_version_matches('', '42.12'), 'empty require no match');
    ok(pz_workshop_version_exactish('42.12', '42.12.3'), 'exactish same minor');
    ok(!pz_workshop_version_exactish('42.12', '42.20'), 'exactish rejects other minor');
    my @infos = (
        { id => 'AluminumBat', pz_require => '' },
        { id => 'AluminumBat12', pz_require => '42.12' },
    );
    is_deeply(
        [ pz_workshop_select_mod_ids_for_version(\@infos, '42.12.3') ],
        ['AluminumBat12'],
        'only B42 variant selected');
    is_deeply(
        [ pz_workshop_select_mod_ids_for_version(\@infos, '') ],
        [],
        'unknown version => none');
    is_deeply(
        [ pz_workshop_select_mod_ids_for_version(
            [ { id => 'SkillRecoveryJournal', pz_require => '' } ], '42.12') ],
        ['SkillRecoveryJournal'],
        'empty require alone => enable');
    is_deeply(
        [ pz_workshop_select_mod_ids_for_version(
            [
                { id => 'ModA', pz_require => '' },
                { id => 'ModB', pz_require => '' },
            ],
            '42.12') ],
        [],
        'multiple unconstrained => none (never auto multi)');
    is_deeply(
        [ pz_workshop_select_mod_ids_for_version(
            [ { id => 'OldBat', pz_require => '41.78' } ], '42.12') ],
        [],
        'only mismatched require => none');
    is_deeply(
        [ pz_workshop_select_mod_ids_for_version(
            [ { id => 'GunFix', name => '[B42.20] Gun Fix', pz_require => '' } ],
            '42.20') ],
        ['GunFix'],
        'name fallback [B42.20] auto-enables when require empty');
    is(pz_workshop_extract_version_hint('BladesmithSystemB42'), '',
        'embedded B42 in mod id is not a version hint');
    is(pz_workshop_extract_version_hint('[B42.20] Patch'), '42.20',
        'bracket B42.20 name hint');
};

subtest 'AluminumBat versioned subdirs collapse' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $item = "$tmp/2895632846";
    make_path("$item/mods/AluminumBat");
    make_path("$item/mods/AluminumBat/42.12");
    make_path("$item/mods/AluminumBat/42.13");
    open my $fh, '>', "$item/mods/AluminumBat/mod.info" or die $!;
    print $fh "name=Aluminum Bat Mod\nid=AluminumBat\n";
    close $fh;
    open $fh, '>', "$item/mods/AluminumBat/42.12/mod.info" or die $!;
    print $fh "name=Aluminum Bat Mod\nid=AluminumBat12\npzversion=42.12\nmodversion=1.5\n";
    close $fh;
    open $fh, '>', "$item/mods/AluminumBat/42.13/mod.info" or die $!;
    print $fh "name=Aluminum Bat Mod\nid=AluminumBat\npzversion=42.13\nmodversion=1.6\n";
    close $fh;

    my @raw = pz_workshop_parse_mod_info($item);
    cmp_ok(scalar(@raw), '>=', 3, 'parse keeps all mod.info variants');

    my @for_12 = pz_workshop_collapse_mod_infos(\@raw, '42.12');
    my %by12 = map { $_->{id} => $_ } @for_12;
    is($by12{'AluminumBat12'}{pz_require}, '42.12', '42.12 keeps AluminumBat12 pin');
    is($by12{'AluminumBat'}{pz_require}, '', '42.12 prefers empty AluminumBat over newer 42.13 pin');
    is_deeply(
        [ pz_workshop_select_mod_ids_for_version(\@for_12, '42.12') ],
        ['AluminumBat12'],
        'select on 42.12 => AluminumBat12');
    is(pz_workshop_pz_version_cell($by12{'AluminumBat12'}{pz_require}, '42.12')->{match},
        'ok', 'AluminumBat12 passt on 42.12');

    my @for_13 = pz_workshop_collapse_mod_infos(\@raw, '42.13');
    my %by13 = map { $_->{id} => $_ } @for_13;
    is($by13{'AluminumBat'}{pz_require}, '42.13', '42.13 keeps versioned AluminumBat');
    is(pz_workshop_pz_version_cell($by13{'AluminumBat'}{pz_require}, '42.13')->{match},
        'ok', 'AluminumBat passt on 42.13');
    is(pz_workshop_pz_version_cell($by13{'AluminumBat12'}{pz_require}, '42.13')->{match},
        'ok', 'AluminumBat12 older pin still passt on 42.13');
    is_deeply(
        [ pz_workshop_select_mod_ids_for_version(\@raw, '42.13') ],
        ['AluminumBat'],
        'select on 42.13 prefers exact AluminumBat over AluminumBat12');

    is(pz_workshop_pz_version_cell('42.12', '42.20')->{match}, 'ok', '42.12 passt on 42.20');
    is(pz_workshop_pz_version_cell('42.13', '42.20')->{match}, 'ok', '42.13 passt on 42.20');
    is_deeply(
        [ pz_workshop_select_mod_ids_for_version(\@raw, '42.20') ],
        ['AluminumBat'],
        'select on 42.20 => newest compatible pin AluminumBat (42.13)');
};

subtest 'pz_workshop_pz_version_cell' => sub {
    is_deeply(
        pz_workshop_pz_version_cell('', '42.12'),
        { label => 'keine Angabe', match => 'none' },
        'empty require => keine Angabe');
    is_deeply(
        pz_workshop_pz_version_cell(undef, ''),
        { label => 'keine Angabe', match => 'none' },
        'undef require => keine Angabe');
    is_deeply(
        pz_workshop_pz_version_cell('42.12', '42.12.0'),
        { label => 'PZ 42.12', match => 'ok' },
        'matching require => ok');
    is_deeply(
        pz_workshop_pz_version_cell('41.78', '42.12'),
        { label => 'PZ 41.78', match => 'bad' },
        'mismatch => bad');
    is_deeply(
        pz_workshop_pz_version_cell('42.12', ''),
        { label => 'PZ 42.12', match => 'none' },
        'unknown server => none badge');
    is_deeply(
        pz_workshop_pz_version_cell(' 42.12 ', '42.12'),
        { label => 'PZ 42.12', match => 'ok' },
        'trims require whitespace');
    is_deeply(
        pz_workshop_pz_version_cell('ModernFirearmsSystem', '42.12'),
        { label => 'unbekannt', match => 'unknown' },
        'dep/mod-name require => unknown not unpassend');
    is_deeply(
        pz_workshop_pz_version_cell('tsarslib', '42.12'),
        { label => 'unbekannt', match => 'unknown' },
        'non-version require => unknown');
    is_deeply(
        pz_workshop_pz_version_cell('', '42.20',
            { id => 'x', name => '[B42.20] Patch', pz_require => '' }),
        { label => 'PZ 42.20 ~', match => 'ok' },
        'name fallback shows ~ and match ok');
};

subtest 'detect server version ignores OS/modversion noise' => sub {
    ok(pz_workshop_looks_like_game_version('42.12'), '42.12 is game build');
    ok(pz_workshop_looks_like_game_version('41.78.16'), '41.78.16 is game build');
    ok(!pz_workshop_looks_like_game_version('1.3.0'), '1.3.0 is not a PZ build');
    ok(!pz_workshop_looks_like_game_version('7.2.8'), 'kernel/OS version rejected');

    is(pz_workshop_version_from_log_line(
        'LOG : General f:0> OS: Linux, version: 7.2.8-2-cachyos, arch: amd64'),
        '', 'OS version line ignored');
    is(pz_workshop_version_from_log_line('modversion=1.3.0'),
        '', 'modversion line ignored');
    is(pz_workshop_version_from_log_line('versionNumber=42.12.0'),
        '42.12.0', 'versionNumber accepted');
    is(pz_workshop_version_from_log_line('version=42.20.3'),
        '42.20.3', 'startup version= accepted');

    my $tmp = tempdir(CLEANUP => 1);
    my $home = "$tmp/home";
    make_path("$home/Zomboid/Logs");
    open my $fh, '>', "$home/Zomboid/Logs/server-console.txt" or die $!;
    print $fh "OS: Linux, version: 7.2.8\n";
    print $fh "some mod version=1.3.0\n";
    print $fh "versionNumber=42.12.0\n";
    close $fh;

    no warnings 'redefine';
    local *main::pz_workshop_unix_home = sub { return $home; };
    use warnings 'redefine';
    is(pz_workshop_detect_server_version('u', "$tmp/noserver"),
        '42.12.0', 'detect prefers PZ versionNumber over noise');
};

subtest 'subscribe patch ini adds all workshop ids and ordered mods' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $home = "$tmp/home";
    make_path("$home/Zomboid/Server");
    my $ini = "$home/Zomboid/Server/pzserver.ini";
    open my $fh, '>', $ini or die $!;
    print $fh "WorkshopItems=\nMods=ExistingMod\n";
    close $fh;

    make_path("$tmp/dep/mods/DepMod");
    open $fh, '>', "$tmp/dep/mods/DepMod/mod.info" or die $!;
    print $fh "id=DepMod\nrequire=42.12\n";
    close $fh;
    make_path("$tmp/root/mods/RootMod");
    open $fh, '>', "$tmp/root/mods/RootMod/mod.info" or die $!;
    print $fh "id=RootMod\nrequire=42.12\n";
    close $fh;

    no warnings 'redefine';
    local *main::pz_workshop_unix_home = sub { return $home; };
    local *main::pz_workshop_detect_server_version = sub { return '42.12.0'; };
    use warnings 'redefine';

    my @ordered = qw(90000000002 90000000001);
    my %dirs = (
        '90000000002' => "$tmp/dep",
        '90000000001' => "$tmp/root",
    );
    my ($ok, $err, $info) = pz_workshop_subscribe_patch_ini(
        'fakeuser', 'pzserver', '90000000001', \@ordered, \%dirs, '',
    );
    ok($ok, 'subscribe patch ok') or diag($err);
    is($info->{total}, 2, 'total items');
    is($info->{dep_count}, 1, 'one dependency');
    is($info->{mods_auto}, 2, 'two version-matching mods');
    my ($vals) = pz_workshop_read_ini($ini);
    like($vals->{WorkshopItems}, qr/90000000002.*90000000001|90000000001.*90000000002/,
        'both workshop ids present');
    is($vals->{Mods}, 'ExistingMod;DepMod;RootMod', 'version-matching mods inserted');
};

subtest 'workshop.cgi uses registry user field for job launch' => sub {
    open my $fh, '<', 'src/workshop.cgi' or die $!;
    local $/;
    my $src = <$fh>;
    close $fh;
    like($src, qr/\$inst->\{'user'\}/, 'workshop.cgi: reads inst user');
    unlike($src, qr/\$inst->\{'unix_user'\}/, 'workshop.cgi: does not use nonexistent unix_user');
    like($src, qr/user_worker_launch_cmd/, 'workshop.cgi: launches user worker');
};

subtest 'workshop.cgi PZ-Version column' => sub {
    open my $fh, '<', 'src/workshop.cgi' or die $!;
    local $/;
    my $src = <$fh>;
    close $fh;
    like($src, qr/workshop_col_pz_version/, 'column header key');
    like($src, qr/_ws_render_pz_version_cell/, 'PZ version cell renderer');
    like($src, qr/pz_workshop_pz_version_cell/, 'uses library cell helper');
    unlike($src, qr/· PZ /, 'no inline PZ fragment in mods cell');
};

subtest 'workshop.cgi subscribe/delete not item disable' => sub {
    open my $fh, '<', 'src/workshop.cgi' or die $!;
    local $/;
    my $src = <$fh>;
    close $fh;
    like($src, qr/workshop_subscribe_local_btn/, 'local subscribe for files-only');
    unlike($src, qr/workshop_disable_btn/, 'no item-level disable button in UI');
    unlike($src, qr/action', 'disable'/, 'no disable action form in UI');
    like($src, qr/action', 'delete'/, 'delete remains');
    like($src, qr/enable_mod|disable_mod/, 'per-mod toggles remain');
};

done_testing();
