# PZ Workshop Inventory — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On `workshop.cgi`, list downloaded Workshop items (disk ∪ INI), show `mod.info` + Steam details, enable / disable / delete per item; on **subscribe**, transitively download Steam Required items and order `Mods=` (deps first).

**Architecture:** Extend `pz_workshop.pl` with content-root scan, richer `mod.info` parse, inventory merge, Steam details, enable/disable/delete. Subscribe worker resolves Steam children closure (cap 20), downloads all, patches INI once. Inventory Enable does **not** auto-pull deps.

**Tech Stack:** Perl Webmin CGI, existing `pz_workshop.pl` / `workshop.cgi` / `pz_workshop_subscribe_user.sh`, Steam Web API, `module_config` flash, `t/test_pz_workshop.pl`.

**Related specs:** Inventory `2026-09-29-pz-workshop-inventory-design.md`; Deps `2026-09-29-pz-workshop-deps-design.md`.

## Global Constraints

- Game-user only for disk delete / no root writes to home or `$SERVER_DIR`
- Path delete only under validated workshop content roots
- Success: flash + verify (INI read-back; dir gone after delete)
- UI strings in `src/lang/de` + `src/lang/en`
- `bash scripts/verify.sh` green before claiming done
- No version bump / tag unless user asks
- Unit of management: one workshop item (not per mod-id toggle)

## File map

| File | Role |
|------|------|
| `src/lib/pz_workshop.pl` | Scan, inventory, steam details, enable/disable/delete |
| `src/workshop.cgi` | Inventory UI + actions |
| `src/lang/de`, `src/lang/en` | New keys |
| `t/test_pz_workshop.pl` | Unit tests + fixtures |
| `CHANGELOG.md` | Short Fixed/Changed note |
| Spec | `docs/superpowers/specs/2026-09-29-pz-workshop-inventory-design.md` |

---

### Task 1: Richer `mod.info` parse + content roots + disk scan

**Files:**
- Modify: `src/lib/pz_workshop.pl`
- Test: `t/test_pz_workshop.pl`

**Interfaces:**
- Produces:
  - `pz_workshop_parse_mod_info($item_dir)` → list of hashrefs `{ id, name, modversion, pz_require, authors }`
  - Keep `pz_workshop_parse_mod_ids` as thin wrapper returning `id`s only (callers unchanged)
  - `pz_workshop_content_roots($unix_user, $server_dir, $appid)` → `@roots` (existing dirs only)
  - `pz_workshop_scan_disk($unix_user, $server_dir, $appid)` → hashref `{ $workshop_id => { content_dir, mod_infos => [...] } }`
  - `pz_workshop_path_under_content_roots($path, \@roots)` → 1/0 after realpath

- [ ] **Step 1: Write failing tests** in `t/test_pz_workshop.pl`:

```perl
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
    # Inject fake home via optional override env for tests:
    # Prefer: pz_workshop_scan_disk_in_roots([ "$home/Steam/steamapps/workshop/content/108600" ])
    my $map = pz_workshop_scan_disk_in_roots([
        "$home/Steam/steamapps/workshop/content/108600"
    ]);
    ok(exists $map->{'2859296945'}, 'found workshop id');
    is($map->{'2859296945'}{mod_infos}[0]{id}, 'Brita');
};

subtest 'path under roots rejects escape' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    make_path("$tmp/ok/108600/1");
    my @roots = ("$tmp/ok/108600");
    ok(pz_workshop_path_under_content_roots("$tmp/ok/108600/1", \@roots), 'inside ok');
    ok(!pz_workshop_path_under_content_roots("$tmp/other", \@roots), 'outside rejected');
};
```

- [ ] **Step 2: Run tests — expect FAIL** (missing subs)

```bash
perl t/test_pz_workshop.pl
```

- [ ] **Step 3: Implement** in `pz_workshop.pl`:

