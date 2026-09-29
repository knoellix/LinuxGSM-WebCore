# Start-Ready + Monitor-Pause + Control Bar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wait for a game ready marker before treating Start/Restart as fully successful, pause WebCore monitor auto-restart until then, add a shared Start/Stop/Restart/Log control bar (Mods + Workshop), optional embedded start-log toggle, and a Workshop PZ-Version column.

**Architecture:** Ready markers live in `games_meta.json` and are consumed by a generalized wait in `lgsm_control.sh` (MC Done stays; PZ gets `*** SERVER STARTED ****`). Monitor gains `status=starting` with a deadline so cron skips recovery during boot. A small `server_control_bar.pl` helper drives Mods/Workshop chrome. Module config `manage_show_start_log` embeds the existing poll_monitor panel on the page that launched Start/Restart.

**Tech Stack:** Perl Webmin CGI, `games_meta.json`, bash `lgsm_control.sh` / `monitor_instance_user.sh`, `module_config`, existing `poll_monitor` / `server_log.pl`, `t/test_*.pl`.

**Spec:** `docs/superpowers/specs/2026-09-29-start-ready-monitor-design.md`

## Global Constraints

- Ready-wait + monitor pause: **always on** when meta has a marker; start-log UI: **toggle**, default off
- Game-user runtime only for `$SERVER_DIR` / monitor state writes; no root writes to game data
- Success only after verified outcomes (job `status=ok`, flash + consume, read-back)
- UI strings in `src/lang/de` + `src/lang/en`
- `bash scripts/verify.sh` green before claiming done
- No version bump / tag unless user asks
- Control-bar helper must stay game-agnostic (no PZ/MC business logic inside)
- Empty PZ `require` displays **keine Angabe** (never “neueste”)

## File map

| File | Role |
|------|------|
| `src/lib/games_meta.json` | `start_ready_*` for `pzserver` (+ document MC) |
| `src/lib/games_meta.pl` | `get_start_ready_config($script)` |
| `src/scripts/lib/lgsm_control.sh` | Generalized ready-wait; PZ console marker |
| `src/lib/monitor.pl` | `starting` status + helpers |
| `src/scripts/monitor_instance_user.sh` | Skip recovery while `starting` |
| `src/manage.cgi` / `src/mods.cgi` | Set starting on Start/Restart; start-log embed |
| `src/lib/server_control_bar.pl` | Shared Start/Stop/Restart/Log bar |
| `src/workshop.cgi` | Control bar + PZ-Version column + start/stop/restart |
| `src/integrations.cgi` | `manage_show_start_log` toggle |
| `src/lang/de`, `src/lang/en` | New keys |
| `t/test_monitor_state.pl`, `t/test_pz_workshop.pl`, new `t/test_start_ready.pl`, `t/test_server_control_bar.pl` | Tests |
| `CHANGELOG.md` | Short note |

---

### Task 1: Ready-marker meta + Perl accessor

**Files:**
- Modify: `src/lib/games_meta.json` (`pzserver`; optional minecraft keys for documentation parity)
- Modify: `src/lib/games_meta.pl`
- Create: `t/test_start_ready.pl`

**Interfaces:**
- Produces: `get_start_ready_config($script_name)` → hashref  
  `{ log => 'console'|'latest_log'|'', regex => $re, secs => $int }`  
  Empty/missing meta → `{ log => '', regex => '', secs => 0 }`

- [ ] **Step 1: Write failing test** in `t/test_start_ready.pl`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../src/lib";

# Minimal bootstrap: set $module_root for load_games_meta
our $module_root = "$FindBin::Bin/../src";
require "$module_root/lib/games_meta.pl";

my $pz = get_start_ready_config('pzserver');
ok(length($pz->{regex}), 'pzserver has ready regex');
like($pz->{regex}, qr/SERVER STARTED/, 'pz marker mentions SERVER STARTED');
cmp_ok($pz->{secs}, '>=', 60, 'pz timeout sensible');
is($pz->{log}, 'console', 'pz uses console log');

my $none = get_start_ready_config('unknownserverxyz');
is($none->{regex}, '', 'unknown game → no regex');

