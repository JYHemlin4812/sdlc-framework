"""Single shared O_EXCL lock <live>/.sync.lock (design §2, R3-09), same file as the current scripts."""
import datetime
import os
import socket

from .errors import LockHeld

LOCK_NAME = '.sync.lock'


class Lock(object):
    def __init__(self, path):
        self.path = path
        self._fd = None

    def acquire(self):
        parent = os.path.dirname(self.path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        try:
            fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            raise LockHeld('sync lock already held: %s' % self.path)
        except (PermissionError, IsADirectoryError):
            # Windows reports an existing DIRECTORY (the Bash mkdir lock) as access denied.
            if os.path.lexists(self.path):
                raise LockHeld('sync lock already held: %s' % self.path)
            raise
        try:
            meta = 'pid=%d\nhost=%s\nat=%s\n' % (
                os.getpid(), socket.gethostname(), datetime.datetime.now().isoformat())
            os.write(fd, meta.encode('utf-8'))
        except BaseException:
            os.close(fd)
            os.unlink(self.path)
            raise
        self._fd = fd
        return self

    def release(self):
        if self._fd is None:
            return
        try:
            os.close(self._fd)
        finally:
            self._fd = None
            try:
                os.unlink(self.path)
            except FileNotFoundError:
                pass

    def __enter__(self):
        return self.acquire()

    def __exit__(self, *exc):
        self.release()
        return False


def live_lock(live_root):
    return Lock(os.path.join(live_root, LOCK_NAME))
