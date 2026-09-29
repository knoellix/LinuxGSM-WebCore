# Design: Start-Ready + Monitor-Pause + optional Start-Log

**Date:** 2026-09-29  
**Status:** approved (2026-09-29) — plan: `docs/superpowers/plans/2026-09-29-start-ready-monitor.md`  
**Scope:** All LGSM games with a known ready marker; PZ + MC first; others extend via meta. Shared server control bar for Mods / Workshop (reusable for future games).

## Problem

1. **PZ (and similar):** After Start, the tmux session is up long before the game is joinable. Workshop downloads (`DownloadPending` / `download X/Y`) and asset/world load can take minutes. WebCore monitor resumes immediately and may treat a slow/unstable mid-boot as offline → false auto-restart.
2. **Start UX:** Start/stop/restart are silent jobs (banner only). Operators cannot watch workshop/mod load without opening the console monitor manually. When watching, they want poll-based tail — not full-page reloads.
3. **Control bar duplication:** Mods and Workshop (and later other games) need the same Start/Stop/Restart/Log strip — must be one helper, not copy-paste.

## Goals

| Always on | Optional (toggle) |
|---|---|
| Wait for game **ready marker** before start job = success | Auto-open **embedded start log** after Start/Restart (Manage, Workshop, Mods) |
| **Pause WebCore monitor** until ready (or soft timeout) | — |
| Afterwards: **LGSM monitor as today** (session / `querymode=1`) | — |
| Shared **Start / Stop / Restart / Log** control bar | Same start-log toggle wherever Start/Restart is pressed |

Non-goals:

- Replacing LGSM monitor in steady state
- Dedicated Workshop “Update” button (PZ updates on server start)
- Query/GameDig readiness for PZ (keep `querymode=1`)
- Filtering console noise (AnimSets etc.) in the UI
- Dedicated inventory scanner for `required mod "…" not found` (runtime message — visible in start-log)

## Decisions (approved in brainstorm)

1. **Ready marker PZ:** line containing `*** SERVER STARTED ****` (exact asterisks as in console).
2. **Ready marker MC:** existing `Done (…)!` in `latest.log` (already implemented for start wait).
3. **Monitor during start:** **always** pause until ready marker (or timeout) — not behind the UI toggle.
4. **Start log UI:** **switchable** — when off, pages stay as today (silent banner); when on, after Start/Restart an embedded console poll panel opens on the **current** page.
5. **Steady state:** LGSM `./script monitor` remains the authority once ready.
6. **Control bar:** shared modular helper — Start / Stop / **Restart** / Log (+ back). Used by `mods.cgi` and `workshop.cgi` (Restart also added on MC mods).
7. **Workshop CGI:** stay game-pluggable (PZ first); control bar and page shell must not hard-code PZ-only chrome so other Steam workshop games can reuse later.
8. **`required mod "…" not found`:** PZ runtime console during load (not our subscribe script). Operators see it in the start-log / live log. No separate Workshop inventory warn in this feature.
9. **AnimSets / actiongroups `NoSuchFileException`:** harmless PZ scan noise — **do not filter** in v1; operators ignore it.
10. **Workshop PZ column:** show require when present (+ passt/unpassend); empty → label **keine Angabe**; ops assume OK on current server until start proves otherwise (do not print “neueste”).

## Ready-marker registry

Extend game meta (e.g. `games_meta.json` / local override) with optional fields:

```text
start_ready_log:   path hint or candidate key (console | latest_log | …)
start_ready_regex: Perl/compatible pattern (multiline off, one line)
start_ready_secs:  max wait (default e.g. 900 for heavy games, 180 light)
```

Initial entries:

| Game | Log source | Pattern | Default timeout |
|---|---|---|---|
| Project Zomboid | LGSM console (`log/console/${script}-console.log`) | `\*\*\* SERVER STARTED \*\*\*\*` | 900s |
| Minecraft | `serverfiles/logs/latest.log` (existing helper) | `Done \(` … (existing) | 900s |
| Others | none → session-only (current behaviour) until meta filled | — | — |

Phase hints (UI only, not success criteria): e.g. `Workshop: download`, `LOADING ASSETS`, `Loading world…`.

## Start job behaviour

1. LGSM start CLI + wait until session/tmux up (as today).
2. If meta has `start_ready_regex`: poll log from byte offset at session-up until match or `start_ready_secs`.
3. Match → write job `status=ok`, mark instance **ready**, resume monitor eligibility.
4. Timeout with session still up → `status=ok` with **warning** in job log (same spirit as MC “no Done but session up”), resume monitor after timeout with warning (avoid permanent pause).
5. Session dies before ready → `status=failed`.

Minecraft: keep current `lgsm_start_minecraft` Done-wait; unify under the same meta/registry API where practical.

Restart jobs use the same ready-wait + monitor pause as Start.

## Monitor hardening (always)

After Start/Restart dispatch:

1. Set monitor state to **starting** / pause WebCore auto-restart path (extend existing `set_monitor_resume_after_start` / pause helpers).
2. Cron tick: if state is starting and ready marker not yet seen (and within grace), **skip** restart recovery — log “still starting”.
3. When ready (marker or start-job timeout path above): clear starting → normal LGSM monitor path.
4. Manual Stop: keep existing pause/`disabled` behaviour.
5. Cap `MAX_RESTARTS` / window unchanged for true post-ready crashes.

Do **not** lengthen only WAIT_TRIES as the primary fix; pause-until-ready is the fix. PZ’s longer wait remains a secondary safety net.

## Shared server control bar (modular)

Extract a small UI helper (e.g. in `lib/` or shared CGI include) used by **Mods**, **Workshop**, and optionally Manage fragments:

```text
[Instance · online/offline]  [Start] [Stop] [Restart] [Log]  [← Manage]
```

