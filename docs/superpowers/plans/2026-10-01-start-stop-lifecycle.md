# Start/Stop/Restart Lifecycle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One shared start/stop/restart lifecycle (ready marker, sliding log stall, phase keywords, stop save-grace, restart offline hard-gate) for LGSM + SteamCMD, driven by `games_meta.json`, used by manual jobs, monitor auto-restart, and scheduled restart.

**Architecture:** Extend game meta with stall/phase/stop fields. Generalize `lgsm_start_wait_ready_marker` into a sliding-stall + phase-aware wait; add matching stop grace + `lgsm_restart_reliable` hard-gate. SteamCMD (Windrose) gets a thin twin that reuses the same wait helpers against PID + log path. Callers (`game_action_user.sh`, `steamcmd_control_user.sh`, `monitor_instance_user.sh`, `scheduled_restart_user.sh`) only call the public lifecycle functions — no parallel kill/ready logic.

**Tech Stack:** `games_meta.json` + `games_meta.pl`, bash `lgsm_control.sh` / `steamcmd_control_user.sh`, Perl accessors, shell unit tests in `t/`, `bash scripts/verify.sh`.

**Spec:** `docs/superpowers/specs/2026-09-30-start-phase-stall-design.md` (approved; decisions locked 2026-10-01).

**Status:** implementation complete 2026-10-01 (subagent-driven; uncommitted until user asks).

## Global Constraints

- Stall **C**: warn after `start_stall_secs` (default **120**), fail after `start_stall_fail_secs` (default **300**); ready timeout default **900** (MC overridden by mod-count tiers)
- UI phase: **job log only** in v1 (badge stays blink Startet…, no phase subtitle)
- Stop: verified offline; while stop-phase `saving` matches, no force until `stop_force_secs` (grace **120** / force **180** defaults; Windrose 60/120)
- Restart: must be offline before start; stop failure aborts restart
- Callers in same wave: manual + monitor auto-restart + scheduled restart
- Windrose ready = `Start preloading GenlandiaMulty`; Palworld ready = `Running Palworld dedicated server on` (console log)
- MC: ready = `Done (…s)!` (all loaders); scale ready/stall by enabled `serverfiles/mods/*.jar` count (tier **replaces** meta for that start)
- Workshop (`mod_support: workshop`, v1 PZ): boot downloads new Workshop items before asset load — **normal**; scale ready/stall by INI `WorkshopItems` count (+ pending vs disk); **no stall-fail** while phase = `workshop_download`
- Game-user runtime only for `$SERVER_DIR` / monitor state; no root writes to game data
- Success only after verified outcomes (`status=ok`, read-back)
- UI strings: `src/lang/de` + `src/lang/en` if any new keys; code/comments English
- `bash scripts/verify.sh` green before claiming done
- No version bump / tag unless user asks
- **No commits** unless user asks

## Locked game data (from root-server logs)

| Game | Script | Log source | Ready regex (locked) | Sample note |
|---|---|---|---|---|
| Project Zomboid | `pzserver` | `console` | `\*\*\* SERVER STARTED \*\*\*\*` | existing |
| Minecraft | `mcserver` (+ variants) | `latest_log` | `Done \([0-9.]+s\)!` | NeoForge 2026-10-01: `Done (3.259s)! For help, type "help"` |
| Windrose | `windrose` | `live_log` → R5.log | `Start preloading GenlandiaMulty` | decision B; map-specific |
| Palworld | `pwserver` | `console` | `Running Palworld dedicated server on` | `pwserver-console.log` 2026-09-29; port varies |

**MC mod-count tiers** (enabled jars only; tier replaces meta for that start):

| Enabled mods | ready | stall warn / fail |
|---|---|---|
| 0–49 | 300 (5 min) | 90 / 180 |
| 50–149 | 480 (8 min) | 120 / 240 |
| 150–299 | 600 (10 min) | 150 / 300 |
| ≥300 | 1200 (20 min) | 240 / 480 |

**Workshop item tiers** (`mod_support: workshop`; count INI `WorkshopItems`, tier from `max(configured, pending_on_disk)`; tier **replaces** meta for that start):

| Configured items | ready | stall warn / fail |
|---|---|---|
| 0–9 | 900 (15 min) | 120 / 300 |
| 10–29 | 1200 (20 min) | 180 / 420 |
| 30–49 | 1500 (25 min) | 240 / 480 |
| ≥50 | 1800 (30 min) | 300 / 600 |

**Workshop stall rule:** while `phase=workshop_download`, freeze sliding stall clock — no stall-fail (optional one informational warn after `2× stall_fail` if still in that phase). After phase advances, normal stall applies.

**MC phases (job log):** `mod_loader` (FancyModLoader\|Forge\|Fabric\|…) → `mod_list` (`Mod List:`) → `preparing` → `ready`. Loader-specific phases optional; success only on `Done`.