done_testing();
```

- [ ] **Step 2: Run — expect FAIL**

```bash
perl t/test_start_ready.pl
```

Expected: FAIL (missing `get_start_ready_config` and/or meta fields).

- [ ] **Step 3: Implement meta + accessor**

In `games_meta.json` under `pzserver` add:

```json
"start_ready_log": "console",
"start_ready_regex": "\\*\\*\\* SERVER STARTED \\*\\*\\*\\*",
"start_ready_secs": 900
```

Optional under the Minecraft script key used by the module (same shape, `log: latest_log`, regex matching existing Done pattern) — only if that key already exists in the file; do not invent a second MC entry.

In `games_meta.pl`:

```perl
sub get_start_ready_config {
    my ($script) = @_;
    $script //= '';
    $script =~ s/[^a-zA-Z0-9_\-]//g;
    my %meta = load_games_meta();
    my $g = $meta{$script} // {};
    my $log = $g->{start_ready_log} // '';
    my $re  = $g->{start_ready_regex} // '';
    my $secs = int($g->{start_ready_secs} // 0);
    $secs = 0 if $secs < 0;
    $secs = 3600 if $secs > 3600;
    return { log => "$log", regex => "$re", secs => $secs };
}
```

- [ ] **Step 4: Run test — expect PASS**

```bash
perl t/test_start_ready.pl
```

- [ ] **Step 5: Commit**

```bash
git add src/lib/games_meta.json src/lib/games_meta.pl t/test_start_ready.pl
git commit -m "$(cat <<'EOF'
feat: add start_ready meta fields for PZ

EOF
)"
```

---

### Task 2: Shell ready-wait for PZ (generalize after session-up)

**Files:**
- Modify: `src/scripts/lib/lgsm_control.sh`
- Test: shell via `bash -n` + small fixture script under `t/` if practical; otherwise document manual check + `bash -n`

**Interfaces:**
- Consumes: meta regex/secs (hardcode PZ fallback matching meta if Perl dump unavailable)
- Produces: `lgsm_log_has_ready_after "$log" "$offset" "$regex"`; `lgsm_start_wait_ready_marker …`; PZ path in `lgsm_start_reliable` waits after session-up

- [ ] **Step 1: Add helpers** (after `lgsm_mc_log_has_done_after`):

```bash
# True if bytes after offset match ERE $3 (grep -E).
lgsm_log_has_ready_after() {
    local log="$1" offset="${2:-0}" regex="${3:-}"
    [[ -f "$log" && -n "$regex" ]] || return 1
    local size
    size=$(wc -c <"$log" 2>/dev/null | tr -d ' ') || return 1
    [[ "$size" -gt "$offset" ]] || return 1
    tail -c +"$((offset + 1))" "$log" 2>/dev/null | grep -Eq -- "$regex"
}

# Resolve console log path (LGSM).
lgsm_console_log() {
    local server_dir="$1" script_name="$2"
    local f="$server_dir/log/console/${script_name}-console.log"
    [[ -f "$f" ]] || return 1
    printf '%s\n' "$f"
}

# After session is up: poll log until regex or timeout. Session die → fail.
# Timeout + session up → warn + return 0.
lgsm_start_wait_ready_marker() {
    local server_dir="$1" script_name="$2" log="$3" offset="${4:-0}"
    local regex="$5" ready_secs="${6:-900}"
    local elapsed=0 last_report=0
    script_name="${script_name//[^a-zA-Z0-9_-]/}"
    [[ -n "$regex" ]] || return 0
    echo "Waiting for ready marker (≤${ready_secs}s): $regex"
    while (( elapsed < ready_secs )); do
        if ! lgsm_is_started "$server_dir" "$script_name"; then
            echo "ERROR: session died before ready marker" >&2
            return 1
        fi
        if [[ -n "$log" ]] && lgsm_log_has_ready_after "$log" "$offset" "$regex"; then
            echo "Ready: marker seen after ${elapsed}s"
            return 0
        fi
        if [[ -z "$log" ]]; then
            log=$(lgsm_console_log "$server_dir" "$script_name" || true)
            offset=0
        fi
        if (( elapsed - last_report >= 30 )); then
            echo "Still starting… ${elapsed}s / ${ready_secs}s"
            last_report=$elapsed
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    if lgsm_is_started "$server_dir" "$script_name"; then
        echo "WARNING: no ready marker within ${ready_secs}s — session still up"
        return 0
    fi
    echo "ERROR: failed to become ready" >&2
    return 1
}
```

- [ ] **Step 2: Wire PZ in `lgsm_start_reliable`**

After session-up success for non-MC path, if `lgsm_is_project_zomboid_instance`:

1. Capture console log + byte offset (like MC).
2. Run LGSM start + session wait as today.
3. Call `lgsm_start_wait_ready_marker` with regex `\*\*\* SERVER STARTED \*\*\*\*` and secs `${WEBCORE_PZ_START_READY_SECS:-900}` (env override; default matches meta).

Keep MC path on `lgsm_start_minecraft` unchanged functionally (may optionally call the shared `lgsm_log_has_ready_after` later — not required in this task).

- [ ] **Step 3: Syntax check**

```bash
bash -n src/scripts/lib/lgsm_control.sh
```

Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add src/scripts/lib/lgsm_control.sh
git commit -m "$(cat <<'EOF'
feat: wait for PZ SERVER STARTED before start success

EOF
)"
```

