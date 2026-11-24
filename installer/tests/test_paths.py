import os
import unittest

from sdlc_installer import paths
from sdlc_installer.errors import SecurityError, UsageError
from tests.helpers import TempDirCase, make_junction


class RelValidation(unittest.TestCase):
    def test_refused(self):
        for bad in ('', '/etc/x', 'C:/x', 'C:x', 'a/../b', './a', 'a//b', '..', 'a/.',
                    'skills/sdlc/a\\b.md', 'a/b.md.', 'a/b ', 'a/CON', 'a/nul.txt', 'a/b.md:stream', 'a/b\x01', 'a/COM¹.txt', 'a/conin$', 'skills/sdlc/NUL .txt', 'a/b' + chr(0xDCFF) + '.md'):
            with self.assertRaises(SecurityError, msg=bad):
                paths.validate_rel(bad)

    def test_accepted(self):
        self.assertEqual(paths.validate_rel('skills/sdlc/SKILL.md'), 'skills/sdlc/SKILL.md')

    def test_case_collision(self):
        with self.assertRaises(SecurityError):
            paths.check_unique(['skills/sdlc/A.md', 'skills/sdlc/a.md'])
        paths.check_unique(['skills/sdlc/a.md', 'skills/sdlc/b.md'])
        with self.assertRaises(SecurityError):
            paths.check_unique(['skills/sdlc/A', 'skills/sdlc/a/page.md'])
        with self.assertRaises(SecurityError):
            paths.check_unique(['skills/sdlc/Guide/a.md', 'skills/sdlc/guide/b.md'])


class Junctions(TempDirCase):
    """R3-02: a junction below the live root must be refused before any mutation."""

    def test_nested_junction_refused(self):
        live = os.path.join(self.tmp, 'live')
        sentinel = os.path.join(self.tmp, 'outside')
        os.makedirs(os.path.join(live, 'commands'))
        os.makedirs(sentinel)
        with open(os.path.join(sentinel, 'dev.md'), 'wb') as fh:
            fh.write(b'sentinel')
        if not make_junction(os.path.join(live, 'commands', 'sdlc'), sentinel):
            self.skipTest('cannot create a junction here')
        with self.assertRaises(SecurityError):
            paths.check_all(live, ['skills/sdlc/SKILL.md', 'commands/sdlc/dev.md'])
        with open(os.path.join(sentinel, 'dev.md'), 'rb') as fh:
            self.assertEqual(fh.read(), b'sentinel')

    def test_plain_paths_ok(self):
        live = os.path.join(self.tmp, 'live')
        os.makedirs(live)
        targets = paths.check_all(live, ['skills/sdlc/SKILL.md'])
        self.assertEqual(targets, [os.path.join(live, 'skills', 'sdlc', 'SKILL.md')])


class ExistingSpelling(TempDirCase):
    """E1-R4-03: an existing entry answering to another spelling is refused (case-insensitive FS)."""

    def test_existing_dir_other_case(self):
        live = os.path.join(self.tmp, 'live')
        os.makedirs(os.path.join(live, 'skills', 'sdlc', 'guide'))
        if not os.path.exists(os.path.join(live, 'skills', 'sdlc', 'GUIDE')):
            self.skipTest('case-sensitive filesystem')
        with self.assertRaises(SecurityError):
            paths.check_all(live, ['skills/sdlc/Guide/a.md'])
        paths.check_all(live, ['skills/sdlc/guide/a.md'])


class Roots(TempDirCase):
    @unittest.skipIf(os.name == 'nt', 'a backslash is a separator on Windows')
    def test_backslash_ending_worktree(self):
        repo = os.path.join(self.tmp, 'repo\\')
        os.makedirs(os.path.join(repo, 'live'))
        with self.assertRaises(UsageError):
            paths.check_outside_worktree(repo, {'live': os.path.join(repo, 'live')})

    def test_disjoint(self):
        a = os.path.join(self.tmp, 'repo', 'claude')
        os.makedirs(a)
        paths.check_disjoint(a, os.path.join(self.tmp, 'live'))
        with self.assertRaises(UsageError):
            paths.check_disjoint(a, os.path.join(a, 'sub'))
        with self.assertRaises(UsageError):
            paths.check_disjoint(a, a)

    def test_state_outside_worktree(self):
        repo = os.path.join(self.tmp, 'repo')
        os.makedirs(repo)
        paths.check_outside_worktree(repo, {'live': os.path.join(self.tmp, 'live')})
        with self.assertRaises(UsageError):
            paths.check_outside_worktree(repo, {'live': os.path.join(repo, 'live')})
        with self.assertRaises(UsageError):
            paths.check_outside_worktree(repo, {'manifest': os.path.join(repo, 'state', '.sync-manifest.json')})
