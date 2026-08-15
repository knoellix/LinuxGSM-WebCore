# Minecraft Mods-Seite (`mods.cgi`) — Implementation Plan

> **Status:** Implementiert (2026-08-15)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Move mod/modpack management onto a dedicated `mods.cgi` page with an installed-mod list (filter/sort/pagination), enable/disable/delete, optional version pick on install, version pick on update, plus Start/Stop/Log for quick testing.

**Architecture:** Disk scan of `serverfiles/{mods|plugins}/*.jar(.disabled)` is source of truth for enable state; `.mc_mods_index.json` supplies titles/API ids. Sync rename/unlink as game user for enable/disable/delete (flash after verify). Install/update/modpack stay async jobs → `job_live.cgi`. UI leaves `manage.cgi` (link only).

**Tech Stack:** Perl Webmin CGI (`ui_*`), `mc_mods.pl` / `mc_modpack.pl`, existing `mc_mod_install` / `modpack_import` workers, `module_config_flash_*`, Test::More.

**Spec:** [`docs/superpowers/specs/2026-08-15-mc-mods-page-design.md`](../specs/2026-08-15-mc-mods-page-design.md)

## Global Constraints

- UI strings: German `src/lang/de` + English `src/lang/en`; code/comments English.
- Success only after verify / flash / `$JOB_DIR/status=ok` (`no-blind-success-feedback.mdc`).
- Game data writes as game user only (`security-isolation.mdc`); path sanitize + stay under `serverfiles/$mod_dir/`.
- `&redirect(...)` always followed by `exit;`.
- End each milestone with scoped tests; finish with `bash scripts/verify.sh`.
- Do not commit unless the user asks (plan steps may still list suggested commit messages).

---

## File map

| File | Role |
|------|------|
| `src/lib/mc_mods.pl` | `list_installed_mods`, enable/disable/delete, path guards, version list helpers |
| `src/mods.cgi` | New page: toolbar, list, search/install, modpack, actions |
| `src/manage.cgi` | Remove mod/modpack sections; add link to `mods.cgi`; keep start/stop/monitor for reuse patterns |
| `src/lib/jobs.pl` | Optional label for `mc_mod_update` if introduced (else reuse `mc_mod_install`) |
| `src/lang/de`, `src/lang/en` | All new `mc_mods_page_*` / action keys |
| `t/test_mc_mods.pl` | List/enable/disable/delete/filter/pagination tests |
| `.cursor/rules/minecraft-mods.mdc` | Point UI to `mods.cgi` |
| `docs/superpowers/specs/2026-08-15-mc-mods-page-design.md` | Spec (already written) |

**Out of scope:** Bulk actions, auto-restart after toggle, modpack export, dependency resolver.

---

### Task 1: Library — path guard + list installed mods

**Files:**
- Modify: `src/lib/mc_mods.pl`
- Test: `t/test_mc_mods.pl`

**Interfaces:**
- Produces:
  - `mod_basename_sanitize($name) -> $safe_or_empty`
  - `mod_file_paths($server_dir, $mod_dir, $basename) -> ($enabled_path, $disabled_path)`  
    `$basename` is always `something.jar` (no `.disabled` suffix in the logical name)
  - `mod_validate_under_mod_dir($server_dir, $mod_dir, $abs_path) -> 1/0`
  - `list_installed_mods($server_dir, $profile) -> \@mods`  
    each: `{ basename, enabled, filename_on_disk, title, source, project_id, version_id, file_id, hangar_slug, has_update_meta }`

- [x] **Step 1: Failing tests**

```perl
subtest 'list_installed_mods scans jar and disabled' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $sf = "$tmp/serverfiles/mods";
    File::Path::make_path($sf);
    open my $a, '>', "$sf/Alpha.jar" or die $!;
    print $a 'x'; close $a;
    open my $b, '>', "$sf/Beta.jar.disabled" or die $!;
    print $b 'y'; close $b;
    write_mc_mods_index($tmp, {
        'mods/Alpha.jar' => { title => 'Alpha Mod', source => 'modrinth', modrinth_project => 'abc' },
    });
    my $profile = { mod_dir => 'mods', loader => 'neoforge', mc_version => '1.21.1' };
    my $list = list_installed_mods($tmp, $profile);
    is(scalar @$list, 2, 'two mods');
    my %by = map { $_->{basename} => $_ } @$list;
    ok($by{'Alpha.jar'}{enabled}, 'alpha enabled');
    ok(!$by{'Beta.jar'}{enabled}, 'beta disabled');
    is($by{'Alpha.jar'}{title}, 'Alpha Mod', 'title from index');
    ok($by{'Alpha.jar'}{has_update_meta}, 'update meta when project known');
    ok(!$by{'Beta.jar'}{has_update_meta}, 'no update meta without index');
};
```