---

### Task 3: Monitor `starting` state + cron skip

**Files:**
- Modify: `src/lib/monitor.pl`
- Modify: `src/scripts/monitor_instance_user.sh`
- Modify: `t/test_monitor_state.pl`
- Modify: `src/manage.cgi`, `src/mods.cgi` (Start/Restart → starting; Stop unchanged)

**Interfaces:**
- Produces:
  - `set_monitor_starting($server_dir, $config_dir, $id, $until_epoch)` → writes `status=starting`, `starting_until=$until_epoch`
  - `set_monitor_resume_after_start` — if currently `starting` and past deadline OR caller finishes start job → prefer new `set_monitor_ready_after_start` that clears starting → running (keep disabled guard)
  - `monitor_is_starting($state_href)` → 1 if status eq starting and now < starting_until
- Cron: if `starting` and now < `starting_until` → log + exit 0 (no LGSM monitor / no restart). If past deadline while still `starting` → treat as ready (set running) then continue normal path **or** clear starting and proceed once (prefer: clear to running with log “starting grace expired”).

- [ ] **Step 1: Failing tests** in `t/test_monitor_state.pl`:

```perl
# set_monitor_starting writes starting + starting_until
set_monitor_starting($server_dir, $tmp, 'instS', time() + 600);
my $s = read_monitor_state($server_dir, $tmp, 'instS');
is($s->{status}, 'starting', 'starting status');
cmp_ok(int($s->{starting_until} // 0), '>', time(), 'deadline future');

# monitor_is_starting true inside window
ok(monitor_is_starting($s), 'inside grace');

# past deadline → not starting
$s->{starting_until} = time() - 10;
ok(!monitor_is_starting($s), 'past grace');
```

- [ ] **Step 2: Run — expect FAIL**, then implement helpers + extend `_read_state_from_file` to parse `starting_until`.

- [ ] **Step 3: Cron gate** near top of `monitor_instance_user.sh` after reading STATUS:

```bash
if [[ "$STATUS" == "starting" ]]; then
    UNTIL=$(_read_state_key starting_until 0)
    NOW=$(date +%s)
    if [[ "$UNTIL" =~ ^[0-9]+$ ]] && (( NOW < UNTIL )); then
        _log "Skipping — still starting (until $UNTIL)"
        exit 0
    fi
    _log "Starting grace expired — resuming monitor"
    # rewrite status=running via existing state write helper if available,
    # else sed/inline write of status=running keeping other keys
fi
```

(Use the same state-write pattern already used in this script / `monitor_job.sh` — do not introduce root writes.)

- [ ] **Step 4: CGI dispatch**

On Start and Restart in `manage.cgi` / `mods.cgi` (where `set_monitor_resume_after_start` is called today):

```perl
my $ready = get_start_ready_config($script_name);
my $secs = ($ready->{secs} && $ready->{regex}) ? $ready->{secs} : 180;
&set_monitor_starting($server_dir, $config_directory, $instance_id, time() + $secs)
    unless (($mon = &read_monitor_state(...))->{status} // '') eq 'disabled';
```

Do **not** call `set_monitor_resume_after_start` immediately on Start/Restart when a ready marker exists; call `set_monitor_running` (or `set_monitor_ready_after_start`) from the start worker completion path **or** let cron expire grace. Prefer: worker end of successful start clears starting → running via a small Perl helper invoked from `game_action_user.sh` after `lgsm_start_reliable` returns 0 (game user can write `.monitor/state`).

Minimal worker hook in `game_action_user.sh` after successful start/restart:

```bash
if [[ -f "$MODULE_ROOT/scripts/monitor_mark_ready.pl" ]]; then
  perl "$MODULE_ROOT/scripts/monitor_mark_ready.pl" "$SERVER_DIR" || true
fi
```

`monitor_mark_ready.pl`: if state status is `starting` or `paused` (not disabled), set `running`.

- [ ] **Step 5: Run tests + verify slice**

```bash
perl t/test_monitor_state.pl
bash -n src/scripts/monitor_instance_user.sh
```

- [ ] **Step 6: Commit**

