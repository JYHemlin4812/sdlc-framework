"""Design §6 (PYI-05): the .sh and .ps1 scripts return the documented code for the same condition.
Baseline for the Python port, kept after E7 on the scripts of legacy_fixtures.SCRIPTS_COMMIT (removed from the tree).
Each shell is checked on its own (a missing shell or commit skips only what it needs).
Temporary roots only; ~/.claude is never touched."""
import os
import shutil
import subprocess
import unittest

from tests.helpers import TempDirCase, which
from tests.legacy_fixtures import SCRIPTS_COMMIT, pinned_scripts

BASH = which('bash')
PWSH = which('pwsh')
SHELLS = [s for s in (('sh', BASH), ('ps1', PWSH)) if s[1]]


def run(shell, name, args):
    kind, exe = shell
    scripts = pinned_scripts()
    if kind == 'sh':
        # Native paths on purpose (E1-R3-07): bash must handle Windows backslash paths too.
        cmd = [exe, os.path.join(scripts, name + '.sh')] + args['sh']
    else:
        cmd = [exe, '-NoProfile', '-File', os.path.join(scripts, name + '.ps1')] + args['ps1']
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                          timeout=300).returncode


def snapshot(root):
    out = {}
    for d, _dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            with open(p, 'rb') as fh:
                out[os.path.relpath(p, root)] = fh.read()
    return out


