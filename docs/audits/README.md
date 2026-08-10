# Audit reports

Structured output from the **linuxgsm-webcore-audit** skill (agent: `linuxgsm-auditor`).

## Naming

```
docs/audits/YYYY-MM-DD-<scope>.md
```

Examples: `2026-07-11-full.md`, `2026-07-11-changed.md`, `2026-07-11-release.md`

## When to write

After every **full**, **release**, or user-requested audit — not after quick-scan alone.

## Template

Copy [REPORT-TEMPLATE.md](REPORT-TEMPLATE.md) or use the template in
`.cursor/skills/linuxgsm-webcore-audit/SKILL.md` § Schritt 4.

## Trend

Before writing a new report, skim the latest file in this directory:

- Mark findings fixed since last audit (optional § **Since last audit**)
- Do not re-list resolved items as open unless regressed
