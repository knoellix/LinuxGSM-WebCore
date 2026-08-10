# Subagent: Tests & Lang Parity

Readonly audit. Focus: `t/`, `src/lang/`, `t/stubs.pl`.

## Read first

- `.cursor/rules/testing-perl.mdc`
- `.cursor/rules/project-core.mdc` (de+en lang keys)

## Automated checks (run first)

```bash
bash .cursor/skills/linuxgsm-webcore-audit/scripts/lang-parity.sh
bash scripts/verify.sh
```

For release scope also: `bash scripts/verify-full.sh`

## Search patterns

```bash
# Test plan mismatches (heuristic)
rg -n 'use Test::More tests =>' t/

# New lang keys in one file only — use lang-parity.sh output

# SKIP/skip misuse inside subtest
rg -n 'skip\s' t/ | rg -v 'SKIP:'

# Real /home in job tests
rg -n "'/home/" t/ | rg -v '_jobs_home_base|fake_home'

# Missing stubs for CGI-only subs
rg -n '^sub ' t/stubs.pl
```

## Check manually

- New save/ACL/security flows have regression test in `t/`?
- Security/provisioning changes: `test_security_guards.pl`, `test_provisioning_flow.pl` covered?
- `%text` in stubs complete for tested keys?
- Shell tests in `scripts/verify.sh` critical list when adding new `t/test_*.sh`
- Test count in `use Test::More tests => N` matches actual ok/plan

## Output

Bullet list. `critical` = verify red or missing security test; `important` = lang parity gap or wrong test plan.
