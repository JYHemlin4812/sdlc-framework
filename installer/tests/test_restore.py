"""restore (design §8.4): Python port of test-restore.sh / test-restore.ps1 (C1 to C9, D1) plus the E5 cases
(fast-forward, divergence, HEAD bytes, deployment trace R3-06, sequence A -> B -> C, PYI-03).
Temporary roots only; ~/.claude is never touched (every call passes --live)."""
import json
import os
import shutil
import unittest

from sdlc_installer import manifests
from tests.test_capture import A, B, SyncCase, file_hash
from tests.test_install import SEED, get, git, has, put, run_cli, snapshot


def commit_all(repo, msg):
    git(repo, 'add', '-A')
    git(repo, 'commit', '-q', '-m', msg)


class RestoreCase(SyncCase):
    def restore(self, k, *flags):
        return run_cli(['restore', '--ref', k.repo, '--live', k.live, '--manifest-path', k.manifest] + list(flags))

    def _upstream_ahead(self, k):
        origin = os.path.join(self.tmp, os.path.basename(os.path.dirname(k.repo)), 'origin.git')
        git(k.repo, 'init', '--bare', '-q', origin)
        git(k.repo, 'remote', 'add', 'origin', origin)
        git(k.repo, 'push', '-q', '-u', 'origin', 'HEAD')
        head = git(k.repo, 'rev-parse', 'HEAD')
        put(k.ref, 'agents/sdlc-gamma.md', b'gamma\n')
        commit_all(k.repo, 'ref: add gamma (upstream ahead)')
        git(k.repo, 'push', '-q', 'origin', 'HEAD')
        git(k.repo, 'reset', '--hard', '-q', head)
        return head

    def backed_up(self, k, rel):
        root = os.path.join(k.live, '_backups')
        found = []
        if os.path.isdir(root):
            for d in os.listdir(root):
                if d.startswith('restore-') and has(os.path.join(root, d), rel):
                    found.append(get(os.path.join(root, d), rel))
        return found