def git(repo, *args):
    subprocess.run(['git', '-C', repo] + list(args), check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


FILES = {'skills/sdlc/SKILL.md': b'---\nname: sdlc\n---\n', 'commands/sdlc/dev.md': b'dev\n',
         'agents/sdlc-a.md': b'a\n'}


@unittest.skipUnless(SHELLS, 'neither bash nor pwsh is available')
class ExitCodeParity(TempDirCase):
    def setUp(self):
        if pinned_scripts() is None:
            self.skipTest('commit %s missing: script parity NOT proven' % SCRIPTS_COMMIT)
        super().setUp()
        self.repo = os.path.join(self.tmp, 'repo')
        self.ref = os.path.join(self.repo, 'claude')
        self.live = os.path.join(self.tmp, 'live')
        for rel, data in FILES.items():
            for root in (self.ref, self.live):
                p = os.path.join(root, *rel.split('/'))
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with open(p, 'wb') as fh:
                    fh.write(data)
        git(self.repo, 'init', '-q')
        git(self.repo, 'config', 'user.email', 't@t')
        git(self.repo, 'config', 'user.name', 't')
        git(self.repo, 'config', 'commit.gpgsign', 'false')
        git(self.repo, 'add', '--', 'claude')
        git(self.repo, 'commit', '-q', '-m', 'seed')

    def expect(self, name, args, code, unchanged=None):
        for shell in SHELLS:
            with self.subTest(script=name, shell=shell[0]):
                before = snapshot(unchanged) if unchanged else None
                self.assertEqual(run(shell, name, args), code)
                if unchanged:
                    self.assertEqual(snapshot(unchanged), before)

    @staticmethod
    def sync_args(ref, live):
        return {'sh': ['--ref-root', ref, '--live-root', live], 'ps1': ['-RefRoot', ref, '-LiveRoot', live]}

    def test_missing_roots_give_2(self):
        missing = os.path.join(self.tmp, 'missing')
        self.expect('capture', self.sync_args(missing, self.live), 2, self.live)
        self.expect('restore', self.sync_args(missing, self.live), 2, self.live)
        self.expect('verify', self.sync_args(missing, missing), 2)
        self.expect('install', {'sh': ['--source-root', missing, '--claude-root', self.live, '--dry-run'],
                                'ps1': ['-SourceRoot', missing, '-ClaudeRoot', self.live, '-DryRun']}, 2, self.live)
        empty = os.path.join(self.tmp, 'empty')
        os.makedirs(empty)
        self.expect('uninstall', {'sh': ['--claude-root', empty, '--force'], 'ps1': ['-ClaudeRoot', empty, '-Force']}, 2)
        self.expect('scan-fuites', {'sh': ['--repo-root', missing], 'ps1': ['-RepoRoot', missing]}, 2)

    def test_file_as_root_gives_2(self):
        """E1-R2-10: a regular file given as RefRoot is refused before anything is written."""
        as_file = os.path.join(self.tmp, 'a-file')
        with open(as_file, 'wb') as fh:
            fh.write(b'x')
        self.expect('capture', self.sync_args(as_file, self.live), 2, self.live)

    def test_verify_identical_and_drift(self):
        self.expect('verify', self.sync_args(self.repo, self.live), 0)
        with open(os.path.join(self.live, 'commands', 'sdlc', 'dev.md'), 'wb') as fh:
            fh.write(b'changed\n')
        self.expect('verify', self.sync_args(self.repo, self.live), 1)

    def test_capture_first_run_divergent_gives_5(self):
        with open(os.path.join(self.live, 'agents', 'sdlc-a.md'), 'wb') as fh:
            fh.write(b'live edit\n')
        self.expect('capture', self.sync_args(self.ref, self.live), 5, self.live)

    def test_restore_dirty_reference_gives_5(self):
        with open(os.path.join(self.ref, 'agents', 'sdlc-a.md'), 'wb') as fh:
            fh.write(b'uncommitted\n')
        self.expect('restore', self.sync_args(self.ref, self.live), 5, self.live)

    def test_restore_corrupt_base_gives_6(self):
        with open(os.path.join(self.live, '.sync-manifest.json'), 'wb') as fh:
            fh.write(b'{ not json')
        self.expect('restore', self.sync_args(self.ref, self.live), 6, self.live)

    def test_restore_diverged_upstream_gives_4(self):
        git(self.repo, 'branch', 'up')
        git(self.repo, 'checkout', '-q', 'up')
        with open(os.path.join(self.repo, 'other.txt'), 'wb') as fh:
            fh.write(b'up\n')
        git(self.repo, 'add', 'other.txt')
        git(self.repo, 'commit', '-q', '-m', 'upstream side')
        git(self.repo, 'checkout', '-q', '-')
        with open(os.path.join(self.repo, 'mine.txt'), 'wb') as fh:
            fh.write(b'mine\n')
        git(self.repo, 'add', 'mine.txt')
        git(self.repo, 'commit', '-q', '-m', 'local side')
        git(self.repo, 'branch', '--set-upstream-to=up')
        self.expect('restore', self.sync_args(self.ref, self.live), 4, self.live)

    def _install_drift_gives_7(self, shell):
        """E1-R5-04: post-check drift against a CLEAN reference gives exactly 7, and no registry is published.
        A working-tree change hidden from 'git status' (assume-unchanged) is deployed by the script and then
        differs from HEAD. A registry written by an earlier install stays byte for byte."""
        kind = shell[0]
        registry = os.path.join('skills', 'sdlc', '.install-manifest.json')
        prev, fresh = os.path.join(self.tmp, 'prev'), os.path.join(self.tmp, 'fresh')

        def args(live):
            return {'sh': ['--source-root', self.ref, '--claude-root', live],
                    'ps1': ['-SourceRoot', self.ref, '-ClaudeRoot', live]}
        self.assertEqual(run(shell, 'install', args(prev)), 0)
        with open(os.path.join(prev, registry), 'rb') as fh:
            before = fh.read()
        git(self.repo, 'update-index', '--assume-unchanged', 'claude/commands/sdlc/dev.md')
        with open(os.path.join(self.ref, 'commands', 'sdlc', 'dev.md'), 'wb') as fh:
            fh.write(b'hidden working-tree change\n')
        status = subprocess.run(['git', '-C', self.repo, 'status', '--porcelain', '--', 'claude'],
                                stdout=subprocess.PIPE, check=True).stdout
        self.assertEqual(status, b'')
        self.assertEqual(run(shell, 'install', args(fresh)), 7, kind)
        self.assertFalse(os.path.exists(os.path.join(fresh, registry)))
        self.assertEqual(run(shell, 'install', args(prev)), 7, kind)
        with open(os.path.join(prev, registry), 'rb') as fh:
            self.assertEqual(fh.read(), before)

    @unittest.skipUnless(BASH, 'bash missing: E1-R5-04 NOT proven for install.sh')
    def test_install_clean_reference_drift_gives_7_sh(self):
        self._install_drift_gives_7(('sh', BASH))

    @unittest.skipUnless(PWSH, 'pwsh missing: E1-R5-04 NOT proven for install.ps1')
    def test_install_clean_reference_drift_gives_7_ps1(self):
        self._install_drift_gives_7(('ps1', PWSH))

    def test_lock_held_gives_1(self):
        lock = os.path.join(self.live, '.sync.lock')
        for form in ('file', 'dir'):
            if form == 'file':
                with open(lock, 'w') as fh:
                    fh.write('pid=1\n')
            else:
                os.makedirs(lock)
            for name in ('capture', 'restore'):
                with self.subTest(lock=form):
                    self.expect(name, self.sync_args(self.ref, self.live), 1)
                    self.assertTrue(os.path.lexists(lock))
            if form == 'file':
                os.remove(lock)
            else:
                shutil.rmtree(lock)
