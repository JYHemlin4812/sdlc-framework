"""Exit codes and the exceptions that carry them (design §6)."""

OK = 0
FAILED = 1          # guarantee failed (I/O error, lock held)
USAGE = 2           # usage, prerequisite, root confinement (§5.1)
SECURITY = 3        # security control refused (path, link, ownership, encoding)
BLOCKED = 3         # capture / restore: an unresolved sync state blocks the run, nothing written
GIT_FAILED = 4      # capture: git add/commit failed; restore: the reference diverged from its upstream (not ff)
DIRTY = 5           # install: claude/ has uncommitted changes and --allow-dirty is absent (§7); restore: same guard;
                    # capture: first run with a divergent union and no --adopt
CORRUPT_BASE = 6    # capture / restore: the sync manifest (base) is unreadable, fail closed
DRIFT = 7           # install / capture / restore: the post-check found a real difference (§6)


class InstallerError(Exception):
    """Base error; `code` is the process exit code."""

    code = FAILED


class UsageError(InstallerError):
    code = USAGE


class SecurityError(InstallerError):
    code = SECURITY


class LockHeld(InstallerError):
    code = FAILED


class DirtyReference(InstallerError):
    code = DIRTY
