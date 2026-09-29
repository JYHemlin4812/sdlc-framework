---
name: sdlc-debugger
description: |
  SDLC sub-skill: structured, root-cause-first debugging. Requires
  investigating the root cause before proposing any fix.
  Adapted from the `systematic-debugging` skill of obra/superpowers
  (https://github.com/obra/superpowers).

  Triggers: bug, test failure, unexpected behavior, performance problem,
  build failure, /sdlc:fix, /sdlc:debug, failing T###, blocked P### 🚫,
  AQ Gate exit 1, no fixes without root cause.
  Also triggers on (FR): bug, échec de test, comportement inattendu,
  cause racine, T### rouge, P### bloquée, débogage.
---

# sdlc-debugger — Root-cause-first debugging

Adapted from the `systematic-debugging` skill of
[obra/superpowers](https://github.com/obra/superpowers).

## SDLC integration

- **When to use it**: a failing T###, a P### marked 🚫 or 🔁, an AQ Gate
  exit 1, or through `/sdlc:fix` and `/sdlc:debug`. Use it before editing
  code in reaction to a test failure.
- **Place in the pipeline**: between `dev` (a T### fails) and the re-run of
  the related P###. Do not move on to the next P### until the root cause is
  documented, so later tasks don't build on a broken base.
- **Expected deliverable**: before changing code, add a note
  "root cause identified → fix Y" to `4_tests.md` (on the T###) or to
  `2_5_discussion.md`. Record the task's state in `STATE.md` as usual.
- **Out-of-scope findings**: if the root cause lies in files outside the
  current P###'s Code Lock, record it (see Code Lock) instead of fixing it
  silently.

**Communication** (human-in-the-loop): before your first tool call, say in
one sentence what you're about to do. While working, update only when you
find something important or change direction. When you finish, lead with the
outcome, then the next step.

---

# Systematic debugging

## Overview

Random fixes waste time and create new bugs. Quick patches mask the
underlying issue.

**Core principle:** find the root cause before attempting a fix. A fix that
only addresses the symptom leaves the bug in place and usually moves it.

**The rule:** do not propose a fix until Phase 1 (root cause investigation)
is complete.

## When to use

Any technical issue:
- Test failures
- Bugs in production
- Unexpected behavior
- Performance problems
- Build failures
- Integration issues

The process matters most when a shortcut is tempting: under time pressure,
when "one quick fix" looks obvious, after one or more fixes already failed,
or when you don't fully understand the issue. Simple bugs have root causes
too, and on a simple bug the process is fast.

## The four phases

Complete each phase before starting the next.

### Phase 1: Root cause investigation

Before attempting any fix:

1. **Read error messages carefully**
   - Read warnings and full stack traces; they often point straight at the cause.
   - Note line numbers, file paths, error codes.

2. **Reproduce consistently**
   - Can you trigger it reliably? What are the exact steps?
   - If it is not reproducible, gather more data rather than guessing.

3. **Check recent changes**
   - What changed that could cause this? Git diff, recent commits.
   - New dependencies, config changes, environment differences.

4. **Gather evidence in multi-component systems**

   When the system has several components (CI → build → signing,
   API → service → database), add diagnostic instrumentation before
   proposing fixes:
   ```
   For each component boundary:
     - Log what data enters the component
     - Log what data exits the component
     - Verify environment/config propagation
     - Check state at each layer

   Run once to gather evidence showing where it breaks,
   then analyze the evidence to identify the failing component,
   then investigate that component.
   ```

   **Example (multi-layer system):**
   ```bash
   # Layer 1: Workflow
   echo "=== Secrets available in workflow: ==="
   echo "IDENTITY: ${IDENTITY:+SET}${IDENTITY:-UNSET}"

   # Layer 2: Build script
   echo "=== Env vars in build script: ==="
   env | grep IDENTITY || echo "IDENTITY not in environment"

   # Layer 3: Signing script
   echo "=== Keychain state: ==="
   security list-keychains
   security find-identity -v

   # Layer 4: Actual signing
   codesign --sign "$IDENTITY" --verbose=4 "$APP"
   ```

   This shows which layer fails (secrets → workflow ✓, workflow → build ✗).

5. **Trace data flow**

   When the error is deep in the call stack, see `root-cause-tracing.md` in
   this directory for the full backward-tracing technique. Short version:
   - Where does the bad value originate?
   - What called this with the bad value?
   - Keep tracing up until you find the source.
   - Fix at the source, not at the symptom.

### Phase 2: Pattern analysis

Find the pattern before fixing:

1. **Find working examples**: similar code in the same codebase that works.
2. **Compare against references**: if you are implementing a pattern, read
   the reference implementation in full; partial reading is a common source
   of the bug itself.
3. **Identify differences**: list every difference between working and
   broken, however small. Don't dismiss one as "can't matter" without checking.
4. **Understand dependencies**: other components, settings, config,
   environment, and the assumptions the code makes.

### Phase 3: Hypothesis and testing

Scientific method:

1. **Form a single hypothesis**: "I think X is the root cause because Y."
   Write it down; be specific.
2. **Test minimally**: make the smallest change that tests the hypothesis,
   one variable at a time.
3. **Check the result**: if it worked, go to Phase 4. If not, form a new
   hypothesis instead of stacking more fixes on top.
4. **When you don't know**: say "I don't understand X", research more, or
   ask for help. Pretending to know leads to guessed fixes.

### Phase 4: Implementation

Fix the root cause, not the symptom:

1. **Create a failing test case**
   - Simplest possible reproduction; an automated test if possible, a
     one-off script if there is no framework.
   - Have it before fixing, so you can prove the fix works. In SDLC this is
     the T### for the P###; use the `sdlc-evolve` skill (RED → GREEN →
     REFACTOR) to write it.

2. **Implement a single fix**
   - Address the identified root cause, one change at a time.
   - No "while I'm here" improvements or bundled refactoring; they make it
     impossible to tell what fixed the bug.

3. **Verify the fix**: run the test suite and read the output (see
   `sdlc-verify`). The new test passes, no other test broke, the issue is
   actually resolved.

4. **If the fix doesn't work**
   - Count how many fixes you have tried.
   - Fewer than 3: return to Phase 1 and re-analyze with the new information.
   - 3 or more: stop fixing and question the architecture (step 5). Don't
     attempt a fourth fix without that discussion.

5. **If 3+ fixes failed: question the architecture**

   Signs of an architectural problem:
   - Each fix reveals new shared state, coupling or a problem in a different place.
   - Fixes would require a large refactoring.
   - Each fix creates new symptoms elsewhere.

   Question the fundamentals: is this pattern sound, or are we keeping it
   out of inertia? Should the architecture change rather than the symptoms
   keep being patched?

   Discuss with the user before attempting more fixes. In SDLC, before
   marking the P### 🚫, state the root-cause hypothesis and the evidence in
   the task notes, then escalate (a new A### decision may be needed).

   This is not a failed hypothesis; it is a wrong architecture.

## Red flags

These thoughts mean you are skipping the process; return to Phase 1:
- "Quick fix for now, investigate later."
- "Just try changing X and see if it works."
- "Add several changes, then run the tests."
- "Skip the test, I'll check manually."
- "It's probably X, let me fix that."
- "I don't fully understand, but this might work."
- Proposing solutions before tracing the data flow.
- "One more fix attempt" after two or more have failed (see Phase 4, step 5).

Signals from the user that the approach is off: "Is that not happening?"
(you assumed without verifying), "Will it show us...?" (you should have
gathered evidence), "Stop guessing", "We're stuck?". When you see these,
return to Phase 1.

## Common rationalizations

| Excuse | Reality |
|--------|---------|
| "Issue is simple, no process needed" | Simple issues have root causes too; the process is fast for them. |
| "Emergency, no time for process" | Systematic debugging is faster than guess-and-check. |
| "I'll write the test after confirming the fix" | Untested fixes don't stick; the test first proves it. |
| "Several fixes at once saves time" | You can't isolate what worked, and it causes new bugs. |
| "I see the problem, let me fix it" | Seeing symptoms is not understanding the root cause. |

## Quick reference

| Phase | Key activities | Success criteria |
|-------|---------------|------------------|
| **1. Root cause** | Read errors, reproduce, check changes, gather evidence | Understand what and why |
| **2. Pattern** | Find working examples, compare | Differences identified |
| **3. Hypothesis** | Form a theory, test minimally | Confirmed, or new hypothesis |
| **4. Implementation** | Create test, fix, verify | Bug resolved, tests pass |

## When the process finds "no root cause"

If the investigation shows the issue is truly environmental, timing-dependent
or external:

1. Document what you investigated.
2. Implement appropriate handling (retry, timeout, error message).
3. Add monitoring/logging for future investigation.

Most "no root cause" conclusions turn out to be incomplete investigations, so
make sure Phases 1–3 were actually done.

## Supporting techniques

In this directory:
- **`root-cause-tracing.md`** — trace bugs backward through the call stack to the original trigger.
- **`defense-in-depth.md`** — add validation at several layers after finding the root cause.
- **`condition-based-waiting.md`** — replace arbitrary timeouts with condition polling.
- **`find-polluter.sh`** — bisect which test creates unwanted files or state.

Related SDLC skills:
- **`sdlc-evolve`** — TDD discipline for the failing test case (Phase 4, step 1).
- **`sdlc-verify`** — run the verification command and quote its result before claiming the fix works.
