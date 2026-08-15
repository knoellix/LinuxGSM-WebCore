# MC versions modular (live + local override) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop shipping a hardcoded Minecraft version allowlist; resolve MC versions and Java majors live from Mojang (with cache + offline fallback), support NeoForge’s new `26.x` versioning, and make compat overrides modular like `games_meta_local.json`.

**Architecture:** Keep `mc_compat.json` as the static **policy** layer (loaders, game→loader map, exclusions, optional curated fallbacks). Add live resolution in `mc_loader.pl` / `mc_profile.pl` for **MC release versions + Java** via Mojang’s version manifest (+ per-version JSON). Cache under `$module_config_directory`. Merge optional `mc_compat_local.json` for admin overrides. Fix NeoForge prefix heuristics for both `1.21.x → 21.x` and `26.1.2 → 26.1.2.*`.

**Tech Stack:** Perl (Webmin CGI), `JSON::PP`, Mojang launcher meta HTTPS, existing `_mc_fetch_url` / `_mc_fetch_json`, Test::More in `t/`.

## Global Constraints

- UI strings: German in `src/lang/de` + English in `src/lang/en`; code/comments English.
- Success feedback: verified only (see `no-blind-success-feedback.mdc`); network miss = fallback, never fake green.
- Game-user runtime: no new root writes to `$SERVER_DIR`; cache writes only under module config dir.
- End with `bash scripts/verify.sh`.
- Do not change AGPL / repo settings in this plan.

---

## File map

| File | Role |
|------|------|
| [`src/lib/mc_compat.json`](src/lib/mc_compat.json) | Static policy: loaders, maps, exclusions; `mc_versions` becomes **fallback only** |
| [`src/lib/mc_profile.pl`](src/lib/mc_profile.pl) | Load/merge local override; `mc_list_mc_versions` / `resolve_java_major` use live+cache+fallback |
| [`src/lib/mc_loader.pl`](src/lib/mc_loader.pl) | Mojang fetch helpers; NeoForge prefix for old+new schemes; filter/validate |
| [`src/wizard.cgi`](src/wizard.cgi) | Consume dynamic list; drop hard default `1.21.1` where possible |
| `$module_config_directory/mc_versions_cache.json` | Cached Mojang list + java majors (new) |
| `$module_config_directory/mc_compat_local.json` | Admin override merge (new, optional) |
| [`t/test_mc_compat.pl`](t/test_mc_compat.pl), [`t/test_mc_loader.pl`](t/test_mc_loader.pl), [`t/test_mc_profile.pl`](t/test_mc_profile.pl) | Unit coverage |
| [`.cursor/rules/minecraft-mods.mdc`](.cursor/rules/minecraft-mods.mdc) | Document static vs live split |

**Out of scope (follow-ups):** Paper build picker; rewriting Modrinth/CurseForge loader ID maps; changing download host defaults.

---

### Task 1: NeoForge prefix — old `1.x` and new `26.x`

**Files:** `src/lib/mc_loader.pl`, `t/test_mc_loader.pl`

- [ ] **Step 1: Failing tests for prefix + filter**

```perl
# Old scheme
is(mc_neoforge_version_prefix('1.21.1'), '21.1', '1.21.1 -> 21.1');
is(mc_neoforge_version_prefix('1.20.4'), '20.4', '1.20.4 -> 20.4');
# New Mojang scheme (year.drop[.hotfix]) — NeoForge uses first 3 components as MC id
is(mc_neoforge_version_prefix('26.1.2'), '26.1.2', '26.1.2 stays 26.1.2');
is(mc_neoforge_version_prefix('26.1'), '26.1.0', '26.1 pads to 26.1.0');
# Filter accepts 26.1.2.95 for MC 26.1.2
```

- [ ] **Step 2: Run test — expect FAIL on new-scheme cases**

```bash
perl t/test_mc_loader.pl
```

- [ ] **Step 3: Implement prefix rule**

Logic (document in comment):

- If MC matches `^1\.(\d+)\.(\d+)$` → NeoForge prefix `$1.$2` (legacy).
- If MC matches `^1\.(\d+)$` → prefix `$1.0`.
- Else if MC matches `^(\d+)\.(\d+)(?:\.(\d+))?$` with major `>= 25` (or simply major `!= 1`) → prefix is full MC id padded to 3 components (`26.1` → `26.1.0`).
- Update `mc_filter_neoforge_versions_for_mc` / `mc_pick_neoforge_version` / `mc_loader_version_matches_mc` to accept 4-part NeoForge (`26.1.2.95`) against 3-part MC prefix.

- [ ] **Step 4: Run tests — PASS**

```bash
perl t/test_mc_loader.pl
```

- [ ] **Step 5: Commit**

```bash
git add src/lib/mc_loader.pl t/test_mc_loader.pl
git commit -m "fix(mc): support NeoForge prefixes for Mojang 26.x versions"
```

---

### Task 2: Mojang live MC list + Java major (fetch + cache)

**Files:** `src/lib/mc_loader.pl` (or small `mc_versions.pl` if clearer), `src/lib/mc_profile.pl`, `t/test_mc_compat.pl`, `t/test_mc_profile.pl`

- [ ] **Step 1: Failing tests with mocked fetch**

Cover:

