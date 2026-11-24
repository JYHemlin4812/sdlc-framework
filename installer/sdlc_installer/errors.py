"""Exit codes and the exceptions that carry them (design §6)."""

OK = 0
FAILED = 1          # guarantee failed (I/O error, lock held)
USAGE = 2           # usage, prerequisite, root confinement (§5.1)
SECURITY = 3        # security control refused (path, link, ownership, encoding)


class InstallerError(Exception):
    """Base error; `code` is the process exit code."""

    code = FAILED


class UsageError(InstallerError):
    code = USAGE


class SecurityError(InstallerError):
    code = SECURITY


class LockHeld(InstallerError):
    code = FAILED
