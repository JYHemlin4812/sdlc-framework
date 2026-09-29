---
description: Blocking AQ Gate validation (exit 0/1) — runs check_sdlc.py
argument-hint: ""
---

# /sdlc:gate

**Phase**: validation. Output: exit 0 / 1 and a markdown report.

Write the report and user-facing messages in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

## Steps
0. **Evidence before the gate**: invoke the `sdlc-verify` sub-skill. Every P### marked ✅ since the
   last gate needs fresh evidence from this session (tests/lint/build/`git status` run and quoted),
   not just an agent's report. Without evidence, set the P### back to 🔄 before continuing.
1. Run `python ~/.claude/skills/sdlc/scripts/check_sdlc.py` from the current project.
2. On exit 0: announce ✅ and recommend `/sdlc:report` or `/sdlc:dev`, depending on the phase.
3. On exit 1: list the errors, suggest `/sdlc:fix <P###>` or a manual fix, and do not move to the
   next phase, because the E→A→P→T chain is broken.

Details: `~/.claude/skills/sdlc/SKILL.md` (`/sdlc:gate` section) and
`~/.claude/skills/sdlc/references/aq-gate.md`.
