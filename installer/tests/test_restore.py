"""restore (design §8.4): Python port of test-restore.sh / test-restore.ps1 (C1 to C9, D1) plus the E5 cases
(fast-forward, divergence, HEAD bytes, deployment trace R3-06, sequence A -> B -> C, PYI-03).
Temporary roots only; ~/.claude is never touched (every call passes --live)."""
import json
import os
import shutil
import stat
import subprocess
import unittest
from unittest import mock

from sdlc_installer import manifests
from sdlc_installer import restore as restore_mod
from tests.test_capture import A, B, COMMON, SyncCase, file_hash
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

    def test_g1_restore_writes_through_safe_replace(self):
        k = self.sync_case('g1', seed=True)
        put(k.ref, B, b'beta-v2\n')
        commit_all(k.repo, 'ref: modify beta')
        with mock.patch.object(restore_mod, 'safe_replace', wraps=restore_mod.safe_replace) as spy:
            code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        self.assertGreaterEqual(spy.call_count, 1)
        self.assertEqual(get(k.live, B), b'beta-v2\n')

    def test_n1_files_outside_the_domain_survive_a_restore_byte_for_byte(self):
        k = self.sync_case('n1', seed=True)
        outside = {'settings.local.json': b'{"secret": 1}\r\n', 'skills/other-tool/SKILL.md': b'third party\x00\xff\n'}
        for rel, data in outside.items():
            put(k.live, rel, data)
        put(k.ref, B, b'beta-v2\n')
        commit_all(k.repo, 'ref: modify beta')
        code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        self.assertEqual(get(k.live, B), b'beta-v2\n')                       # the restore did run
        for rel, data in outside.items():
            self.assertEqual(get(k.live, rel), data, rel)

    def test_s8_crlf_script_survives_capture_then_restore_byte_for_byte(self):
        hook_rel = 'skills/sdlc/scripts/hook.ps1'
        crlf = b'hook-v1\r\nline2\r\n'
        # Like sync-bdd.tests.ps1: the .ps1 exists (LF content) in reference, live and base before the base is
        # seeded, then only the live copy is rewritten with CRLF (a modification, not an addition).
        k = self.sync_case('s8', files=dict(COMMON, **{hook_rel: b'base\n'}), seed=True)
        self.assertEqual(get(k.ref, hook_rel), b'base\n')
        self.assertEqual(get(k.live, hook_rel), b'base\n')
        self.assertIn(hook_rel, self.base(k).entries)
        put(k.live, hook_rel, crlf)
        code, out = self.capture(k)
        self.assertEqual(code, 0, out)
        self.assertEqual(get(k.ref, hook_rel), crlf)                          # reference bytes keep the CRLF
        leftovers = [f for _d, _s, fs in os.walk(k.ref) for f in fs if f.startswith('.sdlc-tmp-')]
        self.assertEqual(leftovers, [])                                       # S8/N4: no temporary on the ref side
        blob = subprocess.run(['git', '-C', k.repo, 'cat-file', 'blob', 'HEAD:claude/' + hook_rel],
                              check=True, stdout=subprocess.PIPE).stdout
        self.assertEqual(blob, crlf)                                          # so does the committed blob
        origin = file_hash(k.live, hook_rel)
        os.remove(os.path.join(k.live, *hook_rel.split('/')))
        code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        self.assertEqual(get(k.live, hook_rel), crlf)
        self.assertEqual(file_hash(k.live, hook_rel), origin)

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
        live_only = 'agents/sdlc-live-only.md'
        put(k.live, live_only, b'live-only\n')                      # domain file present in live only
        put(k.ref, 'agents/sdlc-gamma.md', b'gamma\n')
        commit_all(k.repo, 'add gamma')
        code, out = self.restore(k)
        # A live file is never read as an implicit base: it keeps its bytes and the post-check reports it EXTRA (7).
        self.assertEqual(code, 7, out)
        self.assertIn('EXTRA', out)
        self.assertEqual(get(k.live, live_only), b'live-only\n')
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

    def test_final_r1_02_skill_omitted_by_c_is_uninstalled(self):
        """install A -> restore B adds a whole skill -> install C (archive) omits it -> uninstall without history:
        the untouched file proven by retained_hashes is removed, the hand-edited one is kept."""
        k = self.installed('fr102')
        put(k.ref, 'skills/sdlc-b/SKILL.md', b'---\nname: sdlc-b\n---\nskill B\n')
        put(k.ref, 'skills/sdlc-b/guide.md', b'guide B\n')
        commit_all(k.repo, 'version B')
        code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        put(k.live, 'skills/sdlc-b/guide.md', b'edited by hand after B\n')
        archive = os.path.join(self.tmp, 'archive-c', 'claude')
        shutil.copytree(k.ref, archive)
        shutil.rmtree(os.path.join(archive, 'skills', 'sdlc-b'))
        code, out = self.install(archive, k.live)
        self.assertEqual(code, 0, out)
        reg = self.registry(k.live)
        self.assertNotIn('sdlc-b', reg['skills'])
        self.assertIn('skills/sdlc-b/SKILL.md', reg['retained_hashes'])
        code, out = run_cli(['uninstall', '--live', k.live, '--ref', os.path.join(self.tmp, 'no-repo'), '--force'])
        self.assertEqual(code, 0, out)
        self.assertFalse(has(k.live, 'skills/sdlc-b/SKILL.md'))
        self.assertEqual(get(k.live, 'skills/sdlc-b/guide.md'), b'edited by hand after B\n')

    def test_final_r1_03_rerun_after_post_check_failure_records_the_trace(self):
        """restore B deploys, then fails its post-check (7) on a live EXTRA; once the extra is moved, the rerun
        finds nothing to deploy but must still record the trace, so uninstall without history removes B's file."""
        k = self.installed('fr103')
        put(k.ref, 'commands/sdlc/new.md', b'new command of B\n')
        commit_all(k.repo, 'version B')
        put(k.live, 'agents/sdlc-extra.md', b'live only\n')
        code, out = self.restore(k)
        self.assertEqual(code, 7, out)
        self.assertEqual(get(k.live, 'commands/sdlc/new.md'), b'new command of B\n')
        # FINAL-R2-01: the trace is written as soon as the files are, whatever the post-check says, and holds
        # only what restore wrote.
        traced = self.registry(k.live)['file_hashes']
        self.assertEqual(traced.get('commands/sdlc/new.md'), file_hash(k.live, 'commands/sdlc/new.md'))
        self.assertNotIn('agents/sdlc-extra.md', traced)
        os.remove(os.path.join(k.live, 'agents', 'sdlc-extra.md'))
        registry = get(k.live, manifests.INSTALL_REGISTRY_REL)
        code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        self.assertEqual(get(k.live, manifests.INSTALL_REGISTRY_REL), registry)       # nothing to deploy: untouched
        code, out = run_cli(['uninstall', '--live', k.live, '--ref', os.path.join(self.tmp, 'no-repo'), '--force'])
        self.assertEqual(code, 0, out)
        self.assertFalse(has(k.live, 'commands/sdlc/new.md'))

    def test_final_r2_01_captured_personal_file_is_never_traced_by_a_plain_restore(self):
        """install A, base seeded, a personal file added live then captured (HEAD == live == base), restore with
        nothing to deploy: the registry is byte for byte the same, install A is still 'up to date', and uninstall
        without history keeps the personal file."""
        k = self.installed('fr201')
        archive = os.path.join(self.tmp, 'archive-a', 'claude')
        shutil.copytree(k.ref, archive)
        put(k.live, 'commands/sdlc/perso.md', b'personal\n')
        code, out = self.capture(k)
        self.assertEqual(code, 0, out)
        self.assertEqual(get(k.ref, 'commands/sdlc/perso.md'), b'personal\n')
        registry = get(k.live, manifests.INSTALL_REGISTRY_REL)
        code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        self.assertEqual(get(k.live, manifests.INSTALL_REGISTRY_REL), registry)
        code, out = self.install(archive, k.live)
        self.assertEqual(code, 0, out)
        self.assertIn('Already up to date', out)
        code, out = run_cli(['uninstall', '--live', k.live, '--ref', os.path.join(self.tmp, 'no-repo'),
                             '--force', '--remove-core'])
        self.assertEqual(code, 0, out)
        self.assertEqual(get(k.live, 'commands/sdlc/perso.md'), b'personal\n')

    def test_final_r2_02_dangerous_registry_ignored_when_nothing_is_deployed(self):
        """HEAD, live and base identical: the registry serves no operation, so a dangerous skill name in it is no
        reason to refuse, in either mode. With a file to deploy it is still refused (3, e5_r1_07)."""
        k = self.installed('fr202')
        doc = self.registry(k.live)
        doc['skills'] = ['../x']
        put(k.live, manifests.INSTALL_REGISTRY_REL, json.dumps(doc).encode('utf-8'))
        before = snapshot(k.live)
        for flags in (('--dry-run',), ()):
            code, out = self.restore(k, *flags)
            self.assertEqual(code, 0, out)
            self.assertEqual(snapshot(k.live), before)

    def test_final_r3_01_failed_write_in_a_new_skill_does_not_publish_that_skill(self):
        """A write succeeds, then the first file of a new skill fails (its folder already holds an empty personal
        sub-folder): the trace holds the written file only, the registry does not declare the skill, and uninstall
        without history keeps the personal sub-folder."""
        k = self.installed('fr301')
        put(k.ref, 'commands/sdlc/a.md', b'command a\n')
        put(k.ref, 'skills/sdlc-b/SKILL.md', b'---\nname: sdlc-b\n---\nskill B\n')
        commit_all(k.repo, 'version B')
        personal = os.path.join(k.live, 'skills', 'sdlc-b', 'perso')
        os.makedirs(personal)
        real = restore_mod.safe_replace

        def failing(dst, src, *args, **kw):
            if 'sdlc-b' in dst.replace(os.sep, '/'):
                raise OSError('injected failure')
            return real(dst, src, *args, **kw)

        with mock.patch.object(restore_mod, 'safe_replace', failing):
            code, out = self.restore(k)
        self.assertNotEqual(code, 0, out)
        self.assertEqual(get(k.live, 'commands/sdlc/a.md'), b'command a\n')
        reg = self.registry(k.live)
        self.assertEqual(reg['file_hashes'].get('commands/sdlc/a.md'), file_hash(k.live, 'commands/sdlc/a.md'))
        self.assertNotIn('skills/sdlc-b/SKILL.md', reg['file_hashes'])
        self.assertNotIn('sdlc-b', reg['skills'])
        code, out = run_cli(['uninstall', '--live', k.live, '--ref', os.path.join(self.tmp, 'no-repo'),
                             '--force', '--remove-core'])
        self.assertEqual(code, 0, out)
        self.assertFalse(has(k.live, 'commands/sdlc/a.md'))
        self.assertTrue(os.path.isdir(personal))

    def test_no_registry_no_trace(self):
        k = self.sync_case('notrace', seed=True)
        put(k.ref, B, b'beta-v2\n')
        commit_all(k.repo, 'beta v2')
        code, out = self.restore(k)
        self.assertEqual(code, 0, out)
        self.assertNotIn('deployment trace', out)
        self.assertFalse(has(k.live, manifests.INSTALL_REGISTRY_REL))