- [x] **Step 2: Run — expect FAIL** (`list_installed_mods` undefined)

```bash
perl t/test_mc_mods.pl
```

- [x] **Step 3: Implement sanitize + list**

- Logical basename: strip trailing `.disabled`, require `/\.jar\z/`.
- Scan only direct children of `serverfiles/$mod_dir/`.
- Merge index under key `"$mod_dir/$basename"`.
- `has_update_meta`: 1 if source is modrinth/curseforge/hangar with usable project id/slug.

- [x] **Step 4: Run — PASS for this subtest**

```bash
perl t/test_mc_mods.pl
```

---

### Task 2: Library — enable / disable / delete (game-user rename)

**Files:**
- Modify: `src/lib/mc_mods.pl`
- Test: `t/test_mc_mods.pl`

**Interfaces:**
- Produces:
  - `mod_set_enabled($server_dir, $unix_user, $mod_dir, $basename, $want_enabled) -> (ok, err)`  
    `$err`: `missing`, `invalid`, `outside`, `rename_failed`, `verify_failed`
  - `mod_delete_installed($server_dir, $unix_user, $mod_dir, $basename) -> (ok, err)`  
    removes enabled and/or disabled file; drops index key; verify gone

**Implementation notes:**
- Prefer `su -s /bin/bash -c 'mv …'` / `rm` as `$unix_user` when euid is root; if euid already matches user, rename/unlink directly (same pattern as `write_mc_profile`).
- Always `mod_validate_under_mod_dir` on source and destination after resolve (`Cwd::realpath` or careful join + reject `..`).
- After disable: `$basename.disabled` exists, plain jar does not (and vice versa).

- [x] **Step 1: Failing tests** (tempdir as current user; pass `unix_user => ''` or `$<` and document that empty user = direct FS ops for tests)

```perl
subtest 'mod_set_enabled and delete' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $sf = "$tmp/serverfiles/mods";
    File::Path::make_path($sf);
    open my $fh, '>', "$sf/Foo.jar" or die $!;
    print $fh 'x'; close $fh;
    my ($ok, $err) = mod_set_enabled($tmp, '', 'mods', 'Foo.jar', 0);
    ok($ok, 'disable ok') or diag($err);
    ok(-f "$sf/Foo.jar.disabled", 'disabled file present');
    ok(!-f "$sf/Foo.jar", 'enabled file gone');
    ($ok, $err) = mod_set_enabled($tmp, '', 'mods', 'Foo.jar', 1);
    ok($ok, 'enable ok');
    ($ok, $err) = mod_delete_installed($tmp, '', 'mods', 'Foo.jar');
    ok($ok, 'delete ok');
    ok(!-e "$sf/Foo.jar" && !-e "$sf/Foo.jar.disabled", 'both gone');
};
```

- [x] **Step 2: Implement + PASS**

```bash
perl t/test_mc_mods.pl
```

---

### Task 3: Library — filter / sort / pagination

**Files:**
- Modify: `src/lib/mc_mods.pl`
- Test: `t/test_mc_mods.pl`

**Interfaces:**
- Produces:
  - `filter_installed_mods(\@mods, \%opts) -> \@filtered`  
    opts: `q` (substr name/title, case-insensitive), `status` = `all|enabled|disabled`
  - `sort_installed_mods(\@mods, $key, $dir) -> \@sorted`  
    `$key`: `name` | `status`; `$dir`: `asc` | `desc`
  - `paginate_installed_mods(\@mods, $page, $per_page) -> ( \@slice, $total, $pages )`  
    default `$per_page = 50`; `$page` 1-based clamped

