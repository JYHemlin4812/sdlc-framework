---
description: Discussion phase — pre-architecture ADR drafts (optional, M/L projects)
argument-hint: "[topics to debate, comma-separated]"
---

# /sdlc:discuss

**Phase 1.5** — Discussion. Output: `SDLC_PM/v1.0.0/2_5_discussion.md`.
**Precondition**: `1_elicitation.md` validated.

Before your first tool call, say in one sentence what you're about to do. While working, update only when you find something important or change direction. When you finish, lead with the outcome, then the next step.

Write artifact content and user-facing messages in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

## Steps
1. Spawn the `sdlc-discussion-facilitator` agent (Agent tool) with the topics from $ARGUMENTS.
2. For each topic it produces: context, 2-3 options, trade-offs, explicit recommendation.
3. It writes `2_5_discussion.md`, which feeds the A### of phase 2 directly.
4. Present the decisions still open to the user, then announce the next step: `/sdlc:plan`.

Details: `~/.claude/skills/sdlc/SKILL.md` (`/sdlc:discuss` section) and
`~/.claude/skills/sdlc/references/discussion-phase.md`.