```bash
git add src/lib/monitor.pl src/scripts/monitor_instance_user.sh src/scripts/monitor_mark_ready.pl \
  src/manage.cgi src/mods.cgi t/test_monitor_state.pl
git commit -m "$(cat <<'EOF'
feat: pause monitor with starting status until ready

EOF
)"
```

---

### Task 4: Shared server control bar + Restart on Mods/Workshop

**Files:**
- Create: `src/lib/server_control_bar.pl`
- Create: `t/test_server_control_bar.pl`
- Modify: `src/mods.cgi` (use helper; add Restart; keep monitor enable/disable above or beside)
- Modify: `src/workshop.cgi` (render bar; handle `start|stop|restart|monitor|poll_monitor` like mods — reuse manage/mods dispatch patterns; stay on workshop after action)

**Interfaces:**
- Produces: `server_control_bar_html(%opts)` where opts include:
  - `cgi` (form action, e.g. `mods.cgi`)
  - `instance_id`
  - `readonly` (bool)
  - `runtime_status_html` (pre-rendered badge)
  - `extra_status_parts` (array of already-built `ui_instance_status_part` strings)
  - `actions` → list among `start stop restart log back` (default all)
  - `back_cgi` default `manage.cgi`
  - `lang` hash access via `%text`

Helper renders status line + inline forms (same pattern as current mods Start/Stop/Log). No monitor enable/disable inside helper (caller keeps that).

- [ ] **Step 1: Failing test** — helper returns HTML containing Start/Stop/Restart/Log when not readonly:

```perl
require './lib/server_control_bar.pl';  # or via FindBin + fake %text
my $html = server_control_bar_html(
    cgi => 'workshop.cgi',
    instance_id => 'pz1',
    readonly => 0,
    runtime_status_html => 'ONLINE',
);
like($html, qr/action.*start/s, 'start');
like($html, qr/action.*stop/s, 'stop');
like($html, qr/action.*restart/s, 'restart');
like($html, qr/action.*monitor/s, 'log');
```

(Adjust assertions to match actual hidden-field markup.)

- [ ] **Step 2: Implement `server_control_bar.pl`**, then refactor `mods.cgi` bar to call it (add Restart form posting `action=restart`).

- [ ] **Step 3: Workshop**

- Require control bar + jobs/monitor libs as needed.
- At top of page (after header): print control bar.
- POST handlers for `start|stop|restart` mirroring `mods.cgi` (monitor starting + job dispatch). Prefer shared thin wrapper later; copy+adapt once is OK if helper covers HTML only.
- GET `monitor` / `poll_monitor` like mods (console tail) so Log works on workshop.
- Readonly: no mutation buttons.

- [ ] **Step 4: Lang keys** (de+en): `server_control_start`, `server_control_stop`, `server_control_restart`, `server_control_log`, `server_control_back` (or reuse existing `mc_mods_page_*` / manage keys — prefer reuse where identical).

- [ ] **Step 5: Tests + verify**

```bash
perl t/test_server_control_bar.pl
perl -c src/lib/server_control_bar.pl
perl -c src/workshop.cgi
perl -c src/mods.cgi
```

- [ ] **Step 6: Commit**

```bash
git add src/lib/server_control_bar.pl src/mods.cgi src/workshop.cgi src/lang/de src/lang/en \
  t/test_server_control_bar.pl
git commit -m "$(cat <<'EOF'
feat: shared Start/Stop/Restart/Log control bar for mods and workshop

EOF
)"
```

---

### Task 5: Start-log toggle + embedded panel

**Files:**
- Modify: `src/integrations.cgi` (radio for `manage_show_start_log`)
- Modify: `src/lib/module_config.pl` only if defaults list needs the key (else missing → false is enough)
- Modify: `src/manage.cgi`, `src/mods.cgi`, `src/workshop.cgi` — after Start/Restart dispatch: if toggle on, redirect/stay with `start_log=1` flash; render embed using existing `poll_monitor` JS/pattern from manage/mods
- Modify: `src/lang/de`, `src/lang/en`

**Interfaces:**
- Config: `manage_show_start_log` bool, default 0
- Flash: `module_config_flash_mark("start_log_$instance_id")` after verified job launch; GET shows panel only if flash consumed OR `start_log=1` with fresh flash

Behaviour:

| Toggle | After Start/Restart |
|--------|---------------------|
| off | Current silent banner / redirect |
| on | Same page shows embedded console poll (~3s); title Start-Log; optional phase line later |

Do not force `job_live.cgi` for this path. Backend ready-wait still runs in the worker.

