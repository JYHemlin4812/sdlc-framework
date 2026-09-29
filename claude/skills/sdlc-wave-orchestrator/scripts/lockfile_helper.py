"""lockfile_helper.py — Atomic mutex for STATE.md mutations (SDLC).

Implements a file lock based on O_EXCL (atomic creation of a .lock file).
Lets several subagents launched in parallel by the wave orchestrator mutate
STATE.md without collisions.

Python usage:
    from lockfile_helper import FileLock

    with FileLock("SDLC_PM/STATE.md.lock", timeout=10):
        # critical section: read, modify, write STATE.md
        ...

CLI usage:
    python lockfile_helper.py acquire SDLC_PM/STATE.md.lock --timeout 10
    python lockfile_helper.py release SDLC_PM/STATE.md.lock
"""

from __future__ import annotations

import argparse
import errno
import os
import sys
import time
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")


class LockTimeout(Exception):
    """Raised when the lock is not obtained within the timeout."""


class FileLock:
    """File lock based on O_EXCL (atomic on Windows and POSIX)."""

    def __init__(self, lock_path: str | Path, timeout: float = 10.0, poll_interval: float = 0.05):
        self.lock_path = Path(lock_path)
        self.timeout = timeout
        self.poll_interval = poll_interval
        self._fd: int | None = None

    def acquire(self) -> None:
        deadline = time.monotonic() + self.timeout
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        while True:
            try:
                self._fd = os.open(
                    str(self.lock_path),
                    os.O_CREAT | os.O_EXCL | os.O_WRONLY,
                )
                os.write(self._fd, f"pid={os.getpid()};ts={time.time():.3f}".encode("utf-8"))
                return
            except OSError as exc:
                if exc.errno != errno.EEXIST:
                    raise
                if time.monotonic() >= deadline:
                    raise LockTimeout(
                        f"Lock {self.lock_path} not obtained after {self.timeout}s"
                    ) from exc
                time.sleep(self.poll_interval)

    def release(self) -> None:
        if self._fd is not None:
            try:
                os.close(self._fd)
            except OSError:
                pass
            self._fd = None
        try:
            self.lock_path.unlink(missing_ok=True)
        except OSError:
            pass

    def __enter__(self) -> "FileLock":
        self.acquire()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.release()


def cmd_acquire(args: argparse.Namespace) -> int:
    lock = FileLock(args.path, timeout=args.timeout)
    try:
        lock.acquire()
    except LockTimeout as exc:
        print(f"❌ {exc}", file=sys.stderr)
        return 1
    print(f"✅ Lock acquired: {args.path}")
    return 0


def cmd_release(args: argparse.Namespace) -> int:
    path = Path(args.path)
    if not path.exists():
        print(f"⚠️  Lock already released: {path}")
        return 0
    try:
        path.unlink()
    except OSError as exc:
        print(f"❌ Release failed: {exc}", file=sys.stderr)
        return 1
    print(f"✅ Lock released: {path}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Atomic mutex for SDLC STATE.md")
    sub = parser.add_subparsers(dest="cmd", required=True)

    acq = sub.add_parser("acquire")
    acq.add_argument("path")
    acq.add_argument("--timeout", type=float, default=10.0)

    rel = sub.add_parser("release")
    rel.add_argument("path")

    args = parser.parse_args()
    if args.cmd == "acquire":
        return cmd_acquire(args)
    return cmd_release(args)


if __name__ == "__main__":
    sys.exit(main())
