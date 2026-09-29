# SDLC sync system (SP2)

**Bidirectional** synchronization between the live install (`~/.claude/`) and the versioned
canonical tree (`sdlc-framework/claude/` at git `HEAD`), with safeguards against data loss.
Two implementations with **identical behavior**: PowerShell (`.ps1`, reference) and bash
(`.sh`, parity port P018).

## Synced domains

Only these domains are synced (the rest of `~/.claude/` is ignored):

| Domain | Path |
|---|---|
| Skills | `skills/sdlc*` (**excludes** `skills/sdlc/commands/**`) |
| Commands | `commands/sdlc` |
| Agents | `agents/sdlc-*` |

Cross-cutting exclusions (single source: `get_sync_exclusion`): `__pycache__`, `.*cache`,
`_backups`/`_backup`, `*.pyc`/`*.pyo`/`*.bak`, `.sync-manifest.json`, `conflicts.log`,
`.install-manifest.json`.

## Scripts

| Script | Direction | Role |
|---|---|---|
| `capture` | live → ref → git | Captures local changes into the canonical tree and commits them (explicit pathspec `claude/<rel>`, never `git add -A`). |
| `restore` | git → ref → live | Deploys the committed canonical tree to the install (staging + atomic swap + backup). |
| `verify` | — (read-only) | Checks that `live` matches the **committed HEAD** (`git cat-file`, never the working tree). |
| `install` | source → live | **Additive** disaster-recovery bootstrap (a subset of restore, no deletes). |
| `sync-lib` | — | Foundation sourced by all the others (hashing, lock, atomic write, greenlist, state classifier, manifest). |

`.ps1`: run with `pwsh -NoProfile -File <script>.ps1`.
`.sh`: run with `bash <script>.sh`.

## Prerequisites

| | PowerShell | bash |
|---|---|---|
| Interpreter | **PowerShell 7+** | **bash 4+** (macOS `/bin/bash` 3.2 is refused with exit 2 — `brew install bash`) |
| Git | required (capture/restore/verify) | same |
| Hashing | `Get-FileHashByteExact` (native) | `sha256sum` |
| JSON manifest | native | **Python 3** (`python`, then `python3`; override with `SYNC_PY`) |

Hashing is **byte-exact** (SHA256 over raw bytes, CRLF ≠ LF), so fidelity is guaranteed
across tools for capture → push → restore. The bash manifest is machine-local (outside the
worktree) and is **not** required to be byte-identical to the PowerShell one.

## Sync states

Each file is classified by comparing ref, live and the base (last synced hash):
`identical`, `modified-live`, `modified-ref`, `modified-both`, `added-live`, `added-ref`,
`deleted-live`, `deleted-ref`, `absent-both`, `conflict-deleted-live-modified-ref`,
`conflict-deleted-ref-modified-live`.

## Safeguards (data loss)

- **O_EXCL lock** around every mutation (atomic `mkdir` in bash, since `flock` is not portable); released on exit.
- **Atomic write**: temp file + rename (`mv -f` / `Replace`), never in place. A **failed write** aborts before any destructive action.
- **Timestamped backup** under `_backups/` (excluded from sync) **before** any replacement or deletion.
- Exclusive **per-relPath greenlist** + path-traversal guard; **no destructive mirror** (`/MIR`, `rsync --delete`, `cp -r`).
- **Corrupt manifest** → **fail-closed** (empty base, never "identical" by default).
- **Blocks**: `capture`/`restore` refuse to write (`exit 3`) when both sides changed.
- **restore — canonical guard**: aborts (`exit 5`) if the ref working tree (`claude/`) is not clean, **before** any write.
- **install — additive**: never deletes orphans (that is restore's job); verify post-check with classified outcome.

## Exit codes

| Code | `capture` | `restore` | `verify` | `install` |
|---|---|---|---|---|
| 0 | success | success | 0 drift | success / already up to date |
| 1 | error | I/O error (backup failed, aborted) | drift detected | I/O error (backup/swap failed, aborted) |
| 2 | git missing | git missing | unavailable (git/live missing) | prerequisites (bash < 4 / PS < 7) |
| 3 | modified-both block | modified-live / modified-both block | — | cardinality guard (fail-closed) |
| 4 | — | `ff-only` diverges | — | — |
| 5 | — | canonical guard (dirty ref) | — | — |
| 6 | — | corrupt base (fail-closed) | — | — |
| 7 | — | post-check drift | — | real DRIFT (clean ref + missing/hash) |

## Common options

`--dry-run` (0 writes) · `--ref-root` / `--live-root` · `restore --force-restore` ·
`capture --lww` (Last-Write-Wins, logged to `conflicts.log`) · `install --force` / `--no-backup`.
PowerShell uses the same names in PascalCase (`-DryRun`, `-ForceRestore`, `-Lww`, …).

See `KNOWN-ISSUES.md` for remaining limitations and documented parity gaps.
