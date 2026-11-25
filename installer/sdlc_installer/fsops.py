"""Safe file replacement (design §2 fsops): temp file in the same folder, fsync, os.replace."""
import os
import stat
import tempfile
import time

from .errors import InstallerError


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
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return path


def read_bytes(path):
    with open(path, 'rb') as fh:
        return fh.read()
