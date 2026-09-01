# MC Version & Modloader Upgrade — Implementation Plan

> **Status:** Implementiert (0.2.2) — Phases 1–3 shipped  
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Auf `manage.cgi` gezielt **Loader-Version** und später **MC-Version** upgraden — als Job mit Live-Log, ohne destruktives `reinstall` (Mods/Welt bleiben).

**Architecture:** Neue Lib `mc_upgrade.pl` baut Upgrade-Plan + Preflight (offline, no concurrent job, profile valid). Worker `mc_upgrade_user.sh` ruft bestehende Sub-Worker mit `WEBCORE_SUBSTEP=1` auf: optional Java → `mc_loader_install_user.sh` → Profil-Pin → Verify read-back. Phase 1 = **Loader-only**; Phase 2 = MC version bump.

**Tech Stack:** Perl, bash workers, `mc_loader.pl`, `mc_profile.pl`, `game_action_user.sh` stop, `job_live.cgi`.

## Global Constraints

- UI DE/EN; code English.
- Success = job `status=ok` + profile read-back (`loader_version` / `mc_version`).
- Server must be verified **offline** before upgrade job starts.
- No loader **family** change in v1 (NeoForge→Forge blocked).
- Game-user workers only; no root writes to `$SERVER_DIR`.
- `bash scripts/verify.sh` at end.

---

## File map

| File | Role |
|------|------|
| `src/lib/mc_upgrade.pl` | **new** — preflight, plan, target validation |
| `src/scripts/mc_upgrade_user.sh` | **new** — orchestration |
| `src/manage.cgi` | UI block + actions `mc_upgrade_loader`, `mc_upgrade_mc` |
| `src/lib/mc_loader.pl` | reuse `mc_fetch_loader_versions`, `mc_resolve_loader_install` |
| `src/lib/jobs.pl` | job action labels |
| `t/test_mc_upgrade.pl` | **new** |
| `src/lang/de`, `src/lang/en` | `mc_upgrade_*` |

---

## Phase 1 — Loader-only upgrade (ship first)

### Task 1: Preflight + plan (Perl)

**Files:**
- Create: `src/lib/mc_upgrade.pl`
- Create: `t/test_mc_upgrade.pl`

**Interfaces:**
- `mc_upgrade_preflight($inst, $profile, $server_dir, $target) → { ok => 0|1, err => '...' }`
  - Checks: profile exists; loader modded; `target_loader_version` pin valid via `mc_loader_version_valid_for_mc`; instance status not running (use existing online check); no job running for instance.
- `mc_upgrade_loader_plan($profile, $target_loader_version) → { needs_java => 0|1, loader => ..., mc_version => ..., target_pin => ... }`

- [x] **Step 1: Failing tests** — reject when target pin not in filtered NeoForge list; accept valid bump.

```perl
is(mc_upgrade_preflight_offline_required(), 1, 'offline required');
```

- [x] **Step 2: Implement preflight** (no network in tests — mock loader list via injectable array ref or test-only helper `mc_upgrade_set_loader_versions_for_test`).

- [x] **Step 3: `perl t/test_mc_upgrade.pl` — PASS**

- [x] **Step 4: Commit**

---

### Task 2: Worker `mc_upgrade_user.sh`

**Files:**
- Create: `src/scripts/mc_upgrade_user.sh`
- Modify: `src/scripts/mc_loader_install_user.sh` — ensure re-run with new `loader_version` in profile **before** call overwrites cleanly (document: worker reads profile pin).

**Flow:**
1. Read `$JOB_DIR/upgrade_plan.json` (written by CGI): `{ mode: "loader", target_loader_version: "26.1.2.95" }`
2. Update `$SERVER_DIR/.mcprofile.json` → set `loader_version` (via `mc_profile_merge.pl` or inline Perl one-liner as game user)
3. `WEBCORE_SUBSTEP=1 mc_loader_install_user.sh ...`
4. Verify: read profile back + check NeoForge jar / `run.sh` / logs for version string
5. Write `status=ok` or `failed` with `ERROR:` line

