# SDLC documentation tiers

> The **real goal of SDLC**: let anyone (human or AI) pick up an abandoned project at any moment.
>
> The **documentation needed is not uniform**: a one-liner script needs nothing, a colossal
> project needs a complete record. The `documentation_tier` field of `sdlc-config.json` sets this
> level per project.

All tier deliverables are written in the project's `output_language` (`SDLC_PM/sdlc-config.json`;
if absent, the language the user writes in). IDs, template headings and field markers
(`**Depends on**`, `**Target files**`, `**Status**`, `**wave**`) stay in English so the scripts
can parse them. Match each document's length to what the project needs; no filler sections,
redundant summaries or boilerplate.

---

## The 5 tiers

| Tier | Target | Doc effort | Required deliverables |
|---|---|---|---|
| `none` | One/two-liner script, throwaway prototype | 0 | None. The commit message is enough. |
| `minimal` | Small utility (10–500 LOC) | ~30 min | `HANDOFF.md` + `RESUME.md` only |
| `standard` | Medium project (500–5k LOC) | ~3 h | `0_context.md` + `1_elicitation.md` (light) + `3_conception.md` + `HANDOFF.md` + `RESUME.md` |
| `full` | Large project (5k–50k LOC) | ~1 day | Complete E→A→P→T cycle + `0_context.md` + ADRs in `2_5_discussion.md` + `HANDOFF.md` + `RESUME.md` |
| `exhaustive` | Colossal project (>50k LOC or ≥3 languages) | open | Tier `full` + ASVS L2+ audit + per-phase hooks + Phase Z archive (planned, not yet implemented) + version log |

---

## Size → tier mapping (`/sdlc:init` recommendation)

At `/sdlc:init`, the orchestrator asks for the project's `output_language` and **estimated size**,
then **proposes** a default tier, which the user can change.

| User estimate | `project_size_estimate` | Proposed `documentation_tier` |
|---|---|---|
| "It's a one-liner / I'm trying something" | `one-liner` | `none` |
| "Small utility, fits in one file" | `small` | `minimal` |
| "Medium project, several modules" | `medium` | `standard` |
| "Large project, a team or production ambitions" | `large` | `full` |
| "Colossal, multi-language, multi-team, critical" | `colossal` | `exhaustive` |

**An override is always possible.** A 50-line script that is critical in production can justify
`full`; a throwaway 10k-line MVP can stay `minimal`. LOC is an indicator, not a rule.

---

## Per-tier deliverables and steps

### Tier `none`

- No `SDLC_PM/` structure is created.
- No `/sdlc:*` command generates a file.
- The commit message is the documentation.
- **When**: quick prototyping, exploration, throwaway snippet.
- **Risk**: if the project survives, move to `minimal` as soon as it outgrows one file or someone
  else uses it.

### Tier `minimal`

- Creates `SDLC_PM/` with only `HANDOFF.md` + `RESUME.md`.
- No E/A/P/T phases, no gates, no AQ.
- `/sdlc:exit` updates `HANDOFF.md`.
- **When**: personal project, small utility, less than a week of planned work.
- **Promote to `standard`** when the project has >500 LOC OR >3 dependencies OR is used by someone
  else.

### Tier `standard`

