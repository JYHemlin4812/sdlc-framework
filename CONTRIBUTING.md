# Contributing to sdlc-framework

Thank you for your interest in this project. This document describes the contribution workflow,
naming conventions, expected style and the validation required before any pull request (PR).

This file is the single reference for contributing (its content is not duplicated elsewhere —
in particular not in `AGENTS.md`, which covers a different topic).

## 1. Contribution workflow

1. **Fork** the repository.
2. Create a **descriptive branch** from `main`, named after the change
   (e.g. `fix-check-sdlc-exit-code`, `add-sdlc-report-command`, `docs-contributing`).
3. Make the change. **One PR = one logical change**: do not mix independent topics in the same
   PR (a script fix and a new command, for example, must be two separate PRs).
4. Validate locally (see section 4) before opening the PR.
5. Open the **PR against `main`**, with a clear description of the problem solved and the change
   made.

## 2. Naming and structure conventions

The repository is organized as an **inventory of entries**, each carried by **a single source
file**:

| Entry type | Location | Naming convention |
|---|---|---|
| Skills | `claude/skills/` | Framework sub-skills prefixed `sdlc-` (e.g. `sdlc-debugger`, `sdlc-wave-orchestrator`) |
| Commands | `claude/commands/sdlc/` | Invoked as `/sdlc:*` — one `<name>.md` file per command (e.g. `plan.md` → `/sdlc:plan`) |
| Agents | `claude/agents/` | Prefix `sdlc-` (SDLC framework agents) |

General rule: **1 source file per inventory entry** — no file defining several skills, commands
or agents at once, and no inventory entry split across several source files.

## 3. Expected style

- **GFM Markdown** (GitHub Flavored Markdown) for all documentation.
- **PowerShell/bash parity is required for every script**: it is an invariant of the project.
  Every shipped `.ps1` script has its `.sh` equivalent with **the same behavior** (same
  arguments, same exit codes, same effects). Existing examples in the repository:
  `claude/skills/sdlc/scripts/check_sdlc.ps1` / `check_sdlc.py` (Python layer also wrapped in
  PowerShell) and `claude/skills/sdlc/scripts/deploy_init.ps1` / `deploy_init.sh`. A PR that adds
  or changes a script in only one of the two formats is refused (see section 5).

### 3.1 Writing instructions for Claude

Skills, commands, agents and references are prompts. The framework is tuned for Claude Opus 5.5,
which follows instructions closely, so:

- **Calm imperatives with a reason.** Write "Always …" / "Never …" / "Do X when Y" followed by a
  short clause saying why. No ALL-CAPS, `CRITICAL`/`MUST` pressure or warning-emoji spam — it
  makes the model overtrigger. Prefer saying what to do over what not to do.
- **No thinking prose.** Do not write "think step by step", "take your time" or "reason carefully".
  Depth of thinking is set by the agent's `effort:` frontmatter key, not by prose.
- **No redundant verification.** Do not add "double-check" or "re-verify before responding"
  instructions. Keep the structural gates (AQ Gate, Code Lock, running the tests and quoting their
  result, `/sdlc:review`).
- **English instructions, localized artifacts.** Write every instruction in English. Anything the
  framework produces for the user (documents, reports, questions) goes in the project's
  `output_language`; IDs, template headings and field markers (`**Depends on**`,
  `**Target files**`, `**Status**`, `**wave**`) stay in English so the scripts can parse them.

## 4. Validation before any PR

Before opening a PR, run both test suites from the **repository root**:

```bash
for t in bundle/scripts/tests/test-*.sh; do bash "$t" || exit 1; done
PYTHONUTF8=1 python -m pytest -q claude/skills
```

Both must **exit with code 0**. A PR whose validation fails (non-zero exit code) is refused.

## 5. Review rules

- Every PR is **reviewed by the maintainer (repository owner)** before merging.
- PRs are **refused** when they:
  - duplicate content between `AGENTS.md` and `CONTRIBUTING.md` (each document has a distinct
    role and does not repeat the other);
  - ship a script without its PowerShell/bash equivalent (see section 3);
  - do not pass the test suites of section 4 with exit code 0.
- **English is the language of the project's documentation and instructions.** `README.fr.md` is
  the maintained French translation of `README.md`; update both when you change the README.