```perl
sub pz_workshop_parse_mod_info {
    my ($item_dir) = @_;
    return () unless defined $item_dir && -d $item_dir;
    my @out;
    my %seen_id;
    require File::Find;
    File::Find::find({
        wanted => sub {
            return unless -f $_ && lc(basename($_)) eq 'mod.info';
            open(my $fh, '<', $_) or return;
            my %f;
            while (my $line = <$fh>) {
                chomp $line; $line =~ s/\r//g;
                next unless $line =~ /^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$/;
                my ($k, $v) = (lc($1), $2);
                $f{$k} = $v;
            }
            close $fh;
            my $id = $f{id} // '';
            $id =~ s/[;\r\n]//g;
            return unless length $id;
            return if $seen_id{$id}++;
            my $req = $f{require} // $f{pzversion} // $f{'pz-version'} // '';
            push @out, {
                id         => $id,
                name       => $f{name} // '',
                modversion => $f{modversion} // $f{version} // '',
                pz_require => $req,
                authors    => $f{authors} // $f{author} // '',
            };
        },
        no_chdir => 1,
    }, $item_dir);
    return @out;
}

sub pz_workshop_parse_mod_ids {
    my ($item_dir) = @_;
    return map { $_->{id} } pz_workshop_parse_mod_info($item_dir);
}

sub pz_workshop_content_roots {
    my ($unix_user, $server_dir, $appid) = @_;
    $appid = int($appid || 0);
    return () unless $appid > 0;
    my $home = pz_workshop_unix_home($unix_user) // '';
    my @cands;
    push @cands, "$home/Steam/steamapps/workshop/content/$appid" if $home ne '';
    push @cands, "$home/.steam/steam/steamapps/workshop/content/$appid" if $home ne '';
    push @cands, "$home/steamapps/workshop/content/$appid" if $home ne '';
    if (defined $server_dir && $server_dir ne '') {
        push @cands, "$server_dir/steamapps/workshop/content/$appid";
        push @cands, "$server_dir/serverfiles/steamapps/workshop/content/$appid";
    }
    my @out; my %seen;
    for my $r (@cands) {
        next unless -d $r;
        my $rp = _pz_workshop_realpath_allow_missing($r) // $r;
        next if $seen{$rp}++;
        push @out, $rp;
    }
    return @out;
}

sub pz_workshop_scan_disk_in_roots {
    my ($roots) = @_;
    my %map;
    for my $root (@{ $roots // [] }) {
        next unless defined $root && -d $root;
        opendir(my $dh, $root) or next;
        while (my $ent = readdir($dh)) {
            next unless $ent =~ /^\d{5,20}$/;
            my $dir = "$root/$ent";
            next unless -d $dir;
            $map{$ent} = {
                content_dir => $dir,
                mod_infos   => [ pz_workshop_parse_mod_info($dir) ],
            };
        }
        closedir($dh);
    }
    return \%map;
}

sub pz_workshop_scan_disk {
    my ($unix_user, $server_dir, $appid) = @_;
    my @roots = pz_workshop_content_roots($unix_user, $server_dir, $appid);
    return pz_workshop_scan_disk_in_roots(\@roots);
}

sub pz_workshop_path_under_content_roots {
    my ($path, $roots) = @_;
    return 0 unless defined $path && $path ne '';
    my $rp = _pz_workshop_realpath_allow_missing($path);
    return 0 unless defined $rp && -e $rp;
    for my $root (@{ $roots // [] }) {
        my $rr = _pz_workshop_realpath_allow_missing($root) // $root;
        return 1 if $rp eq $rr || index($rp, "$rr/") == 0;
    }
    return 0;
}
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
perl t/test_pz_workshop.pl
```

- [ ] **Step 5: Commit** (only if user asked to commit; otherwise skip)

```bash
git add src/lib/pz_workshop.pl t/test_pz_workshop.pl
git commit -m "$(cat <<'EOF'
feat(pz-workshop): scan disk content and parse rich mod.info

EOF
)"
```

---

### Task 2: Inventory merge + enable/disable with verify

**Files:**
- Modify: `src/lib/pz_workshop.pl`
- Test: `t/test_pz_workshop.pl`

**Interfaces:**
- Consumes: `pz_workshop_scan_disk_in_roots`, `pz_workshop_patch_ini`, `pz_workshop_read_ini`
- Produces:
  - `pz_workshop_list_inventory($unix_user, $script_name, $server_dir)` → arrayref of row hashes:
    `{ workshop_id, on_disk, in_ini, content_dir, mod_infos, status }` where `status` is `active`|`inactive`|`orphan_ini`
  - `pz_workshop_enable_item($ini, $workshop_id, $mod_ids_aref)` → `(ok, err)` after patch + read-back
  - `pz_workshop_disable_item($ini, $workshop_id, $mod_ids_aref)` → `(ok, err)`; for orphan pass empty/undef mod ids (only remove WorkshopItems entry)

Replace body of existing `pz_workshop_list_installed` to call `list_inventory` and map, **or** leave `list_installed` unused and switch CGI to `list_inventory` (prefer replace callers; keep `list_installed` as thin alias returning inventory for back-compat).

- [ ] **Step 1: Failing tests**

