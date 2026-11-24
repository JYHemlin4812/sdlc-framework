import os

from sdlc_installer import locks
from sdlc_installer.errors import LockHeld
from tests.helpers import TempDirCase


class SharedLock(TempDirCase):
    def test_exclusive_and_released(self):
        lk = locks.live_lock(self.tmp)
        with lk:
            self.assertTrue(os.path.isfile(os.path.join(self.tmp, '.sync.lock')))
            with self.assertRaises(LockHeld):
                locks.live_lock(self.tmp).acquire()
        self.assertFalse(os.path.exists(os.path.join(self.tmp, '.sync.lock')))
        with locks.live_lock(self.tmp):
            pass

    def test_bash_directory_lock_is_respected(self):
        # sync-lib.sh takes the lock with mkdir: a directory .sync.lock must block Python too.
        os.makedirs(os.path.join(self.tmp, '.sync.lock'))
        with self.assertRaises(LockHeld):
            locks.live_lock(self.tmp).acquire()
        self.assertTrue(os.path.isdir(os.path.join(self.tmp, '.sync.lock')))

    def test_same_file_as_scripts(self):
        self.assertEqual(locks.LOCK_NAME, '.sync.lock')

    def test_released_on_exception(self):
        try:
            with locks.live_lock(self.tmp):
                raise RuntimeError('boom')
        except RuntimeError:
            pass
        self.assertFalse(os.path.exists(os.path.join(self.tmp, '.sync.lock')))
