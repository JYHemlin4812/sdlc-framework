# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- BPSE engineering practices merged into the framework (provenance and license in
  `claude/skills/sdlc/SOURCES.md`):
  - `sdlc-delivery` sub-skill and `5_delivery.template.md` (tier `full`+): CI with the
    repository's real commands, secrets by name, migrations, deployment order, health signals,
    rollback, evidence. `sdlc-finish` requires it (step 0) and builds the PR body from it.
  - `sdlc-architecture` sub-skill and its messaging checklist; "Boundaries & dependencies"
    section in `2_architecture.template.md` (if applicable, tier `full`+).
  - `sdlc-contract` sub-skill and contract sheet; the Interfaces section of
    `2_architecture.template.md` now points to a machine-readable schema.
  - `README.template.md`, written by `sdlc-delivery` at tier `full`+ only when the project
    has no README.
  - Six behavior evals (proportionality, characterization, missing tool, 202 contract, broker
    failure, routing of former BPSE requests).

### Changed
- TDD: characterization tests and tests written after the code are allowed when declared;
  `4_tests.md` records each test's level rationale, RED status (`observed` /
  `characterization` / `written-after`), command run and checks not run.
- Coverage is the project's `test_coverage_min`, an indicator rather than a universal quota, in
  every agent, standard and template.
- Code review findings keep their severity and add certainty (confirmed / uncertain /
  suggestion) and origin (introduced / pre-existing); reviews end with their limits.
- `sdlc-verify`: a missing tool is "not run", a local run does not prove remote CI, and no
  approval is ever invented.
- Architecture decisions: Verification field, simplest viable option as baseline, statuses
  `Proposed — auto-approve` and `Superseded by A###`; only the user sets `Accepted`. The
  discussion phase splits open questions into blocking and reversible.
- `3_conception.template.md`: a P### that defines a public contract names it (**Fixes
  contract**) so its consumers depend on it.
- `documentation-tiers.md` states, for each deliverable, whether the gate verifies it or it is
  indicative.
- `deploy_init.ps1 -Tier` / `deploy_init.sh --tier` create only the files of the chosen tier and
  write it (and the project name) to the config; `/sdlc:init` passes the tier. Without the
  option, every file is created as before. The bash script now parses `--force` in any position.
- The AQ Gate fails when an unfinished P### hangs from a superseded A### (retire or re-parent it),
  or when a replacing A### has no P###; any other A### in force without a P### is a warning. A
  replacement supersedes the old decision only once the user accepts it.
- `5_delivery.md` records the commit it describes; `sdlc-finish` refreshes it when the code has
  moved since.
- Deferred: the per-edit P###/T### reminder hook (BPSE plan 5.2) needs a change to the user's
  `settings.json` and is not shipped.

### Fixed
- AQ Gate (`check_sdlc.py`) now depends on `documentation_tier`. A standard project initialised
  with the untouched templates used to pass (exit 0); unfilled template placeholders are now
  errors at every tier except `none` and absent. The `minimal` tier checks `HANDOFF.md` and
  `RESUME.md` instead of requiring a version folder. The `standard` tier accepts E→P without
  `A###`/`T###`. Tier `none` reports SKIPPED, never PASS. `full` requires `asvs_level >= 1`,
  `exhaustive` requires `>= 2`.
- Version folders are compared by number (`v10.0.0` after `v9.0.0`), not alphabetically.
- Placeholder detection compares document lines with the shipped templates, so partly filled
  documents are caught and legitimate `<...>` values are not. `check_sdlc.py --phase plan` skips
  `4_tests.md`, which is written during development; `/sdlc:plan` and `/sdlc:dev` use it.
- The planned `--today` option (reference date for the HANDOFF age check) is available for tests.
- An invalid `sdlc-config.json` exits 2, as documented.
- The PowerShell wrapper reports `SKIPPED` and exposes `warnings` in its JSON output.
- The documentation no longer claims that the gate measures test coverage.
- `wave_planner.py` (and `worktree_helper.py select`, which relies on it) ignores code blocks: an
  example `#### P999` in a fenced block no longer becomes a task, a write-set or an annotated wave.
  Annotation rewrites only the wave number, so text around it (a code block included) is kept.
