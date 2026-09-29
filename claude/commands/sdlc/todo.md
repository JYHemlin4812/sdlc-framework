---
description: Show the next P### to run (first wave with ⬜ or 🔁)
argument-hint: ""
---

# /sdlc:todo

**Output**: the next P### with its context.

Write user-facing messages in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

## Steps
1. Read `SDLC_PM/v*/3_conception.md`.
2. Find the first wave with at least one P### ⬜ or 🔁.
3. Show that P###, its dependencies and its context (parent A###).
4. Useful in interactive mode before `/sdlc:dev`.

Details: `~/.claude/skills/sdlc/SKILL.md` (`/sdlc:todo` section) and
`~/.claude/skills/sdlc/references/slash-commands.md`.
