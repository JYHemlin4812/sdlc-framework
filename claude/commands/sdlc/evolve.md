---
description: TDD discipline (RED → GREEN → REFACTOR) — runs the sdlc-evolve sub-skill
argument-hint: "[P### concerned]"
---

# /sdlc:evolve

**Output**: for each evolving P###, at least one T### that fails before the production code and passes after.

## Steps
1. Invoke the `sdlc-evolve` sub-skill (Skill tool).
2. Identify the evolving P### (feature, bug fix, refactor).
3. Write the associated T### in `4_tests.md` first.
4. Run the tests and confirm they fail (RED) before writing code.
5. Write the minimal code that makes them pass (GREEN).
6. Refactor while keeping them green (REFACTOR).
7. Record the initial and final state in `4_tests.md`.

Write `4_tests.md` entries and user-facing messages in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

> **Proxy** status: adapted from `test-driven-development` ([obra/superpowers](https://github.com/obra/superpowers)). It covers continuous improvement through tests, not a dedicated structural refactor.

Details: `~/.claude/skills/sdlc-evolve/SKILL.md`
