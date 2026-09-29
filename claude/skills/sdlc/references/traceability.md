# E → A → P → T traceability

Rules of the SDLC traceability backbone, inherited from v2 unchanged.

## Schema

```
E### (root, no parent)              ← business requirement
  └─ A###:E### (architecture)        ← decision that satisfies the E###
       └─ P###:A### (codable task)   ← task to implement
            └─ T###:P### (test case) ← validation of the P###
```

## Uniqueness rules

- Every ID is unique **across the whole project** (not per phase).
- Every ID matches exactly `[EAPT]\d{3}` (e.g. `E001`, `A042`).
- Every non-E ID declares its parent as `ID:PARENT` (e.g. `P003:A001`).

## Parent rules (checked by check_sdlc.py)

| Child | Allowed parent |
|---|---|
| A### | E### |
| P### | A### |
| T### | P### |

A parent cannot be:
- missing (orphan) — exit 1
- undeclared (`P003` without `:Axxx`) — exit 1
- of the wrong category (`P003:E001` instead of `P003:A001`) — not caught by the regex, but
  blocked by the chaining rule (a P must have an A parent, which must itself exist in
  `2_architecture.md`)

## Required coverage

- **Every MUST E###** is covered by at least one `A###:E###` in `2_architecture.md`.
- **Every accepted A###** produces at least one `P###:A###` in `3_conception.md`.
- **Every P###** produces at least one `T###:P###` in `4_tests.md`.

The AQ Gate reports A###/P### without children as **warnings**, but blocks on orphan children and
wrong parents.

## Edge cases

### Bug found while coding

A bug or hidden requirement found during implementation is **not** a new P###. It is:

1. a new `E###` in `1_elicitation.md` (the root cause is a business need),
2. a new `A###:E<new>` in `2_architecture.md` (the decision to address it),
3. a new `P###:A<new>` in `3_conception.md` (the task),
4. the original code stays locked until that new P### is ✅.

It is tedious on purpose: it prevents silent scope creep.

### Refactoring

A refactoring is **not** automatically a new P###. If it changes no behavior and stays inside a
file already covered by an existing ✅ P###, it can be committed under that P### (status goes
back to 🔄 temporarily, then ✅ after the tests).

If it reshapes the architecture (moves responsibilities, changes interfaces), it is a new
A###/P###.

### Infrastructure / tooling tasks

Non-functional tasks (CI/CD, lint, dependencies) are traced too. Give them a dedicated E###
(e.g. "E099 — Reliable, reproducible CI pipeline") and their own A→P→T.

## Why this discipline

- **Audit**: an auditor can trace any line of code back to the business requirement behind it.
- **Migration**: SDLC can migrate a v2 project without rewriting IDs.
- **Trust in autonomy**: an agent in `--auto-approve` cannot add code "because it's better"
  unless an explicit P### asks for it.
- **Evaluation**: `/sdlc:report` measures E→A→P→T coverage and flags gaps.

## Tools involved

- `scripts/check_sdlc.py` — chain validation (AQ Gate)
- `scripts/wave_planner.py` (sub-skill) — computes waves from the P### dependencies
