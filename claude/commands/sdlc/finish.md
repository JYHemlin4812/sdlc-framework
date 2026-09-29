---
description: Structured branch wrap-up (merge/PR/keep/discard) — runs the sdlc-finish sub-skill
argument-hint: ""
---

# /sdlc:finish

**Output**: a logged integration decision and the action carried out (local merge, PR opened, branch kept, or cleanup).

Before your first tool call, say in one sentence what you're about to do. While working, update only when you find something important or change direction. When you finish, lead with the outcome, then the next step.

## Steps
1. Invoke the `sdlc-finish` sub-skill (Skill tool).
2. Run the test suite and quote the result; if anything fails, stop and handle it first.
3. Detect the environment (regular repo or git worktree).
4. Present the options: (a) local merge, (b) open a PR, (c) keep the branch, (d) discard.
5. Carry out the choice, with a typed confirmation for destructive actions.
6. Log the decision in the "Revisions" section of `HANDOFF.md`.

Write the log entry and user-facing messages in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

Details: `~/.claude/skills/sdlc-finish/SKILL.md`
