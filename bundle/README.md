# SDLC bundle — installable Claude Code SDLC framework

Claude Code skills, `/sdlc:*` slash commands and `sdlc-*` subagents that implement a
structured software development lifecycle: **E→A→P→T** traceability (requirements →
architecture decisions → codable tasks → test cases), a blocking AQ Gate (quality assurance
gate), Code Lock, parallel execution in waves, fresh contexts via subagents, dynamic model
profiles, an `--auto-approve` mode, multi-language agents (Python, JS/TS, Go, Rust) and
OWASP ASVS L1/L2/L3 security checks.

It also provides **documentation tiers** (`none` / `minimal` / `standard` / `full` /
`exhaustive`) and **handoff deliverables** (`HANDOFF.md`, `RESUME.md`, `0_context.md`) so
that anyone, human or AI, can pick up an abandoned project in under 10 minutes.

> **Status**: v4.0 — English instructions, `output_language` per project, tuned for
> Claude Opus 5.5 (`effort` per agent). Upgrading from v3.x: see `MIGRATION_v3_v4.md`.

---

## Install

```bash
git clone https://github.com/JYHemlin4812/sdlc-framework.git
cd sdlc-framework

# Windows (PowerShell 7+)
pwsh bundle/scripts/install.ps1

# Linux / macOS (bash 4+)
bash bundle/scripts/install.sh
```

The installer deploys the canonical content of `claude/` to `~/.claude/`:
10 skills (`skills/sdlc*`), 18 slash commands (`commands/sdlc/`) and 12 agents
(`agents/sdlc-*`). It is idempotent (skipped when the checksum is unchanged), takes a
timestamped backup before replacing any file, and refuses to overwrite a third-party skill
of the same name. Full details: `INSTALL.md`.

Restart Claude Code, then:

```
/sdlc:status                    # dashboard for the current project
/sdlc:brainstorm <description>  # scope a new project
/sdlc:plan                      # architecture + task breakdown
/sdlc:dev --auto-approve        # implementation, wave by wave
/sdlc:gate                      # AQ Gate
```

Check the installation: `pwsh bundle/scripts/verify.ps1` (or `bash bundle/scripts/verify.sh`)
compares every installed file with the committed canonical tree by hash.
Uninstall: `pwsh bundle/scripts/uninstall.ps1` (or `bash bundle/scripts/uninstall.sh`).

### Bootstrap a user project

From the directory of the project to initialize, run `/sdlc:init` in Claude Code, or:

```powershell
pwsh "$HOME/.claude/skills/sdlc/scripts/deploy_init.ps1"
```

This creates `SDLC_PM/v1.0.0/` with the phase files (including `2_5_discussion.md`) and a
`sdlc-config.json`, ready for `/sdlc:brainstorm`.

---

## Bundle layout

```
bundle/
├── README.md             ← this file
├── INSTALL.md            ← install, verify, update, uninstall
├── MIGRATION_v2_v3.md    ← migration guide from SDLCv2
├── MIGRATION_v3_v4.md    ← migration guide from v3.x
├── docs/
│   ├── SYNC.md           ← bidirectional sync between ~/.claude and the repo
│   └── KNOWN-ISSUES.md   ← known limitations of the sync scripts
├── scripts/              ← install / uninstall / verify / capture / restore / sync-lib / scan-fuites
│   └── tests/            ← self-contained script tests (.sh and .ps1)
└── templates/            ← SDLC_PM/ project templates
```

The deployed content itself lives in `claude/` at the repository root. Each skill follows
the skill-creator layout: `SKILL.md` + `references/` (progressive disclosure) + `scripts/` +
`assets/`.

---

## Slash commands

| Command | Phase | Output |
|---|---|---|
| `/sdlc:brainstorm` | Elicitation | `1_elicitation.md` (E###) |
| `/sdlc:discuss` | Discussion (optional) | `2_5_discussion.md` (ADR drafts) |
| `/sdlc:plan` | Architecture + design | `2_architecture.md` (A###), `3_conception.md` (P###) |
| `/sdlc:init` | Bootstrap | `SDLC_PM/` structure |
| `/sdlc:dev` | Implementation in waves | code + `4_tests.md` (T###) |
| `/sdlc:gate` | Blocking AQ Gate | exit 0 / 1 |
| `/sdlc:exit` | Session checkpoint | `HANDOFF.md`, `SDLC_CHECKPOINT.md` |
| `/sdlc:resume` | Resume a session | continuation |
| `/sdlc:import` | Audit an existing project | report + rebuilt `SDLC_PM/` |
| `/sdlc:report` | Release report | markdown summary |
| `/sdlc:status` | Current state | task dashboard |
| `/sdlc:todo` | Next task | P### to run |
| `/sdlc:fix` | Retry a blocked task | retry P### 🚫/🔁 |
| `/sdlc:security` | ASVS scan | security report per level |
| `/sdlc:debug` | Root-cause debugging | diagnosis |
| `/sdlc:evolve` | TDD (RED → GREEN → REFACTOR) | tested change |
| `/sdlc:review` | Code review by a subagent | review report |
| `/sdlc:finish` | Close a branch | merge / PR / keep / discard |

Contracts for each command: `claude/skills/sdlc/references/slash-commands.md`.

---

## Project configuration (`sdlc-config.json`)

Lives in the project's `SDLC_PM/`. Validated by
`claude/skills/sdlc/assets/sdlc-config.schema.json`.

```json
{
  "version": "4.0",
  "project_name": "my-project",
  "output_language": "en",
  "primary_language": "python",
  "model_profile": "balanced",
  "auto_approve": false,
  "asvs_level": 1,
  "max_retry_per_task": 3,
  "fresh_context_per_task": true,
  "wave_parallelism": true,
  "max_parallel_agents": 4,
  "documentation_tier": "standard",
  "project_size_estimate": "medium"
}
```

`output_language` sets the language of the artifacts the framework writes for you
(`1_elicitation.md`, `HANDOFF.md`, reports, questions). Identifiers, template headings and
field markers stay in English so the tooling can parse them. Full example:
`claude/skills/sdlc/assets/sdlc-config.example.json`.

---

## Tests

```bash
# Python tests of the skills
PYTHONUTF8=1 python -m pytest -q claude/skills

# Install/sync script tests
for t in bundle/scripts/tests/test-*.sh; do bash "$t" || echo "FAIL $t"; done
pwsh -NoProfile -File bundle/scripts/tests/test-install.ps1   # same for the other test-*.ps1
```

---

## References

- `INSTALL.md` — installation guide
- `docs/SYNC.md` — capture / restore / verify between `~/.claude` and the repository
- `claude/skills/sdlc/SKILL.md` — orchestrator skill
- `claude/skills/sdlc/references/documentation-tiers.md` — documentation tiers
- Optional interoperability with `nestor-agents`: `docs/INTEROP.md` at the repository root
