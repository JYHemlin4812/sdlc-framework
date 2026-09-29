---
description: Markdown dashboard — current phase, wave, P###/T### counters
argument-hint: ""
---

# /sdlc:status

**Output**: a quick markdown dashboard.

Write the dashboard in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

## Steps
1. Read `SDLC_PM/SDLC_PLAN.md` and `STATE.md` (if present).
2. Show the current phase and the current wave / total.
3. P### counters: ⬜ / 🔄 / ✅ / 🔁 / 🚫
4. T### counters: ✅ / ❌ and coverage.
5. Last action and its timestamp.

Details: `~/.claude/skills/sdlc/SKILL.md` (`/sdlc:status` section) and
`~/.claude/skills/sdlc/references/slash-commands.md`.
