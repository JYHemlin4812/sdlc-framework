# 4 — Tests (T###)

> **Language**: write this file's content in the project's `output_language`
> (`SDLC_PM/sdlc-config.json`). Keep headings, field markers and IDs in
> English so the tooling can parse them.

> SDLC phase 4. Describes the **T###:P###** test cases that validate each
> P### task. Coverage target: the project's `test_coverage_min` (70% by
> default), an indicator rather than a universal quota; the AQ Gate does not
> measure it.

---

## Metadata

- **Project** : `<name>`
- **Version** : `v1.0.0`
- **Target coverage** : `<70%>`
- **Phase status** : ⬜ To do | 🔄 In progress | ✅ Done

---

## Test strategy

| Type | Tool | Target | When |
|---|---|---|---|
| Unit | `<pytest\|vitest\|go test\|cargo test>` | pure functions, classes | Every P### |
| Integration | `<...>` | assembled components | End of wave |
| Security | `asvs_scanner.py` | ASVS L`<n>` findings | Before the gate |
| End-to-end | `<...>` | user scenarios | Before release |

Choose the lowest level that really observes the risk. Unit tests use the real domain objects
(test doubles only at I/O boundaries); integration tests exercise the real adapter (a mocked
database does not prove the SQL); end-to-end tests are kept for critical journeys. Control the
clock and randomness, make time zones explicit, isolate data.

---

## Test cases (T###)

### T001:P001 — `<short title>`

- **Target** : P001
- **Type** : `<unit\|integration\|e2e\|security>`
- **Precondition** : `<initial state>`
- **Action** : `<steps>`
- **Expected result** : `<observation>`
- **Edge cases** :
  - `<null / empty input>`
  - `<maximum input>`
  - `<invalid input>`
- **Level rationale** : `<why this level observes the risk>`
- **RED** : observed | characterization | written-after
- **Command run** : `<exact command and result>`
- **Not run** : `<none, or the check not run and why>`
- **Status** : ⬜

### T002:P001 — `<title>`

- **Target** : P001
- **Type** : `<...>`
- **Status** : ⬜

### T003:P002 — `<title>`

- **Target** : P002
- **Type** : `<...>`
- **Status** : ⬜

---

## Summary table

| ID | Title | Parent | Type | Status |
|---|---|---|---|---|
| T001 | `<...>` | P001 | unit | ⬜ |
| T002 | `<...>` | P001 | integration | ⬜ |
| T003 | `<...>` | P002 | unit | ⬜ |

Status legend: ⬜ To do · 🔄 In progress · ✅ Pass · ❌ Fail · 🔁 In rework.

---

## Security tests (ASVS — if `asvs_level >= 1`)

### Txxx:Pxxx — ASVS L`<n>` scan (number it when phase 4 starts)

- **Type** : security
- **Tool** : `asvs_scanner.py`
- **Level** : L1 (basic) | L2 (recommended) | L3 (high security)
- **Criteria** :
  - No undocumented finding of `<high>` severity
  - Every pattern of the configured level is checked
- **Status** : ⬜

> Replace `Txxx:Pxxx` with a real 3-digit identifier (e.g. `Thhh:Pddd` where
> h and d are digits) when phase 4 starts; otherwise the AQ Gate flags an
> orphan T###.

---

## Phase 4 checklist

- [ ] Every P### has at least one associated T###
- [ ] Measured coverage compared with `test_coverage_min` (default 70%); any gap justified
- [ ] Edge cases identified for every unit T###
- [ ] ASVS security tests run if `asvs_level >= 1`
- [ ] AQ Gate: `check_sdlc.py --phase plan` exit 0 (release at the end of the waves)

> **Next**: `/sdlc:gate` runs the final validation; on PASS, `/sdlc:report`
> produces the version summary; otherwise run `/sdlc:fix` on the ❌ T###.
