import os

from sdlc_installer import backup
from sdlc_installer.errors import InstallerError, SecurityError
from tests.helpers import TempDirCase, make_junction


def tree(root):
    out = []
    for d, dirs, files in os.walk(root):
        for name in dirs + files:
            out.append(os.path.relpath(os.path.join(d, name), root))
    return sorted(out)


class Backups(TempDirCase):
    def setUp(self):
        super().setUp()
        self.live = os.path.join(self.tmp, 'live')
        os.makedirs(self.live)

    def test_relative_paths_kept_and_unique(self):
        self.write('live/skills/sdlc/dev.md', b'X')
        self.write('live/commands/sdlc/dev.md', b'Y')
        d1, done = backup.backup_files(self.live, ['skills/sdlc/dev.md', 'commands/sdlc/dev.md', 'agents/sdlc-absent.md'], 'sdlc')
        d2, _ = backup.backup_files(self.live, ['skills/sdlc/dev.md'], 'sdlc')
        self.assertNotEqual(d1, d2)
        self.assertEqual(done, ['skills/sdlc/dev.md', 'commands/sdlc/dev.md'])
        self.assertTrue(d1.startswith(os.path.join(self.live, '_backups')))
        with open(os.path.join(d1, 'skills', 'sdlc', 'dev.md'), 'rb') as fh:
            self.assertEqual(fh.read(), b'X')
        with open(os.path.join(d1, 'commands', 'sdlc', 'dev.md'), 'rb') as fh:
            self.assertEqual(fh.read(), b'Y')

    def test_nothing_to_back_up_creates_nothing(self):
        before = tree(self.tmp)
        self.assertEqual(backup.backup_files(self.live, ['skills/sdlc/absent.md'], 'sdlc'), (None, []))
        self.assertEqual(tree(self.tmp), before)

    def test_refusal_creates_nothing(self):
        self.write('live/skills/sdlc/ok.md', b'ok')
        before = tree(self.tmp)
        with self.assertRaises(SecurityError):
            backup.backup_files(self.live, ['skills/sdlc/ok.md', '../escape.md'], 'sdlc')
        self.assertEqual(tree(self.tmp), before)

    def test_directory_source_fails(self):
        os.makedirs(os.path.join(self.live, 'skills', 'sdlc', 'dir.md'))
        before = tree(self.tmp)
        with self.assertRaises(InstallerError):
            backup.backup_files(self.live, ['skills/sdlc/dir.md'], 'sdlc')
        self.assertEqual(tree(self.tmp), before)

    def test_bad_prefix_creates_nothing(self):
        self.write('live/skills/sdlc/ok.md', b'ok')
        for prefix in ('../outside', os.path.join(self.tmp, 'abs'), 'a/b', ''):
            with self.subTest(prefix=prefix):
                before = tree(self.tmp)
                with self.assertRaises(SecurityError):
                    backup.backup_files(self.live, ['skills/sdlc/ok.md'], prefix)
                self.assertEqual(tree(self.tmp), before)

    def test_backup_root_junction_refused(self):
        self.write('live/skills/sdlc/ok.md', b'ok')
        outside = os.path.join(self.tmp, 'outside')
        os.makedirs(outside)
        if not make_junction(os.path.join(self.live, '_backups'), outside):
            self.skipTest('cannot create a junction here')
        with self.assertRaises(SecurityError):
            backup.backup_files(self.live, ['skills/sdlc/ok.md'], 'sdlc')
        self.assertEqual(os.listdir(outside), [])
