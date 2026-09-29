---
description: Session checkpoint — regenerates HANDOFF.md and saves the state to SDLC_CHECKPOINT.md
argument-hint: ""
---

# /sdlc:exit

**Phase**: checkpoint. Outputs: `SDLC_PM/HANDOFF.md` (regenerated),
`SDLC_PM/SDLC_CHECKPOINT.md` (raw state).

Write artifact content and user-facing messages in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

## Steps

1. **Regenerate `HANDOFF.md`** (tier `minimal` or above) from:
   - the last P### marked ✅ and the next P### to run
   - the last AQ Gate exit code
   - the last clean commit (sha, message, date)
   - pitfalls found during the session (go in the "Known pitfalls" section)
   - the next 3 actions (pick at most 3)
   If `HANDOFF.md` does not exist, create it from
   `~/.claude/skills/sdlc/assets/HANDOFF.template.md`, then fill it.
2. Snapshot the state: current wave, P### in progress / last ✅, auto-approve counters, timestamp.
3. Write it to `SDLC_CHECKPOINT.md` (YAML frontmatter + markdown state).
4. Optional: spawn `sdlc-archive-manager` to archive non-essential artifacts.
5. Announce: HANDOFF.md is up to date, and whoever picks up the project can now open it cold.

Details: `~/.claude/skills/sdlc/SKILL.md` (`/sdlc:exit` section) and
`~/.claude/skills/sdlc/references/documentation-tiers.md`.
