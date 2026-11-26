"""uninstall (design §8.6): Python port of test-uninstall.sh / .ps1 (U1 to U4) and of the uninstall cases of the three
test-retrait-* suites, plus the E4 cases (R3-04, R3-07, §3 ownership, §5.2 confinement).
Registries are written by a real installer (Python, or the old install.sh of 667d7ed), never by hand, except
the corrupt ones. Temporary roots only; ~/.claude is never touched (every call passes --live)."""
import json
import os
import unittest
from unittest import mock

from sdlc_installer import manifests
from tests.helpers import make_junction
from tests import legacy_fixtures
from tests.test_install import SEED, InstallCase, get, has, put, run_cli, snapshot

REGISTRY = manifests.INSTALL_REGISTRY_REL
CLAUDE_MD = b'# My personal CLAUDE.md\nPre-existing user content.\n@keep-me.md\n'


class Uninstall(InstallCase):
    def installed(self, name):
        """Fixture repo + live installed by install.py, with files outside the domain (as in test-uninstall)."""
        repo, ref, live = self.new_case(name)
        put(live, 'agents/autre-clara.md', b'clara agent\n')
        put(live, 'PERSO.md', b'perso core\n')
        put(live, 'CLAUDE.md', CLAUDE_MD)
        code, out = self.install(ref, live)
        self.assertEqual(code, 0, out)
        return repo, ref, live

    def uninstall(self, live, *flags, ref=None):
        return run_cli(['uninstall', '--live', live, '--ref', ref or os.path.join(self.tmp, 'no-repo')] + list(flags))

    def backup_folder(self, live, prefix='uninstall-'):
        found = self.backups(live, prefix)
        self.assertEqual(len(found), 1, found)
        return os.path.join(live, '_backups', found[0])

    # --- test-uninstall U1 to U4 ------------------------------------------------------------

    def test_u1_default_keeps_agents_and_core(self):
        repo, _ref, live = self.installed('u1')
        claude_md = get(live, 'CLAUDE.md')
        code, out = self.uninstall(live, '--force', ref=repo)
        self.assertEqual(code, 0, out)
        for rel in ('skills/sdlc', 'skills/sdlc-verify', 'commands/sdlc', REGISTRY):
            self.assertFalse(os.path.lexists(os.path.join(live, *rel.split('/'))), rel)
        for rel in ('agents/sdlc-architect.md', 'agents/nested/sdlc-deep.md', 'agents/autre-clara.md', 'PERSO.md'):
            self.assertTrue(has(live, rel), rel)
        self.assertEqual(get(live, 'CLAUDE.md'), claude_md)
        bk = self.backup_folder(live)
        self.assertTrue(has(bk, 'skills/sdlc/SKILL.md'))
        self.assertTrue(has(bk, REGISTRY))
        self.assertFalse(os.path.isdir(os.path.join(bk, 'agents')))

    def test_u2_remove_core(self):
        repo, _ref, live = self.installed('u2')
        claude_md = get(live, 'CLAUDE.md')
        code, out = self.uninstall(live, '--force', '--remove-core', ref=repo)
        self.assertEqual(code, 0, out)
        self.assertFalse(os.path.lexists(os.path.join(live, 'skills', 'sdlc')))
        self.assertFalse(has(live, 'agents/sdlc-architect.md'))
        self.assertFalse(has(live, 'agents/nested/sdlc-deep.md'))
        self.assertTrue(has(live, 'agents/autre-clara.md'))
        self.assertTrue(has(live, 'PERSO.md'))
        self.assertEqual(get(live, 'CLAUDE.md'), claude_md)
        bk = self.backup_folder(live)
        self.assertTrue(has(bk, 'agents/sdlc-architect.md'))
        self.assertTrue(has(bk, 'agents/nested/sdlc-deep.md'))
        self.assertFalse(has(bk, 'agents/autre-clara.md'))
        self.assertFalse(has(bk, 'PERSO.md'))

    def test_u3_remove_core_without_agents(self):
        repo, _ref, live = self.installed('u3')
        for rel in ('agents/sdlc-architect.md', 'agents/nested/sdlc-deep.md', 'agents/autre-clara.md',
                    'PERSO.md', 'CLAUDE.md'):
            os.remove(os.path.join(live, *rel.split('/')))
        os.rmdir(os.path.join(live, 'agents', 'nested'))          # E4-R1-09: no agents/ at all, as in U3
        os.rmdir(os.path.join(live, 'agents'))
        self.assertFalse(os.path.lexists(os.path.join(live, 'agents')))
        code, out = self.uninstall(live, '--force', '--remove-core', ref=repo)
        self.assertEqual(code, 0, out)
        self.assertFalse(os.path.lexists(os.path.join(live, 'skills', 'sdlc')))

    def test_u4_confirmation_refused(self):
        repo, _ref, live = self.installed('u4')
        before = snapshot(live)
        for answer in ('non', 'n', ''):
            with mock.patch('builtins.input', return_value=answer):
                code, out = self.uninstall(live, ref=repo)
            self.assertEqual(code, 0, out)
            self.assertIn('Cancelled', out)
            self.assertEqual(snapshot(live), before)
        with mock.patch('builtins.input', side_effect=EOFError):
            self.assertEqual(self.uninstall(live, ref=repo)[0], 0)
        self.assertEqual(snapshot(live), before)
        with mock.patch('builtins.input', return_value='oui'):
            self.assertEqual(self.uninstall(live, ref=repo)[0], 0)
        self.assertFalse(has(live, REGISTRY))

    # --- test-retrait-* (uninstall cases) ----------------------------------------------------

    def test_retrait_t4_t5_t9_remove_core_with_discover(self):
        repo, _ref, live = self.installed('t4')
        os.remove(os.path.join(live, *REGISTRY.split('/')))
        put(live, 'NESTOR.md', b'core\n')
        put(live, 'agents/nestor-b.md', b'other\n')
        claude_md = get(live, 'CLAUDE.md')
        code, out = self.uninstall(live, '--discover', '--force', '--remove-core', ref=repo)
        self.assertEqual(code, 0, out)
        self.assertEqual(get(live, 'CLAUDE.md'), claude_md)
        self.assertEqual(get(live, 'NESTOR.md'), b'core\n')          # T4 (Codex .sh): bytes intact
        self.assertEqual(get(live, 'agents/nestor-b.md'), b'other\n')
        self.assertFalse(has(live, 'agents/sdlc-architect.md'))
        self.assertFalse(has(live, 'agents/nested/sdlc-deep.md'))

    def test_retrait_t6_personal_and_modified_files_kept(self):
        repo, _ref, live = self.installed('t6')
        put(live, 'skills/sdlc/mes-notes.md', b'mes notes\n')
        put(live, 'commands/sdlc/dev.md', b'modified by hand\n')
        code, out = self.uninstall(live, '--force', ref=repo)
        self.assertEqual(code, 0, out)
        self.assertEqual(get(live, 'skills/sdlc/mes-notes.md'), b'mes notes\n')
        self.assertEqual(get(live, 'commands/sdlc/dev.md'), b'modified by hand\n')
        self.assertFalse(has(live, 'skills/sdlc/SKILL.md'))
        self.assertFalse(has(live, REGISTRY))
        self.assertIn('kept (not from the bundle, or modified): commands/sdlc/dev.md', out)

    def test_retrait_t8_no_registry_no_discover(self):
        _repo, _ref, live = self.installed('t8')
        os.remove(os.path.join(live, *REGISTRY.split('/')))
        before = snapshot(live)
        code, out = self.uninstall(live, '--force')
        self.assertEqual(code, 2, out)
        self.assertEqual(snapshot(live), before)

    def test_retrait_t10_homonyms_both_backed_up(self):
        """--discover proves ownership by the Git history (E4-R1-02): both homonyms are committed in the reference;
        a personal file without proof is kept, and so is everything when no history is readable."""
        seed = dict(SEED, **{'skills/sdlc/dev.md': b'XBYTES\n', 'commands/sdlc/dev.md': b'YBYTES\n'})
        repo, ref, live = self.new_case('t10', seed=seed)
        for rel in ('skills/sdlc/SKILL.md', 'skills/sdlc/dev.md', 'commands/sdlc/dev.md'):
            put(live, rel, seed[rel])
        put(live, 'commands/sdlc/notes.md', b'personal\n')
        before = snapshot(live)
        code, out = self.uninstall(live, '--discover', '--force')          # no readable history
        self.assertEqual(code, 0, out)
        self.assertEqual(snapshot(live), before)
        code, out = self.uninstall(live, '--discover', '--force', ref=repo)
        self.assertEqual(code, 0, out)
        bk = self.backup_folder(live)
        self.assertEqual(get(bk, 'skills/sdlc/dev.md'), b'XBYTES\n')
        self.assertEqual(get(bk, 'commands/sdlc/dev.md'), b'YBYTES\n')
        self.assertFalse(has(live, 'commands/sdlc/dev.md'))
        self.assertEqual(get(live, 'commands/sdlc/notes.md'), b'personal\n')
        self.assertFalse(has(bk, 'commands/sdlc/notes.md'))          # only what is deleted is backed up

    @unittest.skipUnless(legacy_fixtures.BASH and legacy_fixtures.commit_exists(legacy_fixtures.OLD_COMMIT),
                         'bash or commit 667d7ed missing')
    def test_retrait_t9_t12_legacy_registry(self):
        """Registry written by the real install.sh of 667d7ed (no file_hashes). Without readable history: global
        warning, everything in the SDLC folders removed (§1 decision 3). With the history: a hand edit is kept."""
        repo = legacy_fixtures.make_repo(self.tmp, legacy_fixtures.OLD_COMMIT)
        for name, ref, kept in (('nohist', None, False), ('hist', repo, True)):
            with self.subTest(case=name):
                live = os.path.join(self.tmp, 'legacy-' + name)
                legacy_fixtures.install_with('sh', repo, live)
                put(live, 'agents/sdlc-architect.md', b'x\n')          # outside the default scope
                put(live, 'commands/sdlc/dev.md', b'hand edit\n')
                code, out = self.uninstall(live, '--force', ref=ref)
                self.assertEqual(code, 0, out)
                self.assertEqual('no file_hashes' in out and 'Legacy install' in out, not kept)
                self.assertEqual(has(live, 'commands/sdlc/dev.md'), kept)
                self.assertFalse(has(live, 'commands/sdlc/brainstorm.md'))
                self.assertFalse(has(live, REGISTRY))

    # --- E4 cases of the design --------------------------------------------------------------

    def test_r3_04_nothing_left_after_install_then_uninstall(self):
        repo, ref, live = self.new_case('r304')
        self.assertEqual(self.install(ref, live)[0], 0)
        self.assertEqual(self.uninstall(live, '--force', ref=repo)[0], 0)
        self.assertFalse(os.path.lexists(os.path.join(live, 'skills', 'sdlc')))
        self.assertFalse(os.path.lexists(os.path.join(live, 'commands')))
        repo2, ref2, live2 = self.new_case('r304b')
        self.assertEqual(self.install(ref2, live2)[0], 0)
        put(live2, 'skills/sdlc/perso.md', b'mine\n')
        self.assertEqual(self.uninstall(live2, '--force', ref=repo2)[0], 0)
        self.assertEqual(os.listdir(os.path.join(live2, 'skills', 'sdlc')), ['perso.md'])

    def test_registry_file_hashes_without_history(self):
        """Archive install (no Git): the registry hashes alone prove ownership."""
        _repo, ref, live = self.new_case('archive', use_git=False)
        self.assertEqual(self.install(ref, live)[0], 0)
        put(live, 'skills/sdlc/notes.md', b'notes\n')
        code, out = self.uninstall(live, '--force')
        self.assertEqual(code, 0, out)
        self.assertFalse(has(live, 'skills/sdlc/SKILL.md'))
        self.assertTrue(has(live, 'skills/sdlc/notes.md'))
        self.assertNotIn('no file_hashes', out)                       # E4-R1-10

    def test_r3_07_invalid_json_registry(self):
        repo, _ref, live = self.installed('r307')
        put(live, REGISTRY, b'{ not json')
        before = snapshot(live)
        code, out = self.uninstall(live, '--force', ref=repo)
        self.assertEqual(code, 2, out)
        self.assertEqual(snapshot(live), before)
        code, out = self.uninstall(live, '--force', '--discover', ref=repo)
        self.assertEqual(code, 0, out)
        self.assertIn('heuristic', out)
        self.assertFalse(os.path.lexists(os.path.join(live, 'commands', 'sdlc')))
        self.assertFalse(has(live, REGISTRY))

    def test_e4_r1_01_live_inside_the_reference(self):
        repo, ref, _live = self.new_case('inref')
        before = snapshot(repo)
        for live in (ref, repo):
            code, out = self.uninstall(live, '--discover', '--force', ref=repo)
            self.assertEqual(code, 2, out)
        self.assertEqual(snapshot(repo), before)

    def test_e4_r1_03_plan_shown_is_the_plan_run_under_the_lock(self):
        repo, _ref, live = self.installed('underlock')
        seen = []

        def answer(_prompt):
            seen.append(os.path.exists(os.path.join(live, '.sync.lock')))
            return 'yes'
        with mock.patch('builtins.input', answer):
            code, out = self.uninstall(live, ref=repo)
        self.assertEqual(code, 0, out)
        self.assertEqual(seen, [True])

    @unittest.skipUnless(os.name == 'nt', 'case-insensitive volume')
    def test_e4_r1_04_case_variant_folder_refused_before_any_deletion(self):
        repo, _ref, live = self.installed('casevar')
        os.rename(os.path.join(live, 'commands', 'sdlc'), os.path.join(live, 'commands', 'SDLC'))
        before = snapshot(live)
        code, out = self.uninstall(live, '--force', ref=repo)
        self.assertEqual(code, 3, out)
        self.assertEqual(snapshot(live), before)

    def test_e4_r1_05_unreadable_history_falls_back_to_hashes(self):
        repo, _ref, live = self.installed('badgit')
        with mock.patch('sdlc_installer.ownership.history_blobs', side_effect=__import__(
                'sdlc_installer.errors', fromlist=['UsageError']).UsageError('git log failed')):
            code, out = self.uninstall(live, '--force', ref=repo)
        self.assertEqual(code, 0, out)
        self.assertIn('unreadable', out)
        self.assertFalse(has(live, 'skills/sdlc/SKILL.md'))

    def test_e4_r1_06_registry_path_is_a_directory(self):
        repo, _ref, live = self.installed('regdir')
        reg = os.path.join(live, *REGISTRY.split('/'))
        os.remove(reg)
        put(reg, 'inside.txt', b'keep\n')
        before = snapshot(live)
        self.assertEqual(self.uninstall(live, '--force', ref=repo)[0], 2)
        self.assertEqual(snapshot(live), before)
        code, out = self.uninstall(live, '--force', '--discover', ref=repo)
        self.assertEqual(code, 0, out)
        self.assertEqual(get(reg, 'inside.txt'), b'keep\n')
        self.assertFalse(has(live, 'commands/sdlc/dev.md'))

    def test_e4_r1_07_empty_folders_removed(self):
        live = os.path.join(self.tmp, 'emptydirs')
        os.makedirs(os.path.join(live, 'commands', 'sdlc'))
        os.makedirs(os.path.join(live, 'commands', 'other'))
        code, out = self.uninstall(live, '--discover', '--force')
        self.assertEqual(code, 0, out)
        self.assertFalse(os.path.lexists(os.path.join(live, 'commands', 'sdlc')))
        self.assertTrue(os.path.isdir(os.path.join(live, 'commands', 'other')))
        repo, _ref, live2 = self.installed('emptyskills')
        reg = json.loads(get(live2, REGISTRY).decode('utf-8'))
        reg['skills'] = []
        put(live2, REGISTRY, json.dumps(reg).encode('utf-8'))
        for name in os.listdir(os.path.join(live2, 'skills', 'sdlc')):
            if name != '.install-manifest.json':
                os.remove(os.path.join(live2, 'skills', 'sdlc', name))
        self.assertEqual(self.uninstall(live2, '--force', ref=repo)[0], 0)
        self.assertFalse(os.path.lexists(os.path.join(live2, 'skills', 'sdlc')))

    def test_e4_r2_01_readable_history_without_sdlc_blobs_proves_nothing(self):
        if not (legacy_fixtures.BASH and legacy_fixtures.commit_exists(legacy_fixtures.OLD_COMMIT)):
            self.skipTest('bash or commit 667d7ed missing')
        repo = legacy_fixtures.make_repo(self.tmp, legacy_fixtures.OLD_COMMIT)
        live = os.path.join(self.tmp, 'legacy-live')
        legacy_fixtures.install_with('sh', repo, live)
        put(live, 'commands/sdlc/notes.md', b'personal\n')
        other = os.path.join(self.tmp, 'other-repo')
        put(other, 'README.md', b'readme\n')
        from tests.test_install import git
        git(other, 'init', '-q')
        git(other, '-c', 'user.email=t@t', '-c', 'user.name=t', 'add', '-A')
        git(other, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '-m', 'readme')
        code, out = self.uninstall(live, '--force', ref=other)
        self.assertEqual(code, 0, out)
        self.assertEqual(get(live, 'commands/sdlc/notes.md'), b'personal\n')
        self.assertNotIn('Legacy install', out)

    def test_e4_r2_02_missing_reference_nested_in_live(self):
        _repo, _ref, live = self.installed('nestedref')
        before = snapshot(live)
        code, out = self.uninstall(live, '--force', ref=os.path.join(live, 'ref-absente'))
        self.assertEqual(code, 2, out)
        self.assertEqual(snapshot(live), before)

    def test_e4_r2_03_registry_directory_tree_preserved(self):
        repo, _ref, live = self.installed('regtree')
        reg = os.path.join(live, *REGISTRY.split('/'))
        os.remove(reg)
        os.makedirs(os.path.join(reg, 'empty-sub'))
        put(reg, 'perso.md', b'keep\n')
        code, out = self.uninstall(live, '--force', '--discover', ref=repo)
        self.assertEqual(code, 0, out)
        self.assertTrue(os.path.isdir(os.path.join(reg, 'empty-sub')))
        self.assertEqual(get(reg, 'perso.md'), b'keep\n')

    def test_e4_r2_04_link_under_agents_ignored_without_remove_core(self):
        repo, _ref, live = self.installed('agentlink')
        outside = os.path.join(self.tmp, 'third-party-agents')
        put(outside, 'a.md', b'a\n')
        if not make_junction(os.path.join(live, 'agents', 'perso'), outside):
            self.skipTest('cannot create a junction or symlink here')
        code, out = self.uninstall(live, '--force', ref=repo)
        self.assertEqual(code, 0, out)
        self.assertFalse(has(live, 'commands/sdlc/dev.md'))
        repo2, _r2, live2 = self.installed('agentlink2')
        make_junction(os.path.join(live2, 'agents', 'perso'), outside)
        self.assertEqual(self.uninstall(live2, '--force', '--remove-core', ref=repo2)[0], 3)
        self.assertEqual(snapshot(outside), {'a.md': b'a\n'})

    def test_e4_r2_05_registry_listed_before_confirmation(self):
        repo, _ref, live = self.installed('reglisted')
        reg = json.loads(get(live, REGISTRY).decode('utf-8'))
        reg['skills'] = []
        put(live, REGISTRY, json.dumps(reg).encode('utf-8'))
        with mock.patch('builtins.input', return_value='non'):
            code, out = self.uninstall(live, ref=repo)
        self.assertEqual(code, 0, out)
        self.assertIn('    - ' + REGISTRY, out)
        self.assertIn('Will be removed (3 file(s))', out)      # 2 commands + the registry

    def test_e4_r3_01_empty_ref_refused(self):
        _repo, _ref, live = self.installed('emptyref')
        before = snapshot(live)
        code, out = run_cli(['uninstall', '--live', live, '--ref', '', '--force'])
        self.assertEqual(code, 2, out)
        self.assertEqual(snapshot(live), before)

    def test_e4_r3_02_missing_reference_inside_the_live_worktree(self):
        repo, ref, _live = self.new_case('absentref')
        before = snapshot(repo)
        code, out = self.uninstall(ref, '--force', '--discover', ref=os.path.join(repo, 'installer', 'absent'))
        self.assertEqual(code, 2, out)
        self.assertEqual(snapshot(repo), before)

    def test_e4_r3_03_link_inside_the_registry_directory(self):
        repo, _ref, live = self.installed('reglink')
        reg = os.path.join(live, *REGISTRY.split('/'))
        os.remove(reg)
        os.makedirs(reg)
        outside = os.path.join(self.tmp, 'outside')
        put(outside, 'x.md', b'x\n')
        if not make_junction(os.path.join(reg, 'link'), outside):
            self.skipTest('cannot create a junction or symlink here')
        code, out = self.uninstall(live, '--force', '--discover', ref=repo)
        self.assertEqual(code, 0, out)
        self.assertFalse(has(live, 'commands/sdlc/dev.md'))
        self.assertTrue(os.path.lexists(os.path.join(reg, 'link')))
        self.assertEqual(snapshot(outside), {'x.md': b'x\n'})

    def test_e4_r3_04_excluded_subtree_not_opened(self):
        repo, _ref, live = self.installed('cache')
        put(live, 'skills/sdlc/.pytest_cache/v/data', b'cache\n')
        real_scandir = os.scandir

        def guarded(path='.'):
            if '.pytest_cache' in str(path):
                raise PermissionError(5, 'Access is denied', str(path))
            return real_scandir(path)
        with mock.patch('os.scandir', guarded):
            code, out = self.uninstall(live, '--force', ref=repo)
        self.assertEqual(code, 0, out)
        self.assertFalse(has(live, 'commands/sdlc/dev.md'))
        self.assertTrue(has(live, 'skills/sdlc/.pytest_cache/v/data'))

    def test_e4_r3_05_read_only_installed_file(self):
        import stat as _stat
        repo, _ref, live = self.installed('readonly')
        target = os.path.join(live, 'commands', 'sdlc', 'dev.md')
        os.chmod(target, _stat.S_IREAD)
        self.addCleanup(lambda: os.path.exists(target) and os.chmod(target, _stat.S_IREAD | _stat.S_IWRITE))
        code, out = self.uninstall(live, '--force', ref=repo)
        self.assertEqual(code, 0, out)
        self.assertFalse(os.path.lexists(target))
        self.assertFalse(has(live, REGISTRY))

    @unittest.skipIf(os.name == 'nt', 'directory symlinks followed by .. are a POSIX case')
    def test_e4_r4_01_reference_through_a_link_then_dotdot(self):
        repo, ref, _live = self.new_case('dotdot')
        os.makedirs(os.path.join(repo, 'installer'))
        link = os.path.join(self.tmp, 'lien')
        os.symlink(os.path.join(repo, 'installer'), link)
        before = snapshot(repo)
        code, out = self.uninstall(ref, '--force', '--discover', ref=os.path.join(link, '..', 'bundle'))
        self.assertEqual(code, 2, out)
        self.assertEqual(snapshot(repo), before)

    @unittest.skipUnless(os.name == 'nt', 'Windows read-only attribute')
    def test_e4_r4_02_read_only_file_with_another_hard_link(self):
        import stat as _stat
        repo, _ref, live = self.installed('hardlink')
        target = os.path.join(live, 'commands', 'sdlc', 'dev.md')
        other = os.path.join(self.tmp, 'personal-link.md')
        os.link(target, other)
        os.chmod(target, _stat.S_IREAD)
        self.addCleanup(lambda: os.path.exists(other) and os.chmod(other, _stat.S_IREAD | _stat.S_IWRITE))
        before = snapshot(live)
        code, out = self.uninstall(live, '--force', ref=repo)
        self.assertEqual(code, 3, out)
        self.assertEqual(snapshot(live), before)
        self.assertFalse(os.stat(other).st_mode & _stat.S_IWRITE)

    @unittest.skipUnless(os.name == 'nt', 'Windows read-only attribute')
    def test_final_r1_01_read_only_registry_with_another_hard_link(self):
        import stat as _stat
        repo, _ref, live = self.installed('reglink')
        target = os.path.join(live, *REGISTRY.split('/'))
        other = os.path.join(self.tmp, 'registry-link.json')
        os.link(target, other)
        os.chmod(target, _stat.S_IREAD)
        self.addCleanup(lambda: os.path.exists(other) and os.chmod(other, _stat.S_IREAD | _stat.S_IWRITE))
        before = snapshot(live)
        code, out = self.uninstall(live, '--force', ref=repo)
        self.assertEqual(code, 3, out)
        self.assertEqual(snapshot(live), before)
        self.assertFalse(os.stat(other).st_mode & _stat.S_IWRITE)

    def test_e4_r4_03_skip_never_opens_a_selected_root(self):
        from sdlc_installer import domain
        _repo, _ref, live = self.installed('skiproot')
        opened = []
        real = os.scandir

        def spy(path='.'):
            opened.append(os.path.normcase(os.path.abspath(str(path))))
            return real(path)
        with mock.patch('os.scandir', spy):
            rels = domain.domain_rels(live, tops=('commands',), skip='commands/sdlc')
            rels2 = domain.domain_rels(live, skills=('sdlc-verify',), tops=('skills',), skip='skills/sdlc-verify')
        self.assertEqual((rels, rels2), ([], []))
        for rel in ('commands/sdlc', 'skills/sdlc-verify'):
            self.assertNotIn(os.path.normcase(os.path.join(live, *rel.split('/'))), opened)

    def test_hand_written_registry_without_aggregate_is_corrupt(self):
        """Wanted difference (E2 decision): the hand-made registries of test-retrait (no checksum_sha256) are corrupt
        here, so 2 without --discover; the scripts accepted them."""
        _repo, _ref, live = self.new_case('handmade')
        put(live, 'skills/sdlc/SKILL.md', b'---\nname: sdlc\n---\n')
        put(live, REGISTRY, json.dumps({'version': '3.9', 'skills': ['sdlc']}).encode('utf-8'))
        before = snapshot(live)
        self.assertEqual(self.uninstall(live, '--force')[0], 2)
        self.assertEqual(snapshot(live), before)

    def test_unsafe_skill_name_in_registry(self):
        _repo, _ref, live = self.installed('badname')
        reg = json.loads(get(live, REGISTRY).decode('utf-8'))
        reg['skills'] = ['../x']
        put(live, REGISTRY, json.dumps(reg).encode('utf-8'))
        before = snapshot(live)
        self.assertEqual(self.uninstall(live, '--force')[0], 3)
        self.assertEqual(snapshot(live), before)

    def test_junction_in_the_domain_refused(self):
        repo, _ref, live = self.installed('junction')
        sentinel = os.path.join(self.tmp, 'sentinel')
        put(sentinel, 'dev.md', b'dev cmd\n')
        target = os.path.join(live, 'commands', 'sdlc')
        for name in os.listdir(target):
            os.remove(os.path.join(target, name))
        os.rmdir(target)
        if not make_junction(target, sentinel):
            self.skipTest('cannot create a junction or symlink here')
        code, out = self.uninstall(live, '--force', ref=repo)
        self.assertEqual(code, 3, out)
        self.assertEqual(snapshot(sentinel), {'dev.md': b'dev cmd\n'})
        self.assertTrue(has(live, 'skills/sdlc/SKILL.md'))

    def test_lock_held_and_missing_live(self):
        repo, _ref, live = self.installed('lock')
        put(live, '.sync.lock', b'pid=1\n')
        before = snapshot(live)
        self.assertEqual(self.uninstall(live, '--force', ref=repo)[0], 1)
        self.assertEqual(snapshot(live), before)
        self.assertEqual(self.uninstall(os.path.join(self.tmp, 'nowhere'), '--force')[0], 2)
        self.assertEqual(run_cli(['uninstall', '--live', '', '--force'])[0], 2)

    def test_nothing_to_remove(self):
        live = os.path.join(self.tmp, 'empty-live')
        os.makedirs(live)
        code, out = self.uninstall(live, '--discover', '--force')
        self.assertEqual(code, 0, out)
        self.assertIn('Nothing to remove', out)
        self.assertEqual(snapshot(live), {})


if __name__ == '__main__':
    unittest.main()
