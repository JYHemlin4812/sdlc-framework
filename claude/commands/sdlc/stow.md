---
description: Session sweep — captures durable knowledge into SDLC_PM/STOW.md with tiered decay
argument-hint: ""
---

# /sdlc:stow

**Phase**: any, typically before `/sdlc:exit` or a context reset. Output:
`SDLC_PM/STOW.md` (updated), `SDLC_PM/.stow-archive.md` (stale entries, git-ignored).

Write artifact content and user-facing messages in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

## Steps

1. Load the `sdlc-stow` sub-skill (`~/.claude/skills/sdlc-stow/SKILL.md`) and
   follow its steps: sweep the conversation, check each finding against its
   owner, read `STOW.md`, classify and write, then curate stale entries with
   `scripts/stow_decay.py`.
2. Report what was captured, what was archived, what could not be captured and
   whether the session is safe to end.
3. Close with the resume pointer naming the files a fresh session should load.

Details: `~/.claude/skills/sdlc-stow/SKILL.md`.