class FinalReview(RestoreCase):
    @unittest.skipUnless(os.name == 'nt', 'Windows read-only attribute')
    def test_final_r2_04_hard_link_refusal_comes_before_dry_run_and_fast_forward(self):
        """The refusal (3) covers a deletion carried by an upstream commit too: dry-run and real run alike leave HEAD,
        the live tree, the backups and the other link's attribute untouched."""
        k = self.sync_case('fr204', seed=True)
        origin = os.path.join(self.tmp, 'fr204', 'origin.git')
        git(k.repo, 'init', '--bare', '-q', origin)
        git(k.repo, 'remote', 'add', 'origin', origin)
        git(k.repo, 'push', '-q', '-u', 'origin', 'HEAD')
        head = git(k.repo, 'rev-parse', 'HEAD')
        os.remove(os.path.join(k.ref, *A.split('/')))
        commit_all(k.repo, 'upstream deletes alpha')
        git(k.repo, 'push', '-q', 'origin', 'HEAD')
        git(k.repo, 'reset', '--hard', '-q', head)
        target = os.path.join(k.live, *A.split('/'))
        other = os.path.join(self.tmp, 'personal-link.md')
        os.link(target, other)
        os.chmod(target, stat.S_IREAD)
        self.addCleanup(lambda: os.path.exists(other) and os.chmod(other, stat.S_IREAD | stat.S_IWRITE))
        before = snapshot(k.live)
        for flags in (('--dry-run',), ()):
            code, out = self.restore(k, *flags)
            self.assertEqual(code, 3, out)
            self.assertEqual(git(k.repo, 'rev-parse', 'HEAD'), head)
            self.assertEqual(snapshot(k.live), before)                   # no backup, no removal
            self.assertFalse(os.stat(other).st_mode & stat.S_IWRITE)

    @unittest.skipUnless(os.name == 'nt', 'Windows read-only attribute')
    def test_final_r1_01_deleted_ref_read_only_with_another_hard_link(self):
        k = self.sync_case('fr101', seed=True)
        os.remove(os.path.join(k.ref, *A.split('/')))
        commit_all(k.repo, 'ref: delete alpha')
        target = os.path.join(k.live, *A.split('/'))
        other = os.path.join(self.tmp, 'personal-link.md')
        os.link(target, other)
        os.chmod(target, stat.S_IREAD)
        self.addCleanup(lambda: os.path.exists(other) and os.chmod(other, stat.S_IREAD | stat.S_IWRITE))
        before = snapshot(k.live)
        code, out = self.restore(k)
        self.assertEqual(code, 3, out)
        self.assertEqual(snapshot(k.live), before)                       # no backup, no removal
        self.assertFalse(os.stat(other).st_mode & stat.S_IWRITE)

    def test_final_r1_04_dry_run_never_fetches_in_a_partial_clone(self):
        """A blob:none clone whose upstream is ahead: the upstream blob is absent; restore --dry-run must refuse (2)
        without fetching it."""
        k = self.sync_case('fr104', seed=True)
        git(k.repo, 'config', 'uploadpack.allowFilter', 'true')
        git(k.repo, 'config', 'uploadpack.allowAnySHA1InWant', 'true')
        clone = os.path.join(self.tmp, 'fr104', 'clone')
        url = 'file:///' + k.repo.replace(os.sep, '/').lstrip('/')
        res = subprocess.run(['git', 'clone', '-q', '--filter=blob:none', url, clone], stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE)
        if res.returncode != 0:
            self.skipTest('partial clone not supported here: %s' % res.stderr.decode('utf-8', 'replace'))
        put(k.ref, 'agents/sdlc-gamma.md', b'gamma\n')
        commit_all(k.repo, 'upstream ahead')
        git(clone, 'fetch', '-q')
        blob = git(k.repo, 'rev-parse', 'HEAD:claude/agents/sdlc-gamma.md')
        self.assertIn(blob, missing_objects(clone))
        objects = snapshot(os.path.join(clone, '.git', 'objects'))
        code, out = run_cli(['restore', '--ref', clone, '--live', k.live, '--manifest-path', k.manifest,
                             '--dry-run'])
        self.assertEqual(code, 2, out)
        self.assertEqual(snapshot(os.path.join(clone, '.git', 'objects')), objects)
        self.assertIn(blob, missing_objects(clone))


def missing_objects(repo):
    """Objects absent from a partial clone (--missing=print never fetches them)."""
    res = subprocess.run(['git', '-C', repo, 'rev-list', '--objects', '--all', '--missing=print'],
                         stdout=subprocess.PIPE, check=True)
    return [l[1:] for l in res.stdout.decode().split() if l.startswith('?')]


if __name__ == '__main__':
    unittest.main()
