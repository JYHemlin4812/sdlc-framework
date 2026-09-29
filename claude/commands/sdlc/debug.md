---
description: Structured root-cause-first debugging — runs the sdlc-debugger sub-skill
argument-hint: "[optional symptom/context]"
---

# /sdlc:debug

**Output**: a root-cause investigation, then a proposed fix once the cause is identified.

Before your first tool call, say in one sentence what you're about to do. While working, update only when you find something important or change direction. When you finish, lead with the outcome, then the next step.

## Steps
1. Invoke the `sdlc-debugger` sub-skill (Skill tool).
2. Phase 1 first: reproduce, isolate, identify the root cause.
3. Propose a fix only once the root cause is documented, so the fix targets the cause and not a symptom.
4. Record the finding in `4_tests.md` (the T### concerned) or `2_5_discussion.md` before editing code.
5. If a failing T### blocks a P###, run `/sdlc:fix` after the cause is resolved.

Write recorded findings and user-facing messages in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

Details: `~/.claude/skills/sdlc-debugger/SKILL.md`
