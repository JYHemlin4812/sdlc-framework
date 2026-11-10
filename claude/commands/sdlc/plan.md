---
description: Architecture A### and task breakdown P### with wave column (phases 2+3)
argument-hint: ""
---

# /sdlc:plan

**Phases 2+3** — Architecture and design / task breakdown. Outputs: `2_architecture.md` and `3_conception.md`.
**Precondition**: `1_elicitation.md` ✅ (and `2_5_discussion.md` if present).

Before your first tool call, say in one sentence what you're about to do. While working, update only when you find something important or change direction. When you finish, lead with the outcome, then the next step.

Write artifact content and user-facing messages in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

## Steps
1. Read `documentation_tier` in `SDLC_PM/sdlc-config.json`. At tier `standard`, architecture is optional
   (REV-003, option a): skip `sdlc-architect` unless the user asks for an architecture document. At tier
   `full` or `exhaustive` (and for legacy configs without a tier), always spawn `sdlc-architect` (Agent tool) to produce `2_architecture.md`
   (A###:E###, ADRs, ASCII diagram).
2. Spawn `sdlc-system-analyst` (Agent tool) to produce `3_conception.md`. Parent rule: `P###:A###` when
   written A### exist in `2_architecture.md`; `P###:E###` only when no A### exists (standard tier without
   architecture). Never `P###:E###` when A### exist: that breaks the traceability chain.
3. Run `wave_planner.py --conception ... --annotate` to compute and annotate the `wave: N` values.
4. Run `check_sdlc.py --phase plan` once, after steps 1 to 3 (AQ Gate for the planning phase: `4_tests.md`
   is not written yet). Only this run checks the planning documents; the agents do not run it themselves.
5. On ✅, announce `/sdlc:dev`. On ❌, fix the reported errors and rerun the gate.

Details: `~/.claude/skills/sdlc/SKILL.md` (`/sdlc:plan` section) and
`~/.claude/skills/sdlc/references/slash-commands.md`.
