# INSTALL — SDLC bundle (system install)

How to install, verify, update and uninstall the SDLC bundle in `~/.claude/`.

---

## Prerequisites

| Component | Minimum | Check |
|---|---|---|
| **PowerShell** (Windows) | 7.0 recommended (5.1 supported) | `pwsh -v` |
| **bash** (Linux/macOS) | 4.0 (macOS ships 3.2: `brew install bash`) | `bash --version` |
| **Python** | 3.9 | `python --version` or `python3 --version` |
| **git** | any recent version | `git --version` |
| **Claude Code** | recent | `claude --version` |

On Windows without PowerShell 7: `winget install Microsoft.PowerShell`.

git is only needed for the post-install check (`verify`) and for the sync scripts; the
install itself works from an extracted archive too.

---

## Install

### Windows (PowerShell 7)

```powershell
git clone https://github.com/JYHemlin4812/sdlc-framework.git
cd sdlc-framework
pwsh bundle/scripts/install.ps1
```

### Linux / macOS

```bash
git clone https://github.com/JYHemlin4812/sdlc-framework.git
cd sdlc-framework
bash bundle/scripts/install.sh
```

### Install options

| Flag (PS / bash) | Effect |
|---|---|
| `-DryRun` / `--dry-run` | Simulation: lists what would be deployed, writes nothing. |
| `-Force` / `--force` | Reinstall even if the checksum is unchanged. |
| `-NoBackup` / `--no-backup` | Skip the backup before replacing files (not recommended). |
| `-ClaudeRoot <path>` / `--claude-root <path>` | Target directory (default: `~/.claude`). |
| `-SourceRoot <path>` / `--source-root <path>` | Source directory (default: `claude/` at the repository root). |
| `-RemoveImport` / `--remove-import` | Only remove the `@NESTOR.md` import line from `~/.claude/CLAUDE.md`, then exit (optional `nestor-agents` interop). |

### What gets installed

```
~/.claude/
├── skills/
│   ├── sdlc/                       (orchestrator: scripts, references, assets, tests, evals)
│   │   └── .install-manifest.json  (version + checksum registry)
│   ├── sdlc-wave-orchestrator/     (DAG + Kahn + lockfile)
│   ├── sdlc-lang-dispatcher/       (Python/JS/Go/Rust standards)
│   ├── sdlc-asvs-auditor/          (OWASP ASVS L1/L2/L3)
│   └── sdlc-debugger/ sdlc-evolve/ sdlc-finish/ sdlc-receive-review/ sdlc-reviewer/ sdlc-verify/
├── commands/
│   └── sdlc/                       (18 slash commands)
└── agents/
    └── sdlc-*.md                   (12 subagents)
```

The list of deployed files is derived from the canonical `claude/` tree, never hard-coded.
Files are copied one by one through an atomic write (temporary file + rename); no mirror
copy ever deletes files in `~/.claude/`.

---

## Activating the slash commands

Restart Claude Code after installing so it discovers the new skills, commands and agents.

In any project, type:

```
/sdlc:status
```

In a project without `SDLC_PM/`, the command reports that no SDLC project was found and
suggests `/sdlc:init` or `/sdlc:brainstorm <description>`.

The 18 commands are listed in `README.md`; their contracts are in
`claude/skills/sdlc/references/slash-commands.md`.

---

## Post-install check

The installer runs `verify` automatically at the end. To run it yourself:

```powershell
pwsh bundle/scripts/verify.ps1          # or: bash bundle/scripts/verify.sh
```

`verify` is read-only. It compares every installed file of the SDLC domain with the
committed `HEAD` of the repository (`git cat-file`, not the working tree) by SHA256 and
reports `[MISSING]`, `[HASH DIFF]`, `[EXTRA]` and `[FLOOR]` findings (a floor finding means
fewer skills, agents or commands than the canonical tree).

| Exit code | Meaning |
|---|---|
| 0 | installation identical to the committed tree |
| 1 | at least one difference |
| 2 | check unavailable (no `~/.claude`, no git, or no commit) |

---

## Update

Pull the repository and run the installer again:

- unchanged checksum: reports that everything is already up to date, exit 0, nothing written;
- changed checksum: timestamped backup, then the changed files are deployed and the manifest updated.

```powershell
pwsh bundle/scripts/install.ps1            # standard update (with backup)
pwsh bundle/scripts/install.ps1 -Force     # reinstall even if up to date
pwsh bundle/scripts/install.ps1 -DryRun    # preview, no changes
```

Backups are stored under `~/.claude/_backups/`.

To synchronize local edits made in `~/.claude/` back into the repository (or the other way
round), use `capture` / `restore`: see `docs/SYNC.md`.

---

## Uninstall

```powershell
pwsh bundle/scripts/uninstall.ps1          # Windows
bash bundle/scripts/uninstall.sh           # Linux / macOS
```

Behavior:

- reads `~/.claude/skills/sdlc/.install-manifest.json` to know exactly what to remove;
- always backs up to `~/.claude/skills/_backups/sdlc-uninstall-<timestamp>/` first;
- removes the `sdlc*` skills and `commands/sdlc/`; other skills are left untouched;
- without a manifest, refuses by default (use `-Discover` / `--discover` to remove by naming convention).

| Flag (PS / bash) | Effect |
|---|---|
| `-Force` / `--force` | No interactive confirmation. |
| `-Discover` / `--discover` | Expert mode when the manifest is missing. |
| `-RemoveCore` / `--remove-core` | Also remove the installed `sdlc-*` / `nestor-*` agents and `NESTOR.md`, and the `@NESTOR.md` import in `CLAUDE.md` (optional `nestor-agents` interop). |

---

## Safeguards

The installer refuses (exit 3) to overwrite a target `SKILL.md` whose frontmatter `name:`
does not start with `sdlc`, which protects third-party skills with the same folder name:

```
~/.claude/skills/sdlc/SKILL.md  → name: other-skill   ← ABORT, exit 3
```

The uninstaller never deletes a skill that is not part of the SDLC domain. Local edits to
installed files are backed up before any upgrade or uninstall.

---

## Troubleshooting

### Slash command not recognized after install

1. Restart Claude Code completely (not just a reload).
2. Check that `~/.claude/commands/sdlc/brainstorm.md` exists.
3. Run `pwsh bundle/scripts/verify.ps1` to diagnose.

### Skill not triggered by natural-language requests

Triggers are defined in the `description:` frontmatter of
`~/.claude/skills/sdlc/SKILL.md`. Check that the file exists and contains the keywords
("SDLC", "brainstorm", "scoping", etc.).

### Manifest missing after install

```powershell
ls "$HOME/.claude/skills/sdlc/.install-manifest.json"
```

If it is missing, the install failed part-way. Run it again with `-Force` / `--force`.

---

## References

- `README.md` — bundle overview
- `MIGRATION_v3_v4.md` — upgrade from v3.x
- `MIGRATION_v2_v3.md` — migration from SDLCv2
- `docs/SYNC.md` — capture / restore / verify
- `claude/skills/sdlc/SKILL.md` — orchestrator spec
- `claude/skills/sdlc/references/aq-gate.md` — AQ Gate
- `claude/skills/sdlc/references/code-lock.md` — Code Lock rules
