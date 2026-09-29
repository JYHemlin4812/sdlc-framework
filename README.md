# sdlc-framework

🇫🇷 [Version française](README.fr.md)

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

A structured **software development lifecycle (SDLC)** for Claude Code: skills, `/sdlc:*` slash
commands and subagents, packaged as a bundle you install under `~/.claude/`. It takes a project
from scoping to release with end-to-end traceability (requirements E### → architecture decisions
A### → codable tasks P### → test cases T###), a blocking quality gate (AQ Gate), Code Lock and
parallel execution in waves.

Standalone. It can optionally work alongside
[`nestor-agents`](https://github.com/JYHemlin4812/nestor-agents) (see
[`docs/INTEROP.md`](docs/INTEROP.md)).

## Requirements

- [Claude Code](https://claude.com/claude-code) — the framework runs inside it.
- Python 3.9+ (AQ Gate and wave planner scripts), git, and PowerShell 7 (Windows) or bash 4+
  (Linux/macOS) for the installer. Details in [`bundle/INSTALL.md`](bundle/INSTALL.md).

## Languages

- **Instructions** (skills, commands, agents, references, scripts) are written in English.
- **Artifacts** the framework produces for you (`1_elicitation.md`, `2_architecture.md`,
  `HANDOFF.md`, reports, questions) are written in your project's `output_language`, asked at
  `/sdlc:init` and stored in `SDLC_PM/sdlc-config.json`. Without it, artifacts follow the language
  you write in. IDs, template headings and field markers stay in English so the scripts can parse
  them.

## Tuned for Claude Opus 5.5

- Prompts use calm imperatives with a short reason, no "think step by step" prose and no
  redundant self-verification; the structural gates (AQ Gate, Code Lock, test runs) do the
  checking.
- Each agent sets an `effort` level by tier in its frontmatter: `low` for simple agents
  (code-auditor, archive-manager), `medium` for execution agents (developers, analysts, test
  designer), `high` for design agents (architect, discussion facilitator).
- Model profiles (`budget` / `balanced` / `quality` / `inherit`) resolve to `claude-haiku-4-5`,
  `claude-sonnet-5` and `claude-opus-5-5`. See
  [`claude/skills/sdlc/references/model-profiles.md`](claude/skills/sdlc/references/model-profiles.md).

Upgrading from v3.x: see [`bundle/MIGRATION_v3_v4.md`](bundle/MIGRATION_v3_v4.md).

## Quickstart

Clone the repository and run the installer — under 5 minutes, no prior configuration. Both
commands deploy the same content (`sdlc*` skills, `/sdlc:*` commands, `sdlc-*` agents) to
`~/.claude/` and report the same result.

### PowerShell (Windows)

```powershell
git clone https://github.com/JYHemlin4812/sdlc-framework.git
cd sdlc-framework
pwsh bundle/scripts/install.ps1
```

### Bash (Linux/macOS)

```bash
git clone https://github.com/JYHemlin4812/sdlc-framework.git
cd sdlc-framework
bash bundle/scripts/install.sh
```

**Expected result (both commands)**: an `Installation complete` report listing the number of
skills/commands/agents deployed and the target path (`~/.claude/` by default). Restart Claude
Code, then run `/sdlc:init` in your project (or `/sdlc:status` to check the install).

Useful options (same in both scripts, native flag style per shell):
`-DryRun`/`--dry-run` (simulation, no writes), `-Force`/`--force` (reinstall even if up to date),
`-NoBackup`/`--no-backup` (no timestamped backup before replacing).

## Typical workflow

```
/sdlc:init        → SDLC_PM/ structure, output_language, documentation tier
/sdlc:brainstorm  → 1_elicitation.md (requirements E###)
/sdlc:discuss     → 2_5_discussion.md (optional, M/L projects)
/sdlc:plan        → 2_architecture.md (A###) + 3_conception.md (P### with waves)
/sdlc:gate        → AQ Gate, exit 0 required to continue
/sdlc:dev         → implementation wave by wave + test cases T### (--wave N, --auto-approve)
/sdlc:gate        → then /sdlc:report for the release
```

## Repository layout

```
sdlc-framework/
├── claude/           # Canonical content deployed by the installer (skills, commands/sdlc, agents)
├── bundle/           # Install/uninstall/verify/sync scripts and their tests, templates, install docs
├── docs/             # Interop, known issues, historical notes
├── AGENTS.md         # Instructions for AI agents + detailed bundle inventory
├── CONTRIBUTING.md   # Contribution workflow, conventions, validation before a PR
├── CHANGELOG.md      # Notable changes
└── LICENSE           # MIT license
```

## Inventory

| Category | Count |
|---|---|
| Skills (`claude/skills/*/SKILL.md`) | 10 |
| Commands (`claude/commands/sdlc/*.md`, `/sdlc:*`) | 18 |
| Agents (`claude/agents/*.md`) | 12 |

Full detail (role, effort and source of each skill/command/agent): see [`AGENTS.md`](AGENTS.md).

## Links

- [`LICENSE`](LICENSE) — MIT license.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — contribution workflow, naming conventions, validation before a PR.
- [`AGENTS.md`](AGENTS.md) — instructions for AI agents + bundle inventory.
- [`CHANGELOG.md`](CHANGELOG.md) — notable changes.
