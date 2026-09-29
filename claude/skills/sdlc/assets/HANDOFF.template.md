# HANDOFF — `<project name>`

> **Language**: write this file's content in the project's `output_language`
> (`SDLC_PM/sdlc-config.json`). Keep headings, field markers and IDs in
> English so the tooling can parse them.

> **Purpose**: if anyone (human or AI, six months from now) reopens this
> project cold, this file lets them resume **in under 2 minutes**. Read it
> first.
>
> Updated **automatically** by `/sdlc:exit` and by `/sdlc:gate` on ✅.
> Can also be edited by hand at any time.

---

## Identity

- **Project** : `<name>`
- **Current version** : `v<X.Y.Z>`
- **Last updated** : `<YYYY-MM-DD HH:mm>` by `<author>`
- **Tier** : `<minimal | standard | full | exhaustive>`

---

## Where things stand (10 lines max)

`<Exact state of the project at the time of the update: what was just done,
what works, what does not, where work stopped, and why. Terse style. Do not
retell the whole history — only the current state + the last transition.>`

---

## Next 3 actions

> **No more than 3**, so the list forces a priority choice.

1. **`<action 1, imperative verb>`**
   - **Why** : `<reason>`
   - **Where** : `<file:line or task P###>`
   - **Done when** : `<verifiable criterion>`

2. **`<action 2>`**
   - **Why** : `<...>`
   - **Where** : `<...>`
   - **Done when** : `<...>`

3. **`<action 3>`**
   - **Why** : `<...>`
   - **Where** : `<...>`
   - **Done when** : `<...>`

---

## Known pitfalls

Things that already bit, or bite as soon as attention is elsewhere.

- ⚠️ `<pitfall>` — `<how to avoid it>`
- ⚠️ `<pitfall>` — `<...>`

---

## Pending decisions

Choices that only wait for an answer to unblock the rest. Empty list = project
fully unblocked.

| ID | Question | Blocks | Deadline |
|---|---|---|---|
| D1 | `<e.g. choose SQLite vs Postgres for the cache>` | `<P017>` | `<YYYY-MM-DD or "before next release">` |

---

## Revisions

Decisions that closed a branch or a release (written by `/sdlc:finish`), newest first.

| Date | Branch / version | Decision (merge / PR / keep / discard) | Notes |
|---|---|---|---|
| `<YYYY-MM-DD>` | `<feature/x or v1.0.0>` | `<merge>` | `<PR link, commit, reason>` |

---

## How to resume (copy-paste)

```
1. cd <project path>
2. <command to activate the venv / install dependencies>
3. <command to run the tests — must pass today>
4. Read RESUME.md, then 0_context.md (tier ≥ standard)
5. Resume at action 1 above
```

---

## If something is on fire (active incident)

> **Empty** in normal times. Fill it only while a serious blocker is ongoing
> and an emergency responder needs to know what to do.

- **Nature of the incident** : `<...>`
- **Last attempt** : `<YYYY-MM-DD HH:mm>` — `<result>`
- **Temporary workaround** : `<...>`
- **Who to contact** : `<if someone else is better placed>`

---

## Technical metadata

- **Current SDLC phase** : `<E | A | P | T | release | none>`
- **Last P### done** : `<P0XX ✅ or "none">`
- **Next P### to run** : `<P0XX or "none pending">`
- **Last AQ Gate exit code** : `<0 ✅ | 1 ❌ | not run>`
- **Last clean commit** : `<sha + message + date>`
