---
description: Concise markdown release report for a version
argument-hint: "[version]"
---

# /sdlc:report

**Output**: a markdown report (stdout or file). **Precondition**: the version exists in `SDLC_PM/`.

Write the report in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

## Steps
1. Read the four phase files of the version (`v$ARGUMENTS/` or the default).
2. Compile: requirements (E###), key decisions (A### + ADR), delivered tasks (P### ✅), passing tests (T### + coverage).
3. Compute metrics: success rate, residual risks, E→T coverage.
4. Shape it as a release report or a PR description.

$ARGUMENTS = target version (e.g. `1.0.0`).

Details: `~/.claude/skills/sdlc/SKILL.md` (`/sdlc:report` section) and
`~/.claude/skills/sdlc/references/slash-commands.md`.