- A code block closes only on a fence of its opening character (```` ```~ ```` no longer closes
  ```` ``` ````), in both `check_sdlc.py` and `wave_planner.py`; a test keeps the two patterns equal.
  Inline code such as ```` ```x``` ```` no longer opens a block that hid the rest of the document.
  A differential test checks the fence rule against a CommonMark parser (`markdown-it-py`, when
  installed).
- `wave_planner.py --annotate` inserts a missing `wave` field after the whole heading line, so
  `#### P001:A001 — Title` keeps its parent link.
- Field values (`Depends on`, `Target files`, `Last updated`) are read on their own line: an
  empty value no longer picks up the next lines, and the HANDOFF date must open the value.
- The PowerShell wrapper returns its JSON `ERROR` response under Windows PowerShell 5.1 when
  Python writes to stderr, instead of stopping without output.
- The HANDOFF `**Last updated**` date is read outside code blocks, so an example date no longer
  satisfies or skews the age check.
- A project document that is not valid UTF-8 is reported as a `❌` line (exit 1) instead of a
  traceback; an undecodable `sdlc-config.json` exits 2. The config is read with a tolerated BOM
  (`check_sdlc.py`, `model_profiler.py`).
- `deploy_init.ps1` writes `sdlc-config.json` without a BOM under Windows PowerShell 5.1.
  `deploy_init.sh` now copies `0_context.md`, like the PowerShell version.
- `/sdlc:plan`: the planning gate runs once, after the system analyst; the architect no longer has
  to pass a check on a `3_conception.md` that does not exist yet. A P### hangs from an A### whenever
  written A### exist, and from an E### only when there is none.

### Changed
- Code Lock: writing code for a P### no longer requires status ✅. It requires a planned, unblocked P### whose
  `--phase plan` gate passes. ✅ is set only after its T### pass with the output quoted. Developer agents, templates and
  the reference documents follow this rule.

- Optional skeletons (`2_architecture`, `4_tests`) shipped by earlier releases are recognised as not authored,
  so projects created before the change keep passing. When a template changes, its previous digest is added to
  `KNOWN_SHIPPED_SKELETONS` in `check_sdlc.py` first.
- `check_sdlc.ps1` is saved as UTF-8 with BOM, so Windows PowerShell 5.1 reads its emoji literals correctly.
- The workflow (SKILL.md, README in both languages) runs `--phase plan` before development and the release gate at the end.

### Added
- `sdlc-wave-orchestrator`: optional per-task git worktrees (`worktree_helper.py`
  and the `wave_worktrees` config key, default `auto`): a wave with a declared write
  conflict runs each P### in its own worktree and the branches are merged back after
  the wave. Idea adapted from kunchenguid/firstmate (MIT), implemented with stdlib and git only.
- `sdlc-stow` sub-skill and `/sdlc:stow`: end-of-session sweep that captures durable
  knowledge into `SDLC_PM/STOW.md` with tiered decay (pinned, aging 30 days,
  perishable 7 days) and a git-ignored archive. `/sdlc:exit` can run it first. Concept
  adapted from the `stow` skill of kunchenguid/firstmate (MIT).
- `0_context.template.md`: a **Glossary** section (term, definition, aliases / not to be
  confused with) so whoever picks up a project reads business terms with one agreed meaning.
  Documentation only; the AQ Gate does not check it.

## [1.0.0] - 2026-09-28

First public release — framework v4.0.

### Changed
- All instructions, scripts and docs rewritten in English (skills, references, commands, agents,
  templates, script messages, tests, repository docs). `README.md` is now English;
  `README.fr.md` is the French translation (replaces `README.en.md`).
- Instructions tuned for Claude Opus 5.5: calm wording with a short reason instead of ALL-CAPS
  pressure; no "think step by step" prose; no redundant self-verification instructions (the AQ
  Gate, Code Lock and test runs stay); the code reviewer reports every issue with a severity and
  filtering happens afterwards; a standing instruction for unattended runs under
  `--auto-approve`; a time signal in the prompt of each wave subagent; a communication line for
  human-in-the-loop commands (say what you're about to do, update only on important findings,
  lead with the outcome).
