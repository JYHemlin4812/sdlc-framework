---
description: Bootstrap the SDLC_PM/ structure (HANDOFF, RESUME, 0_context, E→A→P→T templates) for the chosen documentation tier
argument-hint: "[project-root]"
---

# /sdlc:init

**Phase**: bootstrap. Output: `SDLC_PM/` populated according to `documentation_tier`.

## Steps

1. **Ask for the estimated project size** (`project_size_estimate`):
   - `one-liner` → tier `none` (decline the init, suggest a commit message instead)
   - `small` → tier `minimal` (HANDOFF + RESUME only)
   - `medium` → tier `standard` (+ 0_context + light 1_elicitation + 3_conception)
   - `large` → tier `full` (complete E→A→P→T cycle + ADRs)
   - `colossal` → tier `exhaustive` (full + ASVS L2+ + hooks + Phase Z)
2. Confirm the proposed tier (it can be edited by hand after init).
3. **Ask for the output language** (`output_language`): the language for artifacts and messages.
   Propose the language the user writes in as the default.
4. Run `~/.claude/skills/sdlc/scripts/deploy_init.ps1` (Windows) or `deploy_init.sh`.
   The script creates every skeleton file; you then decide which ones the tier requires.
5. Write `"version": "4.0"`, `output_language`, `documentation_tier` and `project_size_estimate`
   to `SDLC_PM/sdlc-config.json`. Do this after step 4, because the script copies the example
   config over it.
6. Pre-fill `RESUME.md` (prerequisites detected in the project) and `HANDOFF.md`
   (10-line pitch + next 3 actions = the phases of the chosen tier), in `output_language`.
   Keep IDs, template headings and field markers in English.
7. Announce the next step, by tier:
   - `minimal`: edit HANDOFF.md and RESUME.md, then `/sdlc:exit`
   - `standard` / `full` / `exhaustive`: run `/sdlc:brainstorm <description>`

$ARGUMENTS = path of the project to initialize (default: current directory).

Details: `~/.claude/skills/sdlc/SKILL.md` (`/sdlc:init` section) and
`~/.claude/skills/sdlc/references/documentation-tiers.md`.