Requirements:

- Same ACL / readonly gating as Manage (`user_can_operate`, `user_is_readonly`).
- Dispatch via existing job paths (start / stop / restart); after dispatch stay on caller page when start-log toggle is on, else existing redirect/banner behaviour.
- **Restart** on both `mods.cgi` and `workshop.cgi` (MC mods gains Restart in the same change).
- Parameters: `cgi` name (form action), `instance_id`, optional extra status parts (loader / PZ version), return target.
- No game-specific business logic inside the helper — only chrome + action buttons.

### Workshop page shell (game-pluggable)

`workshop.cgi` remains the Steam Workshop UI entry. PZ inventory/INI (`WorkshopItems` / `Mods=`) stays behind `pz_workshop.pl`. Future games: meta flag (e.g. `workshop_ui=1` + adapter lib) reuses the **same control bar + page chrome**; game body stays adapter-specific. This feature must not bake PZ-only assumptions into the control-bar helper.

Same start-log toggle: if on, Start/Restart from workshop embeds the start-log panel on **workshop.cgi**.

After workshop INI changes, keep existing restart hint; control bar makes stop → change → start/restart (+ watch) practical without leaving the page.

## Workshop inventory: PZ-Version column

Add a dedicated column (not buried in the Mods cell):

| `mod.info` require / pzversion | Display |
|---|---|
| Set (e.g. `42.12`) | `PZ 42.12` + badge **passt** / **unpassend** vs detected server version |
| Empty / missing | **keine Angabe** |

Optional: keep Mod release `v…` (`modversion`) in the Mods column or a small sub-line — not mixed into the PZ column.

**Assumption (ops, not a false certainty in the UI):** when require is empty we have no author pin; treat as usable on the current server (same as today’s unconstrained auto-enable for single-ID items / no mismatched siblings). Real incompatibility surfaces only at **server start** (console / start-log, e.g. `required mod "…" not found`). Do **not** label empty require as “neueste” in the UI — that misleads on multi-variant packs (AluminumBat empty vs AluminumBat12 `42.12`).

Auto-enable rules unchanged: prefer matching require; empty alone OK; empty beside a versioned sibling → matching sibling only.

## Start-log UI (toggle)

**Config key** (module config, Integrations or Manage preference):

- `manage_show_start_log` (bool, default **0**/off)

When **off:**

- Start/Restart remains silent redirect/banner (current).
- Backend ready-wait + monitor pause still run.

When **on:**

- After Start/Restart from **Manage, Workshop, or Mods**, the **current page** shows an **embedded** panel: console tail via existing `poll_monitor` / server_log poll (≈3s), no full page reload.
- Panel title e.g. “Start-Log”; optional phase line derived from last matching hint.
- When ready marker detected (poll side or job flash): banner “Server gestartet”; panel may collapse or stay open until dismissed.
- Runtime warnings such as `required mod "…" not found` appear in this tail (no extra parser required for v1).
- Toggle change does not require restart of a running server.

Implementation note: prefer embedding on the page that launched Start/Restart over forcing `job_live.cgi`, so operators stay in context. Job output can still record ready-wait progress for history.

## Success criteria

- PZ start with workshop downloads does not trigger WebCore monitor_restart before `*** SERVER STARTED ****`.
- Start/Restart job does not claim unqualified success on session-only for games with a ready marker (warning path if timeout).
- With toggle off, Manage/Mods/Workshop UX unchanged aside from any status text if we surface “starting…”.
- With toggle on, Start/Restart opens embedded log with poll updates only.
- Mods and Workshop share one control-bar helper; both expose Start/Stop/**Restart**/Log.
- MC behaviour remains green; PZ gains parity via marker.
- Workshop page chrome stays reusable for non-PZ workshop games later.

## Checklist — covered vs deferred

| Item | Status |
|---|---|
| Ready marker PZ `*** SERVER STARTED ****` | in scope |
| Ready marker MC `Done` (existing) | unify under meta |
| Monitor pause until ready (always) | in scope |
| Steady state = LGSM monitor | confirmed |
| Start-log auto-open toggle (default off) | in scope |
| Embedded poll log on Manage / Workshop / Mods | in scope |
| Shared control-bar helper (modular) | **in scope** |
| Start / Stop / **Restart** / Log on Mods + Workshop | **in scope** (Restart also for MC) |
| Workshop shell reusable for other games | architecture constraint |
| Workshop inventory: dedicated **PZ-Version** column | **in scope** (see below) |
| Timeout warning if no marker but session up | in scope |
| `required mod "…" not found` | via start-log / live log only (no inventory UI) |
| Filter AnimSets console noise | **out** (harmless; ignore) |
| Per-instance start-log toggle | later (v1 module-wide) |
| SteamCMD update button | out (PZ updates on start) |

## Out of scope / later

- Per-instance start-log toggle (v1 = module-wide).
- Auto-scroll filter for AnimSets / icon / `libjsig` noise.
- SteamCMD pre-download before start (PZ already updates on boot).
- Query-based joinability checks.
- Parsing `required mod "…" not found` into a Workshop inventory warning row.
- Non-PZ workshop adapters (shell must allow them; adapters themselves later).

## Related

- `docs/superpowers/specs/2026-05-03-monitor-design.md` (steady-state monitor)
- `docs/superpowers/specs/2026-08-15-mc-mods-page-design.md` (control bar pattern — extended with Restart + shared helper)
- MC Done wait: `src/scripts/lib/lgsm_control.sh` (`lgsm_start_minecraft`, `lgsm_mc_log_has_done_after`)
- Console poll: `server_log.pl` / `live_log.pl` / manage `action=monitor`
- PZ workshop: `src/workshop.cgi`, `src/lib/pz_workshop.pl`
