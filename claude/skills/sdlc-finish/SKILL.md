---
name: sdlc-finish
description: |
  SDLC sub-skill: structured close-out of a development branch. Verifies the
  tests, detects the environment (plain repo vs worktree), presents the
  integration options (local merge, PR, keep, discard) and requires a typed
  confirmation for destructive ones. Adapted from the
  `finishing-a-development-branch` skill of obra/superpowers
  (https://github.com/obra/superpowers).

  Triggers: close branch, end of implementation, final merge, delivery,
  /sdlc:finish, /sdlc:exit, after /sdlc:gate exit 0, last P### ✅,
  release preparation, finishing.
  Also triggers on (FR): clôture de branche, fin d'implémentation, merge
  final, livraison, préparation de release.
---

# sdlc-finish — Structured branch close-out (v4.0)

Adapted from `finishing-a-development-branch` in
[obra/superpowers](https://github.com/obra/superpowers).

## SDLC integration

- **When to use:** (1) after `/sdlc:gate` exit 0 on the last wave of a
  version; (2) on `/sdlc:finish`, or alongside `/sdlc:exit` to decide the
  final integration.
- **Place in the pipeline:** final step after a successful `dev → gate`.
  Comes before regenerating HANDOFF and bumping the version in
  `SDLC_PM/v<X>/`.
- **Deliverable:** depending on the chosen option — local merge done, PR
  created and its URL returned, branch kept for later, or cleanup confirmed.
  Record the decision in the "Revisions" section of `HANDOFF.md`.

Before your first tool call, say in one sentence what you're about to do.
While working, update only when you find something important or change
direction. When you finish, lead with the outcome, then the next step.

Write user-facing messages (the option menu, confirmations, the HANDOFF
entry) in the project's `output_language` (`SDLC_PM/sdlc-config.json`; if
absent, the language the user writes in). Keep IDs, commands and branch names
as they are.

## Process

Verify tests → detect environment → determine base branch → present options
→ execute the choice → clean up.

### Step 1: Verify tests

Run the project's test suite before presenting any option, because merging
or opening a PR on failing tests spreads the breakage:

```bash
# Run the project's test suite
npm test / cargo test / pytest / go test ./...
```

If tests fail, stop here and report:

```
Tests failing (<N> failures). They must be fixed before completing:

[Show failures]

Merge/PR is on hold until tests pass.
```

If tests pass, quote the result (see `sdlc-verify`) and continue to step 2.

### Step 2: Detect the environment

```bash
GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
```

This decides which menu to show and how cleanup works:

| State | Menu | Cleanup |
|-------|------|---------|
| `GIT_DIR == GIT_COMMON` (plain repo) | Standard 4 options | No worktree to clean up |
| `GIT_DIR != GIT_COMMON`, named branch | Standard 4 options | Based on provenance (step 6) |
| `GIT_DIR != GIT_COMMON`, detached HEAD | Reduced 3 options (no merge) | None (managed externally) |

### Step 3: Determine the base branch

```bash
# Try common base branches
git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null
```

If unclear, ask: "This branch split from main — is that correct?"

### Step 4: Present the options

Present exactly these options, without extra explanation, so the choice is
quick and unambiguous.

**Plain repo or named-branch worktree — 4 options:**

```
Implementation complete. What would you like to do?

1. Merge back to <base-branch> locally
2. Push and create a Pull Request
3. Keep the branch as-is (I'll handle it later)
4. Discard this work

Which option?
```

**Detached HEAD — 3 options:**

```
Implementation complete. You're on a detached HEAD (externally managed workspace).

1. Push as a new branch and create a Pull Request
2. Keep as-is (I'll handle it later)
3. Discard this work

Which option?
```

### Step 5: Execute the choice

#### Option 1: Merge locally

```bash
# Go to the main repo root so the worktree can be removed safely later
MAIN_ROOT=$(git -C "$(git rev-parse --git-common-dir)/.." rev-parse --show-toplevel)
cd "$MAIN_ROOT"

# Merge first — confirm it succeeded before removing anything
git checkout <base-branch>
git pull
git merge <feature-branch>

# Run the tests on the merged result
<test command>
```

Once the merge and the tests succeed: clean up the worktree (step 6), then
delete the branch:

```bash
git branch -d <feature-branch>
```

#### Option 2: Push and create a PR

```bash
# Push the branch
git push -u origin <feature-branch>

# Create the PR
gh pr create --title "<title>" --body "$(cat <<'EOF'
## Summary
<2-3 bullets of what changed>

## Test Plan
- [ ] <verification steps>
EOF
)"
```

Keep the worktree: the user needs it to iterate on PR feedback.

#### Option 3: Keep as-is

Report: "Keeping branch <name>. Worktree preserved at <path>." Leave the
worktree in place.

#### Option 4: Discard

This deletes work permanently, so ask for a typed confirmation first:

```
This will permanently delete:
- Branch <name>
- All commits: <commit-list>
- Worktree at <path>

Type 'discard' to confirm.
```

Proceed only on the exact word `discard`; any other answer cancels.

If confirmed:
```bash
MAIN_ROOT=$(git -C "$(git rev-parse --git-common-dir)/.." rev-parse --show-toplevel)
cd "$MAIN_ROOT"
```

Then clean up the worktree (step 6) and force-delete the branch:
```bash
git branch -D <feature-branch>
```

### Step 6: Clean up the workspace

Runs only for options 1 and 4; options 2 and 3 always keep the worktree.

```bash
GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
WORKTREE_PATH=$(git rev-parse --show-toplevel)
```

**If `GIT_DIR == GIT_COMMON`:** plain repo, no worktree to clean up. Done.

**If the worktree is under `.worktrees/`, `worktrees/` or
`~/.config/superpowers/worktrees/`:** it was created by this workflow (or by
obra/superpowers), so we own its cleanup:

```bash
MAIN_ROOT=$(git -C "$(git rev-parse --git-common-dir)/.." rev-parse --show-toplevel)
cd "$MAIN_ROOT"
git worktree remove "$WORKTREE_PATH"
git worktree prune  # clean up any stale registrations
```

**Otherwise:** the host environment (harness) owns the workspace. Leave it
in place; if the platform provides a workspace-exit tool, use that instead.
Removing a harness-owned worktree leaves the harness with phantom state.

## Quick reference

| Option | Merge | Push | Keep worktree | Delete branch |
|--------|-------|------|---------------|---------------|
| 1. Merge locally | yes | - | - | yes |
| 2. Create PR | - | yes | yes | - |
| 3. Keep as-is | - | - | yes | - |
| 4. Discard | - | - | - | yes (force, after typed `discard`) |

## Common mistakes

- **Skipping test verification** — merges broken code or opens a failing PR.
  Run the suite before offering options.
- **Open-ended questions** ("What should I do next?") — ambiguous. Present
  the 4 options (3 on detached HEAD).
- **Removing the worktree for option 2** — the user needs it for PR
  iterations. Clean up only for options 1 and 4.
- **Deleting the branch before removing the worktree** — `git branch -d`
  fails while a worktree references the branch. Merge, remove the worktree,
  then delete the branch.
- **Running `git worktree remove` from inside the worktree** — fails when the
  current directory is the worktree. `cd` to the main repo root first.
- **Cleaning up harness-owned worktrees** — only remove worktrees under the
  paths listed in step 6.
- **Discarding without confirmation** — always require the typed word
  `discard`.

## Rules

- Proceed only when the tests pass, and re-run them on the merged result.
- Delete work only after the typed `discard` confirmation.
- Force-push only when the user explicitly asks.
- Remove a worktree only after the merge succeeded, only if you created it,
  and never from inside it; run `git worktree prune` afterwards.