- [ ] **Step 1: Add lang keys** — `integrations_show_start_log`, `integrations_show_start_log_desc`, `start_log_panel_title`, `start_log_ready_banner`

- [ ] **Step 2: Integrations save/load** with `module_config_bool`, flash ok pattern (same as debug_logging).

- [ ] **Step 3: Embed panel** — extract or reuse manage’s poll_monitor fetch into a small include function e.g. `server_log_embed_html($instance_id, $poll_cgi)` in `live_log.pl` or `server_log.pl` if not already shareable; call from manage/mods/workshop when flash says show start log.

- [ ] **Step 4: Manual checklist** (document in commit body): toggle off → no panel; toggle on → Start on workshop opens panel; poll updates without full reload.

- [ ] **Step 5: Commit**

```bash
git add src/integrations.cgi src/manage.cgi src/mods.cgi src/workshop.cgi \
  src/lib/server_log.pl src/lang/de src/lang/en
git commit -m "$(cat <<'EOF'
feat: optional embedded start-log after Start/Restart

EOF
)"
```

---

### Task 6: Workshop PZ-Version column

**Files:**
- Modify: `src/workshop.cgi` (`_ws_render_mod_infos` strip PZ from mods cell; new column renderer)
- Modify: `src/lang/de`, `src/lang/en`
- Modify: `t/test_pz_workshop.pl` if any HTML helper is moved to `pz_workshop.pl`; otherwise CGI-level is enough — add `pz_workshop_pz_version_label($require, $server_ver)` in `pz_workshop.pl` for testability

**Interfaces:**
- Produces: `pz_workshop_pz_version_cell($pz_require, $server_ver)` → `{ label => 'keine Angabe'|'PZ 42.12', match => 'none'|'ok'|'bad' }`

Rules:

| require | server | label | match |
|---------|--------|-------|-------|
| empty | any | keine Angabe | none |
| set | matches | `PZ $req` | ok |
| set | mismatch / unknown server | `PZ $req` | bad / none |

UI: column header `workshop_col_pz_version`; badge text `workshop_pz_match_ok` / `workshop_pz_match_bad`.

Keep `v…` modversion in Mods column.

- [ ] **Step 1: Failing unit tests** for `pz_workshop_pz_version_cell`.

- [ ] **Step 2: Implement + wire column** in inventory table between Mods and Status (or after Mods).

- [ ] **Step 3: Run**

```bash
perl t/test_pz_workshop.pl
```

- [ ] **Step 4: Commit**

```bash
git add src/lib/pz_workshop.pl src/workshop.cgi src/lang/de src/lang/en t/test_pz_workshop.pl
git commit -m "$(cat <<'EOF'
feat: show PZ require column with match badges on workshop

EOF
)"
```

---

### Task 7: CHANGELOG + full verify + spec status

**Files:**
- Modify: `CHANGELOG.md`
- Spec already points at this plan; ensure Status remains approved

- [ ] **Step 1: CHANGELOG** under Unreleased / current version section (no version bump):

```markdown
- Start: wait for game ready marker (PZ `*** SERVER STARTED ****`); pause monitor until ready
- Mods/Workshop: shared Start/Stop/Restart/Log control bar; optional embedded start-log (Integrations)
- Workshop: PZ-Version column (keine Angabe / passt / unpassend)
```

- [ ] **Step 2: Full verify**

```bash
bash scripts/verify.sh
```

Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md docs/superpowers/specs/2026-09-29-start-ready-monitor-design.md
git commit -m "$(cat <<'EOF'
docs: changelog for start-ready monitor and workshop control bar

EOF
)"
```

---

## Spec coverage check

| Spec item | Task |
|-----------|------|
| PZ ready marker | 1–2 |
| MC Done (keep / unify where practical) | 2 (keep path); meta optional in 1 |
| Monitor pause until ready | 3 |
| Steady state LGSM monitor | 3 (resume after ready) |
| Start-log toggle default off | 5 |
| Embed on Manage / Workshop / Mods | 5 |
| Shared control bar | 4 |
| Restart on Mods + Workshop | 4 |
| Workshop reusable chrome | 4 (agnostic helper) |
| PZ-Version column + keine Angabe | 6 |
| Timeout warning session up | 2 |
| required mod via start-log only | 5 (no inventory parser) |
| No AnimSets filter | — out |
| No SteamCMD update button | — out |

## Out of scope (do not implement in this plan)

- Per-instance start-log toggle
- AnimSets noise filter
- Inventory parsing of `required mod "…" not found`
- Non-PZ workshop adapters (only keep helper generic)