- Parse `version_manifest_v2.json` → release IDs only (exclude snapshots by default).
- `resolve_java_major('1.21.1')` from cache/fixture.
- Offline: empty fetch → fall back to `mc_compat.json` `mc_versions` / `versions`.
- Cache file read/write under a temp `$module_config_directory` / `$config_directory` stub.

- [ ] **Step 2: Run — FAIL**

```bash
perl t/test_mc_compat.pl
perl t/test_mc_profile.pl
```

- [ ] **Step 3: Implement**

APIs:

- `https://launchermeta.mojang.com/mc/game/version_manifest_v2.json`
- For Java: fetch version URL from manifest entry; read `javaVersion.majorVersion` (cache per id).

Functions (names illustrative):

- `mc_fetch_mojang_release_ids()` → list of release version strings
- `mc_fetch_java_major_for_mc($id)` → int or undef
- `mc_versions_cache_load()` / `mc_versions_cache_save($href)` → `$module_config_directory/mc_versions_cache.json`
- Cache TTL: e.g. 24h (`fetched_at`); stale still usable if network fails.

`mc_list_mc_versions()` order:

1. Live (or fresh cache) release IDs, newest first (manifest already ordered — keep release subset).
2. Else stale cache.
3. Else `mc_compat.json` `mc_versions`.

`resolve_java_major($mc)` order:

1. Live/cache entry for that id.
2. Else `mc_compat.json` `versions{$mc}.java_major`.
3. Else sensible default (21 for unknown modern; document).

`build_mc_profile`: allow any version present in **effective** list (live∪fallback), not only static JSON.

Timeouts: reuse existing `_mc_fetch_url` short timeout; never block wizard forever.

- [ ] **Step 4: Run tests — PASS**

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(mc): resolve Minecraft versions and Java from Mojang with cache fallback"
```

---

### Task 3: Modular local override (`mc_compat_local.json`)

**Files:** `src/lib/mc_profile.pl`, `t/test_mc_compat.pl`, docs/rules note

- [ ] **Step 1: Failing test — local override merges**

```perl
# base has loaders; local adds/overrides versions entry or pins extra fallback mc_versions
# mirrors games_meta_local merge semantics (deep or shallow — match games_meta.pl style)
```

- [ ] **Step 2: Implement `_load_mc_compat` merge**

Candidates (after bundled `mc_compat.json`):

- `$module_config_directory/mc_compat_local.json` (preferred)
- `$config_directory/linuxgsm-webcore/mc_compat_local.json` if that is how other locals resolve

Merge rules (lock in tests):

- `loaders`, `game_to_loader`, `java_mod_excluded`: local keys override/extend.
- `versions`: local per-id override.
- `mc_versions`: if local non-empty array, use as **offline fallback list** (does not replace live list).

- [ ] **Step 3: Tests PASS + commit**

```bash
git commit -m "feat(mc): merge mc_compat_local.json overrides like games_meta_local"
```

---

### Task 4: Wizard + worker consumers

**Files:** `src/wizard.cgi`, any manage/profile CGI using `mc_list_mc_versions` / hardcoded `1.21.1`

- [ ] **Step 1: Grep for hardcoded `1.21.1` / `mc_list_mc_versions`**

```bash
rg -n '1\.21\.1|mc_list_mc_versions|resolve_java_major' src/
```

- [ ] **Step 2: Wizard Step 3b**

- Populate dropdown from `mc_list_mc_versions()` (now live).
- If list empty (offline + empty fallback), show existing error path / lang key — do not invent success.
- Default selection: previously posted `mc_version` if still in list; else first list entry; else fallback from compat.
- Ensure NeoForge loader-version step still uses `mc_fetch_loader_versions` (already live) — verify `26.1.2` returns `26.1.2.*` builds after Task 1.

- [ ] **Step 3: Manual smoke (or stubbed integration test)**

Document expected: NeoForge + `26.1.2` appears; loader dropdown non-empty when network available.

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(wizard): use live Minecraft version list for profile step"
```

---

### Task 5: Docs, lang, verify

**Files:** `.cursor/rules/minecraft-mods.mdc`, optionally short note in `docs/superpowers/specs/…` or AGENTS function map, `src/lang/de` + `en` if new error strings

- [x] **Step 1: Document static vs live**

| Data | Source |
|------|--------|
| Loader definitions / LGSM script map | `mc_compat.json` (+ local) |
| MC release list | Mojang manifest (cache) → fallback `mc_versions` |
| Java major | Mojang version JSON (cache) → fallback `versions` |
| Forge/NeoForge/Fabric builds | Maven / Fabric meta (existing) |

- [x] **Step 2: Add lang keys only if new user-visible errors** (both de+en) — none needed; wizard empty list uses `mc_profile_invalid`

- [x] **Step 3: Full verify**

```bash
bash scripts/verify.sh
```

- [x] **Step 4: Commit**

```bash
git commit -m "docs(mc): document modular live MC versions vs static compat policy"
```

---

## Done when

- Wizard can select current Mojang **release** versions (including `26.x`) without editing `mc_compat.json`.
- NeoForge install resolution works for both `1.21.1` / `21.1.*` and `26.1.2` / `26.1.2.*`.
- Offline installs still work via cache or static fallback.
- Admins can pin/override policy via `mc_compat_local.json`.
- `bash scripts/verify.sh` green.