class Parity(RestoreCase):
    """Scenarios of test-restore.sh / .ps1, same names (C0 is about the script text: no equivalent)."""

    def test_c1_c7_nominal_restore(self):
        k = self.sync_case('c1', seed=True)
        put(k.ref, B, b'beta-v2\n')
        put(k.ref, 'agents/sdlc-gamma.md', b'gamma-new\n')
        commit_all(k.repo, 'ref: modify beta + add gamma')
        code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        self.assertEqual(get(k.live, B), b'beta-v2\n')
        self.assertEqual(get(k.live, 'agents/sdlc-gamma.md'), b'gamma-new\n')
        self.assertEqual(get(k.live, A), b'alpha-v1\n')
        self.assertEqual(self.backed_up(k, B), [b'beta-v1\n'])
        leftovers = [f for _d, _s, fs in os.walk(k.live) for f in fs if f.startswith('.sdlc-tmp-')]
        self.assertEqual(leftovers, [])                                     # C7
        self.assertFalse(os.path.exists(os.path.join(k.live, '.sync.lock')))

    def test_c2_base_aware_deletion(self):
        k = self.sync_case('c2', seed=True)
        os.remove(os.path.join(k.ref, *A.split('/')))
        commit_all(k.repo, 'ref: delete alpha')
        code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        self.assertFalse(has(k.live, A))
        self.assertEqual(self.backed_up(k, A), [b'alpha-v1\n'])

    def test_c3_modified_live_blocked_then_forced(self):
        k = self.sync_case('c3', seed=True)
        put(k.live, B, b'beta-LOCAL\n')
        code, out = self.restore(k)
        self.assertEqual(code, 3, out)
        self.assertIn('modified-live-only', out)
        self.assertEqual(get(k.live, B), b'beta-LOCAL\n')
        self.assertFalse(os.path.exists(os.path.join(k.live, '_backups')))
        code, out = self.restore(k, '--force-restore')
        self.assertEqual(code, 0, out)
        self.assertEqual(get(k.live, B), b'beta-v1\n')
        self.assertEqual(self.backed_up(k, B), [b'beta-LOCAL\n'])

    def test_c4_modified_both_blocked_even_forced(self):
        k = self.sync_case('c4', seed=True)
        put(k.ref, B, b'beta-REF\n')
        commit_all(k.repo, 'ref: modify beta')
        put(k.live, B, b'beta-LIVE\n')
        code, out = self.restore(k, '--force-restore')
        self.assertEqual(code, 3, out)
        self.assertIn('modified-both', out)
        self.assertEqual(get(k.live, B), b'beta-LIVE\n')

    def test_c5_added_live_protected(self):
        k = self.sync_case('c5', seed=True)
        put(k.live, 'agents/sdlc-extra.md', b'live-only\n')
        code, out = self.restore(k)
        self.assertEqual(code, 7, out)                          # EXTRA reported by the post-check, as the scripts
        self.assertIn('EXTRA', out)
        self.assertEqual(get(k.live, 'agents/sdlc-extra.md'), b'live-only\n')

    def test_c6_dry_run_writes_nothing(self):
        k = self.sync_case('c6', seed=True)
        put(k.ref, B, b'beta-v2\n')
        commit_all(k.repo, 'ref: modify beta')
        before = snapshot(k.live)
        code, out = self.restore(k, '--dry-run')
        self.assertEqual(code, 0, out)
        self.assertIn('dry-run', out)
        self.assertIn('~ ' + B, out)
        self.assertEqual(snapshot(k.live), before)

    def test_c8_canonical_guard(self):
        k = self.sync_case('c8', seed=True)
        put(k.ref, B, b'beta-UNCOMMITTED\n')
        before = snapshot(k.live)
        for flags in ((), ('--dry-run',)):
            code, out = self.restore(k, *flags)
            self.assertEqual(code, 5, out)
            self.assertIn('not clean', out)
        self.assertEqual(snapshot(k.live), before)

    def test_c9_dry_run_does_not_advance(self):
        k = self.sync_case('c9', seed=True)
        head = self._upstream_ahead(k)
        code, out = self.restore(k, '--dry-run')
        self.assertEqual(code, 0, out)
        self.assertEqual(git(k.repo, 'rev-parse', 'HEAD'), head)

    def test_d1_corrupt_base_fails_closed(self):
        k = self.sync_case('d1')
        put(k.state, '.sync-manifest.json', b'{ this is : not json')
        put(k.ref, B, b'beta-v2\n')
        commit_all(k.repo, 'ref: modify beta')
        code, out = self.restore(k)
        self.assertEqual(code, 6, out)
        self.assertIn('FAIL CLOSED', out)
        self.assertEqual(get(k.live, B), b'beta-v1\n')
        self.assertFalse(os.path.exists(os.path.join(k.live, '_backups')))