- [x] **Step 1: Tests for filter/sort/page**
- [x] **Step 2: Implement + PASS**

---

### Task 4: Library — list compatible versions (optional install + update)

**Files:**
- Modify: `src/lib/mc_mods.pl`
- Test: `t/test_mc_mods.pl` (unit with mocked HTTP if existing pattern; otherwise pure helper shaping + one live SKIP)

**Interfaces:**
- Produces:
  - `modrinth_list_compatible_versions($project_id, $profile) -> \@versions`  
    each: `{ version_id, name, filename, download_url?, env, published? }` — reuse filters from `modrinth_resolve_version_file` but return **all** matching versions (cap e.g. 30)
  - `curseforge_list_compatible_files($project_id, $profile) -> \@files`  
    each: `{ file_id, display_name, filename, … }` — filter by game version + loader like resolve
  - `hangar_list_compatible_versions(...)` if Paper path already has hangar resolve; else v1 Paper update only when hangar helpers exist

Refactor `modrinth_resolve_version_file` to pick first of `modrinth_list_compatible_versions` (DRY).

- [x] **Step 1: Test list returns multiple / empty safely**
- [x] **Step 2: Implement + keep existing resolve tests green**

```bash
perl t/test_mc_mods.pl
```

---

### Task 5: `mods.cgi` skeleton + server toolbar (Start / Stop / Log)

**Files:**
- Create: `src/mods.cgi`
- Modify: `src/lang/de`, `src/lang/en`

**Behaviour:**
- Bootstrap like `manage.cgi` (web-lib, ui-lib, same lib requires needed for instance/jobs/mc_*).
- ACL: `user_can_manage($instance_id)`; readonly blocks mutations.
- Gate: `mc_mod_ui_ready` — else show message + link back to manage setup.
- Header: instance name, online/offline (reuse manage status helpers if extractable; else minimal `get_instance` + status string).
- Buttons:
  - Start / Stop → same job launch as manage (`game_action` / steamcmd / mc paths). Prefer **extract** shared `_manage_launch_game_action` usage by calling thin wrappers copied carefully, or redirect POST to manage with `return_to=mods` — **preferred:** dispatch jobs from `mods.cgi` mirroring manage’s `start`/`stop` branch, redirect to `job_live.cgi?…&return=mods.cgi%3Finstance_id%3D…`.
  - Log → `mods.cgi?action=monitor` (copy manage monitor tail UI) with link back to mods main view; do not pull schedule/monitor cron UI.

- [x] **Step 1: Create `mods.cgi` with header + Start/Stop/Log + back to manage**
- [x] **Step 2: Wire start/stop/monitor actions; `&redirect` + `exit`**
- [x] **Step 3: Lang keys** e.g. `mc_mods_page_title`, `mc_mods_page_back_manage`, `mc_mods_page_log`

Manual smoke: open `mods.cgi?instance_id=…` in Webmin after deploy (agent: `perl -c src/mods.cgi`).

```bash
perl -c src/mods.cgi
```

---

### Task 6: Installed list UI + enable / disable / delete

**Files:**
- Modify: `src/mods.cgi`
- Modify: `src/lang/de`, `src/lang/en`

**UI:**
- Query params: `q`, `status`, `sort`, `dir`, `page` (GET form).
- Table columns: title/name, filename, source, status (An/Aus), actions.
- Actions: Enable or Disable (POST), Delete (POST + confirm page or `ui_confirmation`), Update link (Task 7).
- After enable/disable/delete: `module_config_flash_mark('mod_enabled'|'mod_disabled'|'mod_deleted')` then redirect with query flag; GET shows `ui_success` only if `module_config_flash_consume(...)`.
- Show small hint: restart server for loader to pick up toggles (`mc_mods_page_restart_hint`).

- [x] **Step 1: Render list using Task 3 helpers**
- [x] **Step 2: POST handlers `mod_enable`, `mod_disable`, `mod_delete` with sanitize + verify + flash**
- [x] **Step 3: Lang keys for columns, buttons, errors, flash OK**

---

### Task 7: Update flow with version picker

**Files:**
- Modify: `src/mods.cgi`, `src/lib/mc_mods.pl` (if needed), reuse `_manage_launch_mod_install` logic

