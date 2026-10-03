# Design draft: Start-Phase + Log-Stall Hardening

**Date:** 2026-09-30 (decisions locked 2026-10-01)  
**Status:** approved for planning — implement via `docs/superpowers/plans/2026-10-01-start-stop-lifecycle.md`  
**Builds on:** `docs/superpowers/specs/2026-09-29-start-ready-monitor-design.md`  
**Implement:** after this plan; Windrose + Palworld ready locked from root-server log samples

## Intent (user)

1. During start, **keep checking the live log**.
2. If the log is **stuck** (nothing new) → something is wrong.
3. Cover **all runtimes we care about**: LinuxGSM, SteamCMD/Wine, Minecraft.
4. Put **keywords + start phases** in game meta so start can be monitored properly.
5. First pass: only the games currently on the **root server**.
6. Document tonight; decide open points and implement **tomorrow morning**.
7. **Stop path:** same games — do not force-kill while the server is still saving / shutting down cleanly; watch log (and timeouts) like start phases.
8. **Restart:** full **stop → (optional config already on disk) → start**: must complete a proper stop (save grace) before start; after config changes, start must load the **new** config (no half-dead process / old session).
9. **Everything related must fit modularly:** manual Start/Stop/Restart, **WebCore monitoring** (auto-restart), **scheduled restart**, status blink / monitor `starting` grace — one shared lifecycle + same meta, no parallel special cases.

## Scope v1 (confirmed)

| Game | Runtime | Script / key | Notes |
|---|---|---|---|
| Project Zomboid | LinuxGSM | `pzserver` | Ready marker already in meta |
| Minecraft (vanilla + loaders) | LinuxGSM | `mcserver` (+ variants) | Ready = `Done (…)!` |
| Windrose | SteamCMD + Wine | `windrose` | No start_ready meta yet; log via `live_log_path` / R5.log |
| Palworld | LinuxGSM | `pwserver` | No start_ready meta yet |

Out of scope for v1: Valheim, Rust, CS, Arma, etc. — same meta schema, fill later.

Live instances live on the **root server** (not the local dev box). Keyword lines must be harvested from real start logs there.

## Problem today

| Gap | Current behaviour |
|---|---|
| Ready marker | Only PZ + MC in `games_meta.json` (`start_ready_log` / `_regex` / `_secs`) |
| Stall | LGSM ready-wait fails only if **zero growth from start** for `WEBCORE_START_LOG_STALL_SECS` (default 300). Mid-boot freeze after some output is **not** detected |
| Phases | Spec mentioned UI-only phase hints; **not implemented** in meta |
| Windrose / Palworld | Session/PID up ≠ joinable; no structured ready/phase watch |
| SteamCMD path | `steamcmd_control_user.sh` marks ready after start success; no log-phase state machine |
| Stop grace | `lgsm_stop_reliable` / `lgsm_stop_direct`: fixed waits then force (MC ~60s stop, PZ ~8s quit then force). No meta-driven “still saving” wait; Windrose/SteamCMD stop may TERM/KILL without save-complete marker |
| Restart | Often stop + start chained; if stop is soft-failed / process still up, start may hit Already-online or boot with **stale** config; no explicit “offline verified before start” gate tied to config reload |
| Modularity | Manual jobs, `monitor_instance_user.sh` recovery, `scheduled_restart_user.sh`, and UI “starting” blink each touch start/stop differently; risk of diverging grace/ready/kill behaviour |

## Goals

1. **Sliding log stall:** if the watched log stops growing for N seconds *during* start (even after earlier growth) → treat as stuck (exact reaction = open decision).
2. **Phase keywords in meta:** ordered start phases with match patterns; expose current phase in job log / UI badge context.
3. **Unified for LGSM + SteamCMD + MC:** one meta schema, shared wait helper (or thin wrappers).
4. **Ready marker remains success criteria;** phases are progress + stall context (and optional per-phase stall overrides later).
5. **Graceful stop:** wait for save/shutdown markers (or growth during stop) before force-kill; meta keywords per game (same v1 set).
6. **Restart = verified stop then start:** do not start until offline (and stop phase OK); then run the same start ready/phase/stall watch so a post-edit restart actually picks up new config.
7. **One modular lifecycle for all callers:** same stop/start/restart (+ ready/stall/phases) used by manage/mods/workshop jobs, monitor auto-restart, and scheduled restart; monitor `starting` grace and UI blink stay aligned with that lifecycle.

