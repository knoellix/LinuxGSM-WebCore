# Minecraft Mod-Management (Phase 3) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox syntax.

**Goal:** Modpack-Import und Mod-Browser in `manage.cgi` für MC-Instanzen mit `.mcprofile.json` — Import zuerst (ATM10/CurseForge/Modrinth), danach Einzelmod-Suche.

**Architecture:** Shared libs `mc_modpack.pl` (parse/validate/export) + `mc_mods.pl` (API clients, env filter, download whitelist). Background jobs via bestehendes Job-Pattern + `job_live.cgi`. Writes nur als Game-User in `$SERVER_DIR/serverfiles/{mods|plugins}/`.

**Tech Stack:** Perl (Webmin CGI), bash workers, Modrinth/CurseForge/Hangar APIs, JSON fixtures in `t/fixtures/`.

**Spec:** `docs/superpowers/specs/2026-06-28-minecraft-profile-mods-design.md`

---

## File map

| File | Role |
|------|------|
| `src/lib/mc_mods.pl` | env normalize, URL whitelist, Modrinth/CurseForge/Hangar HTTP |
| `src/lib/mc_modpack.pl` | detect/parse mrpack + CF manifest, profile validate, export builder |
| `src/scripts/mc_modpack_install.sh` | Download mods + overrides as game user |
| `src/scripts/mc_mod_install.sh` | Single mod download |
| `src/manage.cgi` | UI: Modpack upload, Mod browser, job dispatch |
| `src/mc_mods.cgi` | Optional: AJAX search endpoint (if manage too large) |
| `t/test_mc_modpack.pl` | Parse + validate fixtures |
| `t/test_mc_mods.pl` | env filter + URL whitelist |

---

## Milestone A — Foundation (Import-ready)

- [ ] **A1** `mc_mods.pl`: `normalize_mod_env`, `mod_env_allowed`, `mc_download_url_allowed`, `modrinth_user_agent`
- [ ] **A2** `mc_modpack.pl`: `detect_modpack_format`, `parse_modrinth_index`, `parse_curseforge_manifest`, `extract_pack_meta`, `validate_modpack_against_profile`
- [ ] **A3** Fixtures: `t/fixtures/modpack/minimal.mrpack`, `t/fixtures/modpack/cf_manifest.json`
- [ ] **A4** Tests `t/test_mc_modpack.pl`, `t/test_mc_mods.pl` + `verify.sh`
- [ ] **A5** `mc_modpack_install.sh`: read `$JOB_DIR/pack_meta.json`, download files, hash verify, overrides, write `.mc_mods_index.json`

## Milestone B — Modpack Import UI

- [ ] **B1** `manage.cgi`: section „Modpack importieren“ (multipart upload → `$JOB_DIR/upload/`)
- [ ] **B2** Pre-validate on upload → structured `error()` on mismatch
- [ ] **B3** Job `modpack_import` → `job_live.cgi` poll
- [ ] **B4** Lang keys DE/EN (`mc_modpack_*`)

## Milestone C — Mod Browser

- [ ] **C1** `mc_mods.pl`: Modrinth search + version resolve (loader + game_version filters)
- [ ] **C2** Paper: Hangar project search
- [ ] **C3** CurseForge search (requires API key from integrations)
- [ ] **C4** `manage.cgi`: search form + results table + install button
- [ ] **C5** `mc_mod_install.sh` + job `mc_mod_install`

## Milestone D — Export (later)

- [ ] `build_mrpack_from_instance`, `mc_modpack_export.sh`, UI (deferred after A–C stable)

---

## Job actions (registry)

| action | worker | next_status |
|--------|--------|-------------|
| `modpack_import` | `mc_modpack_install.sh` | — (keeps installed) |
| `mc_mod_install` | `mc_mod_install.sh` | — |

---

## Security checklist

- Download URLs only from whitelist (cdn.modrinth.com, api.curseforge.com, …)
- Upload max size limit, only `.mrpack` / `.zip`
- Pack path under `$JOB_DIR/upload/` only
- Target mod path: `$SERVER_DIR/serverfiles/$mod_dir/` validated

---

## Verification

```bash
perl t/test_mc_modpack.pl
perl t/test_mc_mods.pl
bash scripts/verify.sh
```
