# Player Query Status Display — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show live player counts on the manage instance status line via modular RCON/REST admin query driven by `games_meta.player_query`.

**Architecture:** Meta describes keys, command, and parse type; `player_query.pl` reads game config, checks readiness, queries `127.0.0.1` with a short cache, and renders one generic status cell. Manage only calls the lib + a 60s visibility-aware poll endpoint.

**Tech Stack:** Perl 5 (Webmin CGI), Source RCON (TCP), HTTP Basic REST (Palworld), `games_meta.json`, `t/` TAP tests, `bash scripts/verify.sh`.

**Spec:** `docs/superpowers/specs/2026-10-04-player-query-status-design.md` (approved 2026-10-04).

## Global Constraints

- Modular: **no per-game tooltip/HTML** in manage; parsers selected by meta `parse`
- Host always `127.0.0.1`; never open RCON/REST via firewall for this feature
- Empty password / disabled enable → `RCON fehlt` (generic lang tip), never fake `0` players
- Query only when runtime is reliably **online** (not `starting` / offline)
- Poll **60 s**, pause when `document.hidden`, server cache TTL **60 s**
- Display `N/M` when `max_players_key` yields >0, else `N`
- v1 games only: MC (+ variants via `_resolve_meta_key`), PZ, Palworld; Windrose out
- Windrose meta: English `player_query_note` only (no `player_query` block)
- A2S manage table row removed when `player_query` present
- UI strings: `src/lang/de` + `src/lang/en` (+ UTF-8 copies if present); code English; `ui_*` only
- `bash scripts/verify.sh` green before claiming done
- **No commits** unless user asks
- **Version bump** only when user asks
- Docs/README meta onboarding = **follow-up after** this plan (not a task here)

## File map

| File | Role |
|------|------|
| `src/lib/player_query.pl` | Meta, readiness, RCON/REST, parsers, cache, status HTML |
| `src/lib/games_meta.pl` | `get_game_player_query($script)` accessor |
| `src/lib/games_meta.json` | `player_query` for MC/PZ/Palworld; Windrose `player_query_note` |
| `src/manage.cgi` | Status cell, `poll_players`, JS poll, drop A2S row when meta set |
| `src/lang/de`, `src/lang/en` (+ `.UTF-8` if used) | Generic player/RCON strings |
| `t/test_player_query.pl` | Readiness, parsers, cache, HTML, meta |
| `scripts/verify.sh` | Register new test |
| `CHANGELOG.md` | Unreleased note |

---

### Task 1: Meta accessor + schema smoke

**Files:**
- Modify: `src/lib/games_meta.pl`
- Create: `t/test_player_query.pl`
- Modify: `scripts/verify.sh` (add `t/test_player_query.pl`)

**Interfaces:**
- Produces: `get_game_player_query($script_name)` → hashref copy of `player_query` or undef
- Optional test helper: `games_meta_clear_cache()`
- Consumes: `_resolve_meta_key`, `load_games_meta`

- [ ] **Step 1:** Write failing test using temp `games_meta_local.json` under `$config_directory`, clear cache, assert `get_game_player_query('demoserver')->{kind}` and missing script → false
- [ ] **Step 2:** Implement accessor (shallow copy; return undef unless HASH with keys)
- [ ] **Step 3:** `perl t/test_player_query.pl` green; wire into `verify.sh`
- [ ] **Step 4:** No commit unless user asks

```perl
sub get_game_player_query {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key  = _resolve_meta_key($script_name);
    my $entry = $meta{$key} or return;
    my $pq = $entry->{'player_query'};
    return unless ref($pq) eq 'HASH' && keys %$pq;
    return { %$pq };
}
```

---

### Task 2: Config read + readiness (TDD)

**Files:**
- Create: `src/lib/player_query.pl`
- Modify: `t/test_player_query.pl`

**Interfaces:**
- `player_query_meta($script)` — wrapper; optional `$PLAYER_QUERY_META_OVERRIDE` for tests
- `player_query_config_values($server_dir, $script, %opts)` → `{ enabled, port, password, max_players, err }`
- `player_query_readiness($server_dir, $script, %opts)` → `{ ok => 0|1, reason => '…' }`
- `%opts`: `unix_user` (PZ home paths), optional `script_basename`
- Reasons: `no_meta` | `missing_enabled` | `missing_password` | `missing_port` | `config_unreadable`
- Enable truthy: `1/true/yes/on` (ci); falsy: empty/`0/false/no/off`
- If meta omits `enabled_key` (PZ): enabled implied when password+port ok