## Modular architecture (draft)

```text
games_meta.json  →  start/stop phases, ready, stall, grace
                         │
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
   lifecycle start   lifecycle stop   lifecycle restart
   (ready+stall)     (save+grace)     (stop∨fail → start)
         │               │               │
    ┌────┴────┬──────────┴──────┬────────┴────────┐
    ▼         ▼                 ▼                 ▼
 game_action  steamcmd_control  monitor_restart   scheduled_restart
 manage/mods  (Windrose)        monitor_instance  scheduled_restart
 workshop                                         _user.sh
         │
         ▼
 monitor state: starting → running   +   UI blink / poll_runtime
```

Rules:

- **No second implementation** of “wait until ready” or “force kill after N” inside monitor or schedule scripts — call the shared helpers (`lgsm_control` / SteamCMD twins / thin wrappers).
- Monitor cron: while `monitor_is_starting`, skip crash-restart (already); clear `starting` only when lifecycle reports ready (or approved timeout path) — same definition as start job success.
- Monitor recovery restart and scheduled restart: must use **full restart lifecycle** (verified stop → start), not “start only” or short force-kill.
- UI “Startet…” blink: driven by monitor starting **or** in-flight start/restart job — already; keep that as the user-visible face of the same state machine.
- New games later: only add meta keywords; callers stay unchanged.

Non-goals (v1):

- Replacing steady-state LGSM `./script monitor` after ready (WebCore still orchestrates crash recovery / schedule via shared lifecycle)
- GameDig/query as primary ready signal for PZ
- Filtering harmless console noise (AnimSets etc.)
- Auto-restart on stall (only fail/warn the start job unless decided otherwise)
- Rewriting the whole monitor cron from scratch — only wire it to the shared lifecycle

## Decisions (locked 2026-10-01)

1. **Stall outcome: C** — warn after `start_stall_secs` (default **120**), fail job after `start_stall_fail_secs` (default **300**) of no log growth; ready timeout stays **900** (per-game override OK, e.g. MC higher).
2. **UI phase on badge:** v1 **job log only**; badge stays blink Startet… without phase subtitle.
3. **Stop:** success = verified offline; while stop-phase `saving` matches, do not force until `stop_force_secs` (**grace 120** / **force 180** defaults).
4. **Restart hard gate:** must be offline before start; stop failure aborts restart.
5. **Caller matrix:** manual + monitor auto-restart + scheduled restart share one lifecycle in the same wave.
6. **Architecture:** shared helpers in `lgsm_control.sh` + SteamCMD twin + meta (approach 1).
7. **Keywords:**
   - PZ / MC: existing ready markers + phase seeds below.
   - **Windrose ready (B):** `Start preloading GenlandiaMulty` (confirmed from root `server.log` sample 2026-05-10).
   - **Palworld ready:** `Running Palworld dedicated server on` (confirmed from `pwserver-console.log` 2026-09-29).

## Proposed meta schema (draft)

Extend per-game entry in `games_meta.json` (and local overrides):

```json
{
  "start_ready_log": "console",
  "start_ready_regex": "…",
  "start_ready_secs": 900,
  "start_stall_secs": 120,
  "start_stall_fail_secs": 300,
  "start_phases": [
    {
      "id": "workshop_download",
      "label_de": "Workshop-Download",
      "label_en": "Workshop download",
      "match": "Waiting for response from Steam servers|DownloadPending|Workshop: download |Workshop: onItemDownloaded|Workshop: onItemQueryCompleted"
    },
    {
      "id": "loading_assets",
      "label_de": "Assets laden",
      "label_en": "Loading assets",
      "match": "LOADING ASSETS"
    },
    {
      "id": "ready",
      "label_de": "Bereit",
      "label_en": "Ready",
      "match": "\\*\\*\\* SERVER STARTED \\*\\*\\*\\*"
    }
  ],
  "stop_grace_secs": 120,
  "stop_force_secs": 180,
  "stop_phases": [
    {
      "id": "saving",
      "label_de": "Speichern",
      "label_en": "Saving",
      "match": "[Ss]aving"
    },
    {
      "id": "stopped",
      "label_de": "Gestoppt",
      "label_en": "Stopped",
      "match": "[Ss]topped|Shutdown complete|Server stopped"
    }
  ]
}
```

