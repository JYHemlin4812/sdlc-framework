# SDLC sync system (SP2)

**Bidirectional** synchronization between the live install (`~/.claude/`) and the versioned
canonical tree (`sdlc-framework/claude/` at git `HEAD`), with safeguards against data loss.
One implementation for every platform: `python installer/install.py <command>` (Python 3.9+,
standard library only). The former PowerShell and bash scripts in `bundle/scripts/` are
deprecated and will be removed in the next release; their documented differences from the
Python installer are listed in `installer/parite.md`.

## Synced domains

Only these domains are synced (the rest of `~/.claude/` is ignored):

| Domain | Path |
|---|---|
| Skills | `skills/sdlc*` (**excludes** `skills/sdlc/commands/**`) |
| Commands | `commands/sdlc` |
| Agents | `agents/**/sdlc-*` (any depth) |

Cross-cutting exclusions (single source: `installer/sdlc_installer/domain.py`): folders `__pycache__`,
`.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `_backups`, `_backup`; files `*.pyc`, `*.pyo`, `*.bak`,
`.sync-manifest.json`, `conflicts.log`, `.install-manifest.json` (names compared without case).

## Commands

| Command | Direction | Role |
|---|---|---|
| `capture` | live → ref → git | Captures local changes into the canonical tree and commits only the copied paths (changes staged elsewhere stay staged). |
| `restore` | git → live | Deploys the committed canonical tree (`HEAD`, or its upstream after a fast-forward) to the install, with backups. |
| `verify` | — (read-only) | Checks that `live` matches the **committed HEAD** (`git cat-file`, never the working tree). |
| `install` | source → live | **Additive** bootstrap (no deletes). |
| `scan-fuites` | — (read-only) | Leak scan of the repository before a public release; writes a report. |

Run them as `python installer/install.py <command> [options]` from the repository root.

## Prerequisites

| | |
|---|---|
| Python | 3.9 or later, standard library only |
| Git | 2.26 or later (capture/restore/verify) |

Hashing is **byte-exact** (SHA256 over raw bytes, CRLF ≠ LF), so fidelity is guaranteed for
capture → push → restore. The sync base (`~/.claude/.sync-manifest.json`) is machine-local,
outside the worktree.

## Sync states

Each file is classified by comparing ref, live and the base (last synced hash):
`identical`, `modified-live`, `modified-ref`, `modified-both`, `added-live`, `added-ref`,
`deleted-live`, `deleted-ref`, `absent-both`, `conflict-deleted-live-modified-ref`,
`conflict-deleted-ref-modified-live`.

## Safeguards (data loss)

- **O_EXCL lock** (`~/.claude/.sync.lock`) around every mutation; released on exit. A dry-run takes no lock and writes nothing.
- **Atomic write**: temp file + rename (`mv -f` / `Replace`), never in place. A **failed write** aborts before any destructive action.
- **Timestamped backup** under `_backups/` (excluded from sync) **before** any replacement or deletion.
- Exclusive **per-relPath greenlist** + path-traversal guard; **no destructive mirror** (`/MIR`, `rsync --delete`, `cp -r`).
- **Corrupt manifest** → **fail-closed** (empty base, never "identical" by default).
- **Blocks**: `capture`/`restore` refuse to write (`exit 3`) when both sides changed; nothing is written.
- **restore — canonical guard**: aborts (`exit 5`) if the ref working tree (`claude/`) is not clean, or if the
  fast-forward would overwrite a local file, **before** any write.
- **State files** (sync base, `conflicts.log`, lock, backups) must be outside the repository worktree (`exit 2`).
- **install — additive**: never deletes orphans (that is restore's job); verify post-check with classified outcome.

## Exit codes

| Code | `install` | `uninstall` | `verify` | `capture` | `restore` | `scan-fuites` |
|---|---|---|---|---|---|---|
| 0 | success / already up to date | success / cancelled | 0 drift | success / nothing to capture | success | report written (with or without hits) |
| 1 | I/O error, lock held | I/O error, lock held | drift detected | I/O error, lock held | I/O error, lock held | — |
| 2 | prerequisite or source missing, roots overlap | registry missing or corrupt (without `--discover`) | unavailable (no domain file in HEAD included) | root, git or option error, state inside the worktree | prerequisite, git or option error | root, prerequisite or report path unusable |
| 3 | third-party or unreadable skill, unsafe path | unsafe path | — | block (modified-both, deleted-live, conflict), unsafe path | block (modified-live, modified-both, conflict), unsafe path | — |
| 4 | — | — | — | `git add` / `git commit` failed | the reference diverged from its upstream, or the fast-forward failed | — |
| 5 | `claude/` has uncommitted changes (without `--allow-dirty`) | — | — | first run with a divergent tree (without `--adopt`) | reference not clean, or the fast-forward would overwrite a local file | — |
| 6 | — | — | — | corrupt sync base (fail-closed) | corrupt sync base (fail-closed) | — |
| 7 | real drift after deployment | — | — | post-check failed (committed paths not in HEAD or still dirty) | post-check drift | — |

## Common options

`--dry-run` (0 writes) · `--live <path>` · `--ref <repository>` · `restore --force-restore` ·
`capture --lww [--provenance ref|live]` (logged to `conflicts.log`; the reference wins by default) ·
`capture --adopt` · `--manifest-path` · `install --force` / `--no-backup` / `--allow-dirty` ·
`scan-fuites --motifs-path` / `--report-path`.

See `KNOWN-ISSUES.md` for remaining limitations and documented parity gaps.
