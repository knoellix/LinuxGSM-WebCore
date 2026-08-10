---
name: linuxgsm-webcore-audit
description: >-
  Strukturiertes Code-Audit für LinuxGSM-WebCore: Projektregeln (.cursor/rules/),
  Security/su-Grenze, Tests/Lang-Parität, MC/Config, tote Code-Pfade, Effizienz.
  Parallele Subagents; Reports nach docs/audits/. Modi full/changed/release.
  Verwenden bei audit, regel-check, release-check, toter code, regelmässig prüfen.
disable-model-invocation: true
---

# LinuxGSM-WebCore Audit Koordinator

Wiederkehrendes Qualitäts-Audit. Ziel: **Regeln einhalten**, **toten Code entfernen**, **falsch aufgelöste Stellen fixen**, **Effizienz verbessern** — mit parallelen Subagents.

## Wann welches Tool?

| Situation | Tool |
|-----------|------|
| Regelmässig / full repo / release | **Dieser Skill** + Agent `linuxgsm-auditor` |
| Nach einem Feature-Chunk (kleiner Diff) | Agent `linuxgsm-reviewer` |
| Vor Merge, diff-basiert | Bugbot / Security-Review Skills |

---

## Schritt 0: Modus & Scope

| Modus | Wann | Baseline | Subagents |
|-------|------|----------|-----------|
| `full` | „alles prüfen“ | verify + lang-parity | alle 8 |
| `changed` | nach Feature/Fix | verify + lang-parity | 5–8 (MC/Config nur wenn Pfade betroffen) |
| `area` | z.B. „Schedule“ | verify | passende Subagents |
| **`release`** | vor `.wbm` / Tag | **verify-full** + lang-parity + build smoke | **alle 8** |

Scope-Pfade bei `changed`:

```bash
git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null
git diff --name-only "$(git merge-base HEAD main 2>/dev/null || echo HEAD~20)"...HEAD
```

Falls unklar: `changed` wenn Branch-Commits existieren, sonst `full`.

**Fix-Modus:** User will nur Report → Schritte 1–4 + Report speichern. Fix → Schritt 5.

---

## Schritt 1: Baseline (immer)

**Standard** (`full`, `changed`, `area`):

```bash
bash .cursor/skills/linuxgsm-webcore-audit/scripts/lang-parity.sh
bash scripts/verify.sh
```

**Release** (`release`):

```bash
bash .cursor/skills/linuxgsm-webcore-audit/scripts/lang-parity.sh
bash scripts/verify-full.sh
```

- lang-parity FAIL → **🟠** (fehlende de/en Keys)
- verify rot → **🔴** Blocker im Report
- verify-full rot bei release → **🔴** kein Release

Optional Mini-Scan: `bash .cursor/skills/linuxgsm-webcore-audit/scripts/quick-scan.sh`

---

## Schritt 2: Regeln laden

Kurz lesen:

- `.cursor/rules/project-core.mdc`
- `.cursor/rules/security-isolation.mdc`
- `.cursor/rules/no-blind-success-feedback.mdc`
- `.cursor/rules/webmin-cgi.mdc`
- `.cursor/rules/workers-shell.mdc`
- `.cursor/rules/instance-jobs.mdc`
- `.cursor/rules/testing-perl.mdc`
- `.cursor/rules/lgsm-games-config.mdc`
- `.cursor/rules/minecraft-mods.mdc` (wenn MC im Scope)
- `AGENTS.md`

Referenz: [checklist.md](checklist.md) · [allowed-patterns.md](allowed-patterns.md)

**Vor Report:** neuesten Eintrag in `docs/audits/` lesen → § „Since last audit“.

---

## Schritt 3: Subagents parallel

**Eine Message, mehrere Task-Calls parallel.** Repo-Pfad = **Workspace-Root** (nicht hardcoden).

| Subagent | Briefing | Fokus |
|----------|----------|-------|
| Security | [audit-security.md](subagents/audit-security.md) | su, apt, escape, SFTP |
| CGI & Feedback | [audit-cgi-feedback.md](subagents/audit-cgi-feedback.md) | Flash, `$1`, redirect+exit |
| Workers & Jobs | [audit-workers-jobs.md](subagents/audit-workers-jobs.md) | dispatch, job_live, cron |
| **Tests & Lang** | [audit-tests.md](subagents/audit-tests.md) | TAP plan, stubs, de/en |
| **Minecraft** | [audit-minecraft.md](subagents/audit-minecraft.md) | modpack worker, secrets, errors |
| **Config/Games** | [audit-config-games.md](subagents/audit-config-games.md) | Palworld INI, games_meta |
| Dead Code | [audit-dead-code.md](subagents/audit-dead-code.md) | orphan, plan drift |
| Efficiency | [audit-efficiency.md](subagents/audit-efficiency.md) | Duplikate, sync→async |

### Task-Prompt-Vorlage

```
Full Repository Path: <workspace-root — pwd from repo root>
Scope: <full|changed|area|release>
Scope paths: <git diff names or "all">
Read briefing: .cursor/skills/linuxgsm-webcore-audit/subagents/<file>.md
Read: .cursor/skills/linuxgsm-webcore-audit/allowed-patterns.md

Return ONLY findings as bullets:
- Severity: critical|important|suggestion
- Path:line — problem — rule — suggested fix
Max 25 findings. Readonly — do not modify files.
```

**Modi → Subagents:**

- `full` / `release`: **alle 8**
- `changed`: Security + CGI + Workers + Tests + Dead Code; + Minecraft wenn `mc_|modpack` in diff; + Config wenn `config_editor|games_meta` in diff
- `security-only`: Security + Workers
- `post-feature`: CGI + Workers + Tests + Dead Code

Subagent: `explore`, `readonly: true`.

---

## Schritt 4: Report zusammenführen & speichern

Template: [docs/audits/REPORT-TEMPLATE.md](../../../docs/audits/REPORT-TEMPLATE.md)

**Pflicht:** Report-Datei anlegen:

```
docs/audits/YYYY-MM-DD-<scope>.md
```

Inhalt: Chat-Zusammenfassung **und** persistierte Datei (gleicher Inhalt).

Felder nicht vergessen:

- Branch + `git rev-parse --short HEAD`
- Baseline: verify / verify-full / lang-parity
- § **Since last audit** (Diff zum vorherigen Report in `docs/audits/`)
- Zähler: X kritisch · Y wichtig · …

Abschlussfrage: „Soll ich mit 🔴 anfangen?“

---

## Schritt 5: Fix-Pass (nach Freigabe)

🔴 → 🟠 → 🟡 → ⚪ · minimaler Diff · `perl -c` / `bash -n`

Abschluss:

- Normal: `bash scripts/verify.sh`
- Nach release-Fixes: `bash scripts/verify-full.sh`
- Optional: Bugbot auf uncommitted changes

**Commits:** nur auf Anfrage.

---

## Schnell-Scan (ohne Subagents)

```bash
bash .cursor/skills/linuxgsm-webcore-audit/scripts/lang-parity.sh
bash .cursor/skills/linuxgsm-webcore-audit/scripts/quick-scan.sh
```

Kein Report in `docs/audits/` nötig.

---

## Rhythmus

| Intervall | Modus |
|-----------|-------|
| Wöchentlich | `changed` |
| Monatlich | `full` |
| Vor Release | **`release`** |
| Nach grossem Feature | `full` oder `area` |
