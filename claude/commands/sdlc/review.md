---
description: Code review by a dispatched subagent — runs the sdlc-reviewer sub-skill
argument-hint: "[optional BASE_SHA HEAD_SHA]"
---

# /sdlc:review

**Output**: the reviewer subagent's markdown report, attached to the P### or the current wave.

Before your first tool call, say in one sentence what you're about to do. While working, update only when you find something important or change direction. When you finish, lead with the outcome, then the next step.

## Steps
1. Invoke the `sdlc-reviewer` sub-skill (Skill tool).
2. Get `BASE_SHA` / `HEAD_SHA` (default: `HEAD~1` → `HEAD`).
3. Dispatch a `general-purpose` subagent with the sub-skill's `code-reviewer.md` template. Ask it to
   report every issue it finds with a severity; prioritize the findings afterwards, because a
   reviewer told to report only severe issues reports fewer of them.
4. Capture the report and attach it to the "notes" column of the P### in `3_conception.md`.
5. **Reception**: invoke the `sdlc-receive-review` sub-skill to handle the findings: verify before
   implementing, no performative agreement, challenge with YAGNI, clarify ambiguous items first.
6. Handle non-trivial findings before `/sdlc:gate`.

Write attached notes and user-facing messages in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

Details: `~/.claude/skills/sdlc-reviewer/SKILL.md` (requesting) and
`~/.claude/skills/sdlc-receive-review/SKILL.md` (receiving).
