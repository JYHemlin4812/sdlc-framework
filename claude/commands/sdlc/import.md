---
description: Audit an existing project (SDLC v2 or never under SDLC) and rebuild SDLC_PM/ from it
argument-hint: "<project-root>"
---

# /sdlc:import

**Phase**: audit / reconstruction. Output: a rebuilt `SDLC_PM/` and a report.

Before your first tool call, say in one sentence what you're about to do. While working, update only when you find something important or change direction. When you finish, lead with the outcome, then the next step.

Write artifact content and user-facing messages in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

## Steps
1. Spawn `sdlc-code-auditor` (subagent): observation only, no changes. It maps structure, stack, docs, gaps.
2. Spawn `sdlc-quality-assessor`: cross-checks code and docs, rates maturity.
3. Spawn `sdlc-system-analyst`: rebuilds `1_elicitation.md` … `4_tests.md`.
4. Run `check_sdlc.py` and fix the remaining gaps.
5. If the project is SDLC v2, follow `MIGRATION_v2_v3.md` (bundle root) for the rest.

$ARGUMENTS = path of the project to import.

Details: `~/.claude/skills/sdlc/SKILL.md` (`/sdlc:import` section) and
`~/.claude/skills/sdlc/references/slash-commands.md`.