- [x] **Step 1: Plan JSON write helper in `mc_upgrade.pl`**: `write_upgrade_job_plan($job_dir, $plan)`

- [x] **Step 2: Implement worker**

- [x] **Step 3: `bash -n` + dry-run test with fake job dir**

- [x] **Step 4: Commit**

---

### Task 3: manage.cgi UI — Loader upgrade

**Files:**
- Modify: `src/manage.cgi` (~MC profile section, near Java/Loader setup buttons)
- Modify: `src/lib/jobs.pl` — label `mc_upgrade_loader`
- Modify: `src/lang/de`, `src/lang/en`

**UX:**
- Show current: `mc_version`, `loader`, `loader_version`
- Dropdown: loader versions from `mc_fetch_loader_versions($loader, $mc_version)` — only versions **newer** than current (string compare via existing NeoForge filter helpers)
- Button „Loader updaten“ (`ui_submit`, **not** `btn-danger`)
- Warning banner: Server stoppen; Backup empfohlen; Mods können brechen
- Preflight: if online → error `mc_upgrade_server_must_be_stopped`

**Action handler:**

```perl
elsif ($action eq 'mc_upgrade_loader') {
    &_manage_redirect_if_job_running($instance_id, 'mc_upgrade_loader');
    # verify offline, build plan, write upgrade_plan.json, dispatch mc_upgrade_user.sh
    &_manage_redirect_poll_job($job_id, $instance_id);
}
```

- [x] **Step 1: UI + lang keys**

- [x] **Step 2: Action handler + job dispatch**

- [x] **Step 3: Manual test on Pepega (NeoForge 26.1.2.x → newer build)**

- [x] **Step 4: Commit**

---

### Task 4: Verify Phase 1

```bash
perl t/test_mc_upgrade.pl
bash scripts/verify.sh
```

---

## Phase 2 — MC version bump (after Phase 1 stable)

### Task 5: MC version target picker

**Files:**
- Modify: `src/lib/mc_profile.pl` — use `mc_list_mc_versions` (existing or from `mc-versions-modular` plan if merged)
- Modify: `src/lib/mc_upgrade.pl` — `mc_upgrade_mc_plan($profile, $target_mc_version)`

**Rules:**
- Same loader family only
- If Java major changes → plan includes `mc_java_install_user.sh` sub-step first
- Then update `mc_version` in profile + `mc_loader_install_user.sh` (new loader build for new MC)
- **Do not** wipe `serverfiles/mods/`

- [x] UI: second dropdown + action `mc_upgrade_mc`
- [x] Tests for Java-major change detection
- [x] Commit

---

## Phase 3 — Mod compat warning (optional, after mod-deps plan)

Read-only before MC upgrade:
- Scan `.mc_mods_index.json` project_ids
- Modrinth: count compatible versions for `target_mc_version`
- UI: „X Mods haben keine Version für MC Y“ — no auto-update

Depends on: `2026-09-01-mc-mod-dependencies-implementation.md` index quality.

---

## Explicit non-goals

- Auto-update all mod JARs
- Switch Forge ↔ NeoForge
- Replace `reinstall` (stays destructive escape hatch)

---

## Open decisions (resolve at Task 3)

| Question | Default for v1 |
|----------|----------------|
| LGSM `update` after loader change? | **No** — only our loader installer + verify |
| Paper loader upgrade? | Defer; NeoForge/Fabric/Forge first |
| Auto-stop server before upgrade? | **No** — user must stop; preflight errors if online |

---

## Execution order vs Mod Dependencies plan

1. **Mod dependencies** (crash prevention on install)
2. **Loader upgrade Phase 1** (Pepega operational need)
3. **MC version Phase 2**
4. **Compat warning Phase 3**