Rules:

- `start_phases` ordered; last phase that matched (or explicit `ready` id) drives UI/progress.
- Final ready still comes from `start_ready_regex` (may equal the last phase `match`).
- `start_stall_secs`: warn threshold (no new bytes); `start_stall_fail_secs`: fail threshold (must be ≥ warn); `0` disables that tier.
- Missing `start_phases` → behaviour as today (ready wait + improved stall only).
- `stop_grace_secs` / `stop_force_secs` / `stop_phases`: as above.

Log source keys (reuse / extend `start_ready_log`):

| Key | Meaning |
|---|---|
| `console` | LGSM `log/console/${script}-console.log` |
| `latest_log` | MC `serverfiles/logs/latest.log` (and candidates) |
| `live_log` | Game `live_log_path` from meta (Windrose R5.log) |
| absolute/relative path | Future escape hatch |

## Per-game seed (to fill from root-server logs)

### Project Zomboid (`pzserver`) — locked from console log 2026-10-01 (`gs_pz_knoellix/pz-1`)

Log: `console` (`pzserver-console.log`). Timeout: 900s baseline; **workshop item tier replaces** when `mod_support: workshop` — see below.

Sample: PZ 42.21, Steam workshop query `numResult=34`; several items `None` → `DownloadPending` (one ~230 MB item alone ~60 s). Workshop phase ran ~1.5+ min before backup + mod load. Progress lines every ~100 ms while bytes change; **byte counters can stall for many seconds** (e.g. stuck at `0/N` or same mid-progress) — stall-fail must stay off in this phase.

| Phase id | Keyword (locked) | Role |
|---|---|---|
| `workshop_download` | `Workshop:.*(DownloadPending\|download [0-9]+/[0-9]+\|onItemDownloaded\|onItemQueryCompleted)` or simpler `DownloadPending\|Workshop: download \|Workshop: onItemDownloaded\|Waiting for response from Steam servers` | progress — boot Steam download |
| `loading_mods` | `Initialising Server Systems\|loading [A-Za-z]` (job-log progress only; flood of `mod "…" overrides` is normal) | progress |
| `loading_assets` | `LOADING ASSETS` (confirm if still emitted on B42; may appear later in same boot) | progress |
| `loading_world` | `Loading world\|checking server WorldVersion` | progress |
| `ready` | `\*\*\* SERVER STARTED \*\*\*\*` | = `start_ready_regex` |

**Workshop end markers (phase advance):** after last pending item → `Workshop: <id> installed to …/steamapps/workshop/content/108600/<id>` lines, then `Start making backup` / `Backup made`, then `Initialising Server Systems…` and `loading <ModId>`.

**Confirmed line shapes:**

```
Workshop: onItemQueryCompleted handle=1 numResult=34
Workshop: GetItemState()=Installed ID=…
Workshop: item state CheckItemState -> Ready ID=…
Workshop: GetItemState()=None ID=…
Workshop: item state CheckItemState -> DownloadPending ID=…
Workshop: DownloadPending GetItemState()=NeedsUpdate|Downloading|DownloadPending ID=…
Workshop: download 8864/57436880 ID=…
Workshop: onItemDownloaded itemID=… time=22190 ms
Workshop: … installed to …/steamapps/workshop/content/108600/…
```

**Noise (ignore for stall):** `libjsig.so` LD_PRELOAD, `Staging library folder not found`, `IPC function call IClientUGC::GetItemState took too long` — normal Steam noise, not failure.

### Workshop games (`mod_support: workshop`) — locked 2026-10-01

Applies to any game entry with `mod_support: workshop` in `games_meta.json` (v1: **PZ**; future Palworld etc. reuse the same hooks).

