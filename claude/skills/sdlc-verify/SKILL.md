---
name: sdlc-verify
description: |
  SDLC sub-skill: evidence before any completion claim. Do not state that work
  is done, fixed or green until you have run the verification command in the
  current session and read its output. Adapted from the
  `verification-before-completion` skill of obra/superpowers
  (https://github.com/obra/superpowers).

  Triggers: "done", "delivered", "tests pass", "fixed", before a commit,
  before `/sdlc:gate`, before relaying a dev subagent's report, evidence
  before claims, marking a P### ✅, background agent report.
  Also triggers on (FR): « c'est fait », « livré », « tests verts »,
  « corrigé », « ça passe », preuve avant déclaration.
---

# sdlc-verify — Evidence before claims (v4.0)

Adapted from `verification-before-completion` in
[obra/superpowers](https://github.com/obra/superpowers).

## SDLC integration

- **When to use:** just before marking a P### ✅, before any commit, before
  `/sdlc:gate`, and before relaying the report of a dev subagent
  (`sdlc-python-dev`, `-js-dev`, `-go-dev`, `-rust-dev`).
- **Why it matters here:** dev subagents running in the background do not
  always have shell access (so they cannot run the tests), and their reports can
  be wrong ("already delivered" when `git status` shows nothing). The
  orchestrator produces the evidence itself instead of trusting the report.
  This complements the structural AQ Gate with a behavioral rule.
- **Place in the pipeline:** the step between "the code looks written" and
  "the P### is ✅". The status changes only once the evidence has been read.
- **Deliverable:** the actual output (command, relevant excerpt, exit code)
  pasted into the P### notes in `3_conception.md` or into `4_tests.md`, never a
  bare assertion.

## The rule

Claim completion only after you have run the command that proves it, in this
session, and read its output. A previous run, an agent's report or a strong
intuition is not evidence; the command output is.

## How to verify

Before stating a status or reporting success:

1. **Identify** the command that proves the claim (test suite, linter, build,
   `git status`, running the program).
2. **Run** it in full, now. A single test does not prove the suite passes.
3. **Read** the output and the exit code; note every failure.
4. **Claim** the result that the output supports, quoting it (command, the
   decisive lines, exit code). If it shows failures, report those instead.

One run of the right command is enough. Run it again only after changing code.

## What counts as evidence

| Claim | Not enough | Evidence |
|---|---|---|
| "Tests pass" | "I just changed it, it should pass" | Fresh run of the suite, exit 0 |
| "Lint is clean" | "I didn't see errors" | Linter run, 0 errors |
| "Build works" | "It compiled before" | Fresh full build |
| "Bug is fixed" | "I changed the cause" | Repro test that failed now passes |
| "No regression" | "I only touched one file" | Full suite run |
| "The agent delivered" | The agent's report says so | `git status`/diff and tests you ran yourself |
| "Requirement met" | "Looks right" | BDD acceptance criterion executed |

## Signs you are about to skip it

- Wording such as "should", "probably", "looks like it works".
- Reporting success before the command has run.
- Committing without a fresh run.
- Relaying a subagent's self-report as fact.
- Running a subset (one test) and claiming the whole.
- "Trivial change, no need" — trivial changes break things too, and the run
  is usually quick.

## Bottom line

A P### is ✅ only once fresh evidence has been read and quoted. An agent's
report is a claim to check, not evidence. E→A→P→T traceability and the AQ Gate
define *what* to deliver; this skill makes sure nobody claims it was delivered
without having seen it work.
