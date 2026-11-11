# Sources and adaptation notes

## BPSE — engineering practices

Several practices of this framework come from **BPSE** ("Best Practices for Software
Engineering"), a package of six skills (`se-design`, `se-architecture`, `se-api-contract`,
`se-tdd`, `se-review`, `se-delivery`) and a short policy. BPSE was written by the author of this
framework, Jean-Yves Hemlin, with the help of Codex and Gemini. Its reuse here, translated and
adapted, is authorized by its author and falls under this repository's `LICENSE`.

BPSE was merged into this framework: its practices now live in the SDLC sub-skills below, so
the two packages do not need to be installed side by side.

| BPSE source | Where it lives now |
|---|---|
| `policy.md` (proportionate rigor; never invent an approval, a test run or a CI success) | `sdlc-verify` (evidence table), `sdlc-delivery` (honesty rules), `sdlc-architect` agent |
| `se-design` (RFC/ADR, simplest option as baseline, "Proposed" until accepted, supersede instead of rewrite) | `2_architecture.template.md` (Verification, Superseded, status rules), `2_5_discussion.template.md`, `sdlc-architect` and `sdlc-discussion-facilitator` agents |
| `se-architecture` (+ `references/messaging.md`) | `sdlc-architecture` sub-skill and its `references/messaging.md` |
| `se-api-contract` (+ `assets/contract.md`) | `sdlc-contract` sub-skill and its `assets/contract.md` |
| `se-tdd` (characterization, honest RED, test levels, determinism, coverage as an indicator) | `sdlc-evolve`, `sdlc-lang-dispatcher` rule 5, `4_tests.template.md`, `sdlc-test-designer` agent |
| `se-review` (pre-existing vs introduced, confirmed / uncertain / suggestion, limits) | `sdlc-reviewer` (`code-reviewer.md` and triage) |
| `se-delivery` (+ `assets/readme.md`) | `sdlc-delivery` sub-skill, `5_delivery.template.md`, `sdlc-finish` step 0 and PR body |

## Nuances kept from BPSE

- A test that is green on its first run can characterize existing code. It just does not prove,
  by itself, that a new regression was reproduced.
- Test ratios and coverage are indicators, not universal quotas. The thresholds the project
  actually adopted (`test_coverage_min`) remain; none is invented.
- Distinct logical layers do not imply distinct deployments. A modular monolith or a simple CRUD
  does not need four formal layers.
- Real domain objects are preferred; test doubles serve the I/O boundaries.
- An explicit mapping reduces some surprises, but its correctness must be tested.
- Errors never expose technical details to clients.
- Reading a shared database stays an explicit data contract; it does not allow reading another
  component's private database.
- A message queue alone does not ensure correct retries, no loss, deduplication or full failure
  isolation; the messaging checklist adds the decisions this needs.
- No stack, provider, runtime version, person, approval or infrastructure is imposed on projects.

## Other sources

Several sub-skills are adapted from [obra/superpowers](https://github.com/obra/superpowers);
each names its origin in its own header.
