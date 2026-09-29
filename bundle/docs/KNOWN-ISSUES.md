# Known issues — SDLC sync system (SP2)

State at the close of **SP2 / P018**. Fixed ✅ · remaining limitation ⚠️ · deferred ⏭️.

## Fixed in SP2

- ✅ **`install`**: rewritten as an **additive** bootstrap (a subset of restore); `/MIR`
  dropped (per-relPath Copy-Tree), classified verify post-check, idempotence self-heal,
  fail-closed cardinality guard, O_EXCL lock.
- ✅ **`verify`**: rewritten as **read-only**, authoritative on the **committed HEAD**
  (`git cat-file`), shared exclusions (no more false `.pyc` failures), derived floors.
- ✅ **Data loss (P018 review)**: atomic writes are now **tested** everywhere —
  `copy_tree`, the `restore` backup and the `install` backup abort before any destructive
  action if the write fails (the live install stays intact/recoverable).

## `.sh` ↔ `.ps1` parity gaps — documented, accepted

Found by the P018 adversarial review; not fixed because they have no real impact:

- ⚠️ **Case sensitivity**: the bash port filters domains and exclusions
  **case-sensitively** (`case`, globs, `find -name`), whereas PowerShell (`-like`/`-contains`)
  is **case-insensitive**. On a case-sensitive Linux file system, a mixed-case name
  (`SDLC-Foo`) would be handled differently. **Not reachable in practice**: all canonical
  names are lowercase. For strict parity: `shopt -s nocasematch`/`nocaseglob` + `find -iname`.
- ⚠️ **Cosmetic (non-contractual logs)**: `conflicts.log` timestamp as `-0400` (bash) vs
  `-04:00` (PS, ISO round-trip); sort order of the `verify` report (byte-ordinal
  `LC_ALL=C` vs PS culture); hyphen `-` vs em dash `—` in the `capture` commit message.
  No functional impact (same exit codes and same sets).

## Strict prerequisites (P018 review)

- ⚠️ **bash 4+** is required for the `.sh` port (`declare -A`, `mapfile`). macOS ships
  `/bin/bash` 3.2: the entry points refuse cleanly (`exit 2`, message `brew install bash`).
  No 3.2 backport is planned.
- ⚠️ **Python 3** is required for the bash JSON manifest I/O (resolved as `python`, then
  `python3`; override with `SYNC_PY`). If missing, `read_sync_manifest` fails closed
  (safe, but sync is blocked until Python 3 is installed).

## Deferred to wave 4 (locked `.ps1` files — to handle when unlocked)

- ⏭️ **`verify.ps1`**: (a) uncaught internal exception → `exit 1` instead of `2`
  [F5-root]; (b) **vacuous PASS on an empty ref** [N2, documented XFAIL] → guard
  `if refHash.Count == 0 { return 2 }`.
- ⏭️ **`restore.ps1` / `verify.ps1`**: latent fragility with Windows 8.3 short paths
  (`Resolve-Path`) — `install` already protects itself through `Get-CanonicalPath`.
- ⏭️ **`Invoke-VerifyPostCheck`** duplicated in `install`/`restore` → belongs in
  `sync-lib` [F9, DRY].
- ⏭️ **`restore` TOCTOU nit** [N3]: window between the canonical guard and the write —
  outside the threat model (single-user use), documented.

> The bash port faithfully reproduces the current behavior of the `.ps1` scripts; these
> deferred items concern the **PowerShell reference** and will be mirrored in bash when
> they are handled.
