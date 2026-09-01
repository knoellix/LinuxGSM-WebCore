# MC-Version & Modloader upgraden (Server)

> **Status:** Geplant — Umsetzungsplan: [`2026-09-01-mc-version-loader-upgrade-implementation.md`](2026-09-01-mc-version-loader-upgrade-implementation.md)  
> **Anlass:** 2026-09-01 — Pepega/NeoForge 26.1.2 läuft; später MC-Patch und Loader-Version sollen gezielt hochziehbar sein, ohne jedes Mal blind „Neu installieren“.  
> **Verwandt:** `2026-08-28-mc-mod-dependencies.md`, `2026-08-15-mc-versions-modular.md`

## Problem heute

| Was | Ist-Zustand |
|-----|-------------|
| **MC-Version wechseln** | Kein dedizierter „Upgrade“-Flow. Profil (`mc_version`) setzt man indirekt über Wizard/Profil oder Pack-Adopt; danach fehlt ein geführter Re-Apply (Java + Loader + LGSM). |
| **Loader-Version wechseln** | `mc_loader_install_user.sh` existiert (Setup), aber **kein** UI-„Loader auf X updaten“ mit Version-Picker und Verifikation. |
| **Alles neu** | `manage.cgi` → `reinstall` + `mc_reinstall_user.sh` (modded): wipe `serverfiles/`, Java + Loader-Kette — **destruktiv**, Mods weg bis Backup/Modpack. |
| **Version-Liste** | Plan `mc-versions-modular` (Mojang live + Cache) — noch nicht der Upgrade-Workflow. |

Für Betrieb reicht oft: **neue MC-Minor** oder **neuer NeoForge-Build** — ohne komplette Welt/Mods zu verlieren. Das brauchen wir explizit.

## Ziel (Produkt)

**Neue Aktionen** auf `manage.cgi` (nur wenn `mc_mod_ui_ready` / Profil da), jeweils als **Job** → `job_live.cgi`, Erfolg nur bei `status=ok`:

1. **Minecraft-Version upgraden**  
   - Ziel-`mc_version` aus Live-Liste (≥ aktuell, gleiche Loader-Familie).  
   - Vorab: Warnung Mod-Kompatibilität (kein Blind-OK).  
   - Kette: Profil speichern → Java-Major prüfen/sync → Loader für neue MC resolve/install → LGSM `update`/`validate` wo sinnvoll → Start-Readiness (optional `Done` wait wie `lgsm_control`).

2. **Modloader upgraden** (NeoForge/Forge/Fabric/Paper…)  
   - Ziel `loader_version` (gefiltert wie Wizard: NeoForge-Prefix für MC).  
   - **Ohne** wipe `serverfiles/` wenn nur Loader-Binary/JARs wechseln.  
   - `run.sh` / `executable` / Java-Pin erneut anwenden (`mc_java_env_apply`).

3. **Kombiniert** (MC + Loader) — ein Job mit Phasen im Live-Log, Reihenfolge: MC/Java → Loader → Verify.

**Nicht-Ziel v1:** automatisches Mod-Update aller `.jar` auf neue MC (separat / Modpack / manuell).

## UX (Skizze)

- Block **„Minecraft & Loader“** auf `manage.cgi`:
  - Aktuell: `mc_version`, `loader`, `loader_version`, `java_major`
  - Dropdown **Neue MC-Version** + Button „Upgrade“ (nicht `btn-danger`)
  - Dropdown **Neue Loader-Version** + Button „Loader updaten“
  - Hinweis: Server stoppen; Backup empfohlen; Mods können brechen
- Flash + read-back nach Profil-Write (`no-blind-success-feedback.mdc`)
- Lang keys DE/EN: `mc_upgrade_*`, `mc_loader_upgrade_*`, `mc_upgrade_mod_warning`

## Technik / bestehende Bausteine

| Baustein | Nutzen |
|----------|--------|
| `mc_profile.pl` | Profil lesen/schreiben, `java_major` sync |
| `mc_loader.pl` | `mc_resolve_loader_install`, NeoForge-Filter, Mojang-Versionen (wenn modular live) |
| `mc_java_install_user.sh` | Java wenn Major wechselt |
| `mc_loader_install_user.sh` | Loader install/update |
| `mc_reinstall_user.sh` | Nur wenn User explizit „alles neu“ — **nicht** Default für Upgrade |
| `game_action_user.sh` / `lgsm_control.sh` | Stop vor Upgrade, optional Start nach OK |
| `mc_compat.json` + local | Loader erlaubt / game→loader Map |

**Neu (voraussichtlich):**

- `src/scripts/mc_upgrade_user.sh` — orchestriert Phasen, schreibt Job-Log, setzt `status`
- `src/lib/mc_upgrade.pl` — Plan bauen (was muss laufen?), Preflight (Server offline, Disk, Profile valid)
- `manage.cgi` — Actions `mc_upgrade_version`, `mc_upgrade_loader` (oder eine `mc_upgrade` mit `phase`)
- `t/test_mc_upgrade.pl` — Preflight + Plan-Logik ohne echten Download

## Preflight / Safety

- Server **muss offline** (verified stop, nicht nur „Job gestartet“).
- Kein Upgrade wenn anderer MC-Job läuft (`_manage_redirect_if_job_running`).
- Profil-Ziel validieren (`validate` gegen `mc_compat` + Loader-Filter).
- Wenn `loader` wechseln würde (Forge→NeoForge): **blockieren** in v1 — nur Version bump innerhalb gleichem Loader.
- Nach Upgrade: **kein** Success-Banner ohne Worker-`ok` + optional Read-back Profil/Loader-Datei auf Disk.

## Mod-/Pack-Hinweis

Upgrade ≠ Mods compatible. UI muss klar sagen:

- Mods bleiben auf Disk, können beim Start crashen (wie Farming for Blockheads/Balm).
- Später Verknüpfung mit Dependency-Check (`2026-08-28-mc-mod-dependencies.md`): „X Mods haben keine Version für Ziel-MC“ (read-only Warnliste).

## Implementierungs-Reihenfolge (Vorschlag)

1. **Loader-only upgrade** (kleiner Risiko-Radius, Pepega: NeoForge 26.1.2.x → neuer Build)  
2. **MC version bump** (26.1.2 → 26.1.x / 26.2 wenn Loader-API passt)  
3. Live Mojang-Liste einbinden falls `mc-versions-modular` noch offen  
4. Mod-Kompat-Warnung (Modrinth project versions count) — optional Phase 2  

## Verify

```bash
perl t/test_mc_upgrade.pl   # neu
bash scripts/verify.sh
```

Manuell: Instanz stop → Loader upgrade Job → `latest.log` NeoForge-Version → Start → Welt join.

## Offene Fragen (beim Umsetzen klären)

- Paper: nur Build-Upgrade oder auch MC-Minor über Paper-API?
- LGSM `mcserver update` nach Loader-Wechsel automatisch oder nur unsere Installer?
- Backup-Hinweis / optional Snapshot-Job vor Upgrade?