**Flow:**
1. `mods.cgi?action=mod_versions&basename=…` lists compatible versions (Task 4).
2. User picks → POST `mc_mod_install` with explicit `version_id` / `file_id` (already supported in `prepare_mod_install_meta`).
3. Preserve disabled state: if updating a disabled mod, after job success worker or post-step should leave `.disabled` — **v1 approach:** pass `prefer_disabled => 1` in job meta; extend `mc_mod_install_user.sh` to rename to `.disabled` after download if flag set. If too heavy, document “re-disable manually” as interim and implement flag in same task if straightforward.

- [x] **Step 1: Versions page UI**
- [x] **Step 2: Launch install job with fixed ids; return to job_live then mods**
- [x] **Step 3: Prefer `prefer_disabled` in worker when flag set** (test with fixture path if possible)

---

### Task 8: Move mod search/install (+ optional version) to `mods.cgi`

**Files:**
- Modify: `src/mods.cgi`, `src/manage.cgi`
- Modify: `src/lang/de`, `src/lang/en`

**Behaviour:**
- Port `_manage_render_mod_browser` + `mc_mod_install` action to `mods.cgi` (shared helpers may live as `sub` in a new `src/lib/mc_mods_cgi.pl` **or** duplicated briefly then deleted from manage — prefer extract to `src/lib/mc_mods_ui.pl` if both pages need launch helpers for jobs).
- Search results: Install button = auto version (current behaviour).
- Optional: per-row link „Version wählen“ → same versions UI as Task 7 without requiring installed basename (project ids from search hit).

- [x] **Step 1: Extract or copy launch + render into mods page**
- [x] **Step 2: Optional version pick on new install**
- [x] **Step 3: Remove mod browser block from manage**

---

### Task 9: Move modpack section to `mods.cgi`

**Files:**
- Modify: `src/mods.cgi`, `src/manage.cgi`

**Behaviour:**
- Port `_manage_render_modpack_section`, remote/path/resume launch helpers (or require a shared lib of those subs).
- Keep validation warnings in job log (already implemented).
- Remove modpack UI from manage; keep any pending-modpack launch after deps if it currently lives in manage — redirect that launch’s poll return to `mods.cgi` when appropriate.

- [x] **Step 1: Modpack UI + actions work on mods.cgi**
- [x] **Step 2: Remove from manage; add CTA link**

Manage replacement snippet:

```perl
print "<p><a href=\"mods.cgi?instance_id=$safe_id&amp;xnavigation=1\">"
    . &html_escape($text{'mc_mods_page_manage_link'} || 'Mods verwalten')
    . "</a></p>\n";
```

Only show when `mc_mod_ui_ready`.

---

### Task 10: Docs, rules, verify

**Files:**
- Modify: `.cursor/rules/minecraft-mods.mdc`
- Modify: `AGENTS.md` function map row if it lists manage-only mods UI
- Run: `bash scripts/verify.sh`

- [x] **Step 1: Update rule — Mod UI lives on `mods.cgi`; manage only links**
- [x] **Step 2: Spec status → accepted / implementing**
- [x] **Step 3: Full verify**

```bash
bash scripts/verify.sh
```

Expected: all tests ok, including `t/test_mc_mods.pl`.

---

## Suggested implementation order

1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10

Ship-able checkpoints: after Task 6 (list+toggle usable); after Task 9 (full parity + extras).

---

## Self-review (plan vs spec)

| Spec requirement | Task |
|------------------|------|
| Own `mods.cgi` | 5 |
| Start/Stop/Log toolbar | 5 |
| Manage link only | 8–9 |
| List + filter/sort/pagination | 1, 3, 6 |
| Enable/disable `.disabled` | 2, 6 |
| Delete | 2, 6 |
| Update + version pick | 4, 7 |
| Install optional version | 4, 8 |
| Modpack on mods page | 9 |
| Verified success / flash | 6 |
| Game-user writes | 2 |
| Tests + verify | 1–4, 10 |
| No bulk / no auto-restart | honored (hint only) |

No TBD placeholders. Update job reuses `mc_mod_install` unless `prefer_disabled` needs a distinct action label (optional `jobs_action_mc_mod_install` remains fine).