**Before the ready wait:**

1. Read configured Workshop item IDs from server INI (`WorkshopItems=` semicolon list; path from meta `workshop_ini_rel` / existing workshop helpers).
2. Count **pending** = in INI but not yet on disk under workshop content roots (`workshop_appid` + scan helpers — today `pz_workshop.pl`).
3. Log: `Workshop: N configured, P pending download → ready≤Xs stall warn/fail=…`.
4. **Tier replaces** meta ready/stall for that start (same rule as MC mod-count — do not max with a loose 900s default).

| Configured items (INI) | `start_ready_secs` | stall warn / fail |
|---|---|---|
| 0–9 | 900 (15 min) | 120 / 300 |
| 10–29 | 1200 (20 min) | 180 / 420 |
| 30–49 | 1500 (25 min) | 240 / 480 |
| ≥50 | 1800 (30 min) | 300 / 600 |

When **pending > 0**, use the tier for `max(N, P)` (new items force at least the pending tier). Sample with 34 INI items → **30–49 tier (25 min)**. Env overrides (`WEBCORE_WORKSHOP_START_READY_SECS`, stall env) still win when set.

**Stall during `workshop_download` phase:**

- While **current phase** = `workshop_download` (last matching start phase in new log tail): **do not fail** on log stall — freeze or reset the sliding stall clock each poll. Confirmed: progress can sit at `0/N` or the same mid-byte count for many seconds while Steam stages.
- Optional: emit **one** `WARNING: workshop download in progress, log quiet for Ns` after `2 × start_stall_fail_secs` while still in `workshop_download` (informational only — no fail).
- Once phase advances (e.g. `loading_mods` / `Start making backup`), normal sliding stall warn/fail applies.
- If boot never matched `workshop_download` but pending > 0, treat the pre-first-keyword window as workshop-like: no stall-fail until first non-workshop phase match or until `start_ready_secs` (tier already extended).

**Meta match (PZ `start_phases[0]`):** `Waiting for response from Steam servers|DownloadPending|Workshop: download |Workshop: onItemDownloaded|Workshop: onItemQueryCompleted`

### Minecraft (`mcserver` + variants) — locked from NeoForge root log 2026-10-01

Log: `serverfiles/logs/latest.log` (`start_ready_log`: `latest_log`).  
Sample: NeoForge 26.1 / FancyModLoader on `gs_mc_keks/mc-1` (~90 mods).

| Phase id | Keyword | Role |
|---|---|---|
| `mod_loader` | `Starting FancyModLoader\|Forge Mod Loader\|Fabric Loader\|Loading Minecraft` | progress (loader-specific; miss = OK) |
| `mod_list` | `Mod List:` | progress (NeoForge/Forge) |
| `preparing` | `Preparing level\|Preparing spawn area` | progress |
| `ready` | `Done \\([0-9.]+s\\)!` | = `start_ready_regex` (**all loaders**) |

Confirmed ready line (NeoForge): `Done (3.259s)! For help, type "help"`.

**Loader note:** Vanilla / Paper / Forge / NeoForge / Fabric all emit the same `Done (…s)!` joinable signal. Do **not** require NeoForge-only lines for success — only for optional phase progress. Missed early phases on vanilla/Paper are fine.

**Stall:** Baseline for MC without count yet: **`start_stall_secs`: 120**, **`start_stall_fail_secs`: 300** — then **scale by enabled mod count** (table below). Heavy packs can pause logging during Mixin/classload; stall tiers stay shorter than old 15–30 min ready budgets.

**Mod-count scaling (v1):** Before the ready wait, count **enabled** jars under `serverfiles/mods/` (basename ends in `.jar`, not `.jar.disabled`; skip nested jars-in-jars). Log: `Minecraft: N enabled mods → ready≤Xs stall warn/fail=…`. **Tier replaces** meta ready/stall for that start (do not take max with a 900s meta default — that would defeat short tiers). Meta values are fallback only if the mods dir is unreadable.

