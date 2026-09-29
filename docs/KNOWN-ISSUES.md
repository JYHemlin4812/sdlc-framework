# Known issues (at the time of the SP1 baseline)

> Historical record (SP1 baseline, 2026-07-01). Fixes were planned for SP2; see
> [`CHANGELOG.md`](../CHANGELOG.md) for later releases and `bundle/docs/KNOWN-ISSUES.md` for
> current installer issues.

These defects were found by the adversarial review of the SP1 scoping. They were **captured as
is** in the snapshot (the goal of SP1 was to freeze the existing state, not to repair it).
**Repair planned in SP2.**

## Broken installer / verifier (`bundle/scripts/`)

1. **`install.ps1` knew only 8 skills** (hard-coded `$SKILLS` list), so it did **not** install
   `sdlc-receive-review` or `sdlc-verify`. These 2 skills existed only in `~/.claude` (captured
   here under `claude/skills/`), so a restore through this installer would **lose** them.
2. **`install.ps1` read agents non-recursively** and **read commands from the embedded (stale)
   bundle** instead of the canonical top-level versions, so a restore would install 0 agents and
   4 outdated commands.
3. **`verify.ps1` was a false green**: it tested only 4 skills, commands by mere presence, and 0
   agents, so it could return exit 0 on a state that could not be restored.
4. **`check_sdlc.py` existed in 2 versions**: v3.0 (canonical, `claude/skills/sdlc/scripts/`,
   332 lines) and an obsolete v2.0 (outside the bundle, **not captured** here). The baseline kept
   **v3.0**.

## Consequence for SP1

Restorability of the baseline was proven by **hash comparison** (`claude/` vs `~/.claude`),
**not** by an `install.ps1`/`verify.ps1` round trip. Repairing the installer and verifier (plus
bidirectional `capture`/`restore` scripts with overwrite safeguards) was the core of **SP2**.
