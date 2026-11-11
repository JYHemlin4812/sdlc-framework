---
name: sdlc-architecture
description: |
  SDLC sub-skill: boundaries and dependencies for the architecture phase. Maps
  the real responsibilities and imports, then fills the "Boundaries &
  dependencies" section of 2_architecture.md (layers, dependency direction,
  composition point, DTOs, error translation, dependency check). Proportionate:
  a small CRUD can stay simple. Adapted from the BPSE `se-architecture`
  practice (see `sdlc/SOURCES.md`).

  Triggers: boundaries, layers, ports and adapters, hexagonal, clean
  architecture, DTO, dependency direction, composition root, coupling,
  asynchronous messaging, outbox, idempotent consumer, during /sdlc:plan at
  tier full and above. Also triggers on (FR): frontières, couches,
  dépendances, ports et adaptateurs, DTO, messagerie asynchrone.
---

# sdlc-architecture — Boundaries and dependencies (v4.0)

## SDLC integration

- **When to use:** during `/sdlc:plan` (phase 2), when `sdlc-architect` writes
  `2_architecture.md` for a project with real boundaries, at tier `full` and
  above. The section is "if applicable": skip it for a simple CRUD or a script.
- **Deliverable:** the **Boundaries & dependencies** section of
  `2_architecture.md`, plus the **Verification** field of the A### that set
  those boundaries.
- **Traceability:** each boundary decision is an `A###:E###`. Enforcing it in
  code is a `P###:A###` with its own `T###` (dependency check or substitution
  test).
- **Verified by the gate:** no. The gate checks the E→A→P→T chain and the
  placeholders, not the content of this section. Its proof is the dependency
  check named in the section, run as a T###.

## Method

Map the real responsibilities and imports before proposing a structure. Logical
layers are not deployment tiers: separating responsibilities imposes neither
microservices nor extra processes. A small CRUD can stay simple.

- **Presentation**: adapts HTTP, UI or events; authenticates and validates the
  shape of inputs. Business decisions stay in the domain or the use cases.
- **Application**: orchestrates use cases, transactions and the ports they need.
  An interface lives next to its business or application consumer.
- **Domain**: invariants, rules and business objects; no dependency on SQL, HTTP
  or UI adapters. Relevant pure libraries are fine.
- **Infrastructure**: implements the ports, translates technical errors, keeps an
  internal cause for diagnosis without publishing it to clients.

Wire dependencies at the **composition point**. Manual injection is often
enough; do not impose a container. Avoid interfaces without a need, pass-through
layers and global rewrites of existing code.

Keep **input and output DTOs separate**; prefer an explicit list of public
fields, check that no secret leaks, and test the mappings. Input shape
validation does not replace business invariants nor the authorization on the
resource. Never expose ORM objects or SQL exceptions in the public contract. An
explicit mapping still has to be tested: it does not guarantee correctness by
itself.

For asynchronous exchanges, read [the messaging checklist](references/messaging.md).
Choose synchronous or asynchronous from latency, consistency and operations; a
bus is not an automatic choice.

## Verification

Propose an incremental migration and a boundary check with the tool **already
available** in the project (import analysis, ArchUnit, NetArchTest or an
equivalent); do not impose a new one. Check the dependencies actually resolved,
not only folder names. Add substitution tests for critical contracts.

Record in the section: responsibilities, dependency direction, trade-offs, and
the command of the boundary check. If no tool is available, say so and record the
check as **not run**, never as passed.