```perl
subtest 'inventory merge statuses' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $ini = "$tmp/pzserver.ini";
    open my $fh, '>', $ini or die $!;
    print $fh "WorkshopItems=111;999\nMods=ModA\n";
    close $fh;
    make_path("$tmp/content/111/mods/A");
    open $fh, '>', "$tmp/content/111/mods/A/mod.info" or die $!;
    print $fh "id=ModA\nname=A\n";
    close $fh;
    make_path("$tmp/content/222/mods/B");
    open $fh, '>', "$tmp/content/222/mods/B/mod.info" or die $!;
    print $fh "id=ModB\n";
    close $fh;

    my $disk = pz_workshop_scan_disk_in_roots(["$tmp/content"]);
    my $rows = pz_workshop_merge_inventory($ini, $disk);
    my %by = map { $_->{workshop_id} => $_ } @$rows;
    is($by{'111'}{status}, 'active');
    is($by{'222'}{status}, 'inactive');
    is($by{'999'}{status}, 'orphan_ini');
};

subtest 'enable disable verify' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $ini = "$tmp/pzserver.ini";
    open my $fh, '>', $ini or die $!;
    print $fh "WorkshopItems=\nMods=\n";
    close $fh;
    my ($ok, $err) = pz_workshop_enable_item($ini, '111', ['ModA']);
    ok($ok) or diag($err);
    my ($vals) = pz_workshop_read_ini($ini);
    is($vals->{WorkshopItems}, '111');
    is($vals->{Mods}, 'ModA');
    ($ok, $err) = pz_workshop_disable_item($ini, '111', ['ModA']);
    ok($ok) or diag($err);
    ($vals) = pz_workshop_read_ini($ini);
    is($vals->{WorkshopItems}, '');
    is($vals->{Mods}, '');
};
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement** `pz_workshop_merge_inventory`, `pz_workshop_list_inventory`, `enable_item`, `disable_item`:

```perl
sub pz_workshop_merge_inventory {
    my ($ini_path, $disk_map) = @_;
    $disk_map //= {};
    my ($vals) = (-f ($ini_path // '') ? pz_workshop_read_ini($ini_path) : ({},));
    my %in_ini = map { $_ => 1 } pz_workshop_split_list($vals->{'WorkshopItems'} // '');
    my %ids = (%$disk_map, %in_ini);
    my @rows;
    for my $id (sort { $a cmp $b } keys %ids) {
        my $on_disk = exists $disk_map->{$id} ? 1 : 0;
        my $in = $in_ini{$id} ? 1 : 0;
        my $status = ($on_disk && $in) ? 'active'
                   : ($on_disk && !$in) ? 'inactive'
                   : 'orphan_ini';
        my $ent = $disk_map->{$id} // {};
        push @rows, {
            workshop_id => $id,
            on_disk     => $on_disk,
            in_ini      => $in,
            content_dir => $ent->{content_dir},
            mod_infos   => $ent->{mod_infos} // [],
            status      => $status,
        };
    }
    return \@rows;
}

sub pz_workshop_list_inventory {
    my ($unix_user, $script_name, $server_dir) = @_;
    my $appid = get_workshop_appid($script_name) || 108600;
    my $disk = pz_workshop_scan_disk($unix_user, $server_dir, $appid);
    my ($ok, $ini) = pz_workshop_resolve_ini_path($unix_user, $script_name);
    return pz_workshop_merge_inventory($ok ? $ini : undef, $disk);
}

sub pz_workshop_enable_item {
    my ($ini, $wid, $mod_ids) = @_;
    $wid = pz_workshop_normalize_item_id($wid);
    return (0, 'bad_id') unless length $wid;
    my ($ok, $err) = pz_workshop_patch_ini($ini, {
        add_workshop => [$wid],
        add_mods     => [ @{ $mod_ids // [] } ],
    });
    return (0, $err) unless $ok;
    my ($vals) = pz_workshop_read_ini($ini);
    my $wi = $vals->{WorkshopItems} // '';
    return (0, 'verify_failed') unless $wi =~ /(?:^|;)\Q$wid\E(?:;|$)/;
    return (1, undef);
}

sub pz_workshop_disable_item {
    my ($ini, $wid, $mod_ids) = @_;
    $wid = pz_workshop_normalize_item_id($wid);
    return (0, 'bad_id') unless length $wid;
    my ($ok, $err) = pz_workshop_patch_ini($ini, {
        remove_workshop => [$wid],
        remove_mods     => [ @{ $mod_ids // [] } ],
    });
    return (0, $err) unless $ok;
    my ($vals) = pz_workshop_read_ini($ini);
    my $wi = $vals->{WorkshopItems} // '';
    return (0, 'verify_failed') if $wi =~ /(?:^|;)\Q$wid\E(?:;|$)/;
    return (1, undef);
}
```

Fix merge key union: build `%ids` from disk keys + ini ids properly (disk keys are workshop ids; `%in_ini` keys are ids). Do **not** use `%$disk_map` as hash slice mixed with `%in_ini` incorrectly — use:

```perl
my %ids;
$ids{$_} = 1 for keys %$disk_map;
$ids{$_} = 1 for keys %in_ini;
```

- [ ] **Step 4: Tests PASS**

- [ ] **Step 5: Commit** only if user asked

---

### Task 3: Steam details batch + fixture parser

**Files:**
- Modify: `src/lib/pz_workshop.pl`
- Test: `t/test_pz_workshop.pl`
- Optional fixture: `t/fixtures/pz_workshop_details.json`

**Interfaces:**
- Produces:
  - `pz_workshop_parse_details_fixture($json_text)` → `{ $id => { title, description, preview_url, time_updated } }`
  - `pz_workshop_steam_details(\@ids)` → same hashref; empty hash on missing key / API fail (never dies)

Steam call: POST `https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/` with `itemcount=N` and `publishedfileids[0]=…` (curl `--data`). Cap IDs at 50 per request; chunk if needed.

- [ ] **Step 1: Fixture + failing test**

```perl
subtest 'steam details fixture' => sub {
    my $json = '{"response":{"publishedfiledetails":[
      {"publishedfileid":"2859296945","title":"Brita","file_description":"Guns",
       "preview_url":"https://example.com/p.jpg","time_updated":1700000000}
    ]}}';
    my $m = pz_workshop_parse_details_fixture($json);
    is($m->{'2859296945'}{title}, 'Brita');
    ok(length($m->{'2859296945'}{preview_url}) > 0);
};
```

- [ ] **Step 2: Implement parse + `pz_workshop_steam_details`** (live curl; tests only use fixture). Truncate description to 280 chars. Sanitize IDs to digits only.

- [ ] **Step 3: Tests PASS**

---

### Task 4: Delete as game user (path-guarded)

**Files:**
- Modify: `src/lib/pz_workshop.pl`
- Test: `t/test_pz_workshop.pl`

**Interfaces:**
- Produces: `pz_workshop_delete_item($unix_user, $ini, $workshop_id, $content_dir, $mod_ids_aref, \@roots)` → `(ok, err)`
  1. `pz_workshop_disable_item` (even if already inactive — idempotent remove)
  2. If `$content_dir` defined: require `pz_workshop_path_under_content_roots`; then `rm -rf` as user
  3. Verify: `!-d $content_dir` (or never existed) and workshop id absent from INI

```perl
sub _pz_workshop_rmtree_as_user {
    my ($unix_user, $dir) = @_;
    return 0 unless defined $dir && -d $dir;
    my $uid = (getpwnam($unix_user // ''))[2];
    if (defined $uid && $> == $uid) {
        require File::Path;
        File::Path::rmtree($dir);
        return !-d $dir;
    }
    (my $safe = $dir) =~ s/'/'\\''/g;
    system('su', '-s', '/bin/bash', '-c', "rm -rf -- '$safe'", $unix_user);
    return ($? == 0 && !-d $dir) ? 1 : 0;
}
```

- [ ] **Step 1: Test delete under temp roots** (simulate as current user: pass `$unix_user` empty or `$ENV{USER}` with direct path — when `unix_user` is `''` or current euid matches, rmtree direct). Prefer testing with empty unix_user + existing dir under roots so no `su` needed in CI.

- [ ] **Step 2: Implement + PASS**

---

### Task 5: workshop.cgi inventory UI + actions + lang

**Files:**
- Modify: `src/workshop.cgi`
- Modify: `src/lang/de`, `src/lang/en`
- Modify: `CHANGELOG.md`

**Actions** (POST, operate ACL, not readonly):

| `action` | Behavior |
|----------|----------|
| `enable` | resolve row from inventory; `enable_item`; flash `workshop_enabled`; redirect |
| `disable` | `disable_item` with mod ids from disk (empty if orphan); flash `workshop_disabled` |
| `delete` | `delete_item`; flash `workshop_deleted` |

Redirect via `_ws_page_url($id, enabled|disabled|deleted => 1)` after flash mark + verify.

GET banners: consume flash like unsubscribe.

**UI:** Replace INI-only list with inventory columns:

1. Item — Steam title (fallback workshop id), small preview `<img>` if https URL allowlisted host pattern `steam*`/`steamusercontent`/`steamstatic` or skip img and show link; workshop id; orphan warning
2. Mods — each `name (id) · vX · PZ require`
3. Status — badge text from lang (`workshop_status_active` / `_inactive` / `_orphan`)
4. Actions — Enable (if inactive), Disable (if active or orphan), Delete (Confirm JS) if on_disk or orphan

Call `pz_workshop_steam_details([ map ids ])` once per page load when API key present; merge into rows for display.

Keep search/subscribe sections unchanged.

Lang keys (de+en): `workshop_installed_section` (may already exist — retitle to „Installiert“), `workshop_status_*`, `workshop_enable_btn`, `workshop_disable_btn`, `workshop_delete_btn`, `workshop_delete_confirm`, `workshop_enabled_ok`, `workshop_disabled_ok`, `workshop_deleted_ok`, `workshop_action_failed`, `workshop_orphan_hint`, `workshop_restart_hint`.

- [ ] **Step 1: Wire actions + inventory render + lang**
- [ ] **Step 2: Smoke** `perl -c src/workshop.cgi`
- [ ] **Step 3: `bash scripts/verify.sh`** — expect green
- [ ] **Step 4: CHANGELOG** under Fixed/Changed: inventory list + enable/disable/delete

---

### Task 6: Spec status + final verify

- [ ] Set inventory + deps specs to `Implemented` when green
- [ ] `bash scripts/verify.sh`
- [ ] Manual: inactive-on-disk → Enable; Subscribe with Required items pulls deps into INI with deps-first `Mods=`

---

### Task D1: Dependency closure resolver (Steam children)

**Files:** `src/lib/pz_workshop.pl`, `t/test_pz_workshop.pl`  
**Spec:** `docs/superpowers/specs/2026-09-29-pz-workshop-deps-design.md`

**Interfaces:**
- Extend details parse to include `children` → list of workshop ids
- `pz_workshop_resolve_dependency_closure($root_id, %opts)` with `max => 20`, optional `fetch_details => sub ($ids) -> hash`
  - Returns `(ok, { ids => [...ordered...], err => ... })`
  - Order: topological, dependencies before dependents; root included
  - Cycles skipped; over cap → `ok=0`, `err=cap_exceeded`
- Fixture-only tests (no live Steam)

- [ ] **Step 1: Failing tests** — diamond graph, cycle, cap
- [ ] **Step 2: Implement resolver + children in details fixture/parser**
- [ ] **Step 3: Tests PASS**

---

### Task D2: Subscribe worker — resolve → download all → patch once

**Files:** `src/scripts/pz_workshop_subscribe_user.sh`, `src/lib/pz_workshop.pl`

- [ ] **Step 1:** Before any INI patch: call closure for root id (API key from `.worker_secrets`; if missing → warn, ids=`[root]` only)
- [ ] **Step 2:** For each id in order: find/download content dir (reuse existing SteamCMD loop)
- [ ] **Step 3:** Collect all mod ids; patch INI once with all workshop ids + mod ids (deps-first order for new Mods entries)
- [ ] **Step 4:** Verify root in `WorkshopItems`; log “Installed N items (M dependencies)”
- [ ] **Step 5:** `bash -n` worker + `perl t/test_pz_workshop.pl`

---

### Task D3: Lang / CHANGELOG for deps

**Files:** `src/lang/de`, `src/lang/en`, `CHANGELOG.md`

- [ ] Keys: `workshop_deps_cap_failed`, `workshop_deps_included` (optional flash text)
- [ ] CHANGELOG: Subscribe pulls transitive Steam Required items (cap 20)

---

## Spec coverage checklist

| Spec item | Task |
|-----------|------|
| Unified disk ∪ INI list | 2, 5 |
| Per workshop-item unit | 2, 5 |
| Enable / disable / delete semantics | 2, 4, 5 |
| mod.info + Steam metadata | 1, 3, 5 |
| Path-guarded delete as user | 4 |
| Flash + verify success | 5 |
| orphan_ini only strips WorkshopItems | 2, 5 |
| Transitive Steam deps on subscribe only | D1–D3 |
| No auto-deps on inventory enable | D2 (worker only) / 5 |
| Tests + verify.sh | 1–6, D1–D3 |

## Placeholder / consistency notes

- Use `pz_workshop_scan_disk_in_roots` in tests to avoid fake `getpwnam`.
- Inventory merge must union keys correctly (fix called out in Task 2).
- `mod.info require=` is **game version**, never treated as workshop dependency.
- Do not commit unless the user asks.