class Contract(RestoreCase):
    """E5 cases."""

    def test_fast_forward_then_deploy(self):
        k = self.sync_case('ff', seed=True)
        head = self._upstream_ahead(k)
        code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        self.assertNotEqual(git(k.repo, 'rev-parse', 'HEAD'), head)
        self.assertEqual(get(k.live, 'agents/sdlc-gamma.md'), b'gamma\n')

    def test_diverged_gives_4(self):
        k = self.sync_case('div', seed=True)
        self._upstream_ahead(k)
        put(k.ref, 'agents/sdlc-local.md', b'local\n')
        commit_all(k.repo, 'local commit, not on upstream')
        before = snapshot(k.live)
        code, out = self.restore(k)
        self.assertEqual(code, 4, out)
        self.assertEqual(snapshot(k.live), before)

    def test_head_bytes_not_working_tree(self):
        # An ignored file in claude/ never reaches the live root: restore reads HEAD, never the working tree.
        k = self.sync_case('head', seed=True)
        put(k.repo, '.gitignore', b'claude/agents/sdlc-ignored.md\n')
        commit_all(k.repo, 'ignore rule')
        put(k.ref, 'agents/sdlc-ignored.md', b'not committed\n')
        code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        self.assertFalse(has(k.live, 'agents/sdlc-ignored.md'))

    def test_absent_base_is_empty(self):
        k = self.sync_case('nobase')
        put(k.ref, 'agents/sdlc-gamma.md', b'gamma\n')
        commit_all(k.repo, 'add gamma')
        code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        self.assertEqual(get(k.live, 'agents/sdlc-gamma.md'), b'gamma\n')
        self.assertFalse(os.path.exists(k.manifest))                # restore never writes the base

    def test_allow_dirty_refused(self):
        k = self.sync_case('ad', seed=True)
        self.assertEqual(self.restore(k, '--allow-dirty')[0], 2)

    def test_no_git_reference_gives_2(self):
        k = self.sync_case('nogit', seed=True)
        plain = os.path.join(self.tmp, 'plain')
        shutil.copytree(k.ref, os.path.join(plain, 'claude'))
        code, out = run_cli(['restore', '--ref', plain, '--live', k.live, '--manifest-path', k.manifest])
        self.assertEqual(code, 2, out)

    def test_refusal_before_any_write_dry_run_included(self):
        # §5.2 point 4: a directory where a canonical file goes refuses (3), dry-run included; nothing written.
        k = self.sync_case('refuse', seed=True)
        put(k.ref, B, b'beta-v2\n')
        put(k.ref, 'agents/sdlc-gamma.md', b'gamma\n')
        commit_all(k.repo, 'beta v2 + gamma')
        put(k.live, 'agents/sdlc-gamma.md/keep.txt', b'a folder\n')
        before = snapshot(k.live)
        for flags in (('--dry-run',), ()):
            code, out = self.restore(k, *flags)
            self.assertEqual(code, 3, out)
            self.assertEqual(snapshot(k.live), before)

    def test_e5_r1_01_block_leaves_the_reference_untouched(self):
        k = self.sync_case('ffblock', seed=True)
        origin = os.path.join(self.tmp, 'ffblock', 'origin.git')
        git(k.repo, 'init', '--bare', '-q', origin)
        git(k.repo, 'remote', 'add', 'origin', origin)
        git(k.repo, 'push', '-q', '-u', 'origin', 'HEAD')
        head = git(k.repo, 'rev-parse', 'HEAD')
        put(k.ref, B, b'beta-UPSTREAM\n')
        commit_all(k.repo, 'upstream changes beta')
        git(k.repo, 'push', '-q', 'origin', 'HEAD')
        git(k.repo, 'reset', '--hard', '-q', head)
        put(k.live, B, b'beta-LIVE\n')                              # modified-both against the upstream
        for flags in (('--dry-run',), ()):
            code, out = self.restore(k, *flags)
            self.assertEqual(code, 3, out)
            self.assertEqual(git(k.repo, 'rev-parse', 'HEAD'), head)
            self.assertEqual(get(k.ref, B), b'beta-v1\n')
            self.assertEqual(git(k.repo, 'status', '--porcelain'), '')
            self.assertEqual(get(k.live, B), b'beta-LIVE\n')

    def test_e5_r1_05_case_superseded_trace_key(self):
        k = self.sync_case('casekey', files=SEED)
        for rel in SEED:
            os.remove(os.path.join(k.live, *rel.split('/')))
        self.assertEqual(self.install(k.ref, k.live)[0], 0)
        doc = self.registry(k.live)
        doc['file_hashes']['commands/sdlc/Old.md'] = 'a' * 64          # recorded once, gone from live since
        put(k.live, manifests.INSTALL_REGISTRY_REL, json.dumps(doc).encode('utf-8'))
        put(k.ref, 'commands/sdlc/old.md', b'old, lower case\n')
        commit_all(k.repo, 'ship old.md')
        code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        hashes = self.registry(k.live)['file_hashes']
        self.assertIn('commands/sdlc/old.md', hashes)
        self.assertNotIn('commands/sdlc/Old.md', hashes)

    def test_e5_r1_07_unsafe_registry_refused_in_dry_run_too(self):
        k = self.sync_case('badreg', files=SEED)
        for rel in SEED:
            os.remove(os.path.join(k.live, *rel.split('/')))
        self.assertEqual(self.install(k.ref, k.live)[0], 0)
        doc = self.registry(k.live)
        doc['file_hashes']['../x'] = 'a' * 64
        put(k.live, manifests.INSTALL_REGISTRY_REL, json.dumps(doc).encode('utf-8'))
        put(k.ref, 'agents/sdlc-new.md', b'new\n')
        commit_all(k.repo, 'add agent')
        before = snapshot(k.live)
        for flags in (('--dry-run',), ()):
            code, out = self.restore(k, *flags)
            self.assertEqual(code, 3, out)
            self.assertEqual(snapshot(k.live), before)

    def test_e5_r2_01_ignored_file_in_the_way_of_the_fast_forward(self):
        k = self.sync_case('ignff', seed=True)
        put(k.repo, '.gitignore', b'notes.txt\n')
        commit_all(k.repo, 'ignore notes')
        origin = os.path.join(self.tmp, 'ignff', 'origin.git')
        git(k.repo, 'init', '--bare', '-q', origin)
        git(k.repo, 'remote', 'add', 'origin', origin)
        git(k.repo, 'push', '-q', '-u', 'origin', 'HEAD')
        head = git(k.repo, 'rev-parse', 'HEAD')
        put(k.repo, 'notes.txt', b'upstream notes\n')
        git(k.repo, 'add', '-f', 'notes.txt')
        commit_all(k.repo, 'upstream tracks notes.txt')
        git(k.repo, 'push', '-q', 'origin', 'HEAD')
        git(k.repo, 'reset', '--hard', '-q', head)
        put(k.repo, 'notes.txt', b'my local notes\n')                # ignored, local
        for flags in (('--dry-run',), ()):
            code, out = self.restore(k, *flags)
            self.assertEqual(code, 5, out)
            self.assertIn('notes.txt', out)
        self.assertEqual(get(k.repo, 'notes.txt'), b'my local notes\n')
        self.assertEqual(git(k.repo, 'rev-parse', 'HEAD'), head)

    def _upstream_adds(self, k, name, ignore, rel, data):
        """Upstream one commit ahead that force-adds <rel> (ignored by <ignore>); local reset to the old HEAD."""
        put(k.repo, '.gitignore', ignore)
        commit_all(k.repo, 'ignore rule')
        origin = os.path.join(self.tmp, name, 'origin.git')
        git(k.repo, 'init', '--bare', '-q', origin)
        git(k.repo, 'remote', 'add', 'origin', origin)
        git(k.repo, 'push', '-q', '-u', 'origin', 'HEAD')
        head = git(k.repo, 'rev-parse', 'HEAD')
        put(k.repo, rel, data)
        git(k.repo, 'add', '-f', rel)
        commit_all(k.repo, 'upstream adds ' + rel)
        git(k.repo, 'push', '-q', 'origin', 'HEAD')
        git(k.repo, 'reset', '--hard', '-q', head)
        return head

    def test_e5_r3_01_ignored_file_where_a_folder_goes(self):
        k = self.sync_case('ffdir', seed=True)
        head = self._upstream_adds(k, 'ffdir', b'cache\n', 'cache/item.txt', b'upstream\n')
        put(k.repo, 'cache', b'my local cache file\n')
        for flags in (('--dry-run',), ()):
            code, out = self.restore(k, *flags)
            self.assertEqual(code, 5, out)
        self.assertEqual(get(k.repo, 'cache'), b'my local cache file\n')
        self.assertEqual(git(k.repo, 'rev-parse', 'HEAD'), head)

    def test_e5_r3_02_ignored_folder_that_can_coexist(self):
        k = self.sync_case('ffok', seed=True)
        head = self._upstream_adds(k, 'ffok', b'/cache/\n', 'cache/upstream.txt', b'upstream\n')
        put(k.repo, 'cache/local.txt', b'local\n')
        for flags in (('--dry-run',), ()):
            code, out = self.restore(k, *flags)
            self.assertEqual(code, 0, out)
        self.assertNotEqual(git(k.repo, 'rev-parse', 'HEAD'), head)
        self.assertEqual(get(k.repo, 'cache/local.txt'), b'local\n')
        self.assertEqual(get(k.repo, 'cache/upstream.txt'), b'upstream\n')

    def test_ff_refused_over_a_local_change_outside_claude(self):
        k = self.sync_case('fflocal', seed=True)
        put(k.repo, 'README.md', b'v1\n')
        commit_all(k.repo, 'readme')
        origin = os.path.join(self.tmp, 'fflocal', 'origin.git')
        git(k.repo, 'init', '--bare', '-q', origin)
        git(k.repo, 'remote', 'add', 'origin', origin)
        git(k.repo, 'push', '-q', '-u', 'origin', 'HEAD')
        head = git(k.repo, 'rev-parse', 'HEAD')
        put(k.repo, 'README.md', b'upstream edit\n')
        commit_all(k.repo, 'upstream readme')
        git(k.repo, 'push', '-q', 'origin', 'HEAD')
        git(k.repo, 'reset', '--hard', '-q', head)
        put(k.repo, 'README.md', b'local edit\n')                    # tracked, changed locally, outside claude/
        for flags in (('--dry-run',), ()):
            code, out = self.restore(k, *flags)
            self.assertEqual(code, 5, out)
            self.assertIn('README.md', out)
        self.assertEqual(get(k.repo, 'README.md'), b'local edit\n')
        self.assertEqual(git(k.repo, 'rev-parse', 'HEAD'), head)

    def test_e5_r2_02_local_commits_ahead_of_upstream(self):
        k = self.sync_case('ahead', seed=True)
        origin = os.path.join(self.tmp, 'ahead', 'origin.git')
        git(k.repo, 'init', '--bare', '-q', origin)
        git(k.repo, 'remote', 'add', 'origin', origin)
        git(k.repo, 'push', '-q', '-u', 'origin', 'HEAD')
        put(k.ref, B, b'beta-local\n')
        commit_all(k.repo, 'local commit, not pushed')
        head = git(k.repo, 'rev-parse', 'HEAD')
        for flags in (('--dry-run',), ()):
            code, out = self.restore(k, *flags)
            self.assertEqual(code, 0, out)
        self.assertEqual(git(k.repo, 'rev-parse', 'HEAD'), head)
        self.assertEqual(get(k.live, B), b'beta-local\n')

    def test_e5_r2_07_retained_key_under_a_folder_spelled_apart(self):
        k = self.sync_case('retcase', files=SEED)
        for rel in SEED:
            os.remove(os.path.join(k.live, *rel.split('/')))
        self.assertEqual(self.install(k.ref, k.live)[0], 0)
        doc = self.registry(k.live)
        doc['retained_hashes'] = {'commands/sdlc/Old/a.md': 'a' * 64}   # folder gone from live since
        put(k.live, manifests.INSTALL_REGISTRY_REL, json.dumps(doc).encode('utf-8'))
        put(k.ref, 'commands/sdlc/old/b.md', b'b\n')
        commit_all(k.repo, 'ship old/b.md')
        code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        reg = manifests.read_install_registry(k.live)                    # still readable
        self.assertIn('commands/sdlc/old/b.md', reg.file_hashes)
        self.assertEqual(reg.retained, {})

    def test_pyi_04_live_inside_worktree(self):
        k = self.sync_case('pyi04', seed=True)
        live = os.path.join(k.repo, 'live')
        os.makedirs(live)
        code, out = run_cli(['restore', '--ref', k.repo, '--live', live, '--manifest-path', k.manifest])
        self.assertEqual(code, 2, out)
        self.assertEqual(os.listdir(live), [])


