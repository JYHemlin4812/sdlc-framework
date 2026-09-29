---
description: Retry a blocked (🚫) or in-rework (🔁) P### with enriched context
argument-hint: "<P###>"
---

# /sdlc:fix

**Precondition**: `$ARGUMENTS` (a P###) exists and is 🚫 or 🔁.

Before your first tool call, say in one sentence what you're about to do. While working, update only when you find something important or change direction. When you finish, lead with the outcome, then the next step.

## Steps
1. Reset the retry counter for `$ARGUMENTS`.
2. Spawn `sdlc-quality-assessor` for a root-cause diagnosis, then spawn a dev subagent with the
   enriched context (previous logs, the assessor's diagnosis).
3. Retry the implementation.
4. On success, mark ✅. If a full new cycle fails, state the root-cause hypothesis and its evidence
   in the task notes, then escalate to the user.

Write task notes and user-facing messages in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

Details: `~/.claude/skills/sdlc/SKILL.md` (`/sdlc:fix` section) and
`~/.claude/skills/sdlc/references/slash-commands.md`.
