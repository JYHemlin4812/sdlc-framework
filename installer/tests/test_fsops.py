import os
import stat

from sdlc_installer import fsops
from sdlc_installer.errors import InstallerError
from tests.helpers import TempDirCase


class SafeReplace(TempDirCase):
    def test_new_and_replace_bytes_exact(self):
        p = os.path.join(self.tmp, 'a', 'b.md')
        fsops.safe_replace(p, b'one\r\n')
        fsops.safe_replace(p, b'two\r\n')
        self.assertEqual(fsops.read_bytes(p), b'two\r\n')
        self.assertEqual(sorted(os.listdir(os.path.dirname(p))), ['b.md'])

    def test_long_basename(self):
        name = 'a' * 240 + '.md'
        p = os.path.join(self.tmp, name)
        try:
            with open(p, 'wb') as fh:
                fh.write(b'old')
        except OSError:
            self.skipTest('filesystem refuses long names')
        fsops.safe_replace(p, b'new')
        self.assertEqual(fsops.read_bytes(p), b'new')

    def test_directory_refused(self):
        d = os.path.join(self.tmp, 'dir')
        os.makedirs(d)
        with self.assertRaises(InstallerError):
            fsops.safe_replace(d, b'x')
        self.assertTrue(os.path.isdir(d))
        self.assertEqual(os.listdir(d), [])

    def test_mode_preserved(self):
        p = self.write('f.sh', b'#!/bin/sh\n')
        os.chmod(p, 0o644 if os.name == 'nt' else 0o750)
        before = stat.S_IMODE(os.stat(p).st_mode)
        fsops.safe_replace(p, b'#!/bin/sh\necho\n')
        self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), before)

    def test_no_temp_left_on_failure(self):
        p = os.path.join(self.tmp, 'f.md')
        with self.assertRaises(TypeError):
            fsops.safe_replace(p, 'not bytes')
        self.assertEqual(os.listdir(self.tmp), [])