- [ ] **Step 1:** Failing tests for disabled / empty password / port 0 / ok (temp props/ini)
- [ ] **Step 2:** Resolve config via `get_game_config_path` + `resolve_game_server_config_path` (+ home base); MC fallback path `serverfiles/server.properties` if hint empty
- [ ] **Step 3:** Tests green
- [ ] **Step 4:** No commit unless user asks

---

### Task 3: Parsers (TDD, no network)

**Files:**
- Modify: `src/lib/player_query.pl`, `t/test_player_query.pl`

**Interfaces:**
- `player_query_parse($parse, $raw, $meta)` → `{ ok, players, max }` or `{ ok=>0, err }`

- [ ] **Step 1:** Tests for `mc_list`, `lines_skip_header` (0 and N), `json_field` (`currentplayernum`)
- [ ] **Step 2:** Implement parsers
- [ ] **Step 3:** Tests green

`mc_list` example match: `There are 3 of a max of 20 players online`  
`lines_skip_header`: skip first non-empty line, count remaining non-empty lines  
`json_field`: decode JSON; read `players_field` / optional `max_field` from meta

---

### Task 4: Transports + count + cache (TDD with inject hooks)

**Files:**
- Modify: `src/lib/player_query.pl`, `t/test_player_query.pl`

**Interfaces:**
- `player_query_count($server_dir, $script, %opts)` → `{ ok, players, max, err, state }`
- States: `waiting` | `rcon_missing` | `ok` | `unreachable` | `none`
- Cache: `$server_dir/.monitor/player_query.json`, TTL 60s, mode 0600
- Hooks: `$PLAYER_QUERY_RCON_FETCH`, `$PLAYER_QUERY_REST_FETCH`
- Host: `127.0.0.1` only; timeout ~2s
- `runtime_online => 0` → `waiting`, no network
- Fail ≠ players 0 success
- Max: prefer config `max_players` if >0, else parse max

**RCON:** minimal Source RCON (AUTH + EXEC) via `IO::Socket::INET`  
**REST:** GET `http://127.0.0.1:$port$command`, Basic auth (`auth_user` default `admin`)

- [ ] **Step 1:** Cache test — two counts, inject fetch called once; TTL expiry → second fetch
- [ ] **Step 2:** Implement transports + cache
- [ ] **Step 3:** Tests green

---

### Task 5: Meta v1 (MC / PZ / Palworld) + Windrose note

**Files:**
- Modify: `src/lib/games_meta.json`
- Modify: `t/test_player_query.pl`

**Minecraft (`mcserver`, variants resolve here):**

```json
"game_config_path": "serverfiles/server.properties",
"player_query": {
  "kind": "rcon",
  "source": "game_config",
  "enabled_key": "enable-rcon",
  "port_key": "rcon.port",
  "password_key": "rcon.password",
  "max_players_key": "max-players",
  "command": "list",
  "parse": "mc_list"
}
```

Add `enable-rcon`, `rcon.port`, `rcon.password` to `game_config_fields` if missing.

**PZ:**

```json
"player_query": {
  "kind": "rcon",
  "source": "game_config",
  "port_key": "RCONPort",
  "password_key": "RCONPassword",
  "max_players_key": "MaxPlayers",
  "command": "players",
  "parse": "lines_skip_header"
}
```

Add `RCONPort`, `RCONPassword` to `game_config_fields`.

**Palworld:**

```json
"player_query": {
  "kind": "rest",
  "source": "game_config",
  "enabled_key": "RESTAPIEnabled",
  "port_key": "RESTAPIPort",
  "password_key": "AdminPassword",
  "max_players_key": "ServerPlayerMaxNum",
  "command": "/v1/api/metrics",
  "parse": "json_field",
  "players_field": "currentplayernum",
  "max_field": "maxplayernum",
  "auth_user": "admin"
}
```

Add `RESTAPIEnabled`, `RESTAPIPort` to `game_config_fields`.

