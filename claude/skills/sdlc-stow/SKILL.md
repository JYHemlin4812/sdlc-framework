---
name: sdlc-stow
description: |
  SDLC sub-skill: end-of-session sweep that captures durable knowledge still
  living only in the conversation (preferences, project facts, gotchas,
  standing decisions, unfinished next steps) into `SDLC_PM/STOW.md`, with tiered
  decay so stale entries are re-validated or archived instead of piling up.

  Use it via `/sdlc:stow`, as the optional first step of `/sdlc:exit`, or before
  a context reset or long break. Triggers: stow, sweep the session, save what
  we learned, capture session knowledge, before context reset.
  Also triggers on (FR): balayage de session, consigner ce qu'on a appris,
  avant de réinitialiser le contexte.
---

# sdlc-stow — capture what only the conversation knows

Concept adapted from the `stow` skill of kunchenguid/firstmate (MIT). Narrower
on purpose: one destination, no routing to trackers or global memory.

The goal is a compact, current operating map for the next session, not a
journal: every durable finding lands on disk, and the file comes out more
accurate, not merely longer.

## Destination

`SDLC_PM/STOW.md`, one file per project. If `SDLC_PM/` does not exist, say so
and suggest `/sdlc:init`; do not create it. Create `STOW.md` on first use with
this skeleton (headings stay in English, entries go in `output_language`):

```markdown
<!-- memory tiers: see the sdlc-stow skill -->
# STOW

## Preferences
## Project facts
## Gotchas
## Decisions
## Next steps
```

One entry is one list line (`- ...`) ending with a tier marker. Keep entries to
a single line so decay can move them whole.

## Tiers

| Marker | Tier | Stale at | Use for |
|---|---|---|---|
| `<!--P-->` | pinned | never | rules the user stated as standing |
| `<!--a:YYYY-MM-DD-->` | aging | 30 days since the date | facts, gotchas, decisions |
| `<!--p:YYYY-MM-DD-->` | perishable | 7 days since the date | state that expires; the text must name a checkable condition (ticket, version, date), otherwise use aging |

The date is the last time the entry was reinforced by real evidence from the
current session (used, confirmed, re-derived). Re-reading the file is not
reinforcement.

## Steps

1. **Sweep the conversation** for uncaptured durable knowledge:
   preferences stated in passing, project facts (build, test, deploy,
   conventions), gotchas and non-obvious causes, decisions that should outlive
   the session, and next steps nobody wrote down.
2. **Check each finding against its owner first.** If it already lives in
   `0_context.md`, `2_architecture.md`, `HANDOFF.md` or the code, write a
   one-line pointer to that owner, not a copy, so the note cannot go stale on
   its own.
3. **Read `STOW.md` in full, then classify each finding**: new, duplicate,
   superseding an entry, or proof that an entry is obsolete. Rewrite the entry
   it supersedes and fold duplicates; prefer one rewritten sentence over a
   second near-identical entry. File each next step with what it waits on when
   it is blocked.
4. **Curate the whole file, not only what you touched.** Run
   `python scripts/stow_decay.py stale SDLC_PM/STOW.md`. For every stale entry,
   either refresh its date (current evidence re-validates it) or archive it
   with `python scripts/stow_decay.py archive SDLC_PM/STOW.md --line N --reason "..."`.
   Stamp every `unmarked` entry with a dated marker when you can confirm it,
   otherwise archive it with the reason `legacy-unvalidated`. Stale never means
   deleted: archived entries land in `SDLC_PM/.stow-archive.md`, git-ignored,
   and are recovered by copying the line back.
5. **Report** one action per touched entry group (`added`, `rewritten`,
   `archived`, `pointer`, `unchanged`), what could not be captured and why, and
   a verdict: safe to end the session or not. Close with a resume pointer, for
   example `To resume cold, load: SDLC_PM/HANDOFF.md, SDLC_PM/STOW.md`.

## Boundaries

- Write only `SDLC_PM/STOW.md` and its archive. Never stage, commit or push.
- Never file credentials or secrets; the file is plain text and may be shared.
- Never file to an issue tracker or any external system.
- Mark entries aging by default; use pinned only for something the user stated
  as a standing rule, and perishable only with a checkable condition.

## Validation

`tests/test_stow_decay.py` covers the tier horizons (boundary days), pinned and
unmarked handling, archiving with provenance, the archive's `.gitignore` line
and the refusal of non-entry lines. Run: `python -m pytest tests/ -v`.
