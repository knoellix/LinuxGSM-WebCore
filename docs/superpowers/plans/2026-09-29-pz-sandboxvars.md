# PZ SandboxVars Editor — Implementation Plan

> **For agentic workers:** Implement task-by-task. Steps use checkbox syntax.

**Goal:** Edit `$HOME/Zomboid/Server/<name>_SandboxVars.lua` in manage.cgi like Server-INI (all keys as form + raw mode).

**Architecture:** Flatten nested Lua `SandboxVars` to dotted keys for the form; parse/update/serialize in `config_editor.pl`; fourth config view `sandbox` when meta path resolves.

**Tech Stack:** Perl (Webmin CGI), existing manage config panels, games_meta.

## Global Constraints

- Writes as game user only; path under unix home `Zomboid/Server/*_SandboxVars.lua`
- Verified success (flash + file exists)
- UI strings de+en
- `bash scripts/verify.sh` green

---

### Task 1: Lua SandboxVars parse/update helpers + tests

**Files:** `src/lib/config_editor.pl`, `t/test_config_editor.pl`

- [x] Failing tests: flatten nested keys, update leaf, path reject
- [x] Implement `parse_sandboxvars_lua`, `update_sandboxvars_lua` (flat dotted keys)
- [x] Tests green

### Task 2: Meta + path validation for sandbox file

**Files:** `src/lib/games_meta.json`, `src/lib/games_meta.pl`, `src/lib/config_editor.pl`

- [x] `game_sandbox_path`, labels for pzserver
- [x] `get_game_sandbox_path`, allow `*_SandboxVars.lua` in `check_game_config_path`
- [x] Tests

### Task 3: manage.cgi sandbox tab + save

**Files:** `src/manage.cgi`, `src/lang/de`, `src/lang/en`

- [x] Fourth button/panel `sandbox`
- [x] `save_config` / `config_file=sandbox`
- [x] Stop-server hint lang keys
- [x] verify.sh
