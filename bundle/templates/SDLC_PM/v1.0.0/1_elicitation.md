# 1 — Elicitation (E###)

> **Language**: write this file's content in the project's `output_language`
> (`SDLC_PM/sdlc-config.json`). Keep headings, field markers and IDs in
> English so the tooling can parse them.

> SDLC phase 1. Captures business requirements as **E###** identifiers (roots,
> no parent). Give every E### a BDD-style acceptance criterion before the AQ
> Gate validates it.

---

## Metadata

- **Project** : `<name>`
- **Version** : `v1.0.0`
- **Author** : `<author>`
- **Date** : `<YYYY-MM-DD>`
- **Phase status** : ⬜ To do | 🔄 In progress | ✅ Done

---

## Context

In 2-5 sentences: the business need, target users, the problem solved, the
environment (internal/external, known constraints).

---

## Actors and use cases

| Actor | Role | Main use cases |
|---|---|---|
| `<Actor 1>` | `<role>` | UC1, UC2 |
| `<Actor 2>` | `<role>` | UC3 |

---

## Business rules (excerpts)

- **R1** : `<rule>`
- **R2** : `<rule>`

---

## Requirements (E###) — MoSCoW

### MUST (required for v1.0)

#### E001 — `<short title>`

- **Description** : `<actionable sentence>`
- **Actor(s)** : `<list>`
- **Acceptance criterion** :
  > Given `<context>`, when `<action>`, then `<observable result>`.
- **Status** : ⬜

#### E002 — `<short title>`

- **Description** : `<...>`
- **Acceptance criterion** : `<...>`
- **Status** : ⬜

### SHOULD (desirable for v1.0)

#### E010 — `<short title>`

- **Description** : `<...>`
- **Acceptance criterion** : `<...>`
- **Status** : ⬜

### COULD (nice-to-have)

#### E020 — `<short title>`

- **Description** : `<...>`
- **Status** : ⬜

### WON'T (out of scope for v1.0 — deferred)

- `<item deferred to v1.1 / v2.0>`

---

## Non-functional requirements

| Category | Requirement | Target |
|---|---|---|
| Performance | Response time | < `<X>` ms |
| Availability | Uptime | `<X>` % |
| Security | ASVS level | L`<1\|2\|3>` |
| Scalability | Volume | `<X>` records/day |
| Compliance | Regulation | `<GDPR\|HIPAA\|none>` |

---

## Business assumptions and risks

- **H1** : `<assumption>`
- **R1** : `<risk + impact + mitigation>`

---

## Data handled

| Data | Type | Source | Sensitivity (PII / confidential) |
|---|---|---|---|
| `<field>` | `<type>` | `<source>` | `<level>` |

---

## Phase 1 checklist

- [ ] Every MUST has a BDD acceptance criterion
- [ ] No orphan E### / E### without a description
- [ ] Business risks identified and mitigated
- [ ] Sensitive data classified
- [ ] AQ Gate: `check_sdlc.py` exit 0

> **Next**: run `/sdlc:discuss` to settle the key architecture choices, then
> `/sdlc:plan` to produce the A### and P###.
