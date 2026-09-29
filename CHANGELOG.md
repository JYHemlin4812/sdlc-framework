# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
