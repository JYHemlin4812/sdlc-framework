# Code Lock

Modify a source file only when all three conditions hold:

1. **A P### exists** in `3_conception.md` covering what the code will do.
2. **That P### has status ✅** — it has been planned, its parent chain is correct and its
   `**wave**` field is consistent.
3. **`scripts/check_sdlc.py` returns exit code 0** — the full E→A→P→T chain is intact.

If any condition stops holding, the lock re-engages immediately.

## Why

Without Code Lock, an agent in `--auto-approve` can decide to "improve something along the way"
and create orphan code — the kind of drift that makes agentic workflows ungovernable. Code Lock
enforces the structural discipline that replaces human supervision, and keeps every change
traceable to a requirement.

## The one exception

Developing **the SDLC framework itself** disables Code Lock via `code_lock_enabled: false` in
`sdlc-config.json`; otherwise the system could not be bootstrapped. Adopting SDLC on an existing
codebase is handled the same way (see `documentation-tiers.md`, "Adopting SDLC on an existing
project").

For every other project, leave `code_lock_enabled: true`.

## A bug found while coding

You are writing `P012:A005` and find a bug in a function covered by `P003:A001` (already ✅).

Record it, do not fix it on the side. Procedure:

1. **Stop** work on that code; the lock re-engages for `P003`.
2. **Record** the bug as a new E### in `1_elicitation.md`
   (e.g. `E045 — Crash on empty input in parse_csv`).
3. **Re-plan**: `/sdlc:plan` produces an `A###:E045` and a `P###:A<new>`.
4. **Validate**: `/sdlc:gate` must pass with the new chain.
5. **Resume** P012, or take the new P### first, by priority.

This is slow on purpose: it keeps rabbit holes from eating hours and keeps the fix traceable.

## Failing tests

If T###:Pxxx fails after Pxxx is implemented:

- Pxxx status → 🔁 (retry < max_retry_per_task)
- Code Lock stays active on the **other** files (covered by other P###)
- You may modify the files covered by Pxxx to fix it
- If retry ≥ max → 🚫, escalate

## Refactoring without behavior change

Acceptable within the P### that already covers those files (status goes back to 🔄, then ✅ once
the tests are green). If the refactoring changes interfaces, it needs a new A### + P###.

## Programmatic check

Before any write, a subagent checks:

```python
from pathlib import Path
import re

def can_modify(file_path: Path, pid: str, conception_md: Path) -> bool:
    content = conception_md.read_text(encoding="utf-8")
    # Find the #### Pxxx section with a ✅ status
    pattern = re.compile(rf"####\s+{pid}.*?(?=####|\Z)", re.DOTALL)
    section = pattern.search(content)
    if not section:
        return False
    if "✅" not in section.group(0):
        return False
    # Check that file_path appears in "Target files" (legacy: "Fichiers cibles")
    return str(file_path) in section.group(0)
```

A subagent that writes without this check is treated as failing and escalated.
