---
description: Wave-by-wave implementation with test cases T### (phases 3+4)
argument-hint: "[--auto-approve] [--wave N] [--review-each] [--strict-confirm]"
---

# /sdlc:dev

**Phases 3+4** — Implementation and tests. Output: code, commits, updated `4_tests.md`.
**Precondition**: AQ Gate ✅ on `2_architecture.md` and `3_conception.md`.

Write artifact content and user-facing messages in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template headings and field markers in English.

## Steps
1. Read `sdlc-config.json` and resolve the model profile, parallelism and retries.
2. Pick the first unfinished wave, or wave N if `--wave N` is given (`--vague N` is accepted as an alias).
3. For each P###: check Code Lock, then spawn one subagent per P### (Agent tool, when
   `fresh_context_per_task: true`) or run it inline. Delegate only whole P### tasks, never work
   doable in a handful of tool calls or a re-check of your own work, and respect `max_parallel_agents`.
4. Take the mutex through `lockfile_helper.py` before updating `STATE.md`.
5. On failure: retry with model escalation, up to `max_retry_per_task`. When retries are exhausted,
   state the root-cause hypothesis and its evidence in the task notes, then mark the P### 🚫 and
   escalate to the user.
6. **Evidence before ✅**: invoke the `sdlc-verify` sub-skill (Skill tool). Mark a P### ✅ only after
   running the tests/lint/build/`git status` yourself and quoting the result, not on a subagent's
   report alone.
7. **Review after a major P###** (`--review-each`, recommended except for purely mechanical P###):
   run the `sdlc-reviewer` sub-skill (Skill tool), then `sdlc-receive-review` (Skill tool), on the
   P###'s diff, to catch problems as you go rather than all at once before the gate.
   Note: `sdlc-reviewer` is a sub-skill (Skill tool), not a `subagent_type` of the Agent tool; the
   sub-skill dispatches its own `general-purpose` subagent.
8. Update `3_conception.md` (✅/🔁/🚫) and `4_tests.md` (T### added).
9. When every wave is ✅, run `/sdlc:gate`.

Flags: `--auto-approve` (no Y/N between steps), `--wave N` (target a wave), `--review-each` (review
after each major P###), `--strict-confirm` (confirm every P###, for debugging).

## Auto-approve mode

Only when `--auto-approve` is active (flag, `auto_approve: true` in config, or `SDLC_AUTO_APPROVE=1`);
never in interactive mode. The checklist is the statuses in `3_conception.md` plus `STATE.md`.

In auto-approve mode nobody is watching the turn. A message without a tool call ends your turn
and stops the run. Do not end a turn with (1) a summary that announces the next step instead
of taking it, (2) an offer to continue "unless you prefer otherwise", (3) a list of decisions
none of which blocks the remaining work, or (4) a pause because a wave or milestone finished.
Put status notes in the same message as your next tool call and keep going while `⬜`/`🔁`
tasks remain. Stop only when every task is ✅ and the AQ Gate passed, when a task becomes 🚫,
when Code Lock or the AQ Gate refuses progress, or before a destructive/irreversible action
(these still need the user).

Details: `~/.claude/skills/sdlc/SKILL.md` (`/sdlc:dev` section),
`~/.claude/skills/sdlc/references/slash-commands.md`,
`~/.claude/skills/sdlc/references/auto-approve.md`,
`~/.claude/skills/sdlc/references/code-lock.md`.
