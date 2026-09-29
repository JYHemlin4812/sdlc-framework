# 2.5 — Discussion (ADR drafts)

> **Language**: write this file's content in the project's `output_language`
> (`SDLC_PM/sdlc-config.json`). Keep headings, field markers and IDs in
> English so the tooling can parse them.

> Optional phase, recommended for M/L projects. Settles technical debates
> before the A### are written in `2_architecture.md`. This file supports the
> decision; it is **not a new class of identifiers**: traceability stays
> E→A→P→T.

---

## Metadata

- **Project** : `<name>`
- **Version** : `v1.0.0`
- **Topics discussed** : `<short list>`
- **Date** : `<YYYY-MM-DD>`

---

## Topic 1 — `<topic title>`

### Context

In 3-5 lines: what is at stake, the constraints, the E### requirements
involved.

- **E### involved** : E001, E002, ...
- **External constraints** : `<budget, deadline, team, existing infrastructure>`
- **Sensitivity** : `<low / medium / high>`

### Options considered

#### Option A — `<name>`

- **Description** : `<actionable sentence>`
- **Pros** :
  - `<...>`
  - `<...>`
- **Cons** :
  - `<...>`
- **Size** : `<S/M/L>`
- **Risk** : `<L/M/H>`

#### Option B — `<name>`

- **Description** : `<...>`
- **Pros** : `<...>`
- **Cons** : `<...>`
- **Size** : `<S/M/L>`
- **Risk** : `<L/M/H>`

#### Option C — `<name>` (if relevant)

- ...

### Key trade-offs

| Criterion | Option A | Option B | Option C |
|---|---|---|---|
| Initial cost | `<...>` | `<...>` | `<...>` |
| Operating cost | `<...>` | `<...>` | `<...>` |
| Complexity | `<...>` | `<...>` | `<...>` |
| Maintainability | `<...>` | `<...>` | `<...>` |
| Technology lock-in | `<...>` | `<...>` | `<...>` |
| Time-to-market | `<...>` | `<...>` | `<...>` |

### Recommendation

> **Chosen option** : `<Option X>`
>
> **Why** : `<2-3 sentences — what tipped the balance>`
>
> **Conditions** : `<if applicable, what must hold for this recommendation to
> stand; e.g. "as long as volume stays under 10M rows">`

### Consequences for `2_architecture.md`

This discussion becomes the following **A###**:

- `A00X:E00Y` — `<derived title>`
  - Decision : `<summary of the chosen option>`
  - Discussion reference : Topic 1 above

### Open questions / residual risks

- ❓ `<question still open>`
- ⚠️ `<risk the recommendation may not address>`

---

## Topic 2 — `<title>`

(Repeat the structure above.)

---

## Summary — A### derived from this discussion

| Topic | A### produced | E### covered | Status |
|---|---|---|---|
| Topic 1 | A001 | E001 | Proposed → to confirm in phase 2 |
| Topic 2 | A003 | E002 | Proposed |

---

## Discussion phase checklist (optional)

- [ ] Each topic has at least 2 options considered
- [ ] Trade-offs documented
- [ ] Explicit recommendation with its rationale
- [ ] Clear link to the A### to produce in `2_architecture.md`

> **Note**: the AQ Gate does not block when `2_5_discussion.md` is missing.
> This phase is optional: it improves the A### but is not required for S
> projects.

> **Next**: `/sdlc:plan` uses this discussion to produce `2_architecture.md`
> (A###) and `3_conception.md` (P###).
