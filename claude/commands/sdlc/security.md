---
description: OWASP ASVS L1/L2/L3 scan — runs the sdlc-asvs-auditor sub-skill
argument-hint: ""
---

# /sdlc:security

**Output**: a security report structured by ASVS category, severity, file:line.

Write the report in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

## Steps
1. Read `asvs_level` in `sdlc-config.json` (default 1).
2. Invoke the `sdlc-asvs-auditor` sub-skill (Skill tool).
3. Run `asvs_scanner.py --level <n> --root <project>`.
4. If high-severity findings are not recorded in `4_tests.md` or `2_5_discussion.md`, suggest `/sdlc:fix` or a new E###.

Details: `~/.claude/skills/sdlc/SKILL.md` (`/sdlc:security` section) and
`~/.claude/skills/sdlc/references/slash-commands.md`.