**Windrose (note only — English):**

```json
"player_query_note": "As of 2026-10-04 WebCore player_query: Windrose has no vanilla admin query (no RCON/REST). Needs a supported mod (e.g. Windrose+ query or WindroseRCON) before adding a player_query block."
```

Code must ignore `player_query_note` (only `player_query` enables the UI).

- [ ] **Step 1:** Edit JSON; validate decode
- [ ] **Step 2:** Tests: `mc-paper` resolves meta; `windrose` has note and no `player_query`
- [ ] **Step 3:** No commit unless user asks

---

### Task 6: Status HTML helper + lang keys

**Files:**
- Modify: `src/lib/player_query.pl`
- Modify: `src/lang/de`, `src/lang/en` (+ UTF-8 variants if present)
- Modify: `t/test_player_query.pl`

**Interfaces:**
- `player_query_status_html($server_dir, $script, %opts)` → value HTML or `''` if no meta
- `%opts`: `unix_user`, `runtime_status`

| Condition | Value |
|-----------|--------|
| no meta | `''` |
| not online | `—` + waiting tip |
| readiness fail | `RCON fehlt` + missing tip |
| count ok | `3/32` or `3` |
| unreachable | `?` + unreachable tip |

Lang keys: `manage_players_label`, `manage_players_rcon_missing`, `manage_players_rcon_missing_tip`, `manage_players_waiting`, `manage_players_waiting_tip`, `manage_players_unreachable`, `manage_players_unreachable_tip` (de+en). Escape all dynamic HTML.

- [ ] **Step 1–3:** Tests, implement, green

---

### Task 7: Manage status cell + `poll_players` + visibility JS

**Files:**
- Modify: `src/manage.cgi` (require lib, `_manage_render_status_badges`, allowlists, `poll_players`)
- Optional: `player_query_poll_js($url)` next to status line

- [ ] **Step 1:** If meta present, append status part labeled `manage_players_label` with `<span class="js-player-query">…</span>` wrapping `player_query_status_html(...)`
- [ ] **Step 2:** `poll_players` JSON like `poll_runtime`: `{ html, runtime_status }` — never password. Add to GET allowlists beside `poll_runtime`
- [ ] **Step 3:** JS: interval 60s; skip when `document.hidden`; on visible again refresh; update `.js-player-query` using the **same trusted-HTML update pattern as** `setRuntimeHtml` / `.js-runtime-status` in `src/lib/live_log.pl` (server-escaped fragment only)
- [ ] **Step 4:** No commit unless user asks

---

### Task 8: Remove A2S player row when `player_query` set

**Files:**
- Modify: `src/manage.cgi` (~3393–3403)

```perl
my $has_pq = defined &player_query_meta && player_query_meta($script_name);
if ($qfield && !$has_pq) {
    # existing a2s_query UI row unchanged for CS/Rust/etc.
}
```

- [ ] **Step 1:** Patch + fix any test that assumed A2S row for PZ/Palworld
- [ ] **Step 2:** Tests green

---

### Task 9: CHANGELOG + verify + spec status

- [ ] **Step 1:** `CHANGELOG.md` Unreleased bullet
- [ ] **Step 2:** Spec status → implemented when green
- [ ] **Step 3:** `bash scripts/verify.sh` must pass
- [ ] **Step 4:** Offer commit (do not commit unless asked)

---

## Spec coverage

| Spec item | Task |
|-----------|------|
| Meta + command/parse | 1, 3, 5 |
| Readiness / RCON fehlt | 2, 6 |
| RCON + REST | 4 |
| Parsers | 3 |
| N/M from config | 4, 6 |
| Wait until online | 4, 6–7 |
| 60s poll + visibility | 7 |
| Cache / multi-viewer | 4 |
| Localhost | 4 |
| Generic tooltip | 6 |
| A2S removal | 8 |
| MC/PZ/Palworld | 5 |
| Windrose note | 5 |
| Docs meta onboarding / auto-update / real Windrose query | Follow-up |

## Follow-up (not this plan)

- Docs/README: lighter “add a game to games_meta” onboarding
- Auto-update: use `player_query_count` for PZ
- Windrose `player_query` when mod exists
