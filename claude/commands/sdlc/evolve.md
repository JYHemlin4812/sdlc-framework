---
description: TDD discipline (RED → GREEN → REFACTOR) — runs the sdlc-evolve sub-skill
argument-hint: "[P### concerned]"
---

# /sdlc:evolve

**Output**: for each evolving P###, at least one T### that fails before the production code and passes after. Exceptions, declared in `4_tests.md` with their RED status: `characterization` (pins existing behavior before a refactor; passes at once by design) and `written-after` (code kept that came first, with the user's agreement). Never record either as `observed`.

## Steps
1. Invoke the `sdlc-evolve` sub-skill (Skill tool).
2. Identify the evolving P### (feature, bug fix, refactor).
3. Write the associated T### in `4_tests.md` first. For a refactor of existing behavior, first pin it with characterization tests (declared, RED status `characterization`).
4. Run the new-behavior tests and confirm they fail (RED: `observed`) before writing code. Characterization tests are expected to pass; record that status instead.
5. Write the minimal code that makes them pass (GREEN).
6. Refactor while keeping them green (REFACTOR).
7. Record the initial and final state in `4_tests.md`.

Write `4_tests.md` entries and user-facing messages in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

> **Proxy** status: adapted from `test-driven-development` ([obra/superpowers](https://github.com/obra/superpowers)). It covers continuous improvement through tests, not a dedicated structural refactor.

Details: `~/.claude/skills/sdlc-evolve/SKILL.md`