| Enabled mods | `start_ready_secs` | stall warn / fail |
|---|---|---|
| 0–49 | 300 (5 min) | 90 / 180 |
| 50–149 | 480 (8 min) | 120 / 240 |
| 150–299 | 600 (10 min) | 150 / 300 |
| ≥300 | 1200 (20 min) | 240 / 480 |

Rationale (ops): long boots mainly above ~300 mods (e.g. old DnD pack); 20 min ceiling leaves headroom for slower hardware. Normal NeoForge ~90 mods finishes in a few minutes. Env overrides (`WEBCORE_MC_START_READY_SECS`, stall env) still win when set. Vanilla/Paper with empty `mods/` → low tier. Do not parse NeoForge “Mod List” text — filesystem count is available before boot and loader-agnostic.

Stop:

| Phase id | Keyword | Role |
|---|---|---|
| `saving` | `Saving chunks\|Saving the game\|[Ss]aving` | grace |
| `stopped` | `All dimensions are saved\|Server stopped\|Stopping the server` | offline marker |

### Windrose (`windrose`) — locked from root log 2026-05-10

Log source: `server.log` (wrapper + UE; also `live_log_path` R5.log for UE-only). Prefer **`live_log` / R5.log** for game lines; wrapper `Windrose: starting wine` may only be in `server.log` — watch the file that contains both, or accept UE-only phases on R5.log.

| Phase id | Keyword | Role |
|---|---|---|
| `wine_start` | `Windrose: starting wine on DISPLAY=` | progress (wrapper) |
| `pak_mount` | `Mounted Pak file` / `Mounted IoStore container` | progress |
| `engine_init` | `Game Engine Initialized\.` | progress |
| `engine_ready` | `Engine is initialized\. Leaving FEngineLoop::Init\(\)` | progress |
| `lobby` | `Start preloading R5ServerLobby` | progress |
| `ready` | `Start preloading GenlandiaMulty` | = `start_ready_regex` (**decision B**) |

`start_ready_log`: `live_log` (R5.log) — GenlandiaMulty appears there; if missing, fall back to scanning `server.log`.  
`start_ready_secs`: 900.  
Ignore: Wine OLE/`RpcSs` noise, string-table / missing font warnings.

**Map caveat:** Ready is tied to `GenlandiaMulty`. If the dedicated map changes, update meta.

### Palworld (`pwserver`) — locked from root console 2026-09-29

Log: LGSM `log/console/pwserver-console.log` (`start_ready_log`: `console`).  
Sample path: `/home/gs_pw_keks/pw-1/log/console/pwserver-console.log`.

| Phase id | Keyword | Role |
|---|---|---|
| `breakpad` | `Setting breakpad minidump AppID` | progress |
| `version` | `Game version is` | progress |
| `ready` | `Running Palworld dedicated server on` | = `start_ready_regex` (**locked**) |

`start_ready_secs`: 900. Port after `on` varies — do **not** anchor on `:8211`.

Stop sample (Ctrl+C / signal 130):

| Phase id | Keyword | Role |
|---|---|---|
| `exiting` | `RequestExit|Exiting abnormally` | progress |
| `stopped` | `Shutdown handler: cleanup` | = offline marker |

No “saving” line in this short stop sample — keep generic `[Ss]aving` in meta; force cap still applies.

**Note:** An earlier paste labeled “Palworld” was Windrose; this console sample is the real `pwserver` boot.

## Runtime behaviour (approved)

Shared start-wait loop (LGSM helper today; SteamCMD start path tomorrow):

1. Capture log size/offset at session/PID up.
2. Every few seconds:
   - If process/session dead → **fail**.
   - If ready regex matches (new bytes, or allow_existing when Already online) → **ok**.
   - Update **current phase** from last matching phase pattern in new tail.
   - If no byte growth for `start_stall_secs` → **warn** in job log (once per stall streak) — **except** while phase = `workshop_download` (stall clock frozen; optional informational warn only).
   - If no byte growth for `start_stall_fail_secs` → **fail** — **except** while phase = `workshop_download` (never fail on stall in that phase).
