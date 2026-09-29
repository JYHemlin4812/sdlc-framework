# AGENTS.md

## Working on this repository

- **Install**: `bundle/scripts/install.ps1` (Windows) or `bundle/scripts/install.sh` (Unix) —
  see these scripts for how the bundle is activated under `~/.claude/`.
- **Validation before any PR** (exit code 0 required for both):

  ```bash
  for t in bundle/scripts/tests/test-*.sh; do bash "$t" || exit 1; done
  PYTHONUTF8=1 python -m pytest -q claude/skills
  ```

- **Full contribution workflow, naming conventions, expected style (including how to write
  instructions for Claude) and review rules**: see `CONTRIBUTING.md` — the single reference for
  these topics, not duplicated here.

## Bundle inventory

Strict scope: `claude/` only — nothing outside this folder is covered here.

### Skills (10)

| Skill | Role | Source |
|---|---|---|
| `sdlc` | Full SDLC framework v4.0: scoping, architecture, design, tests, E→A→P→T traceability, AQ Gate, Code Lock, execution by waves, model profiles and per-tier effort | `claude/skills/sdlc/SKILL.md` |
| `sdlc-asvs-auditor` | Configurable OWASP ASVS security audit (L1/L2/L3) of the source code | `claude/skills/sdlc-asvs-auditor/SKILL.md` |
| `sdlc-debugger` | Structured root-cause-first debugging: root cause before any fix | `claude/skills/sdlc-debugger/SKILL.md` |
| `sdlc-evolve` | TDD discipline (RED → GREEN → REFACTOR) for every evolving P### | `claude/skills/sdlc-evolve/SKILL.md` |
| `sdlc-finish` | Structured close-out of a development branch (merge, PR, keep, discard) | `claude/skills/sdlc-finish/SKILL.md` |
| `sdlc-lang-dispatcher` | Routes each P### to the language standards (Python/JS/Go/Rust) and the matching `sdlc-*-dev` agent | `claude/skills/sdlc-lang-dispatcher/SKILL.md` |
| `sdlc-receive-review` | Receiving code review with rigor (verify before implementing) | `claude/skills/sdlc-receive-review/SKILL.md` |
| `sdlc-reviewer` | Code review delegated to a dispatched subagent, on the diff + requirements | `claude/skills/sdlc-reviewer/SKILL.md` |
| `sdlc-verify` | Evidence before any completion claim: run the verification command and quote its result | `claude/skills/sdlc-verify/SKILL.md` |
| `sdlc-wave-orchestrator` | Parallel execution of P### tasks in waves (topological DAG) | `claude/skills/sdlc-wave-orchestrator/SKILL.md` |

### Commands (18)

| Command | Role | Source |
|---|---|---|
| `/sdlc:brainstorm` | Project scoping — elicit requirements E### and size the project S/M/L (phase 1) | `claude/commands/sdlc/brainstorm.md` |
| `/sdlc:debug` | Structured root-cause-first debugging (runs `sdlc-debugger`) | `claude/commands/sdlc/debug.md` |
| `/sdlc:dev` | Wave-by-wave implementation with test cases T### (phases 3+4); `--wave N`, `--auto-approve` | `claude/commands/sdlc/dev.md` |
| `/sdlc:discuss` | Discussion phase — pre-architecture ADR drafts (optional, M/L projects) | `claude/commands/sdlc/discuss.md` |
| `/sdlc:evolve` | TDD discipline (runs `sdlc-evolve`) | `claude/commands/sdlc/evolve.md` |
| `/sdlc:exit` | Session checkpoint — regenerates `HANDOFF.md` and saves `SDLC_CHECKPOINT.md` | `claude/commands/sdlc/exit.md` |
| `/sdlc:finish` | Structured branch wrap-up (runs `sdlc-finish`) | `claude/commands/sdlc/finish.md` |
| `/sdlc:fix` | Retry a blocked (🚫) or in-rework (🔁) P### with enriched context | `claude/commands/sdlc/fix.md` |
| `/sdlc:gate` | Blocking AQ Gate validation (exit 0/1) via `check_sdlc.py` | `claude/commands/sdlc/gate.md` |
| `/sdlc:import` | Audit an existing project and rebuild `SDLC_PM/` from it | `claude/commands/sdlc/import.md` |
| `/sdlc:init` | Bootstrap `SDLC_PM/` for the chosen documentation tier; asks `output_language` | `claude/commands/sdlc/init.md` |
| `/sdlc:plan` | Architecture A### and task breakdown P### with wave column (phases 2+3) | `claude/commands/sdlc/plan.md` |
| `/sdlc:report` | Concise markdown release report for a version | `claude/commands/sdlc/report.md` |
| `/sdlc:resume` | Resume a session from `SDLC_CHECKPOINT.md` | `claude/commands/sdlc/resume.md` |
| `/sdlc:review` | Code review by a dispatched subagent (runs `sdlc-reviewer`) | `claude/commands/sdlc/review.md` |
| `/sdlc:security` | OWASP ASVS L1/L2/L3 scan (runs `sdlc-asvs-auditor`) | `claude/commands/sdlc/security.md` |
| `/sdlc:status` | Markdown dashboard — current phase, wave, P###/T### counters | `claude/commands/sdlc/status.md` |
| `/sdlc:todo` | Show the next P### to run | `claude/commands/sdlc/todo.md` |

### Agents (12)

`Effort` is the `effort:` key in the agent's frontmatter, set by tier (`simple` → `low`,
`exec` → `medium`, `design` → `high`). The model comes from the project's `model_profile`
(see `claude/skills/sdlc/references/model-profiles.md`).

| Agent | Tier | Effort | Role | Source |
|---|---|---|---|---|
| `sdlc-architect` | design | `high` | Writes `2_architecture.md` (A###:E### + ADR) | `claude/agents/sdlc-architect.md` |
| `sdlc-archive-manager` | simple | `low` | Archives non-essential session artifacts (`/sdlc:exit`) | `claude/agents/sdlc-archive-manager.md` |
| `sdlc-business-analyst` | exec | `medium` | Requirements E### with MoSCoW and BDD criteria | `claude/agents/sdlc-business-analyst.md` |
| `sdlc-code-auditor` | simple | `low` | Read-only observation of an existing project (`/sdlc:import`) | `claude/agents/sdlc-code-auditor.md` |
| `sdlc-discussion-facilitator` | design | `high` | ADR drafts in `2_5_discussion.md` | `claude/agents/sdlc-discussion-facilitator.md` |
| `sdlc-go-dev` | exec | `medium` | Implements one P### in Go + its T### | `claude/agents/sdlc-go-dev.md` |
| `sdlc-js-dev` | exec | `medium` | Implements one P### in JavaScript/TypeScript + its T### | `claude/agents/sdlc-js-dev.md` |
| `sdlc-python-dev` | exec | `medium` | Implements one P### in Python + its T### | `claude/agents/sdlc-python-dev.md` |
| `sdlc-quality-assessor` | exec | `medium` | Read-only maturity assessment and diagnosis of blocked tasks | `claude/agents/sdlc-quality-assessor.md` |
| `sdlc-rust-dev` | exec | `medium` | Implements one P### in Rust + its T### | `claude/agents/sdlc-rust-dev.md` |
| `sdlc-system-analyst` | exec | `medium` | Breaks the architecture down into `3_conception.md` (P###) | `claude/agents/sdlc-system-analyst.md` |
| `sdlc-test-designer` | exec | `medium` | Test cases T###:P### in `4_tests.md` | `claude/agents/sdlc-test-designer.md` |
