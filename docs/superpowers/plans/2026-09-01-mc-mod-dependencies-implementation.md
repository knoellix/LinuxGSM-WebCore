# MC Mod-Abhängigkeiten — Implementation Plan

> **Status:** Implementiert (0.2.2, commit series Sep 2026)  
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Beim Einzelmod-Install (Modrinth/CurseForge) required Mod-zu-Mod-Dependencies erkennen, in der UI anzeigen und optional mitinstallieren — damit Fälle wie Farming for Blockheads ohne Balm nicht mehr passieren.

**Architecture:** Logik in `mc_mods.pl` (API-Deps parsen, gegen `.mc_mods_index.json` + Disk prüfen, fehlende Deps auflösen). `prepare_mod_install_meta` liefert Dep-Plan; Worker `mc_mod_install_user.sh` installiert Primary + Deps sequentiell. UI in `mods.cgi`: Dep-Tabelle vor Job-Start + Checkbox „Required mitinstallieren“. Kein endloses Transitive-Resolve (Cap 5).

**Tech Stack:** Perl (CGI/libs), bash worker, Modrinth v2 + CurseForge v1 APIs, JSON fixtures in `t/fixtures/mc_mods/`.

## Global Constraints

- UI strings: German `src/lang/de` + English `src/lang/en`; code/comments English.
- Success only after verified outcome (`no-blind-success-feedback.mdc`): Job `status=ok` + index read-back.
- Runtime workers = game user only; no root writes to `$SERVER_DIR`.
- Download URLs only via `mc_download_url_allowed()`.
- Server-side env filter: skip client-only deps (`mod_env_allowed(..., 'import_server')`).
- End with `bash scripts/verify.sh`.

---

## File map

| File | Role |
|------|------|
| `src/lib/mc_mods.pl` | Dep parse, resolve, plan builder, index match |
| `src/mods.cgi` | Dep preview UI, `install_deps` flag, multi-meta job |
| `src/scripts/mc_mod_install_user.sh` | Loop `mod_meta.json` + `dep_meta_*.json` |
| `t/fixtures/mc_mods/modrinth_version_with_dep.json` | Fixture |
| `t/fixtures/mc_mods/curseforge_file_with_dep.json` | Fixture |
| `t/test_mc_mod_deps.pl` | Unit tests (new) |
| `src/lang/de`, `src/lang/en` | `mc_mod_deps_*` keys |

---

### Task 1: Modrinth/CurseForge dependency extraction

**Files:**
- Create: `t/fixtures/mc_mods/modrinth_version_with_dep.json`
- Create: `t/test_mc_mod_deps.pl`
- Modify: `src/lib/mc_mods.pl`

**Interfaces:**
- Produces: `modrinth_version_dependencies($version_hash) → \@dep` where each dep is `{ project_id, version_id?, dependency_type => required|optional|embedded|incompatible, source => modrinth }`
- Produces: `curseforge_file_dependencies($file_hash) → \@dep` from `dependencies[]` (CF: modId, relationType)
- Produces: `normalize_mod_dependency_type($raw) → required|optional|...`

- [x] **Step 1: Add Modrinth fixture**

```json
{
  "id": "abc123",
  "project_id": "farming-for-blockheads",
  "dependencies": [
    { "project_id": "balm", "version_id": null, "dependency_type": "required" }
  ],
  "files": [{ "primary": true, "filename": "farming.jar", "url": "https://cdn.modrinth.com/data/x/versions/y/farming.jar", "hashes": { "sha1": "a"*40 } }]
}
```

- [x] **Step 2: Failing tests**

```perl
use Test::More;
require './src/lib/mc_mods.pl';
my $v = decode_json(read_file('t/fixtures/mc_mods/modrinth_version_with_dep.json'));
my @d = modrinth_version_dependencies($v);
is(scalar @d, 1, 'one dep');
is($d[0]{project_id}, 'balm', 'balm required');
is(normalize_mod_dependency_type('required'), 'required');
done_testing();
```

- [x] **Step 3: Implement extractors in `mc_mods.pl`**

Parse Modrinth `dependencies[]`; map `embedded`/`incompatible` to skip for install.

- [x] **Step 4: Run tests — PASS**

```bash
perl t/test_mc_mod_deps.pl
```

