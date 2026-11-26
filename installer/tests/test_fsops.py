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

    def test_transient_permission_error_is_retried_on_windows_only(self):
        """A brief Windows lock (indexer, antivirus) must not fail an install; elsewhere the error is immediate."""
        from unittest import mock
        real = os.replace
        calls = []

        def flaky(src, dst):
            calls.append(1)
            if len(calls) < 3:
                raise PermissionError(13, 'locked')
            return real(src, dst)

        p = os.path.join(self.tmp, 'x.md')
        with mock.patch.object(fsops.os, 'replace', flaky), mock.patch.object(fsops.time, 'sleep', lambda s: None):
            if os.name == 'nt':
                fsops.safe_replace(p, b'ok')
                self.assertEqual(fsops.read_bytes(p), b'ok')
                self.assertEqual(len(calls), 3)
            else:
                with self.assertRaises(PermissionError):
                    fsops.safe_replace(p, b'ok')
                self.assertEqual(len(calls), 1)
        self.assertEqual([n for n in os.listdir(self.tmp) if n.startswith('.sdlc-tmp-')], [])

    def test_directory_refused(self):
        d = os.path.join(self.tmp, 'dir')
        os.makedirs(d)
        with self.assertRaises(InstallerError):
            fsops.safe_replace(d, b'x')
        self.assertTrue(os.path.isdir(d))
        self.assertEqual(os.listdir(d), [])

    def test_ancestor_that_is_a_file_propagates(self):
        # R1 (test-sync-lib.sh): the parent folder cannot be created because an ancestor is a regular file.
        blocker = self.write('blocker', b'x')
        with self.assertRaises(OSError):
            fsops.safe_replace(os.path.join(blocker, 'sub', 'f.txt'), b'data')
        self.assertEqual(fsops.read_bytes(blocker), b'x')

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