class Sequence(RestoreCase):
    """§3 and §4: the deployment trace of restore makes B provable without Git history (R3-06, PYI-03)."""

    def installed(self, name):
        k = self.sync_case(name, files=SEED)
        for rel in SEED:                                    # live starts empty: install A
            os.remove(os.path.join(k.live, *rel.split('/')))
        code, out = self.install(k.ref, k.live)
        self.assertEqual(code, 0, out)
        code, out = self.capture(k)                         # first run: seeds the base (ref == live)
        self.assertEqual(code, 0, out)
        self.assertIn('first-run seed', out)
        return k

    def restore_b(self, k):
        put(k.ref, 'agents/sdlc-b.md', b'added by B\n')
        put(k.ref, 'commands/sdlc/dev.md', b'dev cmd B\n')
        commit_all(k.repo, 'version B')
        code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        self.assertIn('deployment trace', out)
        hashes = self.registry(k.live)['file_hashes']
        self.assertEqual(hashes['agents/sdlc-b.md'], file_hash(k.live, 'agents/sdlc-b.md'))
        self.assertEqual(hashes['commands/sdlc/dev.md'], file_hash(k.live, 'commands/sdlc/dev.md'))
        self.assertIn('restored_at', self.registry(k.live))

    def test_r3_06_uninstall_after_restore_without_history(self):
        k = self.installed('r306')
        self.restore_b(k)
        put(k.live, 'commands/sdlc/brainstorm.md', b'edited by hand after B\n')
        code, out = run_cli(['uninstall', '--live', k.live, '--ref', os.path.join(self.tmp, 'no-repo'),
                             '--force', '--remove-core'])
        self.assertEqual(code, 0, out)
        self.assertFalse(has(k.live, 'agents/sdlc-b.md'))              # B proven by the trace alone
        self.assertFalse(has(k.live, 'commands/sdlc/dev.md'))
        self.assertEqual(get(k.live, 'commands/sdlc/brainstorm.md'), b'edited by hand after B\n')

    def test_r3_06_literal_install_c_without_the_b_file(self):
        """Design §13 R3-06 as written: install A -> restore B -> install C from an archive WITHOUT B's file ->
        uninstall without history: B's untouched file removed, B's hand-edited file kept. Install C keeps the
        trace of the untouched file in retained_hashes (decision JYH 2026-11-25, option 1.4.1)."""
        k = self.installed('r306c')
        put(k.ref, 'agents/sdlc-b.md', b'added by B\n')
        put(k.ref, 'agents/sdlc-b2.md', b'also added by B\n')
        commit_all(k.repo, 'version B')
        code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        put(k.live, 'agents/sdlc-b2.md', b'edited by hand after B\n')
        archive = os.path.join(self.tmp, 'archive-c', 'claude')
        shutil.copytree(k.ref, archive)
        os.remove(os.path.join(archive, 'agents', 'sdlc-b.md'))
        os.remove(os.path.join(archive, 'agents', 'sdlc-b2.md'))
        code, out = self.install(archive, k.live)
        self.assertEqual(code, 0, out)
        reg = self.registry(k.live)
        self.assertEqual(reg['retained_hashes'], {'agents/sdlc-b.md': file_hash(k.live, 'agents/sdlc-b.md')})
        self.assertNotIn('agents/sdlc-b.md', reg['file_hashes'])
        code, out = run_cli(['uninstall', '--live', k.live, '--ref', os.path.join(self.tmp, 'no-repo'),
                             '--force', '--remove-core'])
        self.assertEqual(code, 0, out)
        self.assertEqual(get(k.live, 'agents/sdlc-b2.md'), b'edited by hand after B\n')
        self.assertFalse(has(k.live, 'agents/sdlc-b.md'))

    def test_pyi_03_install_a_restore_b_install_c_from_archive(self):
        k = self.installed('pyi03')
        self.restore_b(k)
        put(k.live, 'skills/sdlc-verify/SKILL.md', b'---\nname: sdlc-verify\n---\nedited by hand\n')
        archive = os.path.join(self.tmp, 'archive-c', 'claude')
        shutil.copytree(k.ref, archive)
        with open(os.path.join(archive, 'commands', 'sdlc', 'dev.md'), 'wb') as fh:
            fh.write(b'dev cmd C\n')
        code, out = self.install(archive, k.live)
        self.assertEqual(code, 0, out)
        self.assertNotIn('origin unknown (not a bundle version): commands/sdlc/dev.md', out)   # B recognised
        self.assertIn('origin unknown (not a bundle version): skills/sdlc-verify/SKILL.md', out)
        self.assertEqual(get(k.live, 'commands/sdlc/dev.md'), b'dev cmd C\n')
        backups = os.path.join(k.live, '_backups')
        saved = [get(os.path.join(backups, d), 'skills/sdlc-verify/SKILL.md') for d in os.listdir(backups)
                 if has(os.path.join(backups, d), 'skills/sdlc-verify/SKILL.md')]
        self.assertIn(b'---\nname: sdlc-verify\n---\nedited by hand\n', saved)

    def test_no_registry_no_trace(self):
        k = self.sync_case('notrace', seed=True)
        put(k.ref, B, b'beta-v2\n')
        commit_all(k.repo, 'beta v2')
        code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        self.assertNotIn('deployment trace', out)
        self.assertFalse(has(k.live, manifests.INSTALL_REGISTRY_REL))


if __name__ == '__main__':
    unittest.main()
