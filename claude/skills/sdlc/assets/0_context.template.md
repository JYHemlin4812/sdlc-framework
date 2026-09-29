# 0 — Context (state of the world)

> **Language**: write this file's content in the project's `output_language`
> (`SDLC_PM/sdlc-config.json`). Keep headings, field markers and IDs in
> English so the tooling can parse them.

> SDLC phase 0 — **the first thing whoever picks up the project reads**.
> Describes the state of the world when the project starts: constraints in
> force, **dated** time-bound assumptions, known external dependencies. This
> file is never "finished": update it whenever the state of the world changes
> (new constraint, dependency change, invalidated assumption).

---

## Metadata

- **Project** : `<name>`
- **Current version** : `v1.0.0`
- **Original author** : `<author>`
- **Created** : `<YYYY-MM-DD>`
- **Last updated** : `<YYYY-MM-DD>`
- **Documentation tier** : `<minimal | standard | full | exhaustive>`

---

## Pitch (10 lines max)

In at most 10 lines: **why** this project exists, **who** uses it, **what
problem** it solves, and **what the next step visible** to the end user is.
Terse style — whoever picks up the project should grasp its purpose in under a
minute.

---

## Constraints in force

Decisions made **before** or **around** the project that it must follow.
Distinct from A### (internal architecture): list here what is NOT negotiable.

| ID | Constraint | Source | Date | Type |
|---|---|---|---|---|
| C1 | `<e.g. backend must stay on Python 3.12>` | `<owner decision / production dependency / company policy>` | `<YYYY-MM-DD>` | `tech \| business \| legal \| time` |
| C2 | `<e.g. no paid API calls in CI>` | `<...>` | `<...>` | `<...>` |

---

## Time-bound assumptions (dated)

Give every assumption an issue date AND a "valid until" date, so whoever picks
up the project six months later sees at once what may be stale.

| ID | Assumption | Issued | Valid until | Action if invalidated |
|---|---|---|---|---|
| H1 | `<e.g. the provider API stays free up to 1M tokens/month>` | `<YYYY-MM-DD>` | `<YYYY-MM-DD or "reassess Q3 2026">` | `<e.g. switch to Haiku, see A007>` |
| H2 | `<...>` | `<...>` | `<...>` | `<...>` |

---

## External dependencies

Systems, APIs, files, accounts and secrets the project needs to run but does
**not control**.

| Dependency | Type | Where it is documented | Risk if unavailable |
|---|---|---|---|
| `<e.g. Microsoft Graph API>` | API | `<doc link + credentials file>` | `<blocks email intake, see P012>` |
| `<e.g. shared "MyProject" folder>` | Storage | `<path>` | `<degraded history reads>` |

---

## State of the world — snapshot

> Updated on every work session. Describes what is **true today** about the
> project's environment.

- **Snapshot date** : `<YYYY-MM-DD>`
- **Branch / git state** : `<branch, commit, clean or WIP>`
- **Tested environment** : `<OS, runtime versions, machines>`
- **Reference data used** : `<dataset, fixture, test set>`
- **Active credentials** : `<never a secret here — point to the secret
  manager (DPAPI, 1Password, .env)>`

---

## Out-of-scope decisions (explicit)

Things **deliberately excluded**, with the reason. Guards against scope creep
and "I forgot why we don't do X".

| ID | Out of scope | Reason | Date | Reconsider if |
|---|---|---|---|---|
| OOS1 | `<e.g. no Windows ARM support>` | `<no user demand + high test cost>` | `<YYYY-MM-DD>` | `<≥3 requests or an enterprise customer>` |

---

## Context change log

Append-only. One line per notable change in the state of the world.

- `<YYYY-MM-DD>` — `<change>` (`<author>`)

---

## Suggested reading order for whoever picks up the project

1. Read this file in full (3-5 min).
2. Read `RESUME.md` (technical bootstrap).
3. Read `HANDOFF.md` (exact state + next 3 actions).
4. If tier ≥ `standard`: skim `SDLC_PM/v<version>/1_elicitation.md` to
   understand the business requirements.
