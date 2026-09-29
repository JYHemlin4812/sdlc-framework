# Discussion phase

Optional phase between `/sdlc:brainstorm` and `/sdlc:plan`. It records **technical debates**
before the A### are written.

## When to use it

| Calibration | Recommendation |
|---|---|
| S (<5 tasks) | Skip — go straight to `/sdlc:plan` |
| M (5–15 tasks) | Optional — useful if there is ≥1 non-trivial decision (e.g. choice of DB) |
| L (>15 tasks) | **Recommended** — settles the structuring decisions |

## When a topic deserves a Discussion

A topic deserves the Discussion phase when **at least two** of these hold:

- A wrong choice is expensive (rewriting half the code)
- Several viable options exist (≥ 2 with no obvious favorite)
- There is an explicit trade-off (performance vs simplicity, cost vs flexibility)
- The team disagrees
- The decision constrains future choices

## Topics that do not need a Discussion

- "Which test framework?" → use the language's standard one
- "Tabs or spaces?" → follow the project convention
- "Which folder layout?" → follow the language convention
- "Which logger?" → the standard library is enough in most cases

## Format of `2_5_discussion.md`

See the template `assets/2_5_discussion.template.md`. Write the content in the project's
`output_language`; keep the section headings in English. Structure per topic:

```markdown
## Topic N — <title>

### Context
- E### affected
- External constraints
- Sensitivity

### Options considered

#### Option A — <name>
- Description, pros, cons, size, risk

#### Option B — <name>
- ...

### Key trade-offs
| Criterion | Option A | Option B |
|---|---|---|
| ... | ... | ... |

### Recommendation
> Chosen option + why + conditions

### Consequences for 2_architecture.md
- Derived A###:E###

### Open questions / residual risks
```

Match the document's length to what the decision needs; no filler sections, redundant summaries
or boilerplate.

## No new IDs

`2_5_discussion.md` is a **decision aid**, not a new class of identifiers in the E→A→P→T chain.
Its recommendations become standard `A###:E###` in phase 2. This keeps v2 traceability intact and
avoids ID proliferation.

## Workflow

1. `/sdlc:brainstorm` produces `1_elicitation.md` with E###.
2. **(optional)** `/sdlc:discuss <topics>` produces `2_5_discussion.md`.
   - The `sdlc-discussion-facilitator` subagent (spawned via the Agent tool) runs the debate.
   - Web research is allowed when the stack is unknown.
3. `/sdlc:plan` reads `1_elicitation.md` AND `2_5_discussion.md` (if present) to produce
   `2_architecture.md`. Discussion recommendations become A### with a note "see Topic N of
   2_5_discussion.md".

## Example

**Topic**: "We are torn between Postgres and SQLite to store 10M rows"

```markdown
## Topic 1 — Database for the persistence layer

### Context
- E### affected: E003 (event persistence)
- Target volume: 10M rows (growth ~2M/year)
- Constraints: on-prem deployment, one-developer team

### Options considered

#### Option A — Postgres
- Description: full RDBMS, multi-user, native JSONB
- Pros:
  - Proven vertical and horizontal scaling
  - Mature replication and backup tools
- Cons:
  - Operational complexity (config, monitoring)
  - RAM/disk overhead for a single developer
- Size: M (1–2 days setup)
- Risk: L

#### Option B — SQLite
- Description: embedded, single file, zero-config
- Pros:
  - Zero ops
  - Excellent below 100M rows
  - Backup = copy the file
- Cons:
  - Single writer (a limit if multi-process)
  - No native replication
- Size: S (hours)
- Risk: M (if the project scales)

### Key trade-offs
| Criterion | Postgres | SQLite |
|---|---|---|
| Setup | M | S |
| Ops cost | M | none |
| Scaling > 100M rows | Excellent | Fair |
| Multi-process writes | Yes | No |
| Backup | Dedicated tools | cp file.db |

### Recommendation
> **SQLite** chosen for v1.0.
>
> Why: current and projected volume <100M rows, one-developer team, a single process is enough
> for this load. Zero operational cost and trivial backup outweigh Postgres's theoretical
> advantages at this stage.
>
> Conditions: if growth exceeds 50M rows/year OR the system becomes multi-process, open a new
> Discussion topic to evaluate the migration.

### Consequences for 2_architecture.md
- A003:E003 — "Persistence via SQLite (single process, single file)"
  - Reference: Topic 1 of 2_5_discussion.md

### Open questions / residual risks
- Test concurrent read performance with WAL mode enabled
- Migration strategy to Postgres if the threshold is crossed (to document in a future
  Discussion)
```

## The AQ Gate does not require `2_5_discussion.md`

Discussion is optional, so the AQ Gate checks only the E→A→P→T chain.