- Model IDs updated: `claude-haiku-4-5`, `claude-sonnet-5`, `claude-opus-5-5` (replacing
  `claude-sonnet-4-6` and `claude-opus-4-7`).
- `/sdlc:dev` targets a wave with `--wave N`; `--vague N` is kept as an alias.
- Script output labels are now English: installer ends with `Installation complete` (was
  `Installation terminee`); verify markers `[MISSING]` / `[EXTRA]` / `[FLOOR]` (were
  `[MANQUANT]` / `[SURNUMERAIRE]` / `[PLANCHER]`); sync states `modified-both`,
  `modified-live`, `added-live`, `deleted-ref`. Flags and exit codes are unchanged.
- `sdlc-lang-dispatcher` routes each P### to the matching `sdlc-*-dev` agent.

### Added
- `output_language` field in `SDLC_PM/sdlc-config.json` (asked at `/sdlc:init`): artifacts and
  user-facing messages are written in that language, while IDs, template headings and field
  markers stay in English. Config schema version `4.0` (3.0–3.2 still accepted).
- `effort:` key in agent frontmatter, set per tier: `low` (code-auditor, archive-manager),
  `medium` (developers, analysts, test designer, quality assessor), `high` (architect,
  discussion facilitator).
- AQ Gate (`check_sdlc.py`) and wave planner accept the English field markers
  (`**Depends on**`, `**Target files**`) and the legacy French ones (`**Dépend de**`,
  `**Fichiers cibles**`).
- Migration guide `bundle/MIGRATION_v3_v4.md`.

### Removed
- Personal and local references: calls to a non-public `advisor()` tool (replaced by stating the
  root-cause hypothesis and evidence before marking a task 🚫), local paths and personal names.
- The "clean core" gate of `capture` (exit code 8) and its fixed private patterns: it only scanned
  `NESTOR.md` and `agents/nestor-*.md`, which are outside this repository's sync domains since the
  split from `nestor-agents`, so it could never trigger.

### Notes
- Marking pasted content (recommended in the Opus 5.5 prompting guide) is not implemented:
  Claude Code already marks pasted content.

## [0.1.0] - 2026-09-21

### Changed
- Split from the `nestor-sdlc` mono-repo: this repository now carries only the SDLC framework
  (skills, commands, `sdlc-*` agents, installer). The Nestor ecosystem lives in `nestor-agents`.
- Installer: the `@NESTOR.md` import is no longer added automatically; sync domains are limited
  to `sdlc*`.
- Added `docs/INTEROP.md` (working alongside `nestor-agents`).

## [0.5.0] - 2026-07-05

### Added
- MIT license.
- Contribution guide describing the expected workflow for proposing a change (branch, tests,
  commit style).
- Instructions file for AI agents, combining usage guidance and an inventory of the framework's
  capabilities.
- GitHub templates for issues and pull requests, and a community code of conduct.
- Leak-scan script: scans the repository tree and history for sensitive items before any public
  release.

### Changed
- Landing documentation (French and English) rewritten for an external audience: installation,
  use cases, project positioning.

## [0.4.0] - 2026-07-04

### Changed
- The framework's internal brand renamed throughout (skills, commands, agents, scripts) to a
  single consistent product name, with no change in behavior or features.

## [0.3.0] - 2026-07-04

### Changed
- Clear separation between the framework core, meant to be shared publicly, and the
  configuration/governance items specific to each user's installation — a prerequisite for
  public distribution without exposing private data.

## [0.2.0] - 2026-07-03

### Added
- Development cycle structured in phases (scoping, architecture, design, implementation, tests)
  with end-to-end traceability from requirements to tests.
- Blocking quality gate before any version promotion, so no regression goes unnoticed.
- Orchestration of execution in parallel waves, to run independent development tasks in parallel
  and shorten cycle times.
- Installer and uninstaller with full PowerShell/bash parity, covered by a regression test suite.

## [0.1.0] - 2026-07-01

### Added
- Initial bundle: skills, commands and assistant agents to drive a structured software
  development lifecycle, with PowerShell and bash installers.
