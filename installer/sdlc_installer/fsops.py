"""Safe file replacement (design §2 fsops): temp file in the same folder, fsync, os.replace."""
import os
import stat
import tempfile
import time

from .errors import InstallerError, SecurityError


def _replace(src, dst, attempts=6, delay=0.05):
    """os.replace, retried on Windows when the target is briefly held by an indexer or antivirus
    (PermissionError, observed once in 80+ runs). Any other error, or the last failure, propagates."""
    for attempt in range(attempts):
        try:
            os.replace(src, dst)
            return
        except PermissionError:
            if os.name != 'nt' or attempt == attempts - 1:
                raise
            time.sleep(delay * (attempt + 1))


def safe_replace(path, data):
    """Write `data` (bytes) to `path` atomically. Refuses a directory destination.
    Keeps the permission bits of an existing file. The temp file is removed on any failure."""
    if os.path.isdir(path):
        raise InstallerError('destination is a directory: %s' % path)
    parent = os.path.dirname(path) or '.'
    os.makedirs(parent, exist_ok=True)
    old_mode = None
    try:
        old_mode = stat.S_IMODE(os.stat(path).st_mode)
    except FileNotFoundError:
        pass
    # Short fixed prefix (E1-R5-03): a long destination name must not overflow the component limit.
    fd, tmp = tempfile.mkstemp(prefix='.sdlc-tmp-', dir=parent)
    try:
        with os.fdopen(fd, 'wb') as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        if old_mode is not None:
            os.chmod(tmp, old_mode)
        _replace(tmp, path)
    except BaseException:
        try:
            if os.name == 'nt':
                os.chmod(tmp, stat.S_IREAD | stat.S_IWRITE)    # FINAL-R1-05: a read-only temp cannot be removed
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return path


def check_removable(targets):
    """Windows (E4-R4-02, FINAL-R1-01): removing a read-only file means making it writable first, which changes the
    attribute of its other hard links too, so such a file is refused. `targets`: rel -> path, every removal of the
    run, checked before the first mutation. Absent paths are skipped."""
    if os.name != 'nt':
        return
    for rel, path in targets.items():
        try:
            st = os.stat(path)
        except FileNotFoundError:
            continue
        if not st.st_mode & stat.S_IWRITE and st.st_nlink > 1:
            raise SecurityError('read-only file with other hard links, refusing to change its attribute: %s '
                                '(remove the read-only attribute or the other links first)' % rel)


def read_bytes(path):
    with open(path, 'rb') as fh:
        return fh.read()
