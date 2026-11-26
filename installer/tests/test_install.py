"""install (design §8.1): Python port of test-install.sh / test-install.ps1 (C1b to C15) plus the E3 cases.
Temporary roots only; ~/.claude is never touched (every call passes --live)."""
import contextlib
import io
import json
import os
import subprocess
import unittest
from unittest import mock

from sdlc_installer import cli, gitstate, inventory, manifests
from sdlc_installer import install as install_mod
from tests.helpers import REPO, TempDirCase, make_junction
from tests import legacy_fixtures

SEED = {
    'skills/sdlc/SKILL.md': b'---\nname: sdlc\n---\nroot skill\n',
    'skills/sdlc-verify/SKILL.md': b'---\nname: sdlc-verify\n---\nverify skill\n',
    'skills/sdlc/commands/sdlc/decoy.md': b'embedded DECOY, never deployed\n',
    'commands/sdlc/brainstorm.md': b'brainstorm cmd\n',
    'commands/sdlc/dev.md': b'dev cmd\n',
    'agents/sdlc-architect.md': b'architect agent\n',
    'agents/nested/sdlc-deep.md': b'deep nested agent\n',
}
REGISTRY = manifests.INSTALL_REGISTRY_REL


def git(repo, *args):
    return subprocess.run(['git', '-C', repo] + list(args), check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE).stdout.decode('utf-8', 'replace').strip()


def put(root, rel, data):
    path = os.path.join(root, *rel.split('/'))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as fh:
        fh.write(data)
    return path


def get(root, rel):
    with open(os.path.join(root, *rel.split('/')), 'rb') as fh:
        return fh.read()


def has(root, rel):
    return os.path.isfile(os.path.join(root, *rel.split('/')))


def snapshot(root):
    out = {}
    for d, dirs, files in os.walk(root):
        for name in dirs:
            out[os.path.relpath(os.path.join(d, name), root) + '/'] = None
        for name in files:
            p = os.path.join(d, name)
            with open(p, 'rb') as fh:
                out[os.path.relpath(p, root)] = fh.read()
    return out


