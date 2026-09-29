---
name: sdlc-receive-review
description: |
  SDLC sub-skill: receiving code review feedback with technical rigor.
  Verify before implementing, ask before assuming, and respond with technical
  substance instead of performative agreement ("You're absolutely right!",
  thanks). Counterpart of `sdlc-reviewer` (which produces the review); adapted
  from the `receiving-code-review` skill of obra/superpowers
  (https://github.com/obra/superpowers).

  Triggers: review feedback received, code review comments to process, a
  reviewer's suggestion (human or subagent), unclear or technically doubtful
  feedback, after `/sdlc:review`, before applying review fixes.
  Also triggers on (FR): retour de revue, feedback de revue, commentaires de
  PR, suggestion du revieweur, appliquer les correctifs de revue.
---

# sdlc-receive-review — Receiving code review (v4.0)

Adapted from `receiving-code-review` in
[obra/superpowers](https://github.com/obra/superpowers).

## SDLC integration

- **When to use:** as soon as review feedback arrives — from the
  `sdlc-reviewer` report, an external reviewer (GitHub PR), or the user.
  `sdlc-reviewer` produces the review; `sdlc-receive-review` processes it.
- **Place in the pipeline:** between `/sdlc:review` and the fixes, right
  before `/sdlc:gate`. Every review fix goes through the checks below before
  it is coded.
- **Why:** feedback is a suggestion to evaluate, not an order. Reviewers
  (especially subagents) lack context and can be wrong; accepting everything
  unchecked introduces regressions the AQ Gate will not always catch.
- **Deliverable:** for each review item, a recorded decision (applied /
  declined with a technical reason / clarification requested) in the notes of
  the affected P###.

Before your first tool call, say in one sentence what you're about to do.
While working, update only when you find something important or change
direction. When you finish, lead with the outcome, then the next step.

## Principle

Code review calls for technical evaluation, not social performance. Verify
before implementing, ask before assuming, and put technical correctness ahead
of comfort.

## Response pattern

1. **Read** all the feedback before reacting.
2. **Understand**: restate each requirement in your own words, or ask.
3. **Verify** it against the actual codebase.
4. **Evaluate**: is it technically sound for this codebase?
5. **Respond** with a technical acknowledgment or reasoned pushback.
6. **Implement** one item at a time and test each.

## How to respond

Respond with substance: restate the technical requirement, ask a precise
question, push back with reasoning, or simply make the fix and show it.
Avoid performative agreement — "You're absolutely right!", "Great point!",
thanks, or "implementing it now" before you have checked — because it signals
acceptance before any verification happened and adds nothing the reader can
use.

Good acknowledgments:
- "Fixed. [short description of what changed]"
- "Confirmed: [precise problem]. Fixed in [location]."
- Making the fix and letting the diff show it.

## Unclear feedback

If any item is unclear, ask about it before implementing anything, because
items are often related and a partial understanding leads to a wrong
implementation.

Example — "Fix 1–6", and you understand 1, 2, 3 and 6 but not 4 and 5:
- Not: implement 1, 2, 3, 6 now and ask about 4 and 5 later.
- Instead: "I understand 1, 2, 3 and 6. I need clarification on 4 and 5
  before going further."

## By source

**From the user:** trusted. Implement once you understand it; still ask if
the scope is unclear; skip the performative agreement and go straight to the
work.

**From an external reviewer or a subagent:** before implementing, check:
1. Is it technically correct for this codebase?
2. Does it break existing functionality?
3. Is there a reason for the current implementation?
4. Does it work on every target platform/version?
5. Did the reviewer have the full context?

If the suggestion looks wrong, push back with technical reasoning. If you
cannot verify it, say so: "I can't verify this without X. Should I
investigate, ask, or proceed?" If it conflicts with an earlier decision by the
user (an A### or an ADR), stop and discuss it with the user first.

## YAGNI check on "do it properly" suggestions

When a reviewer asks to "implement this properly", grep the codebase for
actual usage first:
- Unused: "This isn't called anywhere. Remove it (YAGNI)?"
- Used: implement it properly.

## Implementation order

For multi-item feedback:
1. Clarify everything unclear first.
2. Implement in this order: blocking issues (breakage, security), then
   simple fixes (typos, imports), then complex fixes (refactor, logic).
3. Test each fix on its own.
4. Check for regressions with a full run (see `sdlc-verify`).

## When to push back

Push back when the suggestion breaks existing behavior, comes from a reviewer
without full context, violates YAGNI, is wrong for this stack, ignores a
compatibility/legacy reason, or conflicts with an architecture decision of the
user. Do it with technical reasoning rather than defensiveness: precise
questions, references to working tests or code, and the user involved when
the question is architectural.

## Common mistakes

| Mistake | Instead |
|---|---|
| Performative agreement | State the requirement, or just act |
| Blind implementation | Check against the codebase first |
| Batch of untested fixes | One at a time, test each |
| Assuming the reviewer is right | Check whether it breaks something |
| Avoiding pushback | Technical correctness over comfort |
| Partial implementation | Clarify every item first |
| Proceeding without being able to verify | State the limit, ask for direction |

## Bottom line

External feedback is a set of suggestions to evaluate, not orders to follow.
Verify, question, then implement.
