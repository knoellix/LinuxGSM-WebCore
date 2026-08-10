# Contributing to LinuxGSM-WebCore

Thanks for helping. This project is run by a single maintainer with no fixed roadmap — clear, small contributions are easiest to merge.

## Before you start

1. Read the [Code of Conduct](CODE_OF_CONDUCT.md).
2. Prefer an [issue](https://github.com/knoellix/LinuxGSM-WebCore/issues) before large changes.
3. Use the issue templates for **language/UI strings**, **game support**, or **bugs**.

## Development

```bash
bash scripts/verify.sh    # required before claiming done
bash scripts/build.sh     # produces dist/*.wbm
```

- UI strings: German + English in `src/lang/de` and `src/lang/en` (same keys).
- Code and comments: English.
- Follow existing patterns in `.cursor/rules/` / `AGENTS.md` (security isolation, verified success feedback, user-native workers).
- Do not commit secrets (API keys, passwords, live host configs).

## Pull requests

- Keep PRs focused (one topic).
- Describe *why*, not only *what*.
- Note which games you tested (or that you only tested syntax/`verify.sh`).
- Expect review to be asynchronous — there is no SLA.

## Wiki

User documentation lives in the [GitHub Wiki](https://github.com/knoellix/LinuxGSM-WebCore/wiki) (DE + EN, NativMix-style). Wiki edits via PR to the `*.wiki` clone or GitHub UI are welcome if they match reality (mark untested games clearly).
