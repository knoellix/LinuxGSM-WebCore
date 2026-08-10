# Minecraft Phase 1 — Implementation Plan

> **Status:** Phase 1 implemented (2026-06-28)

**Goal:** Wizard MC profile, `.mcprofile.json`, Temurin per instance, Vanilla/Paper LGSM install chain.

**Architecture:** `mc_compat.json` + `mc_profile.pl` as SSOT; `mc_java_install.sh` worker; manage setup chain `fresh → lgsm_ready → mc_ready → installed`.

---

## Delivered (Phase 1)

- [x] `src/lib/mc_compat.json` — Loader/Java matrix
- [x] `src/lib/mc_profile.pl` — read/write/validate, LGSM cfg patch helpers
- [x] `src/scripts/mc_java_install.sh` — Temurin download, wrapper, serverversion
- [x] `wizard.cgi` step 35 — Loader + MC version
- [x] `manage.cgi` — mc_java_setup job, profile display, setup chain
- [x] `t/test_mc_compat.pl`, `t/test_mc_profile.pl`
- [x] Lang keys de/en

## Next (Phase 2)

- [ ] `mc_loader_install.sh` — Fabric/Forge/NeoForge
- [ ] manage: loader install after mc_java_setup for phase-2 loaders

## Next (Phase 3–4)

- Mod browser, modpack import/export, profile migration (see spec)
