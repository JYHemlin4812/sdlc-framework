---
name: sdlc
description: |
  SDLC framework v4.0 that orchestrates the full software development lifecycle — scoping,
  architecture, design/task breakdown, implementation and tests — with E→A→P→T traceability,
  a blocking AQ Gate, Code Lock, parallel execution by waves, fresh contexts via subagents,
  dynamic model profiles with per-tier effort, an --auto-approve mode, Python/JS/Go/Rust agents,
  OWASP ASVS L1/L2/L3 security, and documentation tiers with HANDOFF.md/RESUME.md/0_context.md
  so anyone (human or AI) can pick up an abandoned project.

  Use this skill for any mention of: SDLC, sdlc, brainstorm, scoping, traceability, E###, A###,
  P###, T###, AQ gate, AQ, phase validation, Code Lock, /sdlc:.
  Also use it for structured-development intent: new project, scaffold project, implement a
  feature, break down a task, plan of attack, design an architecture, software lifecycle,
  software development lifecycle; and for quality/audit/compliance: code audit, verify
  traceability, compliance gate, validate the phase, structured code review.

  Also triggers on (FR): cadrage, traçabilité, nouveau projet, implémenter une feature,
  décomposer une tâche, plan d'attaque, créer une architecture, audit code, vérifier la
  traçabilité, valider la phase, code review structuré.
---

# SDLC — orchestrator skill (v4.0)

Self-contained, installable Claude skill bundle. It keeps the **E→A→P→T** traceability backbone
and adds:

- A pre-architecture **Discussion phase** (deliverable `2_5_discussion.md`)
- **Parallel execution by waves** (sub-skill `sdlc-wave-orchestrator`)
- **Fresh context per task** (each P### runs in an isolated subagent via the `Agent` tool)
- **Dynamic model profiles** Budget / Balanced / Quality / Inherit, plus an `effort` level per
  agent tier
- **`--auto-approve` mode** (semi-autonomous; Code Lock and the AQ Gate stay active)
- **Multi-language** Python / JavaScript / TypeScript / Go / Rust (sub-skill `sdlc-lang-dispatcher`)
- **OWASP ASVS L1 / L2 / L3 security** (sub-skill `sdlc-asvs-auditor`)
- **Documentation tiers** `none` / `minimal` / `standard` / `full` / `exhaustive`, proportional to
  project size (see `references/documentation-tiers.md`)
- **Handoff deliverables** `HANDOFF.md` (state + next 3 actions), `RESUME.md` (technical
  bootstrap in under 10 minutes), `0_context.md` (state of the world + dated assumptions)

Version notes:
- **3.1** — installable bundle (`scripts/install.ps1` / `scripts/install.sh`) exposing native
  `/sdlc:*` slash commands under `~/.claude/`.
- **3.2** — documentation tiers and the HANDOFF/RESUME/0_context handoff deliverables.
- **4.0** — instructions rewritten in English, with artifacts written in the project's
  `output_language`; prompts tuned for Claude Opus 5.5 (calm imperatives, reasons given, no
  "think harder" prose); `effort` set per agent tier in agent frontmatter; model IDs updated
  (`claude-haiku-4-5`, `claude-sonnet-5`, `claude-opus-5-5`).

Once installed, the skill lives under `~/.claude/skills/sdlc/` and the `/sdlc:*` commands are
available natively. Check that no other installed command uses the `/sdlc:` prefix before
deploying.

## Output language

Write artifact content and user-facing messages in the project's `output_language`
(`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). Keep IDs, template
headings and field markers (`**Depends on**`, `**Target files**`, `**Status**`, `**wave**`) in
English so the scripts can parse them.

---

## Principles

1. **Traceability.** Every line of code maps to a `T###`, every `T###` to a `P###`, every `P###`
   to an `A###`, every `A###` to an `E###`. No file changes without a validated `P###`. This is
   what makes audits, v2→v3 migration and trust in autonomous execution possible.

2. **Fresh context is an investment.** Instead of accumulating the noise of ten tasks in one
   session (context rot), each `P###` gets a dedicated subagent that receives only what it needs:
   the task, its parent, the target files.

3. **Autonomy is not permissiveness.** `--auto-approve` skips Y/N confirmations, but Code Lock and
   the AQ Gate stay active. An autonomous agent still cannot write a file without a ✅ `P###` or
   pass a phase without a gate PASS; structural discipline replaces human supervision.

4. **Parallel by default, can be switched off.** Independent `P###` (same wave according to
   `wave_planner.py`) run in parallel. Set `wave_parallelism: false` when cost or debugging
   justifies it.

5. **Documentation proportional to the project.** A one-liner needs nothing; a colossal project
   needs a complete record. `documentation_tier` (`none`/`minimal`/`standard`/`full`/`exhaustive`)
   sets what the orchestrator requires and produces. Details in
   `references/documentation-tiers.md`.

6. **Handoff is always possible.** From tier `minimal` up, `HANDOFF.md` (state + next 3 actions)
   and `RESUME.md` (technical bootstrap) are always produced, so anyone can pick up an abandoned
   project in under 10 minutes. Never write secrets in them; reference the secret store (DPAPI,
   vault, `.env`) instead.

---

## Project configuration (read by every command)

Lives at `SDLC_PM/sdlc-config.json` in the user's project, validated by
`assets/sdlc-config.schema.json` (`version` accepts `3.0`, `3.1`, `3.2`, `4.0`; new projects use
`4.0`). Key fields:

| Field | Values | Effect |
|---|---|---|
| `output_language` | language tag or name (`fr`, `en`, `es`, …) | Language of artifacts and user-facing messages. Asked at `/sdlc:init`. |
| `model_profile` | budget / balanced / quality / inherit | Default model tier |
| `auto_approve` | true / false | Skips Y/N confirmations |
| `asvs_level` | 0 / 1 / 2 / 3 | ASVS level applied (0 = disabled) |
| `wave_parallelism` | true / false | Parallel execution by waves |
| `fresh_context_per_task` | true / false | Spawn one subagent per P### via the Agent tool |
| `max_parallel_agents` | 1..16 | Cap on simultaneous agents per wave |
| `soft_failure_escalation` | true / false | Haiku→Sonnet→Opus on failure |
| `code_lock_enabled` | true / false | Enables Code Lock (leave true) |
| `documentation_tier` | none / minimal / standard / full / exhaustive | Documentation level produced. See `references/documentation-tiers.md`. |
| `project_size_estimate` | one-liner / small / medium / large / colossal | Initial estimate (asked at `/sdlc:init`), used to propose a default `documentation_tier`. |

Full example: `assets/sdlc-config.example.json`.

---

## Main slash commands

| Command | Phase | Output |
|---|---|---|
| `/sdlc:brainstorm <description>` | Elicitation | `1_elicitation.md` (E###) |
| `/sdlc:discuss <topics>` | Discussion | `2_5_discussion.md` (ADR drafts) |
| `/sdlc:plan` | Architecture + design | `2_architecture.md` (A###) + `3_conception.md` (P### + wave) |
| `/sdlc:init` | Bootstrap | populated `SDLC_PM/v1.0.0/` |
| `/sdlc:dev [--auto-approve]` | Implementation | code + commits + `4_tests.md` (T###) |
| `/sdlc:gate` | AQ Gate | exit 0 / 1 |
| `/sdlc:exit` | Checkpoint | `SDLC_CHECKPOINT.md` |
| `/sdlc:resume` | Resumption | continues from the checkpoint |
| `/sdlc:import <path>` | Audit | report + rebuilt `SDLC_PM/` |
| `/sdlc:report [version]` | Summary | markdown report |
| `/sdlc:status` | Current state | task dashboard |
| `/sdlc:todo` | Next task | P### to run |
| `/sdlc:fix <P###>` | Fix a blocked task | retry a 🚫 / 🔁 P### |
| `/sdlc:security` | ASVS scan | security report per level |
| `/sdlc:debug` | Root-cause investigation | sub-skill `sdlc-debugger` |
| `/sdlc:review` | Code review by subagent | sub-skill `sdlc-reviewer` |
| `/sdlc:finish` | Close the branch (merge/PR/keep/discard) | sub-skill `sdlc-finish` |
| `/sdlc:evolve` | TDD discipline for an evolving P### | sub-skill `sdlc-evolve` (proxy) |

Full contracts in `references/slash-commands.md`.

### Cross-cutting deliverables

These files exist from tier `minimal` up and the orchestrator updates them on every command that
changes project state (`/sdlc:plan`, `/sdlc:dev` ✅, `/sdlc:gate` ✅, `/sdlc:exit`):

| File | Minimum tier | Role |
|---|---|---|
| `SDLC_PM/HANDOFF.md` | `minimal` | Exact state + next 3 actions + pitfalls. Updated on every `/sdlc:exit` and every AQ Gate ✅. First thing whoever picks up the project reads. |
| `SDLC_PM/RESUME.md` | `minimal` | Technical bootstrap: prerequisites, layout, step-by-step install, useful commands, secrets referenced (never written). |
| `SDLC_PM/v<X>/0_context.md` | `standard` | State of the world + constraints + **dated** assumptions with "valid until" + explicit out-of-scope. |

See `assets/HANDOFF.template.md`, `assets/RESUME.template.md`, `assets/0_context.template.md`.

---

## Overall workflow

```
┌────────────────────────────────────────────────────────────────────────────┐
│  /sdlc:init                                                                │
│  ↓                                                                         │
│  Ask output_language and project_size_estimate → propose documentation_tier│
│  Create HANDOFF.md + RESUME.md (always, from tier minimal)                 │
│  Create 0_context.md (tier ≥ standard)                                     │
├────────────────────────────────────────────────────────────────────────────┤
│  /sdlc:brainstorm   (tier ≥ standard; skipped for minimal)                 │
│  ↓                                                                         │
│  1_elicitation.md (E### MoSCoW + BDD criteria)                             │
├────────────────────────────────────────────────────────────────────────────┤
│  /sdlc:discuss   (optional, M/L projects)                                  │
│  ↓                                                                         │
│  2_5_discussion.md (ADR drafts → recommendations)                          │
├────────────────────────────────────────────────────────────────────────────┤
│  /sdlc:plan                                                                │
│  ↓                                                                         │
│  2_architecture.md (A###:E### + ADR)                                       │
│  3_conception.md (P###:A### + wave + dependencies)                         │
├────────────────────────────────────────────────────────────────────────────┤
│  /sdlc:gate  ✅ → /sdlc:dev                                                │
│  ↓                                                                         │
│  For each wave N (ascending):                                              │
│    For each P### in the wave:                                              │
│      [IF fresh_context_per_task] spawn a subagent (Agent tool)             │
│      [ELSE] run inline                                                     │
│      → ANNOUNCE → CODE → TEST → EVALUATE                                   │
│      → ✅ or 🔁 (retry < max) or 🚫 (escalate)                             │
│    [IF wave_parallelism] wait for the whole wave before the next one       │
├────────────────────────────────────────────────────────────────────────────┤
│  /sdlc:gate  ✅                                                            │
│  ↓                                                                         │
│  → HANDOFF.md updated automatically (state + next actions)                 │
│  → /sdlc:report → release                                                  │
└────────────────────────────────────────────────────────────────────────────┘
```

On every phase transition and on `/sdlc:exit`, the orchestrator regenerates `HANDOFF.md` from the
current state (last finished P###, blocked P###, last commit), so stopping at any moment leaves a
fresh handoff file.

---

## Sub-skills used

| Sub-skill | When to invoke | How |
|---|---|---|
| `sdlc-wave-orchestrator` | At the start of `/sdlc:dev` (or `/sdlc:plan` when `wave: N` needs recomputing) | `Skill` tool, or run `wave_planner.py` directly |
| `sdlc-lang-dispatcher` | Before each P### whose language differs from `primary_language` | `Skill` tool; loads the target language reference |
| `sdlc-asvs-auditor` | On `/sdlc:security`, or in the gate when `asvs_level >= 1` | `Skill` tool, or run `asvs_scanner.py` directly |
| `sdlc-debugger` | On `/sdlc:fix` or `/sdlc:debug`, for a red T###, a 🚫 P###, or AQ Gate exit 1 | `Skill` tool — root-cause phase comes before any fix |
| `sdlc-reviewer` | On `/sdlc:review`, typically just before `/sdlc:gate` or after a major P### lands | `Skill` tool — dispatches a `general-purpose` subagent with the `code-reviewer.md` template |
| `sdlc-finish` | On `/sdlc:finish`, after `/sdlc:gate` exit 0 on the last wave of a version | `Skill` tool — test check → environment detection → merge/PR/keep/discard options |
| `sdlc-evolve` (proxy) | On `/sdlc:evolve`, or during `/sdlc:dev` for a new evolving P### | `Skill` tool — RED→GREEN→REFACTOR; adapted from `test-driven-development` (obra/superpowers) |
| `sdlc-verify` | Before marking a P### ✅, before a commit, before `/sdlc:gate`, before relaying a dev subagent's report | `Skill` tool — run the verification command and quote its result; adapted from `verification-before-completion` (obra/superpowers) |
| `sdlc-receive-review` | When review feedback arrives (from `sdlc-reviewer`, an external reviewer, or the user), before applying fixes | `Skill` tool — verify before implementing, no performative agreement; adapted from `receiving-code-review` (obra/superpowers) |

Invocation contracts in `references/slash-commands.md`.

---

## Structural rules

### Code Lock (reference: `references/code-lock.md`)

Modify a source file only when:
1. a P### exists in `3_conception.md` with status ✅,
2. `check_sdlc.py` returns exit code 0,
3. any bug found while coding has been recorded in `1_elicitation.md` before further changes.

This keeps every change traceable to a requirement. It can be disabled only when developing the
SDLC framework itself, via `code_lock_enabled: false`.

### AQ Gate (reference: `references/aq-gate.md`)

`scripts/check_sdlc.py` is the single source of truth; no phase progresses without exit 0.
v3+ checks:
- `ID:PARENT` format (A###:E###, P###:A###, T###:P###)
- Consistent `wave: N` field (no cycle, no dependency on the same or a later wave)
- Valid `sdlc-config.json` schema
- ASVS scan (delegated sub-skill) when `asvs_level >= 1`
- No active blocker (`🚫` or `[B]` in the .md files)

### Traceability (reference: `references/traceability.md`)

```
E### (root, no parent)
  └─ A###:E### (architecture decision)
       └─ P###:A### (codable task with wave: N)
            └─ T###:P### (test case)
```

No code without a T###, no T### without a P###, and so on up the chain.

### Workflow states (reference: `references/workflow-states.md`)

| Emoji | Meaning |
|---|---|
| ⬜ | To do |
| ⏳ | Waiting on a dependency |
| 🔄 | In progress |
| ✅ | Done / PASS |
| ❌ | Failed / FAIL |
| 🔁 | In rework (retry < max) |
| 🚫 | Blocked (retry ≥ max or serious defect) |
| 🚀 | Released |

---

## Behavior per phase

### Phase 1 — `/sdlc:brainstorm`

1. **Guided elicitation**: 5–10 targeted questions (functional, non-functional, integrations, UX,
   versioning). Adapt them to the project and skip what the description already answers.
2. **Calibration**: S (<5 tasks) → skip Discussion; M (5–15) → normal workflow; L (>15) →
   Discussion + web research if the stack is unknown.
3. **Output**: complete `1_elicitation.md` with MoSCoW + BDD criteria.
4. **Announce** the next step (`/sdlc:discuss` for M/L, `/sdlc:plan` for S).

### Phase 1.5 — `/sdlc:discuss`

See `references/discussion-phase.md`. For each topic: context, 2–3 options with trade-offs, an
explicit recommendation. `2_5_discussion.md` feeds the A### of phase 2 directly.

### Phase 2 — `/sdlc:plan`

1. Read `1_elicitation.md` (and `2_5_discussion.md` if present).
2. Produce `2_architecture.md`: for each MUST/SHOULD E###, at least one `A###:E###` with an ADR
   (context, decision, consequences).
3. Produce `3_conception.md`: break each A### into P###:A### with:
   - an initial `**wave**` field (`wave_planner.py` may recompute it)
   - a `**Depends on**` field listing prerequisite P###
   - a `**Target files**` field (declared write-set)
   - a `**Status**` field
   - Size S/M/L
   - the language, if multi-stack
4. Run `wave_planner.py --annotate` to validate/recompute the waves.
5. Run `check_sdlc.py` (AQ Gate). On ❌ → fix and rerun. On ✅ → announce `/sdlc:dev`.

### Phase 3 — `/sdlc:dev`

See `references/code-lock.md` and `references/auto-approve.md`. Workflow:

```
1. Read SDLC_PM/sdlc-config.json (model_profile, auto_approve, etc.).
2. Read 3_conception.md → find the first unfinished wave.
3. For each P### in that wave:
   a. If fresh_context_per_task=true: spawn via the Agent tool with:
      - subagent_type matching the language (resolved by sdlc-lang-dispatcher)
      - model resolved by model_profiler.py
      - prompt = P### description + parent A### + Code Lock criteria
      - isolation: worktree (optional)
   b. Otherwise: run inline with the model resolved by model_profiler.
   c. Collect the result. On failure:
      - if retries < max_retry_per_task → 🔁, escalate the model if allowed, retry
      - otherwise → before marking 🚫, state the root-cause hypothesis and the evidence
        in the task notes, then mark 🚫 and escalate to the user (except in --auto-approve,
        where the run stops)
4. Update 3_conception.md (✅/🔁/🚫 statuses).
5. Update STATE.md through the file lock (lockfile_helper) to avoid races.
6. When every P### in the wave is ✅ → next wave.
7. When every wave is ✅ → /sdlc:gate.
```

Delegate only sizeable, independent work to subagents (one P### per subagent here); do the rest
inline, and do not spawn subagents to double-check your own work. Respect `max_parallel_agents`.

### Phase 4 — Tests (part of `/sdlc:dev`)

For each P### executed, create/update its T###:P### in `4_tests.md`. Target coverage =
`test_coverage_min` (default 0.7).

### `/sdlc:gate`

Runs `scripts/check_sdlc.py`. On exit 0, announce ✅ and recommend `/sdlc:report`. On exit 1,
list the errors, suggest `/sdlc:fix <P###>` or a manual fix, and do not progress.

### `/sdlc:security`

When `asvs_level >= 1`, invoke the `sdlc-asvs-auditor` sub-skill (or run `asvs_scanner.py`
directly). Report grouped by ASVS category, severity, file:line.

---

## Model profiles (reference: `references/model-profiles.md`)

| Profile | `simple` (code-auditor, archive-manager) | `exec` (python-dev, system-analyst, …) | `design` (architect, discussion-facilitator) |
|---|---|---|---|
| `budget` | Haiku | Haiku | Sonnet |
| `balanced` (default) | Haiku | Sonnet | Opus |
| `quality` | Sonnet | Opus | Opus |
| `inherit` | (session model) | (session model) | (session model) |

Per-agent override via `model_overrides` in the config. With `soft_failure_escalation: true`,
a soft failure escalates one tier (at most one level, handled by `model_profiler.py`).

Effort is set per tier in the agent frontmatter: `simple` → `low`, `exec` → `medium`,
`design` → `high`. See the Effort section of `references/model-profiles.md`.

---

## `--auto-approve` mode (reference: `references/auto-approve.md`)

Runs the `brainstorm → plan → dev → gate → report` chain without Y/N confirmations between
steps. Safeguards that stay active:

- ✅ Code Lock (refuses to write without a ✅ P###)
- ✅ AQ Gate (refuses to progress without exit 0)
- ✅ Max retries per P### (`max_retry_per_task`)
- ✅ Parallel agent cap (`max_parallel_agents`)

Auto-approve stops as soon as a P### becomes 🚫 (unrecoverable). The progress checklist is the
statuses in `3_conception.md` plus `STATE.md`.

---

## Diagnostics / observability

- **`/sdlc:status`**: markdown dashboard of P### per wave + statuses
- **`SDLC_PM/STATE.md`**: raw state, updated by subagents (mutex via `lockfile_helper.py`)
- **`SDLC_PM/SDLC_CHECKPOINT.md`**: created by `/sdlc:exit`, consumed by `/sdlc:resume`

---

## Further reading

- `references/documentation-tiers.md` — 5 tiers, size→tier mapping, orchestrator behavior
- `references/traceability.md` — E→A→P→T rules
- `references/code-lock.md` — Code Lock details and exceptions
- `references/aq-gate.md` — AQ Gate checks in detail
- `references/discussion-phase.md` — using the Discussion phase
- `references/auto-approve.md` — semi-autonomy and safeguards
- `references/model-profiles.md` — model resolution, escalation and effort
- `references/slash-commands.md` — contract of each command
- `references/workflow-states.md` — emoji semantics and transitions

Cross-cutting templates:
- `assets/0_context.template.md` — state of the world + dated assumptions
- `assets/HANDOFF.template.md` — state + next 3 actions + pitfalls
- `assets/RESUME.template.md` — technical bootstrap in under 10 minutes

Core sub-skills:
- `../sdlc-wave-orchestrator/SKILL.md` — DAG, Kahn, lockfile
- `../sdlc-lang-dispatcher/SKILL.md` — Python/JS/Go/Rust standards
- `../sdlc-asvs-auditor/SKILL.md` — OWASP L1/L2/L3 checklists

Sub-skills adapted from [obra/superpowers](https://github.com/obra/superpowers):
- `../sdlc-debugger/SKILL.md` — root-cause-first debugging (adapted from `systematic-debugging`)
- `../sdlc-reviewer/SKILL.md` — code review by subagent (adapted from `requesting-code-review`)
- `../sdlc-finish/SKILL.md` — structured branch closing (adapted from `finishing-a-development-branch`)
- `../sdlc-evolve/SKILL.md` — TDD discipline (adapted from `test-driven-development`, proxy for evolve)
- `../sdlc-verify/SKILL.md` — evidence before claims (adapted from `verification-before-completion`)
- `../sdlc-receive-review/SKILL.md` — receiving code review (adapted from `receiving-code-review`)