**Palworld phases:** `breakpad` → `version` (`Game version is`) → `ready`. Stop: `RequestExit|Exiting abnormally` → `Shutdown handler: cleanup`.

**Windrose phases:** pak mount → engine init → engine ready → lobby (`R5ServerLobby`) → ready (`GenlandiaMulty`).

**PZ phases (locked from console 2026-10-01):** workshop download (`DownloadPending` / `Workshop: download X/Y` / `onItemDownloaded`; stall-fail off; byte counters can freeze mid-DL) → backup → loading mods (`Initialising Server Systems` / `loading …`) → loading assets/world → ready (`*** SERVER STARTED ****`). Sample: 34 items, several pending; one ~230 MB item ~60 s.

**Variant inherit:** stubs like `mc-neoforge` that exist as own meta keys without ready fields must inherit lifecycle from the parent that lists them in `variants[]` (e.g. `mcserver`).

## File map

| File | Role |
|------|------|
| `src/lib/games_meta.json` | Seed stall/phases/stop + Windrose/Palworld/MC ready for v1 games |
| `src/lib/games_meta.pl` | `get_lifecycle_config($script)` (+ variant inherit) |
| `src/scripts/lib/lgsm_control.sh` | Sliding stall, phases, stop grace, restart hard-gate, MC mod-count, workshop tier + stall pause |
| `src/lib/pz_workshop.pl` (read-only) | INI `WorkshopItems` count + pending vs disk for workshop tier (v1 PZ) |
| `src/scripts/steamcmd_control_user.sh` | Windrose start ready-wait + stop grace via shared helpers |
| `src/scripts/monitor_instance_user.sh` | Recovery uses full restart lifecycle (stop→start), not start-only |
| `src/scripts/scheduled_restart_user.sh` | Hard-gate via `lgsm_restart_reliable` / SteamCMD restart |
| `src/scripts/game_action_user.sh` | No change if it already calls `lgsm_*_reliable` |
| `src/scripts/lifecycle_env.pl` (new) | Dump meta as KEY=value for bash |
| `t/test_lifecycle_meta.pl` (new) | Meta seed assertions for PZ/MC/Windrose/Palworld |
| `t/test_lgsm_control.sh` | Sliding stall, phases, stop grace, restart gate, mod count |
| `CHANGELOG.md` | Short unreleased note |
| Spec | source of truth for keywords / tiers |

---

### Task 1: Meta schema + Perl accessor

**Files:**
- Modify: `src/lib/games_meta.json` (`pzserver`, `mcserver`, `windrose`, `pwserver`)
- Modify: `src/lib/games_meta.pl` (`get_start_ready_config` keep; add `get_lifecycle_config`, `get_workshop_start_scale` when `mod_support: workshop`)
- Modify: `t/test_start_ready.pl`
- Create: `t/test_lifecycle_meta.pl`

**Interfaces:**
- Consumes: existing `load_games_meta()`
- **Produces:** `get_lifecycle_config($script_name)` → hashref:

```perl
{
  log => 'console'|'latest_log'|'live_log'|'',
  regex => $re,
  secs => $int,
  stall_secs => $int,
  stall_fail_secs => $int,
  start_phases => [ { id, label_de, label_en, match }, ... ],
  stop_grace_secs => $int,
  stop_force_secs => $int,
  stop_phases => [ { id, label_de, label_en, match }, ... ],
  live_log_path => $rel_or_empty,
}
```

Defaults when keys missing: `stall_secs=120`, `stall_fail_secs=300`, `stop_grace_secs=120`, `stop_force_secs=180`, empty phase arrays. Clamp secs 0..3600. If `stall_fail_secs < stall_secs` and both > 0, raise fail to stall. Variant stubs inherit from parent `variants[]` entry when they lack `start_ready_regex`.

- [ ] **Step 1: Write failing test** `t/test_lifecycle_meta.pl`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
our $module_root = "$FindBin::Bin/../src";
require "$module_root/lib/games_meta.pl";

my $pz = get_lifecycle_config('pzserver');
ok(length($pz->{regex}), 'pz ready regex');
cmp_ok($pz->{stall_secs}, '==', 120, 'pz stall warn default/meta');
cmp_ok($pz->{stall_fail_secs}, '==', 300, 'pz stall fail');
ok(@{ $pz->{start_phases} } >= 2, 'pz has start phases');
ok((grep { $_->{id} eq 'ready' } @{ $pz->{start_phases} }), 'pz ready phase');

my $mc = get_lifecycle_config('mcserver');
like($mc->{regex}, qr/Done/, 'mc ready Done');
ok((grep { $_->{id} eq 'preparing' } @{ $mc->{start_phases} }), 'mc preparing phase');

my $mc_var = get_lifecycle_config('mc-neoforge');
like($mc_var->{regex}, qr/Done/, 'mc-neoforge inherits from mcserver variants');