- [x] **Step 5: Commit**

```bash
git add t/fixtures/mc_mods t/test_mc_mod_deps.pl src/lib/mc_mods.pl
git commit -m "feat(mc): parse Modrinth/CurseForge mod dependencies"
```

---

### Task 2: Installed-mod detection + dep resolution plan

**Files:**
- Modify: `src/lib/mc_mods.pl`
- Modify: `t/test_mc_mod_deps.pl`

**Interfaces:**
- Consumes: `read_mc_mods_index($server_dir)`, `modrinth_resolve_version_file($pid, $profile)`
- Produces: `mod_dependency_status($server_dir, $profile, \@deps) → { missing => [...], satisfied => [...], optional => [...] }`
- Produces: `build_mod_install_plan($source, $ids, $profile, $server_dir, $opts) → (ok, { primary => \%meta, dependencies => [ \%meta, ... ] }, err)`

Rules:
- Match satisfied: index entry with same `project_id` (Modrinth slug / CF numeric id) **and** compatible version for profile.
- Resolve missing required: `modrinth_resolve_version_file` / `curseforge_resolve_mod_file` per dep project.
- Cap transitive depth: **1** (only direct deps of selected mod); log if more exist.
- Max auto-install deps: **5** required; beyond → error `deps_too_many`.

- [x] **Step 1: Tests** — index has balm → farming dep satisfied; empty index → missing balm.

- [x] **Step 2: Implement `mod_index_has_project` + plan builder**

- [x] **Step 3: Wire `prepare_mod_install_meta` to call plan builder** (backward compatible: no deps → same as today).

- [x] **Step 4: `perl t/test_mc_mod_deps.pl` + commit**

---

### Task 3: Worker — install primary + dependencies

**Files:**
- Modify: `src/scripts/mc_mod_install_user.sh`
- Modify: `src/lib/mc_mods.pl` — `write_mod_install_job_meta` → write `mod_install_plan.json`

**Plan JSON shape:**

```json
{
  "primary": { "filename": "...", "download_url": "...", ... },
  "dependencies": [ { "filename": "balm-....jar", ... } ],
  "install_order": ["dep0", "primary"]
}
```

- [x] **Step 1: Extend worker to read plan, install deps first, then primary**

Reuse existing download/hash/verify loop; update `.mc_mods_index.json` per file via existing index helpers.

- [x] **Step 2: Job log lines** `Installing dependency 1/2: Balm ...`

- [x] **Step 3: `bash -n src/scripts/mc_mod_install_user.sh`**

- [x] **Step 4: Commit**

---

### Task 4: UI — dependency preview on mods.cgi

**Files:**
- Modify: `src/mods.cgi`
- Modify: `src/lang/de`, `src/lang/en`

**UX:**
- On version pick / before install: show table Required / Optional / Satisfied (green) / Missing (warning).
- Checkbox default **on**: „Erforderliche Abhängigkeiten mitinstallieren“.
- If missing deps and checkbox off → block install with `mc_mod_deps_missing_blocked`.
- If CF key missing for CF dep → explicit error, not silent skip.

Lang keys (both files):
- `mc_mod_deps_title`, `mc_mod_deps_required`, `mc_mod_deps_optional`, `mc_mod_deps_satisfied`, `mc_mod_deps_missing`, `mc_mod_deps_install_with`, `mc_mod_deps_missing_blocked`

- [x] **Step 1: Helper `_mods_render_dependency_table($plan_status)`**

- [x] **Step 2: Pass `install_deps=1` from form into `prepare_mod_install_meta` opts**

- [x] **Step 3: Manual smoke on Pepega-like profile (Modrinth mod with Balm dep)**

- [x] **Step 4: Commit**

---

### Task 5: Regression + verify

- [x] Extend `t/test_mc_mods.pl` if needed for plan integration hook
- [x] `bash scripts/verify.sh`

---

## Out of scope (document only)

- Hangar plugin deps
- Transitive deps depth > 1
- Upgrade-flow compat warning (see `2026-09-01-mc-version-loader-upgrade-implementation.md` Phase 2)

## Recommended execution order vs Upgrade plan

**Do this plan first** — smaller scope, immediate crash prevention (Pepega/Balm lesson).