3. On ready timeout with session up + some growth → keep current warn+ok policy unless we change it.
4. **Minecraft:** before wait, count enabled `serverfiles/mods/*.jar` and raise ready/stall to the mod-count tier (table above).
5. **Workshop games:** before wait, count INI Workshop items (+ pending vs disk) and raise ready/stall to the workshop tier; stall-fail suppressed while `workshop_download` phase active.
6. Job log lines: `Still starting… phase=workshop_download +1234 bytes` / `WARNING: start log stalled …` / `ERROR: start log stalled …` / `Minecraft: 87 enabled mods → ready≤480s …` / `Workshop: 24 configured, 3 pending download → ready≤1200s …`.

UI: blinking green status already means starting; phase text stays in job log for v1.

## Approaches (chosen)

1. **Shared lifecycle helpers in `lgsm_control.sh` (+ SteamCMD twin) + meta** — **chosen.**
2–4. Rejected as sole/primary paths (see earlier draft discussion).

## Stop behaviour (approved)

Today (relevant bits):

- MC: console `stop`, wait ~60s, then tmux/java force (`lgsm_stop_direct`).
- PZ: short `quit` (~8s) then force — **risk** if world still saving.
- Other LGSM: timed `./script stop`, then force fallback.
- Windrose/SteamCMD: TERM process group then harder kill — **no save-complete wait**.

Desired:

1. Issue graceful stop (game-specific command already in helpers).
2. Poll log + process: if still **saving** (meta match), keep waiting (extend grace, do not force yet).
3. Only force after `stop_force_secs` (even if still “saving” — hard cap), or sooner if process already dead.
4. Job ok only when offline.

## Restart behaviour (approved)

Sequence (LGSM + SteamCMD + MC):

1. **Stop** with save/grace rules until **verified offline** (no session/PID).
2. If still online after `stop_force_secs` → **restart failed** — do **not** call start.
3. Optional short settle (1–2s) so locks/files release.
4. **Start** with full ready/phase/stall watch (same as manual Start).
5. Config contract: saves already write to disk before restart; restart must be a **cold** stop+start so the new process loads the new config. No in-place reload API in v1.

Job log: `=== Restart: stop ===` … then `=== Restart: start ===`.

## Implementation checklist

1. ~~Decide stall / stop / restart / callers~~ — locked above.
2. ~~Windrose ready~~ — GenlandiaMulty.
3. ~~Palworld ready~~ — `Running Palworld dedicated server on` (`pwserver-console.log`).
4. ~~Write plan~~ — `docs/superpowers/plans/2026-10-01-start-stop-lifecycle.md`.
5. Execute plan (implementation).

## Related code (today)

- Meta: `src/lib/games_meta.json`, `get_start_ready_config()` in `games_meta.pl`
- Wait/stop/restart: `lgsm_start_*`, `lgsm_stop_reliable`, restart chain in `src/scripts/lib/lgsm_control.sh`
- Manual jobs: `game_action_user.sh`, `steamcmd_control_user.sh`
- Monitor auto-restart: `monitor_instance_user.sh` (+ `set_monitor_starting` / `monitor_is_starting`)
- Scheduled restart: `scheduled_restart_user.sh`
- UI blink / poll: manage/mods/workshop + `poll_runtime`
- Prior design: `2026-09-29-start-ready-monitor-design.md`

## Notes from 2026-09-30 chat

- User: wait felt long enough; hang was likely “not fully stopped” / Already-online path (local fix: allow_existing + stall).
- User: green status should **blink while starting**, solid when sure — implemented in session.
- User: harden further with continuous log check + stuck detection + phase keywords in meta; document tonight; implement tomorrow.
- Scope amended: **+ Palworld**.
- Stall fail vs warn: **deferred to morning**.
- User: **Stop** also — servers still saving must not be force-killed too early; cover with same meta/phase approach tomorrow.
- User: **Restart** must properly stop first, then start safely so **changed config** is actually loaded (no start on half-dead / old process).
- User: everything related must **fit modularly** — auto-restart, monitoring, etc. share the same lifecycle (no divergent paths).
- 2026-10-01: decision package approved (stall C, stop grace, restart hard-gate, shared callers); Windrose ready = **GenlandiaMulty** (option B) from provided log.