my $wr = get_lifecycle_config('windrose');
like($wr->{regex}, qr/GenlandiaMulty/, 'windrose ready GenlandiaMulty');
is($wr->{log}, 'live_log', 'windrose uses live_log');
ok(length($wr->{live_log_path} // ''), 'windrose live_log_path set');

my $pw = get_lifecycle_config('pwserver');
like($pw->{regex}, qr/Running Palworld dedicated server on/, 'palworld ready line');
is($pw->{log}, 'console', 'palworld uses console log');

my $none = get_lifecycle_config('unknownserverxyz');
is($none->{regex}, '', 'unknown → empty regex');
cmp_ok($none->{stall_secs}, '==', 120, 'unknown still gets stall defaults');

done_testing();
```

Also ensure the returned hash includes `live_log_path` (empty string when absent).

- [ ] **Step 2: Run test — expect FAIL** (`get_lifecycle_config` missing / Windrose regex empty)

```bash
perl t/test_lifecycle_meta.pl
```

- [ ] **Step 3: Implement meta seeds** in `games_meta.json`:

**`pzserver`** (add alongside existing ready keys):

```json
"start_stall_secs": 120,
"start_stall_fail_secs": 300,
"start_phases": [
  {"id": "workshop_download", "label_de": "Workshop-Download", "label_en": "Workshop download", "match": "Waiting for response from Steam servers|DownloadPending|Workshop: download |Workshop: onItemDownloaded|Workshop: onItemQueryCompleted"},
  {"id": "loading_mods", "label_de": "Mods laden", "label_en": "Loading mods", "match": "Initialising Server Systems|Start making backup"},
  {"id": "loading_assets", "label_de": "Assets laden", "label_en": "Loading assets", "match": "LOADING ASSETS"},
  {"id": "loading_world", "label_de": "Welt laden", "label_en": "Loading world", "match": "Loading world|LOADING WORLD"},
  {"id": "ready", "label_de": "Bereit", "label_en": "Ready", "match": "\\*\\*\\* SERVER STARTED \\*\\*\\*\\*"}
],
"stop_grace_secs": 120,
"stop_force_secs": 180,
"stop_phases": [
  {"id": "saving", "label_de": "Speichern", "label_en": "Saving", "match": "[Ss]aving"},
  {"id": "stopped", "label_de": "Gestoppt", "label_en": "Stopped", "match": "[Ss]topped|Shutdown complete|Server stopped"}
]
```

**`mcserver`**: NeoForge-confirmed 2026-10-01; ready identical on all loaders. Meta ready/stall are **fallback only** — `lgsm_start_minecraft` replaces them from mod-count tiers (spec table: 5/8/10/20 min, ≥300 → 20 min).

```json
"start_ready_secs": 600,
"start_stall_secs": 120,
"start_stall_fail_secs": 300,
"start_phases": [
  {"id": "mod_loader", "label_de": "Mod-Loader", "label_en": "Mod loader", "match": "Starting FancyModLoader|Forge Mod Loader|Fabric Loader|Loading Minecraft"},
  {"id": "mod_list", "label_de": "Mod-Liste", "label_en": "Mod list", "match": "Mod List:"},
  {"id": "preparing", "label_de": "Welt vorbereiten", "label_en": "Preparing world", "match": "Preparing level|Preparing spawn area"},
  {"id": "ready", "label_de": "Bereit", "label_en": "Ready", "match": "Done \\([0-9.]+s\\)!"}
],
"stop_grace_secs": 120,
"stop_force_secs": 180,
"stop_phases": [
  {"id": "saving", "label_de": "Speichern", "label_en": "Saving", "match": "Saving chunks|Saving the game|[Ss]aving"},
  {"id": "stopped", "label_de": "Gestoppt", "label_en": "Stopped", "match": "All dimensions are saved|Server stopped|Stopping the server"}
]
```

Apply the same start/stop lifecycle keys on MC variants that inherit ready from `mcserver` via `_resolve_meta_key`, or duplicate on `mc-neoforge` / `mc-forge` / `mc-fabric` / `mc-paper` if they do not inherit nested keys — prefer resolving through the parent `mcserver` entry so one seed covers all loaders.

**MC mod-count scaling:** In `lgsm_start_minecraft` (before ready wait), call:

```bash
lgsm_mc_count_enabled_mods() {
    local mods_dir="$1/serverfiles/mods"
    local n=0
    [[ -d "$mods_dir" ]] || { echo 0; return 0; }
    # Enabled only: *.jar but not *.jar.disabled (disabled ends with .jar.disabled)
    local f
    shopt -s nullglob
    for f in "$mods_dir"/*.jar; do
        [[ -f "$f" ]] || continue
        n=$((n + 1))
    done
    shopt -u nullglob
    echo "$n"
}
```

Tier table (replaces meta for that start):

| N | ready | stall warn/fail |
|---|---|---|
| 0–49 | 300 | 90/180 |
| 50–149 | 480 | 120/240 |
| 150–299 | 600 | 150/300 |
| ≥300 | 1200 | 240/480 |

Job log must print the chosen tier. Unit-test: temp dir with 3 `.jar` + 2 `.jar.disabled` → count 3; empty mods → 0.

Wire this in **Task 3** (after shared wait exists) as step inside `lgsm_start_minecraft`.

**`windrose`**:

```json
"start_ready_log": "live_log",
"start_ready_regex": "Start preloading GenlandiaMulty",
"start_ready_secs": 900,
"start_stall_secs": 120,
"start_stall_fail_secs": 300,
"start_phases": [
  {"id": "pak_mount", "label_de": "Pak mounten", "label_en": "Mounting paks", "match": "Mounted Pak file|Mounted IoStore container"},
  {"id": "engine_init", "label_de": "Engine", "label_en": "Engine init", "match": "Game Engine Initialized\\."},
  {"id": "engine_ready", "label_de": "Engine bereit", "label_en": "Engine ready", "match": "Engine is initialized\\. Leaving FEngineLoop::Init\\(\\)"},
  {"id": "lobby", "label_de": "Lobby", "label_en": "Lobby", "match": "Start preloading R5ServerLobby"},
  {"id": "ready", "label_de": "Bereit", "label_en": "Ready", "match": "Start preloading GenlandiaMulty"}
],
"stop_grace_secs": 60,
"stop_force_secs": 120,
"stop_phases": [
  {"id": "saving", "label_de": "Speichern", "label_en": "Saving", "match": "[Ss]aving|makebak"},
  {"id": "stopped", "label_de": "Gestoppt", "label_en": "Stopped", "match": "Windrose:.*stopped|Server stopped"}
]
```

**`pwserver`** (locked from `pwserver-console.log` 2026-09-29):

```json
"start_ready_log": "console",
"start_ready_regex": "Running Palworld dedicated server on",
"start_ready_secs": 900,
"start_stall_secs": 120,
"start_stall_fail_secs": 300,
"start_phases": [
  {"id": "breakpad", "label_de": "Breakpad", "label_en": "Breakpad", "match": "Setting breakpad minidump AppID"},
  {"id": "version", "label_de": "Version", "label_en": "Version", "match": "Game version is"},
  {"id": "ready", "label_de": "Bereit", "label_en": "Ready", "match": "Running Palworld dedicated server on"}
],
"stop_grace_secs": 120,
"stop_force_secs": 180,
"stop_phases": [
  {"id": "saving", "label_de": "Speichern", "label_en": "Saving", "match": "[Ss]aving"},
  {"id": "exiting", "label_de": "Beenden", "label_en": "Exiting", "match": "RequestExit|Exiting abnormally"},
  {"id": "stopped", "label_de": "Gestoppt", "label_en": "Stopped", "match": "Shutdown handler: cleanup"}
]
```

- [ ] **Step 4: Implement `get_lifecycle_config`** in `games_meta.pl` after `get_start_ready_config`:

```perl
sub get_lifecycle_config {
    my ($script) = @_;
    my $base = get_start_ready_config($script);
    $script //= '';
    $script =~ s/[^a-zA-Z0-9_\-]//g;
    my %meta = load_games_meta();
    my $g = $meta{$script} // {};
    # also resolve via _resolve_meta_key if $g empty (variants)
    if (!%$g) {
        my $key = eval { _resolve_meta_key($script) } || $script;
        $g = $meta{$key} // {};
        # re-pull ready from resolved key
        $base = get_start_ready_config($key) if $key ne $script;
    }
    my $stall = int($g->{start_stall_secs} // 120);
    my $stall_fail = int($g->{start_stall_fail_secs} // 300);
    $stall = 0 if $stall < 0; $stall = 3600 if $stall > 3600;
    $stall_fail = 0 if $stall_fail < 0; $stall_fail = 3600 if $stall_fail > 3600;
    if ($stall > 0 && $stall_fail > 0 && $stall_fail < $stall) {
        $stall_fail = $stall;
    }
    my $sg = int($g->{stop_grace_secs} // 120);
    my $sf = int($g->{stop_force_secs} // 180);
    $sg = 0 if $sg < 0; $sg = 3600 if $sg > 3600;
    $sf = 0 if $sf < 0; $sf = 3600 if $sf > 3600;
    if ($sf > 0 && $sg > 0 && $sf < $sg) { $sf = $sg; }

    my @sp = ();
    if (ref($g->{start_phases}) eq 'ARRAY') {
        for my $p (@{ $g->{start_phases} }) {
            next unless ref($p) eq 'HASH';
            my $id = $p->{id} // '';
            $id =~ s/[^a-zA-Z0-9_\-]//g;
            next unless length($id);
            push @sp, {
                id => $id,
                label_de => '' . ($p->{label_de} // $id),
                label_en => '' . ($p->{label_en} // $id),
                match => '' . ($p->{match} // ''),
            };
        }
    }
    my @stp = ();
    if (ref($g->{stop_phases}) eq 'ARRAY') {
        for my $p (@{ $g->{stop_phases} }) {
            next unless ref($p) eq 'HASH';
            my $id = $p->{id} // '';
            $id =~ s/[^a-zA-Z0-9_\-]//g;
            next unless length($id);
            push @stp, {
                id => $id,
                label_de => '' . ($p->{label_de} // $id),
                label_en => '' . ($p->{label_en} // $id),
                match => '' . ($p->{match} // ''),
            };
        }
    }

    return {
        %$base,
        stall_secs => $stall,
        stall_fail_secs => $stall_fail,
        start_phases => \@sp,
        stop_grace_secs => $sg,
        stop_force_secs => $sf,
        stop_phases => \@stp,
    };
}
```

Ensure `_resolve_meta_key` exists and is used consistently with other getters. Keep `get_start_ready_config` behaviour unchanged for existing tests.

- [ ] **Step 5: Run tests**

```bash
perl t/test_lifecycle_meta.pl
perl t/test_start_ready.pl
```

Expected: PASS

- [ ] **Step 6: Commit** (only if user asked for commits in this wave; otherwise skip until user requests)

```bash
git add src/lib/games_meta.json src/lib/games_meta.pl t/test_lifecycle_meta.pl t/test_start_ready.pl
git commit -m "$(cat <<'EOF'
feat: add lifecycle meta (stall, phases, stop) for PZ/MC/Windrose/Palworld

EOF
)"
```

---

### Task 2: Shell helper — resolve log path + dump lifecycle env

**Files:**
- Modify: `src/scripts/lib/lgsm_control.sh`
- Modify: `t/test_lgsm_control.sh`

**Interfaces:**
- Produces:
  - `lgsm_lifecycle_log_path "$server_dir" "$script_name" "$log_key"` → prints path, returns 0 if found
  - `lgsm_lifecycle_load_from_meta "$script_name"` — if `MODULE_ROOT` set, calls a tiny Perl one-liner / `lifecycle_env.pl` to export `WEBCORE_READY_*` / stall / phases as env for bash wait (alternative: pass args from callers that already know meta)

**Preferred approach (YAGNI):** Callers that already know script name invoke a small Perl helper once:

Create `src/scripts/lifecycle_env.pl` that prints `KEY=value` lines for bash `eval`:

```perl
#!/usr/bin/env perl
# usage: perl lifecycle_env.pl <script_name>
# prints: READY_LOG=... READY_REGEX=... READY_SECS=... STALL_SECS=... STALL_FAIL_SECS=...
#         STOP_GRACE=... STOP_FORCE=...
#         PHASE_N=id|match   STOP_PHASE_N=id|match
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
require "$FindBin::Bin/../lib/games_meta.pl";
my $s = $ARGV[0] // '';
my $c = get_lifecycle_config($s);
printf "READY_LOG=%s\n", $c->{log};
printf "READY_REGEX=%s\n", $c->{regex};
printf "READY_SECS=%d\n", $c->{secs} || 900;
printf "STALL_SECS=%d\n", $c->{stall_secs};
printf "STALL_FAIL_SECS=%d\n", $c->{stall_fail_secs};
printf "STOP_GRACE=%d\n", $c->{stop_grace_secs};
printf "STOP_FORCE=%d\n", $c->{stop_force_secs};
my $i = 0;
for my $p (@{ $c->{start_phases} }) {
    printf "START_PHASE_%d=%s|%s\n", $i++, $p->{id}, $p->{match};
}
$i = 0;
for my $p (@{ $c->{stop_phases} }) {
    printf "STOP_PHASE_%d=%s|%s\n", $i++, $p->{id}, $p->{match};
}
```

Bash loader:

```bash
lgsm_lifecycle_eval_meta() {
    local script_name="$1"
    local helper="${MODULE_ROOT:-}/scripts/lifecycle_env.pl"
    [[ -f "$helper" ]] || return 1
    # shellcheck disable=SC2046
    eval "$(perl "$helper" "$script_name" | sed 's/^/export WEBCORE_LC_/')"
}
```

Adjust prefix so keys become `WEBCORE_LC_READY_REGEX` etc. (sed `s/^/export WEBCORE_LC_/`).

Log path resolver:

```bash
lgsm_lifecycle_log_path() {
    local server_dir="$1" script_name="$2" log_key="${3:-}"
    case "$log_key" in
        console) lgsm_console_log "$server_dir" "$script_name" ;;
        latest_log) lgsm_mc_latest_log "$server_dir" ;;
        live_log)
            # Prefer meta live_log_path via env WEBCORE_LC_LIVE_LOG_REL or hard resolve:
            if [[ -n "${WEBCORE_LC_LIVE_LOG_REL:-}" && -f "$server_dir/${WEBCORE_LC_LIVE_LOG_REL}" ]]; then
                printf '%s\n' "$server_dir/${WEBCORE_LC_LIVE_LOG_REL}"
                return 0
            fi
            # Windrose fallbacks
            for c in \
                "$server_dir/serverfiles/R5/Saved/Logs/R5.log" \
                "$server_dir/server.log" \
                "$server_dir/serverfiles/server.log"
            do
                [[ -f "$c" ]] && { printf '%s\n' "$c"; return 0; }
            done
            return 1
            ;;
        *)
            [[ -n "$log_key" && -f "$server_dir/$log_key" ]] && { printf '%s\n' "$server_dir/$log_key"; return 0; }
            return 1
            ;;
    esac
}
```

Extend `lifecycle_env.pl` to also print `LIVE_LOG_REL=` from meta `live_log_path` when present.

- [ ] **Step 1: Failing test** in `t/test_lgsm_control.sh` — after sourcing control, create fake Windrose tree and assert `lgsm_lifecycle_log_path` finds R5.log

- [ ] **Step 2: Implement** `lifecycle_env.pl` + bash helpers

- [ ] **Step 3: Run** `bash t/test_lgsm_control.sh` — PASS for new assertions; existing tests still green

- [ ] **Step 4: Commit** (if requested)

---

### Task 3: Sliding stall + phase-aware start wait

**Files:**
- Modify: `src/scripts/lib/lgsm_control.sh` — rewrite `lgsm_start_wait_ready_marker` (or replace with `lgsm_lifecycle_wait_ready`)
- Modify: `t/test_lgsm_control.sh`
- Wire: `lgsm_start_reliable` / `lgsm_start_minecraft` to use meta stall/phases via `lgsm_lifecycle_eval_meta`

**Behaviour (locked):**

1. Capture log size at wait start; track `last_growth_at=$elapsed` whenever `size > last_size`.
2. Each loop: process dead → fail; ready regex in new bytes (or allow_existing) → ok; update `phase=` from last matching `START_PHASE_*` in new tail; every 30s log `Still starting… phase=… +N bytes`.
3. If `elapsed - last_growth_at >= stall_secs` and stall_secs > 0 → print **once per stall streak**: `WARNING: start log stalled for Ns (phase=…)` — **skip** while `phase=workshop_download` (optional informational warn at `2× stall_fail` only).
4. If `elapsed - last_growth_at >= stall_fail_secs` and stall_fail_secs > 0 → `ERROR: start log stalled…` → return 1 — **never** while `phase=workshop_download`; while in that phase, reset `last_growth_at=$elapsed` each loop (stall clock frozen).
5. On ready timeout: keep current policy (session up + grown → warn+0; zero growth → fail).
6. **Workshop games:** before wait, if `mod_support: workshop`, call Perl scale helper (INI count + pending); log tier line; apply ready/stall overrides (same pattern as MC mod-count below).

Replace old “zero growth from start for 300s” with sliding window. Env overrides: `WEBCORE_START_LOG_STALL_SECS` / `WEBCORE_START_LOG_STALL_FAIL_SECS` still work as overrides when set.

Signature — keep compatible, add optional stall args or read from env set by meta load:

```bash
# Prefer: callers set WEBCORE_LC_* then call:
lgsm_lifecycle_wait_ready() {
    local server_dir="$1" script_name="$2" log="$3" offset="${4:-0}"
    local regex="${5:-${WEBCORE_LC_READY_REGEX:-}}"
    local ready_secs="${6:-${WEBCORE_LC_READY_SECS:-900}}"
    local allow_existing="${7:-0}"
    local stall_secs="${WEBCORE_LC_STALL_SECS:-${WEBCORE_START_LOG_STALL_SECS:-120}}"
    local stall_fail="${WEBCORE_LC_STALL_FAIL_SECS:-${WEBCORE_START_LOG_STALL_FAIL_SECS:-300}}"
    # ... is_alive callback: default lgsm_is_started
}
```

Keep `lgsm_start_wait_ready_marker` as a thin wrapper calling `lgsm_lifecycle_wait_ready` for back-compat.

Phase match helper:

```bash
lgsm_lifecycle_detect_phase() {
    local chunk_file="$1"  # temp file with new bytes
    local best="" best_i=-1 i=0
    while [[ -n "${WEBCORE_LC_START_PHASE_$i:-}" ]]; do
        # Actually env names from eval are WEBCORE_LC_START_PHASE_0=id|match
        ...
    done
    printf '%s\n' "$best"
}
```

Simpler: store phases in a bash array when loading meta:

```bash
# in lgsm_lifecycle_eval_meta after eval, build:
LC_START_PHASE_IDS=(); LC_START_PHASE_RES=()
```

Implement by parsing `lifecycle_env.pl` output in a `while read` loop instead of blind eval — clearer and safer.

- [ ] **Step 1: Write failing stall test**

```bash
# Mock lgsm_is_started always true; log grows then freezes
# WEBCORE_LC_STALL_SECS=2 WEBCORE_LC_STALL_FAIL_SECS=4 READY_SECS=30
# Expect WARNING then ERROR return 1
```

- [ ] **Step 2: Run — FAIL** (old code only fails on zero growth from start)

- [ ] **Step 3: Implement sliding stall + phase lines**

- [ ] **Step 4: Update PZ/MC start paths** to `lgsm_lifecycle_eval_meta` before wait; MC Done wait should also use sliding stall (refactor `lgsm_start_minecraft` ready loop to call shared wait with `Done` regex and `latest_log`)

**Workshop tier helper (Perl, v1 PZ via existing workshop lib):**

```perl
# games_meta.pl — returns undef unless mod_support eq 'workshop'
sub get_workshop_start_scale {
    my ($script_name, $unix_user, $server_dir) = @_;
    return undef unless get_mod_support($script_name) eq 'workshop';
    require 'pz_workshop.pl';
    my ($ok, $ini) = pz_workshop_resolve_ini_path($unix_user, $script_name);
    my ($vals) = $ok ? pz_workshop_read_ini($ini) : ({});
    my @ids = pz_workshop_split_list($vals->{WorkshopItems} // '');
    my $disk = pz_workshop_scan_disk($unix_user, $server_dir, get_workshop_appid($script_name));
    my $pending = scalar grep { !exists $disk->{$_} } @ids;
    my $n = scalar @ids;
    my $tier_n = $pending > $n ? $pending : $n;  # max(configured, pending)
    # map tier_n → ready_secs, stall_secs, stall_fail_secs (table in spec)
    return { items => $n, pending => $pending, ready_secs => ..., stall_secs => ..., stall_fail_secs => ... };
}
```

Dump via `lifecycle_env.pl` when scale present: `WORKSHOP_ITEMS=`, `WORKSHOP_PENDING=`, override `READY_SECS` / stall env. Bash: `WEBCORE_LC_WORKSHOP_STALL_PAUSE=1` when game has workshop (stall-fail off for `workshop_download` phase).

**Failing tests to add:**

- Mock log: phase stays `workshop_download`, no byte growth for 400s → must **not** return stall-fail (ready timeout or phase advance still applies).
- Mock scale: 25 INI items → ready cap 1200s logged.

- [ ] **Step 5: Run** `bash t/test_lgsm_control.sh` — PASS

- [ ] **Step 6: Commit** (if requested)

---

### Task 4: Stop grace + restart hard-gate (LGSM)

**Files:**
- Modify: `src/scripts/lib/lgsm_control.sh` — `lgsm_stop_reliable`, `lgsm_stop_direct`, `lgsm_restart_reliable`
- Modify: `t/test_lgsm_control.sh`

**Stop behaviour:**

1. Issue graceful command (unchanged per game: MC `stop`, PZ `quit`, else LGSM `stop`).
2. Poll until offline OR `stop_force_secs` elapsed.
3. While online and log matches stop-phase `saving` and `elapsed < stop_force_secs`: do **not** force yet; log `Stop: still saving…`.
4. After `stop_grace_secs` without saving match, may force earlier (optional); hard rule from spec: force only after `stop_force_secs` while saving, or when grace expired and not saving.
5. Force path = existing tmux/java kill.
6. Return 0 only if offline; else 1.

**Restart:**

```bash
lgsm_restart_reliable() {
    local server_dir="$1" script_name="$2"
    echo "=== Restart: stop ==="
    if ! lgsm_stop_reliable "$server_dir" "$script_name"; then
        echo "ERROR: restart aborted — stop did not reach offline" >&2
        return 1
    fi
    if lgsm_is_started "$server_dir" "$script_name"; then
        echo "ERROR: restart aborted — still online after stop" >&2
        return 1
    fi
    sleep 2
    echo "=== Restart: start ==="
    lgsm_start_reliable "$server_dir" "$script_name"
}
```

**Critical:** remove `|| true` on stop in the current `lgsm_restart_reliable`.

- [ ] **Step 1: Failing test** — mock online through stop; assert restart returns non-zero and does not call start (spy `lgsm_start_reliable`)

- [ ] **Step 2: Implement stop grace using `WEBCORE_LC_STOP_*` + phases**

For PZ: raise direct wait from 8s toward meta grace when saving matches — load meta at start of `lgsm_stop_reliable`.

- [ ] **Step 3: Tests PASS**

- [ ] **Step 4: Commit** (if requested)

---

### Task 5: SteamCMD / Windrose twin

**Files:**
- Modify: `src/scripts/steamcmd_control_user.sh` (start + stop + restart branches)
- Modify: `t/test_lgsm_control.sh` or add `t/test_steamcmd_lifecycle.sh` with mocked PID/log

**Start:** After PID is alive, if meta has ready regex for script (derive script from instance / `gamename` / pass `WEBCORE_SCRIPT_NAME`):

1. `lgsm_lifecycle_eval_meta windrose` (or actual script key)
2. Resolve log via `lgsm_lifecycle_log_path`
3. Call `lgsm_lifecycle_wait_ready` with **alive check** = `kill -0 $PID` (pass via env `WEBCORE_LC_ALIVE_PID=$PID` and teach wait helper to use PID when set instead of tmux)

**Stop:** Before hard TERM/KILL storm, wait up to `stop_force_secs` while saving phase matches; then existing kill path. Success only when no game PID.

**Restart:** stop must succeed offline before start (already partly true — tighten to abort on stop failure).

- [ ] **Step 1: Unit test** with temp R5.log appending `Start preloading GenlandiaMulty` and fake PID file

- [ ] **Step 2: Wire start wait into Windrose success path** (replace “readiness files pending → ok” soft path when regex configured)

- [ ] **Step 3: Wire stop grace**

- [ ] **Step 4: `bash scripts/verify.sh` scoped / full**

---

### Task 6: Callers — monitor + scheduled restart

**Files:**
- Modify: `src/scripts/monitor_instance_user.sh`
- Modify: `src/scripts/scheduled_restart_user.sh`

**Monitor LGSM recovery today:** often `lgsm_start_reliable` only when offline. Spec requires **full restart lifecycle** when recovering a half-dead / query-fail restart that left a bad session.

Change recovery when “monitor showed restart” or forced recovery:

```bash
# Prefer full restart when session looked up but unhealthy, or always use restart when replacing a dead session that might still hold locks:
lgsm_restart_reliable "$SERVER_DIR" "$SCRIPT_NAME"
```

When truly offline (no session), `lgsm_restart_reliable` → stop is no-op “Already offline” → start — OK.

When SteamCMD native path restarts via `steamcmd_control_user.sh restart`, ensure that script uses hard-gate.

**Scheduled:** replace separate stop+start with:

```bash
lgsm_restart_reliable "$SERVER_DIR" "$SCRIPT_NAME" || _rc=1
```

and for SteamCMD:

```bash
bash .../steamcmd_control_user.sh restart ...
```

so one code path owns the gate.

- [ ] **Step 1: Patch monitor + scheduled**

- [ ] **Step 2: Grep for other `lgsm_start_reliable` / `lgsm_stop_reliable` / `|| true` restart patterns**

```bash
rg -n 'lgsm_restart_reliable|lgsm_start_reliable|lgsm_stop_reliable' src/scripts
```

Fix any divergent restart.

- [ ] **Step 3: `bash scripts/verify.sh`**

---

### Task 7: Docs + CHANGELOG

**Files:**
- Modify: `CHANGELOG.md` (Unreleased)

CHANGELOG bullet:

```markdown
- Start/Stop/Restart: shared lifecycle — sliding log stall (warn/fail), meta start/stop phases, stop save-grace, restart offline hard-gate; Windrose ready = GenlandiaMulty; Palworld ready = Running Palworld dedicated server on; MC ready/stall scaled by enabled mod count; workshop games (PZ) scale by WorkshopItems + no stall-fail during workshop download phase
```

- [ ] **Step 1: Update CHANGELOG**
- [ ] **Step 2: Full** `bash scripts/verify.sh`
- [ ] **Step 3: Commit** (only if user requests)

---

## Handoff / execution order

**Wait for user go-ahead before coding.** Then:

1. Task 1 (meta + Perl) — foundation  
2. Task 2 (log path + env dump)  
3. Task 3 (sliding stall start + MC mod-count + workshop tier/stall pause)  
4. Task 4 (stop + restart LGSM)  
5. Task 5 (SteamCMD Windrose)  
6. Task 6 (monitor + schedule callers)  
7. Task 7 (changelog + verify)

**Out of scope:** badge phase subtitle; auto-restart on stall; games beyond PZ/MC/Windrose/Palworld.

**Self-review vs spec:**

| Spec requirement | Task |
|---|---|
| Sliding stall warn/fail | Task 3 |
| start_phases in meta + job log | Tasks 1, 3 |
| Windrose GenlandiaMulty + live_log | Tasks 1, 5 |
| Palworld console ready locked | Task 1 |
| MC Done + NeoForge phases + mod-count tiers | Tasks 1, 3 |
| Workshop boot download phase + item tiers + stall pause | Tasks 1, 3 |
| Stop saving grace / force cap | Task 4, 5 |
| Restart offline hard-gate | Task 4, 5, 6 |
| Shared callers (manual/monitor/schedule) | Task 6 |
| UI blink unchanged | already done (prior session) |
