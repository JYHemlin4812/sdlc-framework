# STATE.md mutex protocol (O_EXCL lockfile)

Several subagents launched in parallel within a wave may want to update
`SDLC_PM/STATE.md` at the same time. Without synchronization, the writes
overlap and the state becomes inconsistent.

`scripts/lockfile_helper.py` provides an inter-process mutex based on `O_EXCL`
(atomic file creation), portable across Windows and POSIX.

## Why O_EXCL rather than a POSIX/Win32 mutex

- **Portability**: `O_EXCL` is guaranteed atomic on Windows and POSIX.
- **Inter-process**: works even when subagents run in separate processes (the
  case with the Agent tool + worktree).
- **Zero dependencies**: no need for `filelock`, `portalocker`, etc.
- **Inspectable**: the `.lock` file is visible and can be inspected manually
  when something is stuck.

## Python API

```python
from lockfile_helper import FileLock, LockTimeout

try:
    with FileLock("SDLC_PM/STATE.md.lock", timeout=10):
        # Critical section: read, modify, write STATE.md
        state = read_state()
        state["P003"] = "✅"
        write_state(state)
except LockTimeout:
    # Lock unavailable after 10 s — retry or escalate
    ...
```

The `with` block guarantees release even when an exception is raised.

## CLI

```bash
# Acquire
python lockfile_helper.py acquire SDLC_PM/STATE.md.lock --timeout 10

# Release
python lockfile_helper.py release SDLC_PM/STATE.md.lock
```

## Timeout behavior

Default 10 s, configurable. `LockTimeout` is raised when the lock is not
obtained in time.

Recommendations:

- **Regular subagent**: 10 s timeout. If exceeded, log, retry once, then
  escalate.
- **Pre-commit hook**: 30 s timeout. Tolerates a developer saving in the middle
  of a wave.
- **CI/CD**: 60 s timeout. Tolerates network-disk latency.

## When a subagent crashes

If a subagent crashes while holding the lock, the `.lock` file stays on disk.
Other subagents are then blocked until their timeout.

**Current mitigation**: a fairly short lock timeout (10 s by default) plus a
clear log message for diagnosis.

**Possible future mitigation**: the `.lock` already contains
`pid=<n>;ts=<timestamp>`; at acquisition time, check whether that PID is still
alive and take over the lock if not. Deferred because it needs psutil or
OS-specific code.

## Lock granularity

**One global lock on STATE.md** per project. No per-P### lock.

Why: acquisition is very cheap (<1 ms in practice), critical sections are
short (read + modify + write a Markdown file ≈ ms), and a per-P### lock would
multiply complexity without measurable gain.

## Recommended pattern for STATE.md

```python
def update_state(pid: str, new_status: str) -> None:
    state_path = Path("SDLC_PM/STATE.md")
    lock_path = state_path.with_suffix(".md.lock")
    with FileLock(lock_path, timeout=10):
        content = state_path.read_text(encoding="utf-8") if state_path.exists() else ""
        # simple mutation — prefer a dedicated YAML/JSON file for structured state
        new_line = f"- **{pid}** : {new_status}  <!-- {datetime.now().isoformat()} -->"
        # ... merge into content ...
        state_path.write_text(updated, encoding="utf-8")
```

## What does not go in STATE.md

STATE.md is volatile and concurrently written — keep it minimal:

- **OK**: ✅/🔁/🚫 statuses per P###, current wave, timestamps.
- **Not OK**: detailed logs, stack traces, full agent output.

Verbose details go in separate files (typically one per subagent).

## Tests

No dedicated tests yet (the pattern is simple). A stress test (10 concurrent
acquisitions) can be added if bugs show up in practice.

## Alternatives considered

- **`fcntl.flock`**: not portable to Windows.
- **`msvcrt.locking`**: not portable to POSIX.
- **`portalocker`**: adds a pip dependency for little benefit.
- **`filelock`**: fine, but adds a dependency, and its API is not
  fundamentally simpler than the helper provided here.

`O_EXCL` + an internal helper is the best fit for our target (Windows, Linux,
macOS, zero external dependencies).
