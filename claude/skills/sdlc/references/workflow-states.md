# Workflow states — emoji semantics and transitions

Shared vocabulary for every SDLC file: `1_elicitation.md`, `2_architecture.md`,
`3_conception.md`, `4_tests.md`, `STATE.md`, `SDLC_PLAN.md`.

## States

| Emoji | Short code | Meaning | When to use |
|---|---|---|---|
| ⬜ | TODO | To do | Planned, not started |
| ⏳ | WAIT | Waiting | Held by an unresolved dependency |
| 🔄 | WIP | In progress | Work started, not finished |
| ✅ | DONE | Done / PASS | Tests green, AQ Gate ✅ |
| ❌ | FAIL | Failed | Tests red, to investigate |
| 🔁 | RETRY | In rework | retries < max_retry_per_task, fix in progress |
| 🚫 | BLOCKED | Blocked | retries ≥ max OR serious unrecoverable defect |
| 🚀 | RELEASED | Released | Version released, frozen for archive |

## Transition diagram

```
                                 ┌────────────┐
                                 │            ▼
        ⬜ ──▶ 🔄 ──▶ ✅                  ❌  ◀────┐
              │       │                  │        │
              │       └──▶ 🚀            │        │
              ▼                          ▼        │
              ⏳ (dependency)            🔁 ──────┤ (retries < max)
              │                          │
              └──▶ 🔄 (dependency ✅)    └──▶ 🚫 (retries ≥ max)
                                              │
                                              └──▶ 🔄 (via /sdlc:fix)
```

## Transition rules

### ⬜ → 🔄

Work starts. The agent updates it automatically at the start of a P### or a phase.

### ⬜ → ⏳

The P### depends on another that is not yet ✅. A correctly computed wave should not produce this;
if it happens, wait for the previous wave.

### 🔄 → ✅

All associated T### are ✅, the code passes the linter, and the local AQ check on this P### is OK.
Run the test command and quote its result before setting ✅.

### 🔄 → ❌

Execution error that cannot be recovered immediately (e.g. import error, crashing test).
Needs a diagnosis.

### ❌ → 🔁

The agent attempts a fix (retries++). Limit = `max_retry_per_task`.

### 🔁 → ✅

Fix succeeded after a retry. Status goes back to ✅; retries stay in the logs for observability.

### 🔁 → 🚫

The fix failed beyond `max_retry_per_task`. Before marking 🚫, state the root-cause hypothesis and
the evidence in the task notes, then escalate to the user (in `--auto-approve`, the run stops
cleanly).

### 🚫 → 🔄

Via `/sdlc:fix <P###>`. Resets the retry counter and tries a new approach (usually with richer
context).

### ✅ → 🚀

At the final `/sdlc:report` for a release. Frozen for archive.

### ✅ → 🔄

Exceptional reversal: if another P### causes a regression on a ✅ P###, its status goes back to
🔄 so it is verified again.

## Short codes (for non-Unicode environments)

For environments without emoji support (e.g. some CI/CD), the short codes are accepted as well:

```
[T] = TODO
[W] = WAIT
[I] = WIP
[D] = DONE
[F] = FAIL
[R] = RETRY
[B] = BLOCKED
[X] = RELEASED
```

`check_sdlc.py` treats both `🚫` and `[B]` as an "active blocker". The other short codes are not
checked and can be used freely.

## Writing convention

Prefix each item line or status table cell with the emoji. Examples:

```markdown
| P001 | parse_csv | 1 | A001 | ⬜ |
| P002 | sum_total | 2 | A002 | 🔄 |
| P003 | export_json | 3 | A003 | 🔁 |
```

```markdown
#### P004:A004 — Input validation
- **Status**: ✅
- (...)
```

Keep the `**Status**` marker in English whatever the project's `output_language`, so the scripts
can parse it.

## v2 compatibility

The emojis are the same as in SDLCv2; existing statuses need no migration. Scripts that parse
statuses also accept the legacy French marker `**Statut**` (see the pattern below).

## Reading statuses programmatically

Scripts treat these emojis as **canonical** in .md files. Do not infer state from other
heuristics (comments, modification dates, etc.); the emoji alone is authoritative.

```python
import re

STATUS_PATTERN = re.compile(r"\*\*(?:Status|Statut)\*\*\s*:\s*(⬜|⏳|🔄|✅|❌|🔁|🚫|🚀)")
# or:
TABLE_STATUS_PATTERN = re.compile(r"\|\s*(P\d{3})\s*\|.*\|\s*(⬜|⏳|🔄|✅|❌|🔁|🚫|🚀)\s*\|")
```
