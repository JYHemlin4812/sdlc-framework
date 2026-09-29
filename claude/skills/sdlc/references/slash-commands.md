# SDLC slash commands — detailed contracts

Each command has a precise contract: expected inputs, produced outputs, preconditions, agents and
sub-skills involved.

Every command writes artifact content and user-facing messages in the project's
`output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user writes in). IDs,
template headings and field markers stay in English.

> **Invocation**:
> - **Installed under `~/.claude/` (v3.1+)** — native `/sdlc:<command> [args]`. See `INSTALL.md`
>   at the bundle root for installation.
> - **Standalone bundle (not installed)** — fallback: "Follow the protocol defined in
>   `~/.claude/skills/sdlc/SKILL.md` (or the bundle's `claude/skills/sdlc/SKILL.md`) to run
>   `/sdlc:<command>` with these arguments: ...".

---

## `/sdlc:brainstorm <description>`

**Phase**: 1 (Elicitation)
**Output**: `SDLC_PM/v1.0.0/1_elicitation.md`
**Precondition**: none (can run on an empty project)

**Workflow**:
1. If `SDLC_PM/` is missing → create it with `deploy_init.ps1`
2. Interactive elicitation — 5–10 targeted questions (skip those the description already answers)
3. S/M/L calibration (tell the user)
4. If M/L: invoke `sdlc-business-analyst` (subagent) for MoSCoW + BDD criteria
5. If the stack is unknown: web research allowed via `sdlc-architect`
6. Produce the final scoping document (template `1_elicitation.template.md`)
7. Announce the next step: `/sdlc:discuss` (M/L) or `/sdlc:plan` (S)

---

## `/sdlc:discuss <topics>`

**Phase**: 1.5 (Discussion)
**Output**: `SDLC_PM/v1.0.0/2_5_discussion.md`
**Precondition**: `1_elicitation.md` validated

See `references/discussion-phase.md`. Optional.

**Agent involved**: `sdlc-discussion-facilitator` (subagent, spawned via the Agent tool)

---

## `/sdlc:plan`

**Phase**: 2 + 3 (Architecture + design)
**Output**: `2_architecture.md` + `3_conception.md`
**Precondition**: `1_elicitation.md` ✅ (and `2_5_discussion.md` if present)

**Workflow**:
1. Spawn `sdlc-architect` (Agent tool, model resolved from the profile):
   - Input: `1_elicitation.md` + `2_5_discussion.md` (if present)
   - Output: `2_architecture.md` (A###:E### + ADR + ASCII diagram)
2. Spawn `sdlc-system-analyst` (Agent tool):
   - Input: `2_architecture.md`
   - Output: `3_conception.md` (P###:A### with `**Depends on**`, `**Target files**`, `**Status**`)
3. Run `wave_planner.py --conception ... --annotate` to compute/annotate the `**wave**` fields
4. Run `check_sdlc.py` (AQ Gate)
5. On ✅: announce `/sdlc:dev`. On ❌: fix and rerun.

---

## `/sdlc:init [project-root]`

**Phase**: bootstrap
**Output**: `SDLC_PM/v1.0.0/` populated with templates + `sdlc-config.json`
**Precondition**: none

Asks for `output_language` (default: the language the user writes in) and
`project_size_estimate`, proposes a `documentation_tier`, then runs `scripts/deploy_init.ps1`
(Windows) or `deploy_init.sh` (Linux/macOS).

---

## `/sdlc:dev [--auto-approve] [--wave N]`

**Phase**: 3+4 (Implementation + tests)
**Output**: code + commits + updated `4_tests.md`
**Precondition**: AQ Gate ✅ on `2_architecture.md` + `3_conception.md`

**Workflow** (details in the `SKILL.md` section):

1. Read `sdlc-config.json` → resolve model profile, parallelism, retries
2. Find the first unfinished wave (or the one given by `--wave N`)
3. For each P### in the wave:
   - Check Code Lock
   - If `fresh_context_per_task: true`: spawn via the Agent tool
     - `subagent_type` = lang-dispatcher routing (python/js/go/rust)
     - `model` = resolved by `model_profiler.py`
     - `prompt` = P### description + parent A### + Code Lock criteria
   - Otherwise: run inline
4. Mutex via `lockfile_helper.py` when updating `STATE.md`
5. On failure: retry with model escalation (if allowed), up to `max_retry_per_task`
6. Update `3_conception.md` (✅/🔁/🚫) and `4_tests.md` (T### added)
7. Wave finished → next wave. All waves finished → `/sdlc:gate`.

Spawn one subagent per P###; do not spawn subagents for work doable in a handful of tool calls,
nor to double-check your own work.

**Flags**:
- `--auto-approve`: skip Y/N confirmations (see `references/auto-approve.md`)
- `--wave N`: process only wave N (useful for resumption/testing); `--vague N` is accepted as a
  legacy alias
- `--strict-confirm`: confirm before each P### (debugging)

---

## `/sdlc:gate`

**Phase**: validation
**Output**: exit 0 / 1 + markdown report
**Precondition**: none

Runs `scripts/check_sdlc.py` directly. See `references/aq-gate.md`.

---

## `/sdlc:exit`

**Phase**: checkpoint
**Output**: `SDLC_PM/SDLC_CHECKPOINT.md` + updated `HANDOFF.md`
**Precondition**: none

**Workflow**:
1. Snapshot the state:
   - Current wave
   - P### in progress / last ✅
   - Auto-approve counters, if active
   - Timestamp
2. Write `SDLC_CHECKPOINT.md` (YAML frontmatter + markdown state) and regenerate `HANDOFF.md`
3. Optional: invoke `sdlc-archive-manager` to archive the session's non-essential artifacts

---

## `/sdlc:resume`

**Precondition**: `SDLC_CHECKPOINT.md` present

Reads the checkpoint, restores the conceptual state and proposes the next action (resume dev at
the recorded wave/P###, or a new phase if the checkpoint is older).

---

## `/sdlc:import <project-root>`

**Phase**: audit / reconstruction
**Output**: rebuilt `SDLC_PM/` + report
**Precondition**: an existing project (v2 or outside SDLC)

**Workflow**:
1. Spawn `sdlc-code-auditor` (subagent) — pure observation, no changes. Detects structure, stack,
   docs, gaps.
2. Spawn `sdlc-quality-assessor` — cross-checks code and docs, rates maturity.
3. Spawn `sdlc-system-analyst` — rebuilds `1_elicitation.md` … `4_tests.md` from the
   observations.
4. Run `check_sdlc.py` — fix the unavoidable gaps.
5. For a v2 project → follow `MIGRATION_v2_v3.md` for the rest.

---

## `/sdlc:report [version]`

**Output**: markdown report (stdout or file)
**Precondition**: the version exists in `SDLC_PM/`

Generates a summary: requirements, key decisions, delivered tasks, passing tests, quality
metrics, residual risks. Suitable for release notes or a PR description.

---

## `/sdlc:status`

Quick markdown dashboard:
- Current phase
- Current wave / total
- P###: ⬜ / 🔄 / ✅ / 🔁 / 🚫 (counts)
- T###: ✅ / ❌ (counts + coverage)
- Last action + timestamp

---

## `/sdlc:todo`

Finds the next P### to run (first wave with ⬜ or 🔁) and shows it with its dependencies and
context. Useful in interactive mode.

---

## `/sdlc:fix <P###>`

**Precondition**: `<P###>` exists and is 🚫 or 🔁

**Workflow**:
1. Reset the retry counter
2. Spawn a subagent with richer context (previous logs, quality assessor diagnosis)
3. Retry the implementation
4. On success → ✅. On failure after a new full cycle → escalate to the user.

---

## `/sdlc:security`

Runs `sdlc-asvs-auditor` (sub-skill):
1. Reads `asvs_level` from `sdlc-config.json` (default 1)
2. Runs `asvs_scanner.py --level <n> --root <project>`
3. Produces a report grouped by ASVS category, severity, file:line
4. For high-severity findings not documented in `4_tests.md` or `2_5_discussion.md` → suggest
   `/sdlc:fix` or a new E###.
