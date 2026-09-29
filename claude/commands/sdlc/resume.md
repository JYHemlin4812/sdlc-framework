---
description: Resume a session from SDLC_CHECKPOINT.md
argument-hint: ""
---

# /sdlc:resume

**Phase**: restore. **Precondition**: `SDLC_CHECKPOINT.md` exists.

Write user-facing messages in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

## Steps
1. Read `SDLC_PM/SDLC_CHECKPOINT.md` (frontmatter + state).
2. Restore the working state (current wave, last P###, context).
3. Propose the next action (resume dev at the recorded wave, or a new phase if the checkpoint is older).

Details: `~/.claude/skills/sdlc/SKILL.md` (`/sdlc:resume` section) and
`~/.claude/skills/sdlc/references/slash-commands.md`.
