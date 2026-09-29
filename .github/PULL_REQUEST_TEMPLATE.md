## Description

<!-- Problem solved and change made -->

## Checklist

- [ ] `for t in bundle/scripts/tests/test-*.sh; do bash "$t" || exit 1; done` run from the repository root, exit code **0**.
- [ ] `PYTHONUTF8=1 python -m pytest -q claude/skills` run from the repository root, exit code **0**.
- [ ] PowerShell/bash parity kept if a `.ps1`/`.sh` script is added or changed (same arguments, same exit codes, same effects).
- [ ] Naming conventions followed (see `CONTRIBUTING.md` section 2: one source file per inventory entry, `sdlc-` prefix, etc.).
- [ ] Instructions for Claude follow `CONTRIBUTING.md` section 3.1; documentation written in English.
- [ ] One PR = one logical change (no unrelated topics mixed).
