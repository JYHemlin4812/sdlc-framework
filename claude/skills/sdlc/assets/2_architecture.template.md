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

### A001:E001 — `<decision title>`

- **Context** : `<problem, constraints>`
- **Options evaluated** :
  1. `<option 1>` — pro: `<...>`, con: `<...>`
  2. `<option 2>` — pro: `<...>`, con: `<...>`
- **Decision** : `<chosen option>`
- **Rationale** : `<why this option>`
- **Consequences** :
  - Positive : `<...>`
  - Negative : `<...>`
  - Neutral : `<...>`
- **Covers** : E001, [other E### if applicable]
- **Status** : ⬜ Proposed | ✅ Accepted | ❌ Rejected

### A002:E001 — `<title>`

- **Context** : `<...>`
- **Decision** : `<...>`
- **Covers** : E001
- **Status** : ⬜

### A003:E002 — `<title>`

- **Context** : `<...>`
- **Decision** : `<...>`
- **Covers** : E002
- **Status** : ⬜

---

## Data model (if applicable)

```
Entity1 (id, name, ...) ─┬─ has_many ─▶ Entity2 (id, entity1_id, ...)
                         └─ belongs_to ─▶ Entity3
```

---

## Interfaces / API (if applicable)

| Endpoint | Method | Auth | Description |
|---|---|---|---|
| `/api/v1/...` | GET | Bearer | `<...>` |

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
- [ ] AQ Gate: `check_sdlc.py` exit 0

> **Next**: `/sdlc:plan` continues with the P### breakdown in
> `3_conception.md`.
