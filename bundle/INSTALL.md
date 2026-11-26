# INSTALL — SDLC bundle (system install)

How to install, verify, update and uninstall the SDLC bundle in `~/.claude/`.

---

## Prerequisites

| Component | Minimum | Check |
|---|---|---|
| **Python** | 3.9 (standard library only) | `python --version` or `python3 --version` |
| **git** | 2.26 or later | `git --version` |
| **Claude Code** | recent | `claude --version` |

One installer for every platform: `python installer/install.py <command>` (`python3` on
Linux). Tested on Windows and Linux (WSL Ubuntu); macOS is not verified yet.

git is only needed for the post-install check (`verify`) and for `capture` / `restore`;
the install itself works from an extracted archive too.

The former PowerShell scripts are removed. The bash scripts in `bundle/scripts/` are deprecated
and will be removed in the next release; use the Python installer.

---

## Install

```bash
git clone https://github.com/JYHemlin4812/sdlc-framework.git
cd sdlc-framework
python installer/install.py install
```

From a clean clone, the installer deploys the files of the committed `HEAD`. If `claude/`
has uncommitted changes it refuses (exit 5); `--allow-dirty` deploys the working tree instead.

### Install options

| Flag | Effect |
|---|---|
| `--dry-run` | Simulation: lists what would be deployed, writes nothing. |
| `--force` | Reinstall even if the installed version is unchanged. |
| `--no-backup` | No backup of bundle files before replacing them (a file the installer cannot recognize as a bundle file is always backed up). |
| `--allow-dirty` | Deploy the working tree of a `claude/` folder that has uncommitted changes. |
| `--live <path>` | Target directory (default: `~/.claude`). |
| `--source <path>` | Source directory (default: `claude/` at the repository root). |

### What gets installed

```
~/.claude/
├── skills/
│   ├── sdlc/                       (orchestrator: scripts, references, assets, tests, evals)
│   │   └── .install-manifest.json  (version + checksum registry)
│   ├── sdlc-wave-orchestrator/     (DAG + Kahn + lockfile)
│   ├── sdlc-lang-dispatcher/       (Python/JS/Go/Rust standards)
│   ├── sdlc-asvs-auditor/          (OWASP ASVS L1/L2/L3)
│   ├── sdlc-architecture/ sdlc-contract/ sdlc-delivery/   (adapted from BPSE)
│   └── sdlc-debugger/ sdlc-evolve/ sdlc-finish/ sdlc-receive-review/ sdlc-reviewer/ sdlc-verify/
├── commands/
│   └── sdlc/                       (19 slash commands)
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

The 19 commands are listed in `README.md`; their contracts are in
`claude/skills/sdlc/references/slash-commands.md`.

---

## Post-install check

The installer runs `verify` automatically at the end. To run it yourself:

```bash
python installer/install.py verify
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

- unchanged source and installed files intact: reports that everything is already up to date,
  exit 0, no bundle file redeployed (the installer may still recreate an empty `CLAUDE.local.md`
  if you deleted it, or add its `@CLAUDE.local.md` import line back to `CLAUDE.md`, after a backup
  of `CLAUDE.md`);
- unchanged source but an installed file missing or edited since: **repair**, the bundle version
  is put back (your edited file is backed up first);
- changed source: timestamped backup, then the changed files are deployed and the manifest updated.

To keep a local edit, capture it into the repository first (`docs/SYNC.md`).

```bash
python installer/install.py install             # standard update (with backup)
python installer/install.py install --force     # reinstall even if up to date
python installer/install.py install --dry-run   # preview, no changes
```

Backups are stored under `~/.claude/_backups/`.

To synchronize local edits made in `~/.claude/` back into the repository (or the other way
round), use `capture` / `restore`: see `docs/SYNC.md`.

---

## Uninstall

```bash
python installer/install.py uninstall
```

Behavior:

- reads `~/.claude/skills/sdlc/.install-manifest.json` to know exactly what to remove;
- removes only the files it can prove come from the bundle (recorded hashes, or a version
  committed in the repository history); files you added or edited are kept and reported.
  Exception: an install made by an older installer, whose manifest records no per-file hashes,
  when the repository history cannot be read either (no `--ref` repository): every file in
  the SDLC folders is removed, personal files included, after a warning and a backup;
- backs up everything it removes to `~/.claude/_backups/uninstall-<timestamp>/` first;
- removes the `sdlc*` skills and `commands/sdlc/`; other skills are left untouched;
- without a readable manifest, refuses by default (exit 2). `--discover` finds the candidate
  folders by name (`skills/sdlc*`, `commands/sdlc`) and removes only the files the Git history
  of the repository proves to be bundle files.

| Flag | Effect |
|---|---|
| `--force` | No interactive confirmation. |
| `--discover` | Expert mode when the manifest is missing or unreadable. |
| `--remove-core` | Also remove the installed `sdlc-*` agents. Other files, including `CLAUDE.md`, are left as they are. |
| `--ref <path>` | Repository used as proof of origin (default: this repository). |

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
3. Run `python installer/install.py verify` to diagnose.

### Skill not triggered by natural-language requests

Triggers are defined in the `description:` frontmatter of
`~/.claude/skills/sdlc/SKILL.md`. Check that the file exists and contains the keywords
("SDLC", "brainstorm", "scoping", etc.).

### Manifest missing after install

```bash
ls "$HOME/.claude/skills/sdlc/.install-manifest.json"
```

If it is missing, the install failed part-way. Run it again with `--force`.

---

## References

- `README.md` — bundle overview
- `MIGRATION_v3_v4.md` — upgrade from v3.x
- `MIGRATION_v2_v3.md` — migration from SDLCv2
- `docs/SYNC.md` — capture / restore / verify
- `claude/skills/sdlc/SKILL.md` — orchestrator spec
- `claude/skills/sdlc/references/aq-gate.md` — AQ Gate
- `claude/skills/sdlc/references/code-lock.md` — Code Lock rules