def run_cli(argv):
    """(exit code, stdout + stderr) of cli.main, in process."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        try:
            code = cli.main(argv)
        except SystemExit as exc:          # argparse refusal
            code = exc.code
    return code, buf.getvalue()


class InstallCase(TempDirCase):
    def new_case(self, name, use_git=True, seed=SEED):
        base = os.path.join(self.tmp, name)
        repo = os.path.join(base, 'repo')
        ref = os.path.join(repo, 'claude')
        live = os.path.join(base, 'live')
        os.makedirs(live)
        for rel, data in seed.items():
            put(ref, rel, data)
        if use_git:
            put(repo, '.gitattributes', b'* -text\n')
            git(repo, 'init', '-q')
            for k, v in (('user.email', 't@t'), ('user.name', 't'), ('commit.gpgsign', 'false'),
                         ('core.autocrlf', 'false')):
                git(repo, 'config', k, v)
            git(repo, 'add', '-A')
            git(repo, 'commit', '-q', '-m', 'seed ref')
        return repo, ref, live

    def install(self, ref, live, *flags):
        return run_cli(['install', '--source', ref, '--live', live] + list(flags))

    def registry(self, live):
        return json.loads(get(live, REGISTRY).decode('utf-8'))

    def backups(self, live, prefix='sdlc-'):
        root = os.path.join(live, '_backups')
        return [d for d in os.listdir(root) if d.startswith(prefix)] if os.path.isdir(root) else []


class Parity(InstallCase):
    """Scenarios of test-install.sh / .ps1, same names."""

    def test_c1b_real_reference_into_isolated_live(self):
        live = os.path.join(self.tmp, 'live')
        put(live, 'skills/se-tdd/SKILL.md', b'foreign skill\n')
        code, out = self.install(os.path.join(REPO, 'claude'), live, '--allow-dirty')
        self.assertEqual(code, 0, out)
        for rel in ('skills/sdlc-delivery/SKILL.md', 'skills/sdlc-architecture/references/messaging.md',
                    'skills/sdlc-contract/assets/contract.md', 'skills/sdlc/assets/5_delivery.template.md',
                    'skills/sdlc/SOURCES.md'):
            self.assertTrue(has(live, rel), rel)
        # E3-R1-09: measured on the live tree against the literals of C1 (test-install.sh), not against the source.
        from sdlc_installer.verify import cardinalities
        self.assertEqual(cardinalities(inventory.tree_inventory(live)), (14, 12, 19))
        self.assertEqual(get(live, 'skills/se-tdd/SKILL.md'), b'foreign skill\n')

    def test_c2_bootstrap_git(self):
        repo, ref, live = self.new_case('c2')
        code, out = self.install(ref, live)
        self.assertEqual(code, 0, out)
        for rel in SEED:
            if rel != 'skills/sdlc/commands/sdlc/decoy.md':
                self.assertEqual(get(live, rel), SEED[rel], rel)
        self.assertFalse(has(live, 'skills/sdlc/commands/sdlc/decoy.md'))
        self.assertEqual(inventory.tree_inventory(live), inventory.tree_inventory(ref))
        self.assertIn('0 drift', out)
        reg = self.registry(live)
        self.assertEqual(reg['source_commit'], git(repo, 'rev-parse', 'HEAD'))
        self.assertEqual(reg['file_hashes'], manifests.tree_hashes(live, inventory.tree_inventory(live)))
        self.assertEqual(reg['version'], '3.2.0')
        self.assertFalse(os.path.exists(os.path.join(live, '.sync.lock')))

    def test_c3_archive_source(self):
        _repo, ref, live = self.new_case('c3', use_git=False)
        code, out = self.install(ref, live)
        self.assertEqual(code, 0, out)
        self.assertEqual(get(live, 'skills/sdlc/SKILL.md'), SEED['skills/sdlc/SKILL.md'])
        self.assertEqual(get(live, 'agents/nested/sdlc-deep.md'), SEED['agents/nested/sdlc-deep.md'])
        self.assertIn('unavailable', out)
        self.assertNotIn('source_commit', self.registry(live))

    def test_c4_idempotence_and_c5_force(self):
        _repo, ref, live = self.new_case('c4')
        self.assertEqual(self.install(ref, live)[0], 0)
        code, out = self.install(ref, live)
        self.assertEqual(code, 0, out)
        self.assertIn('Already up to date', out)
        self.assertNotIn('deployed', out)
        code, out = self.install(ref, live, '--force')
        self.assertEqual(code, 0, out)
        self.assertNotIn('Already up to date', out)
        [folder] = self.backups(live)
        self.assertTrue(has(os.path.join(live, '_backups', folder), 'skills/sdlc/SKILL.md'))

    def test_c6_third_party_skill_guard(self):
        _repo, ref, live = self.new_case('c6')
        put(live, 'skills/sdlc/SKILL.md', b'---\nname: evil-third-party\n---\nSQUAT\n')
        before = snapshot(live)
        code, out = self.install(ref, live)
        self.assertEqual(code, 3, out)
        self.assertIn('ABORT', out)
        self.assertEqual(snapshot(live), before)

    def test_c7_dry_run_writes_nothing(self):
        _repo, ref, live = self.new_case('c7')
        code, out = self.install(ref, live, '--dry-run')
        self.assertEqual(code, 0, out)
        self.assertEqual(snapshot(live), {})
        self.assertIn('DRY-RUN', out)
        missing = os.path.join(self.tmp, 'c7', 'not-created')
        self.assertEqual(self.install(ref, missing, '--dry-run')[0], 0)
        self.assertFalse(os.path.lexists(missing))

    @unittest.skipUnless(os.name == 'nt', 'Windows 8.3 short names')
    def test_c8_short_path(self):
        import ctypes
        _repo, ref, live = self.new_case('c8 with a long folder name')
        buf = ctypes.create_unicode_buffer(1024)
        if not ctypes.windll.kernel32.GetShortPathNameW(live, buf, 1024) or buf.value == live:
            self.skipTest('8.3 names disabled on this volume')
        code, out = self.install(ref, buf.value)
        self.assertEqual(code, 0, out)
        self.assertIn('0 drift', out)
        self.assertTrue(has(live, 'agents/nested/sdlc-deep.md'))

    def test_c9_orphan_is_not_fatal(self):
        _repo, ref, live = self.new_case('c9')
        self.assertEqual(self.install(ref, live)[0], 0)
        put(live, 'commands/sdlc/oldcmd.md', b'orphan cmd\n')
        code, out = self.install(ref, live, '--force')
        self.assertEqual(code, 0, out)
        self.assertIn('EXTRA', out)
        self.assertTrue(has(live, 'commands/sdlc/oldcmd.md'))
        self.assertNotIn('commands/sdlc/oldcmd.md', self.registry(live)['file_hashes'])
        code, out = self.install(ref, live)          # E3-R1-07: 'up to date' reports the orphan, never '0 drift'
        self.assertEqual(code, 0, out)
        self.assertIn('Already up to date', out)
        self.assertIn('EXTRA', out)
        self.assertNotIn('0 drift', out)
        self.assertTrue(has(live, 'commands/sdlc/oldcmd.md'))

    def test_c10_self_repair(self):
        _repo, ref, live = self.new_case('c10')
        self.assertEqual(self.install(ref, live)[0], 0)
        os.remove(os.path.join(live, 'agents', 'nested', 'sdlc-deep.md'))
        code, out = self.install(ref, live)
        self.assertEqual(code, 0, out)
        self.assertIn('REPAIR', out)
        self.assertNotIn('Already up to date', out)
        self.assertTrue(has(live, 'agents/nested/sdlc-deep.md'))

    def test_c11_dirty_reference_refused_then_allowed(self):
        """Wanted change (§7): a dirty claude/ is refused (5) without --allow-dirty; the scripts only warned."""
        _repo, ref, live = self.new_case('c11')
        self.assertEqual(self.install(ref, live)[0], 0)
        put(ref, 'skills/sdlc/SKILL.md', b'---\nname: sdlc\n---\nMODIFIED not committed\n')
        before = snapshot(live)
        code, out = self.install(ref, live, '--force')
        self.assertEqual(code, 5, out)
        self.assertEqual(snapshot(live), before)
        code, out = self.install(ref, live, '--force', '--allow-dirty')
        self.assertEqual(code, 0, out)
        self.assertIn('NOT confirmed', out)
        self.assertIn(b'MODIFIED', get(live, 'skills/sdlc/SKILL.md'))

    def test_c12_unreadable_name_fails_closed(self):
        _repo, ref, live = self.new_case('c12')
        put(live, 'skills/sdlc/SKILL.md', b'# no name frontmatter\nopaque content\n')
        before = snapshot(live)
        code, out = self.install(ref, live)
        self.assertEqual(code, 3, out)
        self.assertIn('unreadable', out)
        self.assertEqual(snapshot(live), before)

    def test_c13_force_no_backup(self):
        _repo, ref, live = self.new_case('c13')
        self.assertEqual(self.install(ref, live)[0], 0)
        code, out = self.install(ref, live, '--force', '--no-backup')
        self.assertEqual(code, 0, out)
        self.assertEqual(self.backups(live), [])
        self.assertTrue(has(live, 'skills/sdlc/SKILL.md'))

    def test_c14_external_import_preserved(self):
        _repo, ref, live = self.new_case('c14')
        put(live, 'CLAUDE.md', b'@keep-me.md\nmes consignes\n')
        self.assertEqual(self.install(ref, live)[0], 0)
        self.assertEqual(self.install(ref, live, '--force')[0], 0)
        text = get(live, 'CLAUDE.md')
        self.assertEqual(text.count(b'@keep-me.md'), 1)
        self.assertIn(b'mes consignes', text)
        self.assertEqual(text.count(b'@CLAUDE.local.md'), 1)
        code, out = self.install(ref, live, '--remove-import')
        self.assertEqual(code, 2)
        self.assertIn('unrecognized arguments', out)
        self.assertIn('--remove-import', out)
        self.assertEqual(get(live, 'CLAUDE.md'), text)

    def test_c15_local_overlay(self):
        _repo, ref, live = self.new_case('c15')
        self.assertEqual(self.install(ref, live)[0], 0)
        self.assertEqual(get(live, 'CLAUDE.local.md'), b'')
        self.assertEqual(get(live, 'CLAUDE.md').count(b'@CLAUDE.local.md'), 1)
        self.assertNotIn('CLAUDE.local.md', inventory.tree_inventory(live))
        put(live, 'CLAUDE.local.md', b'private content\n')
        self.assertEqual(self.install(ref, live, '--force')[0], 0)
        self.assertEqual(get(live, 'CLAUDE.local.md'), b'private content\n')
        self.assertEqual(get(live, 'CLAUDE.md').count(b'@CLAUDE.local.md'), 1)


class Contract(InstallCase):
    """E3 cases of the design (§3, §5, §6, §7, §8.1)."""

    def test_r3_01_allow_dirty_reflects_addition_and_deletion(self):
        _repo, ref, live = self.new_case('r301')
        put(ref, 'commands/sdlc/new.md', b'untracked\n')
        os.remove(os.path.join(ref, 'agents', 'sdlc-architect.md'))
        self.assertTrue(inventory.head_inventory(os.path.dirname(ref)))
        code, out = self.install(ref, live, '--allow-dirty')
        self.assertEqual(code, 0, out)
        self.assertEqual(get(live, 'commands/sdlc/new.md'), b'untracked\n')
        self.assertFalse(has(live, 'agents/sdlc-architect.md'))
        reg = self.registry(live)                    # E3-R1-08: base commit kept, hashes of the local bytes
        self.assertEqual(reg['source_commit'], git(os.path.dirname(ref), 'rev-parse', 'HEAD'))
        self.assertEqual(reg['file_hashes']['commands/sdlc/new.md'], manifests.sha256_hex(b'untracked\n'))

    def test_clean_reference_deploys_head_bytes(self):
        """Decision JYH (E3): from a clean worktree the HEAD blobs are deployed. A working-tree change hidden from
        'git status' (assume-unchanged) makes the scripts exit 7 (test_exit_parity); here HEAD is deployed, 0."""
        repo, ref, live = self.new_case('head')
        git(repo, 'update-index', '--assume-unchanged', 'claude/commands/sdlc/dev.md')
        put(ref, 'commands/sdlc/dev.md', b'hidden working-tree change\n')
        self.assertEqual(git(repo, 'status', '--porcelain', '--', 'claude'), '')
        code, out = self.install(ref, live)
        self.assertEqual(code, 0, out)
        self.assertEqual(get(live, 'commands/sdlc/dev.md'), SEED['commands/sdlc/dev.md'])

    def _corrupting(self, rel):
        real = install_mod.safe_replace

        def corrupt(path, data):
            if path.replace(os.sep, '/').endswith(rel):
                data = data + b'corrupted on the way\n'
            return real(path, data)
        return mock.patch.object(install_mod, 'safe_replace', corrupt)

    def test_e1_r5_04_drift_gives_exactly_7_and_no_registry(self):
        _repo, ref, live = self.new_case('r504')
        with self._corrupting('commands/sdlc/dev.md'):
            code, out = self.install(ref, live)
        self.assertEqual(code, 7, out)
        self.assertFalse(has(live, REGISTRY))
        self.assertFalse(os.path.lexists(os.path.join(live, 'CLAUDE.md')))
        self.assertFalse(os.path.lexists(os.path.join(live, '.sync.lock')))

    def test_e1_r5_04_previous_registry_untouched(self):
        repo, ref, live = self.new_case('r504b')
        self.assertEqual(self.install(ref, live)[0], 0)
        before = get(live, REGISTRY)
        put(ref, 'commands/sdlc/dev.md', b'dev v2\n')
        git(repo, 'commit', '-q', '-am', 'v2')
        with self._corrupting('commands/sdlc/dev.md'):
            code, out = self.install(ref, live)
        self.assertEqual(code, 7, out)
        self.assertEqual(get(live, REGISTRY), before)

    def test_write_error_on_the_second_file_fails_without_registry_and_frees_the_lock(self):
        _repo, ref, live = self.new_case('werr')
        real = install_mod.safe_replace
        calls = []

        def failing(path, data):
            calls.append(path)
            if len(calls) == 2:
                raise OSError('disk full')
            return real(path, data)
        with mock.patch.object(install_mod, 'safe_replace', failing):
            code, out = self.install(ref, live)
        self.assertGreaterEqual(len(calls), 2)
        self.assertNotEqual(code, 0, out)
        self.assertFalse(has(live, REGISTRY))
        self.assertFalse(os.path.lexists(os.path.join(live, '.sync.lock')))

    def test_r3_09_reference_changed_before_the_lock(self):
        repo, ref, live = self.new_case('r309')
        real = install_mod.load_source
        calls = []
        locked = []

        def racing(root, allow_dirty=False):
            locked.append(os.path.exists(os.path.join(live, '.sync.lock')))     # E3-R1-11
            src = real(root, allow_dirty)
            if not calls:
                put(ref, 'commands/sdlc/dev.md', b'committed between the checks and the lock\n')
                git(repo, 'commit', '-q', '-am', 'race')
            calls.append(src)
            return src
        with mock.patch.object(install_mod, 'load_source', racing):
            code, out = self.install(ref, live)
        self.assertEqual(code, 0, out)
        self.assertEqual(len(calls), 2)
        self.assertEqual(locked, [False, True])
        self.assertEqual(get(live, 'commands/sdlc/dev.md'), b'committed between the checks and the lock\n')
        reg = self.registry(live)
        self.assertEqual(reg['file_hashes'], manifests.tree_hashes(live, inventory.tree_inventory(live)))
        self.assertEqual(reg['source_commit'], git(repo, 'rev-parse', 'HEAD'))

    def test_pyi_04_live_inside_the_worktree(self):
        repo, ref, _live = self.new_case('pyi04')
        for live in (os.path.join(repo, 'live'), ref, os.path.join(ref, 'inner')):
            with self.subTest(live=live):
                before = snapshot(repo)
                code, out = self.install(ref, live)
                self.assertEqual(code, 2, out)
                self.assertEqual(snapshot(repo), before)

    def test_r3_03_archive_and_explicit_source_accepted(self):
        _repo, ref, live = self.new_case('r303')
        self.assertEqual(self.install(ref, live)[0], 0)
        _r, aref, alive = self.new_case('r303b', use_git=False)
        self.assertEqual(self.install(aref, alive)[0], 0)

    def test_r3_02_junction_in_live_refused(self):
        _repo, ref, live = self.new_case('r302')
        sentinel = os.path.join(self.tmp, 'sentinel')
        put(sentinel, 'dev.md', b'sentinel\n')
        os.makedirs(os.path.join(live, 'commands'))
        if not make_junction(os.path.join(live, 'commands', 'sdlc'), sentinel):
            self.skipTest('cannot create a junction or symlink here')
        code, out = self.install(ref, live)
        self.assertEqual(code, 3, out)
        self.assertEqual(snapshot(sentinel), {'dev.md': b'sentinel\n'})
        self.assertFalse(has(live, 'agents/sdlc-architect.md'))

    def test_e3_r1_01_source_junction_refused(self):
        _repo, ref, _live = self.new_case('srclink', use_git=False)
        link = os.path.join(self.tmp, 'srclink-junction')
        if not make_junction(link, ref):
            self.skipTest('cannot create a junction or symlink here')
        live = os.path.join(self.tmp, 'srclink-live')
        for spelling in (link, link + os.sep + '.', link + os.sep):      # E3-R2-01
            for flags in ([], ['--dry-run']):
                code, out = self.install(spelling, live, *flags)
                self.assertEqual(code, 3, (spelling, out))
                self.assertFalse(os.path.lexists(live))

    def test_e3_r1_02_worktree_without_commit_still_confines(self):
        base = os.path.join(self.tmp, 'nocommit')
        repo = os.path.join(base, 'repo')
        for rel, data in SEED.items():
            put(os.path.join(repo, 'claude'), rel, data)
        git(repo, 'init', '-q')
        live = os.path.join(repo, 'live')
        code, out = self.install(os.path.join(repo, 'claude'), live)
        self.assertEqual(code, 2, out)
        self.assertFalse(os.path.lexists(live))

    def test_e3_r1_03_registry_path_is_a_directory(self):
        _repo, ref, live = self.new_case('regdir')
        os.makedirs(os.path.join(live, *REGISTRY.split('/')))
        before = snapshot(live)
        for flags in (['--dry-run'], []):
            code, out = self.install(ref, live, *flags)
            self.assertEqual(code, 3, out)
            self.assertEqual(snapshot(live), before)

    def test_e3_r1_04_empty_live_refused(self):
        _repo, ref, _live = self.new_case('emptylive')
        code, out = run_cli(['install', '--source', ref, '--live', ''])
        self.assertEqual(code, 2, out)
        self.assertEqual(run_cli(['verify', '--live', ''])[0], 2)

    def test_e3_r1_05_skill_folder_without_skill_md(self):
        excluded = dict(SEED, **{'skills/sdlc-extra/__pycache__/x.pyc': b'bytecode'})
        cases = [('empty-archive', False, SEED, 'sdlc-empty'), ('excluded-archive', False, excluded, 'sdlc-extra'),
                 ('excluded-head', True, excluded, 'sdlc-extra')]           # E3-R2-06: one cause per case
        for name, use_git, seed, folder in cases:
            with self.subTest(case=name):
                _repo, ref, live = self.new_case('nofolder-' + name, use_git=use_git, seed=seed)
                if folder == 'sdlc-empty':
                    os.makedirs(os.path.join(ref, 'skills', 'sdlc-empty'))
                code, out = self.install(ref, live)
                self.assertEqual(code, 2, out)
                self.assertIn('skills/%s/SKILL.md' % folder, out)
                self.assertEqual(snapshot(live), {})

    def test_e3_r3_01_link_in_the_parents_of_the_source(self):
        _repo, ref, _live = self.new_case('parentlink', use_git=False)
        alias = os.path.join(self.tmp, 'alias')
        if not make_junction(alias, os.path.dirname(ref)):
            self.skipTest('cannot create a junction or symlink here')
        live = os.path.join(self.tmp, 'parentlink-live')
        for flags in (['--dry-run'], []):
            code, out = self.install(os.path.join(alias, 'claude'), live, *flags)
            self.assertEqual(code, 3, out)
            self.assertFalse(os.path.lexists(live))

    @unittest.skipIf(os.name == 'nt', 'a trailing space in a folder name is POSIX only')
    def test_e3_r3_02_worktree_name_ending_with_a_space(self):
        repo = os.path.join(self.tmp, 'repo ')
        for rel, data in SEED.items():
            put(os.path.join(repo, 'claude'), rel, data)
        git(repo, 'init', '-q')
        for k, v in (('user.email', 't@t'), ('user.name', 't'), ('commit.gpgsign', 'false')):
            git(repo, 'config', k, v)
        git(repo, 'add', '-A')
        git(repo, 'commit', '-q', '-m', 'seed')
        live = os.path.join(repo, 'live')
        code, out = self.install(os.path.join(repo, 'claude'), live)
        self.assertEqual(code, 2, out)
        self.assertFalse(os.path.lexists(live))

    def test_e3_r3_03_broken_head_is_not_an_archive(self):
        repo, ref, live = self.new_case('brokenhead')
        branch = git(repo, 'symbolic-ref', 'HEAD')
        with open(os.path.join(repo, '.git', *branch.split('/')), 'w') as fh:
            fh.write('1' * 40 + '\n')
        code, out = self.install(ref, live)
        self.assertEqual(code, 2, out)
        self.assertIn('not a readable commit', out)
        self.assertEqual(snapshot(live), {})
        unborn = os.path.join(self.tmp, 'unborn')
        for rel, data in SEED.items():
            put(os.path.join(unborn, 'claude'), rel, data)
        git(unborn, 'init', '-q')
        code, out = self.install(os.path.join(unborn, 'claude'), os.path.join(self.tmp, 'unborn-live'))
        self.assertEqual(code, 0, out)                    # unborn branch: archive mode, outside the worktree

    def test_e3_r3_05_dry_run_follows_the_install_order(self):
        seed = dict(SEED, **{'skills/sdlc/SKILL.md': b'no front matter\n'})
        _repo, ref, live = self.new_case('dryorder', use_git=False, seed=seed)
        self.assertEqual(self.install(ref, live)[0], 0)
        self.assertEqual(self.install(ref, live, '--dry-run')[0], 0)
        self.assertEqual(self.install(ref, live)[0], 0)
        self.assertEqual(self.install(ref, live, '--force', '--dry-run')[0], 3)
        self.assertEqual(self.install(ref, live, '--force')[0], 3)

    def test_e3_r2_02_reserved_registry_path_in_source(self):
        seed = dict(SEED, **{'skills/sdlc/.install-manifest.json/note.md': b'squat\n'})
        _repo, ref, live = self.new_case('reserved', use_git=False, seed=seed)
        for flags in (['--dry-run'], []):
            code, out = self.install(ref, live, *flags)
            self.assertEqual(code, 2, out)
            self.assertEqual(snapshot(live), {})

    def test_e3_r2_03_unreadable_repository_is_not_an_archive(self):
        repo, ref, _live = self.new_case('dubious')
        live = os.path.join(repo, 'live')
        failing = mock.Mock(returncode=128, stdout=b'', stderr=b'fatal: detected dubious ownership')
        real = gitstate._git

        def git_stub(path, *args):
            return failing if args[:2] == ('rev-parse', '--show-toplevel') else real(path, *args)
        with mock.patch.object(gitstate, '_git', git_stub):
            code, out = self.install(ref, live)
        self.assertEqual(code, 2, out)
        self.assertIn('dubious', out)
        self.assertFalse(os.path.lexists(live))

    def test_e3_r2_04_sync_state_linked_into_the_worktree(self):
        repo, ref, live = self.new_case('syncstate')
        put(repo, 'tracked.log', b'tracked\n')
        git(repo, 'add', 'tracked.log')
        git(repo, 'commit', '-q', '-m', 'log')
        for name in ('conflicts.log', '.sync-manifest.json'):
            with self.subTest(name=name):
                link = os.path.join(live, name)
                try:
                    os.symlink(os.path.join(repo, 'tracked.log'), link)
                except (OSError, NotImplementedError):
                    self.skipTest('file symlinks not permitted here')
                for flags in (['--dry-run'], []):
                    code, out = self.install(ref, live, *flags)
                    self.assertEqual(code, 2, out)
                self.assertFalse(has(live, REGISTRY))
                os.remove(link)

    def test_e3_r1_06_backup_root_link_same_verdict_in_dry_run(self):
        _repo, ref, live = self.new_case('bklink')
        self.assertEqual(self.install(ref, live, '--no-backup')[0], 0)
        outside = os.path.join(self.tmp, 'outside-backups')
        os.makedirs(outside)
        if not make_junction(os.path.join(live, '_backups'), outside):
            self.skipTest('cannot create a junction or symlink here')
        before = snapshot(live)
        for flags in (['--force', '--dry-run'], ['--force']):
            code, out = self.install(ref, live, *flags)
            self.assertEqual(code, 3, (flags, out))
            self.assertEqual(snapshot(outside), {})
        self.assertEqual(get(live, REGISTRY), before[os.path.join(*REGISTRY.split('/'))])

    def test_registry_with_unsafe_skill_name_refused(self):
        _repo, ref, live = self.new_case('badname')
        put(live, REGISTRY, json.dumps({'version': '3.2.0', 'checksum_sha256': '0' * 64,
                                        'skills': ['../x']}).encode('utf-8'))
        code, out = self.install(ref, live)
        self.assertEqual(code, 3, out)
        self.assertFalse(has(live, 'agents/sdlc-architect.md'))

    def test_corrupt_registry_is_overwritten_with_warning(self):
        _repo, ref, live = self.new_case('corrupt')
        put(live, REGISTRY, b'{ not json')
        code, out = self.install(ref, live)
        self.assertEqual(code, 0, out)
        self.assertIn('unreadable install registry', out)
        self.assertIn('file_hashes', self.registry(live))

    def test_non_utf8_claude_md_refused_before_writing(self):
        _repo, ref, live = self.new_case('utf8')
        put(live, 'CLAUDE.md', b'\xff\xfe not utf-8\n')
        before = snapshot(live)
        code, out = self.install(ref, live)
        self.assertEqual(code, 3, out)
        self.assertEqual(snapshot(live), before)

    def test_lock_held_gives_1_and_writes_nothing(self):
        _repo, ref, live = self.new_case('lock')
        put(live, '.sync.lock', b'pid=1\n')
        before = snapshot(live)
        code, out = self.install(ref, live)
        self.assertEqual(code, 1, out)
        self.assertEqual(snapshot(live), before)

    def test_incomplete_sources_give_2(self):
        cases = {
            'missing': None,
            'nocmd': dict((k, v) for k, v in SEED.items() if not k.startswith('commands/')),
            'noskillmd': dict([(k, v) for k, v in SEED.items() if k != 'skills/sdlc-verify/SKILL.md']
                              + [('skills/sdlc-verify/notes.md', b'no SKILL.md here\n')]),
            'badskill': dict(SEED, **{'skills/sdlcX/SKILL.md': b'---\nname: sdlcX\n---\n'}),
        }
        for name, seed in cases.items():
            with self.subTest(case=name):
                if seed is None:
                    ref, live = os.path.join(self.tmp, 'nowhere'), os.path.join(self.tmp, 'live-missing')
                else:
                    _repo, ref, live = self.new_case('src-' + name, seed=seed)
                code, out = self.install(ref, live)
                self.assertEqual(code, 2, out)
                self.assertFalse(has(live, REGISTRY))

    def test_unknown_file_backed_up_even_with_no_backup(self):
        _repo, ref, live = self.new_case('unknown')
        self.assertEqual(self.install(ref, live)[0], 0)
        put(live, 'agents/sdlc-architect.md', b'edited by hand\n')
        code, out = self.install(ref, live, '--force', '--no-backup')
        self.assertEqual(code, 0, out)
        self.assertIn('origin unknown', out)
        [folder] = self.backups(live)
        self.assertEqual(get(os.path.join(live, '_backups', folder), 'agents/sdlc-architect.md'), b'edited by hand\n')
        self.assertEqual(get(live, 'agents/sdlc-architect.md'), SEED['agents/sdlc-architect.md'])

    @unittest.skipUnless(legacy_fixtures.BASH and legacy_fixtures.commit_exists(legacy_fixtures.OLD_COMMIT),
                         'bash or commit 667d7ed missing')
    def test_pyi_02_upgrade_of_a_legacy_install(self):
        repo = legacy_fixtures.make_repo(self.tmp, legacy_fixtures.OLD_COMMIT)
        ref = os.path.join(repo, 'claude')
        live = os.path.join(self.tmp, 'legacy-live')
        legacy_fixtures.install_with('sh', repo, live)
        self.assertNotIn('file_hashes', self.registry(live))
        put(ref, 'commands/sdlc/dev.md', b'dev cmd v2\n')
        git(repo, 'commit', '-q', '-am', 'v2')
        code, out = self.install(ref, live)
        self.assertEqual(code, 0, out)
        self.assertNotIn('origin unknown', out)
        self.assertEqual(get(live, 'commands/sdlc/dev.md'), b'dev cmd v2\n')
        put(live, 'agents/sdlc-architect.md', b'hand edit\n')
        put(ref, 'commands/sdlc/dev.md', b'dev cmd v3\n')
        git(repo, 'commit', '-q', '-am', 'v3')
        code, out = self.install(ref, live, '--no-backup')
        self.assertEqual(code, 0, out)
        self.assertIn('origin unknown (not a bundle version): agents/sdlc-architect.md', out)
        backed = [d for d in self.backups(live)]
        self.assertTrue(any(has(os.path.join(live, '_backups', d), 'agents/sdlc-architect.md') for d in backed))

class Retained(InstallCase):
    """R3-06 (decision JYH 2026-11-25, option 1.4.1): files an earlier version deployed and this source no longer ships
    stay provable through retained_hashes while they are present and unchanged."""

    def test_untouched_old_file_retained_and_idempotence_kept(self):
        repo, ref, live = self.new_case('ret', seed=dict(SEED, **{'agents/sdlc-old.md': b'old agent\n'}))
        self.assertEqual(self.install(ref, live)[0], 0)
        os.remove(os.path.join(ref, 'agents', 'sdlc-old.md'))
        git(repo, 'commit', '-q', '-am', 'drop old agent')
        code, out = self.install(ref, live)
        self.assertEqual(code, 0, out)
        reg = self.registry(live)
        self.assertEqual(reg['retained_hashes'], {'agents/sdlc-old.md': manifests.sha256_hex(b'old agent\n')})
        self.assertNotIn('agents/sdlc-old.md', reg['file_hashes'])
        self.assertEqual(reg['files_count'], len(reg['file_hashes']))
        code, out = self.install(ref, live)                 # file_hashes is still this install's snapshot
        self.assertEqual(code, 0, out)
        self.assertIn('Already up to date', out)
        owned = manifests.owned_hashes(manifests.read_install_registry(live))
        self.assertIn('agents/sdlc-old.md', owned)

    def test_changed_or_removed_old_file_is_dropped(self):
        repo, ref, live = self.new_case('drop', seed=dict(SEED, **{'agents/sdlc-old.md': b'old\n',
                                                                   'agents/sdlc-gone.md': b'gone\n'}))
        self.assertEqual(self.install(ref, live)[0], 0)
        for rel in ('agents/sdlc-old.md', 'agents/sdlc-gone.md'):
            os.remove(os.path.join(ref, *rel.split('/')))
        git(repo, 'commit', '-q', '-am', 'drop two agents')
        put(live, 'agents/sdlc-old.md', b'edited by hand\n')
        os.remove(os.path.join(live, 'agents', 'sdlc-gone.md'))
        code, out = self.install(ref, live)
        self.assertEqual(code, 0, out)
        self.assertNotIn('retained_hashes', self.registry(live))

    def test_retained_hashes_schema(self):
        live = os.path.join(self.tmp, 'schema')
        put(live, 'skills/sdlc/SKILL.md', b'x\n')
        h = manifests.sha256_hex(b'x\n')
        manifests.write_install_registry(live, '3.2.0', ['sdlc'], {'skills/sdlc/SKILL.md': h},
                                         retained={'skills/sdlc/SKILL.md': h, 'agents/sdlc-a.md': 'A' * 64})
        reg = manifests.read_install_registry(live)
        self.assertEqual(reg.retained, {'agents/sdlc-a.md': 'a' * 64})     # a key of file_hashes is never duplicated
        self.assertEqual(manifests.owned_hashes(reg), {'skills/sdlc/SKILL.md': h, 'agents/sdlc-a.md': 'a' * 64})
        doc = self.registry(live)
        for bad in ([], None, {'agents/sdlc-a.md': 'short'}):
            doc['retained_hashes'] = bad
            put(live, REGISTRY, json.dumps(doc).encode('utf-8'))
            with self.assertRaises(manifests.CorruptRegistry):
                manifests.read_install_registry(live)
        doc['retained_hashes'] = {'../x': h}
        put(live, REGISTRY, json.dumps(doc).encode('utf-8'))
        from sdlc_installer.errors import SecurityError
        with self.assertRaises(SecurityError):
            manifests.read_install_registry(live)


if __name__ == '__main__':
    unittest.main()
