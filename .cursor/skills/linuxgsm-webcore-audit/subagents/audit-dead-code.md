# Subagent: Dead Code & Drift

Readonly audit. Find removal candidates and unresolved wiring.

## Search patterns

```bash
# Plan status vs reality
rg -l '^Status: Implementiert' docs/superpowers/plans/
# Then spot-check files mentioned in each plan exist and match

# Orphan scripts (no references)
for f in src/scripts/*.sh; do b=$(basename "$f"); rg -l "$b" src t scripts 2>/dev/null | rg -qv "^$f$" || echo "ORPHAN? $f"; done

# Legacy monitor_all
rg -n 'monitor_all' .

# Unused requires in CGIs (heuristic: require line never referenced)
# Manual review of large .pl files with many subs

# Lang keys defined but never used
# keys in lang/de -> rg key name in src/

# Commented-out blocks >5 lines
rg -n '^#\s*(sub |if |my \$)' src/lib src/*.cgi

# Duplicate action labels hash (jobs.cgi vs jobs.pl)
rg -n 'action_labels|job_action_labels' src/
```

## Check manually

- Plans marked **Implementiert** in `docs/superpowers/plans/` — code + tests actually present?
- Subs in `.pl` only called from removed code paths
- Plans in `docs/superpowers/plans/` marked "Implementiert" but code missing
- Feature flags / TODO older than 2 releases
- Test files referencing deleted functions

## Output

Bullet list severity `suggestion` or `important` if drift causes bugs (e.g. duplicate label maps out of sync).
Prefix dead-code items with `DEAD:` for coordinator ⚪ section.
