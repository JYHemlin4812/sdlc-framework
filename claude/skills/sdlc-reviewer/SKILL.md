---
name: sdlc-reviewer
description: |
  SDLC sub-skill: code review by a dispatched subagent. Keeps the main
  context window free by handing the review to a focused agent that receives
  only the diff and the requirements. Adapted from the
  `requesting-code-review` skill of obra/superpowers
  (https://github.com/obra/superpowers).

  Triggers: code review, before merge, after a feature, /sdlc:review,
  preparing /sdlc:gate, delivered P### to validate, upcoming AQ Gate,
  subagent review.
  Also triggers on (FR): revue de code, relecture, avant merge, P### livrée
  à valider, revue par sous-agent.
---

# sdlc-reviewer — Code review by a dispatched subagent (v4.0)

Adapted from `requesting-code-review` in
[obra/superpowers](https://github.com/obra/superpowers).

## SDLC integration

- **When to use:** (1) right before `/sdlc:gate`, to challenge the diff of
  the current wave; (2) after delivering a major P###; (3) before merging
  into `main`/`master`.
- **Place in the pipeline:** between the end of `dev` (every P### of the
  wave ✅) and `/sdlc:gate`, so defects are handled before the AQ Gate turns
  them into exit 1.
- **Deliverable:** the subagent's markdown report, linked from the notes
  column of the affected P### in `3_conception.md`. The findings are then
  handled with `sdlc-receive-review`.

Before your first tool call, say in one sentence what you're about to do.
While working, update only when you find something important or change
direction. When you finish, lead with the outcome, then the next step.

## Why a subagent

The reviewer gets a precisely built context (description, requirements, git
range), not your session history. It judges the work product rather than
your reasoning, and your own context stays free for the rest of the work.
Review early and often: a defect caught after one P### costs less than one
caught after a whole wave.

## When to request a review

- After each P### when a wave is run task by task, or at least once per wave.
- After a major feature.
- Before merging into the main branch.
- Also useful when stuck (fresh perspective), before a refactor (baseline),
  or after fixing a tricky bug.

## How to request it

**1. Get the git range:**
```bash
BASE_SHA=$(git rev-parse HEAD~1)  # or origin/main, or the commit before the wave
HEAD_SHA=$(git rev-parse HEAD)
```

**2. Dispatch the reviewer:** use the Agent tool with a `general-purpose`
subagent and fill in the template in `code-reviewer.md` (same directory).

Placeholders:
- `{DESCRIPTION}` — short summary of what was built
- `{PLAN_OR_REQUIREMENTS}` — what it should do (P### text, linked E###/A###,
  or the path to `3_conception.md`)
- `{BASE_SHA}` — starting commit
- `{HEAD_SHA}` — ending commit

**3. Filter and act on the report.** The reviewer reports every issue it
finds, with a severity. Triage happens here, not in the reviewer:
- Critical: fix now.
- Important: fix before moving to the next P### or wave.
- Minor: record in the P### notes for later, or fix if trivial.
- If the reviewer is wrong, push back with technical reasoning (code or tests
  that show it works). See `sdlc-receive-review`.

## Example

```
[P002 just completed: add verification function]

BASE_SHA=$(git log --oneline | grep "P001" | head -1 | awk '{print $1}')
HEAD_SHA=$(git rev-parse HEAD)

[Dispatch general-purpose reviewer subagent]
  DESCRIPTION: Added verifyIndex() and repairIndex() with 4 issue types
  PLAN_OR_REQUIREMENTS: P002 in SDLC_PM/v1/3_conception.md (E004, A002)
  BASE_SHA: a7981ec
  HEAD_SHA: 3df7661

[Subagent returns]:
  Strengths: clean architecture, real tests
  Issues:
    Important: missing progress indicators
    Minor: magic number (100) for reporting interval
  Assessment: ready with fixes

[Fix progress indicators, note the magic number in P002 notes]
[Continue with P003]
```

## Things to avoid

- Skipping the review because the change "is simple".
- Moving on with unresolved Critical or Important issues.
- Dismissing valid technical feedback; if you disagree, show code or tests.
