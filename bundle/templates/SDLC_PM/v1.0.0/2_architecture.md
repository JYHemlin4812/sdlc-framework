# 2 — Architecture (A###)

> **Language**: write this file's content in the project's `output_language`
> (`SDLC_PM/sdlc-config.json`). Keep headings, field markers and IDs in
> English so the tooling can parse them.

> SDLC phase 2. Records architecture decisions as **A###:E###** (each A###
> names the parent E### it satisfies). Builds on the discussion phase
> (`2_5_discussion.md`) when it was run.

---

## Metadata

- **Project** : `<name>`
- **Version** : `v1.0.0`
- **Previous phase** : Discussion (`2_5_discussion.md`) if applicable
- **Phase status** : ⬜ To do | 🔄 In progress | ✅ Done

---

## Architecture vision

In 5-10 lines: architectural style (monolith, microservices, CLI, library),
communication pattern, persistence, system boundary.

---

## ASCII diagram

```
┌─────────────┐      ┌─────────────┐
│   Client    │ ───▶ │   Service   │
└─────────────┘      └──────┬──────┘
                            │
                     ┌──────▼──────┐
                     │  Storage    │
                     └─────────────┘
```

---

## Tech stack

| Layer | Technology | Version | Rationale |
|---|---|---|---|
| Primary language | `<python\|js\|go\|rust>` | `<version>` | `<...>` |
| Framework | `<...>` | `<...>` | `<...>` |
| Persistence | `<...>` | `<...>` | `<...>` |
| Tests | `<...>` | `<...>` | `<...>` |
| CI/CD | `<...>` | `<...>` | `<...>` |

---

## Architecture decisions (A###) — ADR format

Status rules: an A### stays **Proposed** until the user accepts it; only the user sets
**Accepted** (`/sdlc:plan` asks and records the answer in `HANDOFF.md`). An accepted A### is never
rewritten: write a new A### that **supersedes** it. The old one stays in force until the user
accepts the replacement; only then is it marked **Superseded by A###**. It keeps its `A###:E###`
link and its finished P###, and gets no new task. A rejected replacement changes nothing.

### A001:E001 — `<decision title>`

- **Context** : `<problem, constraints>`
- **Options evaluated** :
  1. `<simplest viable option>` (baseline) — pro: `<...>`, con: `<...>`
  2. `<option 2>` — pro: `<...>`, con: `<...>`
- **Decision** : `<chosen option>`
- **Rationale** : `<why this option>`
- **Consequences** :
  - Positive : `<...>`
  - Negative : `<...>`
  - Neutral : `<...>`
- **Verification** : `<test, dependency check or contract test that shows the decision holds>`
- **Covers** : E001, [other E### if applicable]
- **Status** : ⬜ Proposed | ⬜ Proposed — auto-approve | ✅ Accepted | ❌ Rejected | ↪ Superseded by A###
- **Supersedes** : `<A### it replaces, effective date — or none>`

### A002:E001 — `<title>`

- **Context** : `<...>`
- **Decision** : `<...>`
- **Covers** : E001
- **Status** : ⬜ Proposed | ⬜ Proposed — auto-approve | ✅ Accepted | ❌ Rejected | ↪ Superseded by A###

### A003:E002 — `<title>`

- **Context** : `<...>`
- **Decision** : `<...>`
- **Covers** : E002
- **Status** : ⬜ Proposed | ⬜ Proposed — auto-approve | ✅ Accepted | ❌ Rejected | ↪ Superseded by A###

---

## Data model (if applicable)

```
Entity1 (id, name, ...) ─┬─ has_many ─▶ Entity2 (id, entity1_id, ...)
                         └─ belongs_to ─▶ Entity3
```

---

## Boundaries & dependencies (if applicable, tier full and above)

Logical layers are not deployment tiers: a small CRUD can stay simple. Fill this section only
when the project has real boundaries (see the `sdlc-architecture` sub-skill).

| Layer / module | Responsibility | May depend on | Must not depend on |
|---|---|---|---|
| `<presentation>` | `<adapt HTTP/UI/events, validate input shape>` | `<application>` | `<infrastructure>` |
| `<domain>` | `<invariants, business rules>` | `<pure libraries only>` | `<SQL, HTTP, UI adapters>` |

- **Composition point** : `<where dependencies are wired; manual injection is often enough>`
- **DTOs** : `<input and output DTOs kept separate; explicit list of public fields>`
- **Error translation** : `<where technical errors become public errors>`
- **Dependency check** : `<tool already available in the project (import analysis, ArchUnit, NetArchTest...) and the command>`

---

## Interfaces / API (if applicable)

The contract lives in a machine-readable schema in the repository (OpenAPI, JSON Schema or a
message contract). This section records the decision and the planned schema path; a contract
P### (**Fixes contract**) writes the schema during `/sdlc:dev`, before the P### that implement or
consume it (`sdlc-contract` sub-skill).

| Contract | Schema file | Consumers | Version | Verified by |
|---|---|---|---|---|
| `<service or event>` | `<path/to/openapi.yaml>` | `<known consumers>` | `<v1>` | `<contract test T###>` |

---

## Technical risks

| Risk | Likelihood | Impact | Mitigation | Covered by |
|---|---|---|---|---|
| `<risk>` | `<L\|M\|H>` | `<L\|M\|H>` | `<...>` | A### |

---

## Phase 2 checklist

- [ ] Every MUST E### is covered by at least one A###
- [ ] Every A### has the form `A###:E###` (existing parent)
- [ ] ASCII diagram present
- [ ] Tech stack justified (no arbitrary choices)
- [ ] Technical risks identified and mitigated
- [ ] AQ Gate: `check_sdlc.py --phase plan` exit 0

> **Next**: `/sdlc:plan` continues with the P### breakdown in
> `3_conception.md`.
