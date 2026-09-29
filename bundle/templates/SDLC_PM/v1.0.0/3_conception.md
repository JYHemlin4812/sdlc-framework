# 3 — Design / task breakdown (P###)

> **Language**: write this file's content in the project's `output_language`
> (`SDLC_PM/sdlc-config.json`). Keep headings, field markers and IDs in
> English so the tooling can parse them.

> SDLC phase 3. Breaks each A### into **codable** tasks identified as
> **P###:A###**. The `wave: N` field (integer ≥ 1) enables parallel execution
> by waves through `wave_planner.py`.

---

## Metadata

- **Project** : `<name>`
- **Version** : `v1.0.0`
- **Phase status** : ⬜ To do | 🔄 In progress | ✅ Done

---

## The `wave: N` convention

- Tasks in the **same wave** must **not depend on each other** —
  `sdlc-wave-orchestrator` runs them in parallel.
- A task that depends on another goes in a **strictly later wave**.
- The AQ Gate checks consistency: no `Depends on` may point to a P### in the
  same wave or a later one.
- If unsure, run `wave_planner.py --annotate`: it computes the waves by
  topological sort.

---

## Codable tasks (P###)

### Wave 1

#### P001:A001 — `<short title>`

- **wave** : 1
- **Description** : `<actionable sentence, 1-2 lines>`
- **Covers A###** : A001
- **Depends on** : `<none>` or `<list of P###>`
- **Size** : `<S/M/L>` (S < 30 min, M < 2h, L < 1 day)
- **Language** : `<python\|javascript\|typescript\|go\|rust>` (if multi-stack)
- **Target files** : `<relative paths>` (declared write-set, comma-separated relative paths; feeds the intra-wave write-conflict linter in `wave_planner.py`)
- **Code Lock criteria** :
  - No change allowed until this P### is ✅
  - The associated T### must pass
- **Status** : ⬜

#### P002:A001 — `<title>`

- **wave** : 1
- **Description** : `<...>`
- **Covers A###** : A001
- **Depends on** : none
- **Size** : S
- **Status** : ⬜

### Wave 2

#### P003:A002 — `<title>`

- **wave** : 2
- **Description** : `<...>`
- **Covers A###** : A002
- **Depends on** : P001, P002
- **Size** : M
- **Status** : ⬜

### Wave 3

#### P004:A003 — `<title>`

- **wave** : 3
- **Description** : `<...>`
- **Covers A###** : A003
- **Depends on** : P003
- **Size** : L
- **Status** : ⬜

---

## Summary table

| ID | Title | Wave | Parent | Depends on | Size | Language | Status |
|---|---|---|---|---|---|---|---|
| P001 | `<...>` | 1 | A001 | — | S | python | ⬜ |
| P002 | `<...>` | 1 | A001 | — | S | python | ⬜ |
| P003 | `<...>` | 2 | A002 | P001, P002 | M | python | ⬜ |
| P004 | `<...>` | 3 | A003 | P003 | L | python | ⬜ |

Status legend: ⬜ To do · 🔄 In progress · ✅ Done · 🔁 In rework · blocked
(see `references/workflow-states.md`; the blocked emoji is not shown here
because the AQ Gate fails on any file that contains it).

---

## Development loop (reminder)

For each P###:

1. **ANNOUNCE** — state the P### with its parent A### and its wave
2. **CODE** — implement, small atomic commits
3. **TEST** — run the associated T###, fix failures
4. **EVALUATE** :
   - PASS → set the status to **done** (✅), move to the next task
   - FAIL (retries < max_retry_per_task) → set it to **in rework**, fix, retry
   - FAIL (retries ≥ max) → set it to **blocked**, escalate

See `references/workflow-states.md` for the full meaning of the status
emojis.

When `fresh_context_per_task: true` (default), each P### runs in an isolated
subagent through the `Agent` tool (fresh context).

---

## Phase 3 checklist

- [ ] Every P### has the form `P###:A###` (existing parent)
- [ ] `wave: N` field present, integer ≥ 1
- [ ] No cycle in the DAG (checked by `wave_planner.py`)
- [ ] No `Depends on` pointing to a wave ≥ the current wave
- [ ] AQ Gate: `check_sdlc.py` exit 0

> **Next**: `/sdlc:dev` starts the development loop (wave by wave with
> parallel subagents); the validating T### are created in `4_tests.md`.