- Creates the full `SDLC_PM/v<X.Y.Z>/` structure.
- **Required deliverables**:
  - `0_context.md` (state of the world + dated assumptions)
  - `1_elicitation.md` (light E### — MUST only; BDD criteria not required on every requirement)
  - `3_conception.md` (P### with waves — minimal)
  - `HANDOFF.md` + `RESUME.md` up to date
- **Optional deliverables**: `2_architecture.md`, `4_tests.md`.
- **Light** AQ Gate: checks E→P consistency (skipping A and T is accepted), and `HANDOFF.md` must
  exist and be dated less than 7 days ago.
- **When**: medium project, 1 week – 3 months.

### Tier `full`

- **All** SDLC deliverables are required:
  - `0_context.md`
  - `1_elicitation.md` (complete E### + BDD)
  - `2_architecture.md` (A###:E### + ADR)
  - `2_5_discussion.md` (for M/L projects)
  - `3_conception.md` (P###:A### + wave)
  - `4_tests.md` (T###:P### + coverage)
  - `HANDOFF.md` + `RESUME.md`
- **Complete** AQ Gate: strict E→A→P→T + minimum coverage + ASVS L1+.
- **When**: serious project, more than 3 months, or production impact.

### Tier `exhaustive`

- Tier `full` plus:
  - ASVS L2 or L3 required (`asvs_level >= 2`).
  - Per-phase hooks enabled (`hooks/` present and run — planned, not yet implemented).
  - Phase Z (immutable archive) at each release or abandonment (planned, not yet implemented).
  - A version log kept in addition to `CHANGELOG.md`.
- **When**: critical, multi-team, long-running or regulated system.

---

## Orchestrator behavior per tier

The SDLC orchestrator reads `documentation_tier` at the start of every command and adapts:

| Command | `none` | `minimal` | `standard` | `full` | `exhaustive` |
|---|---|---|---|---|---|
| `/sdlc:init` | refuses | creates HANDOFF+RESUME | + 0_context + 1_elicitation (light) + 3_conception | + 2_arch + 2_5_discussion + 4_tests | + hooks + Phase Z |
| `/sdlc:brainstorm` | refuses | refuses | light E### (MUST only) | complete E### + BDD | as full + ASVS hints |
| `/sdlc:plan` | refuses | refuses | simple P### | A###+P###+wave | as full + full ADR |
| `/sdlc:dev` | free mode | free mode | wave orchestrator optional | wave orchestrator + fresh contexts | as full + pre-merge audit |
| `/sdlc:gate` | n/a | checks HANDOFF date | checks E→P + HANDOFF | strict E→A→P→T | as full + ASVS L2+ |
| `/sdlc:exit` | n/a | updates HANDOFF | updates HANDOFF + 0_context | same + current phase | same + archive snapshot |
| `/sdlc:report` | n/a | HANDOFF summary | same + requirements review | full version report | same + version log |

---

## Promotion / demotion

A project's tier **can change**:

- **Promotion** (tier up): a `minimal` project that grows can move to `standard`. The orchestrator
  then generates the missing files from `HANDOFF.md` and an analysis of the existing code.
- **Demotion** (tier down): a `full` project can drop to `standard` if the ambition shrinks.
  **No file is deleted** — it simply stops being required by the AQ Gate.

How: edit `documentation_tier` in `sdlc-config.json`, then run `/sdlc:gate` to see what is missing
or now optional.

---

## Adopting SDLC on an existing project

> Pattern validated on a ~3,500 LOC project already in production, whose earlier phases were
> documented only in `CHANGELOG.md` and project notes.

When adopting SDLC **on an existing project**, retrofitting history is usually
counter-productive. Recommended pattern:

### Recommended minimal configuration

```json
{
  "version": "4.0",
  "output_language": "en",
  "documentation_tier": "standard",
  "code_lock_enabled": false,
  "project_size_estimate": "medium"
}
```

- **`code_lock_enabled: false`**: required, because Code Lock would otherwise block every change
  to source files that have no ✅ P###, which makes it impossible to keep working on existing code.
- **`documentation_tier: standard`**: the best return on effort. It captures the current state and
  the next actions without a full retrofit.
- **`output_language`**: set it to the language the project's documentation should be written in.

### Which files to fill in / leave as placeholders

| File | Action | Why |
|---|---|---|
| `HANDOFF.md` | **Fill in** | Core of the adoption: current state + next 3 actions + pitfalls. First thing whoever picks up the project reads. |
| `RESUME.md` | **Fill in** | Technical bootstrap (venv, deps, referenced secrets, commands). Key to resuming in <10 min. |
| `v1.0.0/0_context.md` | **Fill in** | State of the world + constraints in force + dated assumptions + external dependencies + out-of-scope. Captures what the outside world imposes on the project. |
| `v1.0.0/1_elicitation.md` | **Leave as placeholder** | Historical requirements already live in `CHANGELOG.md`, `README.md` or project notes. Do not duplicate. |
| `v1.0.0/2_architecture.md` | **Leave as placeholder** | Same — the historical architecture lives in the code and project docs. |
| `v1.0.0/2_5_discussion.md` | **Leave as placeholder** | Historical ADRs are settled. |
| `v1.0.0/3_conception.md` | **Leave as placeholder** | Historical P### are closed. The **next** ones are in `HANDOFF.md`. |
| `v1.0.0/4_tests.md` | **Leave as placeholder** | The existing test suite already lives under `tests/`. |

### Bumping the SDLC version later

When the project starts **a new round of work** (major feature, significant refactor, migration),
create `v1.1.0/` and fill in the E→A→P→T phases **for that round only**. SDLC versioning follows
the development cycle, not the production code.

### AQ Gate on an adopted project

The AQ Gate fails while `1_elicitation.md` and `3_conception.md` are placeholders — **this is
expected and accepted**. The goal is not a green gate on a retrofitted project; it is an
up-to-date `HANDOFF.md` + `RESUME.md` + `0_context.md`. Do not fill in historical phases
artificially to force the gate to pass.

### When to promote to `full`

When the project switches to a major round of work handled entirely with SDLC (complete E→A→P→T
cycle, traced end to end): create `v<X>/` and set `documentation_tier: full` in the config. Tier
`standard` then remains a quick capture step for the initial retrofit.

---

## Anti-patterns

- ❌ **Tier `none` on a project used in production.** If someone depends on it, use `minimal` at
  least.
- ❌ **Tier `exhaustive` on a prototype.** The documentation effort blocks exploration. Promote
  only once the project is validated.
- ❌ **Skipping `HANDOFF.md` on tier `minimal`.** It is precisely the file that prevents
  abandonment, so it is always required from `minimal` up.
- ❌ **Undated assumptions in `0_context.md`.** Whoever picks up the project cannot tell "true
  today" from "true in 2023".

---

## See also

- `../assets/0_context.template.md`
- `../assets/HANDOFF.template.md`
- `../assets/RESUME.template.md`
- `traceability.md` — E→A→P→T rules
- `aq-gate.md` — AQ Gate checks per tier
