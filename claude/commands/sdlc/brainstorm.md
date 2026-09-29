---
description: Project scoping — elicit requirements E### and size the project S/M/L (phase 1)
argument-hint: "[project description]"
---

# /sdlc:brainstorm

**Phase 1** — Elicitation. Output: `SDLC_PM/v1.0.0/1_elicitation.md`.

Before your first tool call, say in one sentence what you're about to do. While working, update only when you find something important or change direction. When you finish, lead with the outcome, then the next step.

Write artifact content and user-facing messages in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

## Steps
1. If `SDLC_PM/` is missing, run `/sdlc:init` first.
2. Guided elicitation: ask 5-10 targeted questions, skipping those already answered in $ARGUMENTS.
   When an answer reveals a deep ambiguity, ask one targeted follow-up question right away to
   resolve it, then continue the batch.
3. Size the project S/M/L and tell the user.
   If the project is L and spans several distinct subsystems, propose splitting it into separate
   SDLC sub-projects rather than one large one.
4. If M/L: spawn the `sdlc-business-analyst` agent (MoSCoW + BDD criteria).
5. If the stack is unknown: web research through `sdlc-architect`.
   When presenting options (at least 2), lead with the recommended option and its reasoning, then
   the alternatives.
6. Generate `1_elicitation.md` from the template, with MoSCoW and BDD criteria. For M/L, the
   document has no leftover placeholder, no contradiction, and no MUST without an identified user
   who needs it (scope creep), so phase 2 starts from settled requirements.
7. Announce the next step: `/sdlc:discuss` (M/L) or `/sdlc:plan` (S).

Details: `~/.claude/skills/sdlc/SKILL.md` (`/sdlc:brainstorm` section) and
`~/.claude/skills/sdlc/references/slash-commands.md`.

> **Deliberate divergence**: this framework does not adopt obra/superpowers' "design always / no
> project is too simple". Sizing a project **S** (skip design and agents) and cutting MUSTs with no
> identified user sort things out faster.
