"""capture (design §8.3): Python port of test-capture.sh / test-capture.ps1 (C1 to C6b, D1 to D4, E1, E2) plus the E5
cases (§5.1 confinement, §7 dirty tree, R3-08 both LWW winners, PYI-01). Same fixture as the scripts: a Git
reference with two domain files, a live root with the same files, the base and conflicts.log in a state folder
outside the worktree and outside live. Temporary roots only; ~/.claude is never touched (every call passes --live)."""
import collections
import os
import stat
import subprocess
import unittest

from sdlc_installer import inventory, manifests
from tests.helpers import make_junction
from tests.test_install import InstallCase, get, git, has, put, run_cli, snapshot

A = 'agents/sdlc-alpha.md'
B = 'commands/sdlc/beta.md'
COMMON = {A: b'alpha-v1\n', B: b'beta-v1\n'}

Case = collections.namedtuple('Case', 'repo ref live state manifest conflict')


def commits(repo):
    return int(git(repo, 'rev-list', '--count', 'HEAD'))


def file_hash(root, rel):
    path = os.path.join(root, *rel.split('/'))
    return manifests.file_sha256(path) if os.path.isfile(path) else None


def hook(repo, name, body):
    path = os.path.join(repo, '.git', 'hooks', name)
    with open(path, 'wb') as fh:
        fh.write(b'#!/bin/sh\n' + body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


class SyncCase(InstallCase):
    def sync_case(self, name, files=COMMON, seed=False):
        repo, ref, live = self.new_case(name, seed=files)
        for rel, data in files.items():
            put(live, rel, data)
        state = os.path.join(self.tmp, name, 'state')
        os.makedirs(state)
        k = Case(repo, ref, live, state, os.path.join(state, '.sync-manifest.json'),
                 os.path.join(state, 'conflicts.log'))
        if seed:
            self.seed_base(k)
        return k

    def seed_base(self, k):
        rels = inventory.tree_inventory(k.ref)
        manifests.write_sync_manifest(k.manifest, manifests.tree_hashes(k.ref, rels))

    def base(self, k):
        return manifests.read_sync_manifest(k.manifest)

    def capture(self, k, *flags):
        return run_cli(['capture', '--ref', k.repo, '--live', k.live, '--manifest-path', k.manifest,
                        '--conflict-log', k.conflict] + list(flags))


class Parity(SyncCase):
    """Scenarios of test-capture.sh / .ps1, same names."""

    def test_c1_modified_both_blocks(self):
        k = self.sync_case('c1', seed=True)
        put(k.ref, A, b'alpha-REF\n')
        put(k.live, A, b'alpha-LIVE\n')
        before = (get(k.ref, A), get(k.state, '.sync-manifest.json'), commits(k.repo))
        code, out = self.capture(k)
        self.assertEqual(code, 3, out)
        self.assertIn('modified-both', out)
        self.assertIn('+alpha-LIVE', out)                     # readable diff
        self.assertEqual((get(k.ref, A), get(k.state, '.sync-manifest.json'), commits(k.repo)), before)
        self.assertFalse(os.path.exists(k.conflict))

    def test_c2b_commit_scope(self):
        k = self.sync_case('c2b', seed=True)
        put(k.live, B, b'beta-captured\n')                     # modified-live: captured
        put(k.live, 'settings.local.json', b'{"secret": 1}\n')  # S1: out of the domain
        put(k.live, 'skills/other-tool/SKILL.md', b'third party\n')
        put(k.repo, 'README.md', b'pre-staged\n')               # S2: staged outside claude/
        git(k.repo, 'add', 'README.md')
        os.remove(os.path.join(k.ref, *A.split('/')))           # S3: deleted-ref, skipped
        code, out = self.capture(k)
        self.assertEqual(code, 0, out)
        names = git(k.repo, 'show', '--name-only', '--format=', 'HEAD').splitlines()
        self.assertEqual(names, ['claude/' + B])
        tip = git(k.repo, 'ls-tree', '-r', '--name-only', 'HEAD').splitlines()
        self.assertIn('claude/' + A, tip)
        self.assertNotIn('README.md', tip)
        self.assertIn('A  README.md', git(k.repo, 'status', '--porcelain'))   # §7: still staged, not committed

    def test_c3_d3_state_outside_worktree_and_success(self):
        k = self.sync_case('c3', seed=True)
        put(k.live, B, b'beta-v2\n')
        code, out = self.capture(k)
        self.assertEqual(code, 0, out)
        self.assertEqual(get(k.ref, B), b'beta-v2\n')
        self.assertEqual(git(k.repo, 'status', '--porcelain', '--', 'claude'), '')
        self.assertTrue(self.base(k).ok)
        self.assertEqual(self.base(k).entries[B], file_hash(k.ref, B))
        found = [f for _d, _s, fs in os.walk(k.repo) for f in fs if f in ('.sync-manifest.json', 'conflicts.log')]
        self.assertEqual(found, [])
        leftovers = [f for _d, _s, fs in os.walk(k.ref) for f in fs if f.startswith('.sdlc-tmp-')]
        self.assertEqual(leftovers, [])
        self.assertFalse(os.path.exists(os.path.join(k.live, '.sync.lock')))

    def test_c4_post_check_failure(self):
        k = self.sync_case('c4', seed=True)
        before = get(k.state, '.sync-manifest.json')
        hook(k.repo, 'post-commit', b'echo dirty >> claude/commands/sdlc/beta.md\n')
        put(k.live, B, b'beta-capture\n')
        code, out = self.capture(k)
        self.assertEqual(code, 7, out)
        self.assertIn('POST-CHECK', out)
        self.assertEqual(get(k.state, '.sync-manifest.json'), before)

    def test_c5a_added_live_captured(self):
        k = self.sync_case('c5a', seed=True)
        put(k.live, 'agents/sdlc-new.md', b'brand-new\n')
        n = commits(k.repo)
        code, out = self.capture(k)
        self.assertEqual(code, 0, out)
        self.assertTrue(has(k.ref, 'agents/sdlc-new.md'))
        self.assertEqual(commits(k.repo), n + 1)
        self.assertIn('claude/agents/sdlc-new.md', git(k.repo, 'show', '--name-only', '--format=', 'HEAD'))
        self.assertIn('agents/sdlc-new.md', self.base(k).entries)

    def test_c5b_deleted_live_blocked(self):
        k = self.sync_case('c5b', seed=True)
        os.remove(os.path.join(k.live, *A.split('/')))
        n, before = commits(k.repo), get(k.state, '.sync-manifest.json')
        code, out = self.capture(k)
        self.assertEqual(code, 3, out)
        self.assertIn('deleted-live', out)
        self.assertTrue(has(k.ref, A))
        self.assertEqual((commits(k.repo), get(k.state, '.sync-manifest.json')), (n, before))

    def test_c6a_dry_run_writes_nothing(self):
        k = self.sync_case('c6a', seed=True)
        put(k.live, 'agents/sdlc-new.md', b'would-add\n')
        put(k.live, B, b'would-modify\n')
        before_ref, before_state, n = snapshot(k.ref), snapshot(k.state), commits(k.repo)
        code, out = self.capture(k, '--dry-run')
        self.assertEqual(code, 0, out)
        self.assertIn('WOULD be captured', out)
        self.assertEqual((snapshot(k.ref), snapshot(k.state), commits(k.repo)), (before_ref, before_state, n))
        self.assertFalse(os.path.exists(os.path.join(k.live, '.sync.lock')))

    def test_c6b_dry_run_reflects_block(self):
        k = self.sync_case('c6b', seed=True)
        put(k.ref, A, b'alpha-REF\n')
        put(k.live, A, b'alpha-LIVE\n')
        before = snapshot(k.state)
        code, out = self.capture(k, '--dry-run')
        self.assertEqual(code, 3, out)
        self.assertEqual(snapshot(k.state), before)
        code, out = self.capture(k, '--dry-run', '--lww', '--provenance', 'live')
        self.assertEqual(code, 0, out)
        self.assertFalse(os.path.exists(k.conflict))          # dry-run: conflicts.log not created

    def test_d1_first_run_seed_block_adopt(self):
        k = self.sync_case('d1seed')
        code, out = self.capture(k)
        self.assertEqual(code, 0, out)
        self.assertEqual(self.base(k).entries, manifests.tree_hashes(k.ref, sorted(COMMON)))
        k2 = self.sync_case('d1block')
        put(k2.live, 'agents/sdlc-extra.md', b'extra\n')
        code, out = self.capture(k2)
        self.assertEqual(code, 5, out)
        self.assertIn('agents/sdlc-extra.md', out)
        self.assertFalse(os.path.exists(k2.manifest))
        code, out = self.capture(k2, '--adopt')
        self.assertEqual(code, 0, out)
        self.assertIn('adopted', out)
        self.assertIn('agents/sdlc-extra.md', self.base(k2).entries)
        self.assertFalse(has(k2.ref, 'agents/sdlc-extra.md'))   # adopt freezes the base, copies nothing

    def test_d2_corrupt_base_fails_closed(self):
        k = self.sync_case('d2')
        put(k.state, '.sync-manifest.json', b'{ this is : not json')
        put(k.live, B, b'beta-v2\n')
        n = commits(k.repo)
        code, out = self.capture(k)
        self.assertEqual(code, 6, out)
        self.assertIn('FAIL CLOSED', out)
        self.assertEqual((commits(k.repo), get(k.ref, B)), (n, b'beta-v1\n'))

    def test_d4_lww_live_winner_logged_and_backed_up(self):
        k = self.sync_case('d4', seed=True)
        put(k.ref, A, b'alpha-REF\n')
        put(k.live, A, b'alpha-LIVE\n')
        n = commits(k.repo)
        code, out = self.capture(k, '--lww', '--provenance', 'live')
        self.assertEqual(code, 0, out)
        self.assertTrue(os.path.isfile(k.conflict))
        self.assertIn('winner=live', get(k.state, 'conflicts.log').decode('utf-8'))
        self.assertEqual(get(k.ref, A), b'alpha-LIVE\n')
        self.assertEqual(commits(k.repo), n + 1)
        [folder] = [d for d in os.listdir(os.path.join(k.live, '_backups')) if d.startswith('capture-lww-')]
        self.assertEqual(get(os.path.join(k.live, '_backups', folder), A), b'alpha-REF\n')

    def test_e1_commit_rejected_then_retry(self):
        k = self.sync_case('e1', seed=True)
        pre = hook(k.repo, 'pre-commit', b'exit 1\n')
        put(k.live, B, b'beta-pending\n')
        n = commits(k.repo)
        code, out = self.capture(k)
        self.assertEqual(code, 4, out)
        os.remove(pre)
        code, out = self.capture(k)
        self.assertEqual(code, 0, out)
        self.assertIn('PENDING', out)
        self.assertEqual(commits(k.repo), n + 1)
        self.assertEqual(git(k.repo, 'show', 'HEAD:claude/' + B), 'beta-pending')
        self.assertEqual(git(k.repo, 'status', '--porcelain', '--', 'claude/' + B), '')
        self.assertEqual(self.base(k).entries[B], file_hash(k.live, B))

    def test_e2_committed_but_base_stale(self):
        k = self.sync_case('e2', seed=True)
        put(k.live, B, b'beta-landed\n')
        put(k.ref, B, b'beta-landed\n')
        git(k.repo, 'add', '--', 'claude/' + B)
        git(k.repo, 'commit', '-q', '-m', 'simulated capture commit', '--', 'claude/' + B)
        n = commits(k.repo)
        code, out = self.capture(k)
        self.assertEqual(code, 0, out)
        self.assertIn('base refreshed', out)
        self.assertEqual(commits(k.repo), n)
        self.assertEqual(self.base(k).entries[B], file_hash(k.ref, B))


class Contract(SyncCase):
    """E5 cases: design §5.1, §7, R3-08, PYI-01."""

    def test_r3_08_default_lww_keeps_the_reference(self):
        k = self.sync_case('lwwref', seed=True)
        put(k.ref, A, b'alpha-REF\n')
        put(k.live, A, b'alpha-LIVE\n')
        n = commits(k.repo)
        code, out = self.capture(k, '--lww')
        self.assertEqual(code, 0, out)
        self.assertEqual(get(k.ref, A), b'alpha-REF\n')            # reference bytes intact
        self.assertEqual(commits(k.repo), n)                        # nothing captured for this path
        self.assertIn('winner=ref', get(k.state, 'conflicts.log').decode('utf-8'))
        self.assertFalse(os.path.isdir(os.path.join(k.live, '_backups')))

    def test_lww_with_a_local_reference_change_and_unrelated_dirt(self):
        # §7: capture refuses nothing globally; an unrelated change in claude/ is neither committed nor lost.
        k = self.sync_case('lwwdirty', seed=True)
        put(k.ref, 'agents/sdlc-draft.md', b'work in progress\n')     # untracked, ref only: added-ref, ignored
        put(k.ref, A, b'alpha-REF\n')
        put(k.live, A, b'alpha-LIVE\n')
        code, out = self.capture(k, '--lww', '--provenance', 'live')
        self.assertEqual(code, 0, out)
        self.assertEqual(git(k.repo, 'show', '--name-only', '--format=', 'HEAD').splitlines(), ['claude/' + A])
        self.assertIn('?? claude/agents/sdlc-draft.md', git(k.repo, 'status', '--porcelain', '-uall'))

    def test_provenance_live_needs_lww(self):
        k = self.sync_case('prov', seed=True)
        code, out = self.capture(k, '--provenance', 'live')
        self.assertEqual(code, 2, out)

    def test_allow_dirty_refused(self):
        k = self.sync_case('ad', seed=True)
        code, out = self.capture(k, '--allow-dirty')
        self.assertEqual(code, 2, out)
        self.assertIn('--allow-dirty', out)

    def test_pyi_04_state_inside_worktree_refused(self):
        k = self.sync_case('pyi04', seed=True)
        put(k.live, B, b'beta-v2\n')
        inside = os.path.join(k.repo, 'state', '.sync-manifest.json')
        code, out = run_cli(['capture', '--ref', k.repo, '--live', k.live, '--manifest-path', inside])
        self.assertEqual(code, 2, out)
        self.assertFalse(os.path.lexists(os.path.join(k.repo, 'state')))
        code, out = run_cli(['capture', '--ref', k.repo, '--live', k.live, '--manifest-path', k.manifest,
                             '--conflict-log', os.path.join(k.repo, 'conflicts.log')])
        self.assertEqual(code, 2, out)
        live_in_repo = os.path.join(k.repo, 'live')
        os.makedirs(live_in_repo)
        code, out = run_cli(['capture', '--ref', k.repo, '--live', live_in_repo, '--manifest-path', k.manifest])
        self.assertEqual(code, 2, out)
        self.assertEqual(os.listdir(live_in_repo), [])
        self.assertEqual(get(k.ref, B), b'beta-v1\n')

    def test_ref_must_be_the_worktree_root(self):
        k = self.sync_case('subref', seed=True)
        code, out = run_cli(['capture', '--ref', k.ref, '--live', k.live, '--manifest-path', k.manifest])
        self.assertEqual(code, 2, out)

    def test_lock_held_gives_1(self):
        k = self.sync_case('lock', seed=True)
        put(k.live, '.sync.lock', b'pid=1\n')
        put(k.live, B, b'beta-v2\n')
        code, out = self.capture(k)
        self.assertEqual(code, 1, out)
        self.assertEqual(get(k.ref, B), b'beta-v1\n')

    def test_empty_manifest_path_refused(self):
        k = self.sync_case('empty', seed=True)
        code, out = run_cli(['capture', '--ref', k.repo, '--live', k.live, '--manifest-path', ' '])
        self.assertEqual(code, 2, out)

    def test_base_with_unsafe_key_fails_closed(self):
        k = self.sync_case('badkey')
        manifests.write_sync_manifest(k.manifest, {A: file_hash(k.ref, A)})
        doc = get(k.state, '.sync-manifest.json').replace(b'"entries": {', b'"entries": {\n    "../x": "00",')
        put(k.state, '.sync-manifest.json', doc)
        code, out = self.capture(k)
        self.assertEqual(code, 6, out)

    def test_refusal_before_any_write_dry_run_included(self):
        # §5.2 point 4: a directory where a captured file goes refuses (3) before conflicts.log, backup or copy,
        # and the dry-run refuses the same way.
        k = self.sync_case('refuse', seed=True)
        put(k.ref, A, b'alpha-REF\n')
        put(k.live, A, b'alpha-LIVE\n')                            # modified-both, resolved by --lww live
        put(k.live, 'agents/sdlc-new.md', b'new\n')                # added-live ...
        put(k.ref, 'agents/sdlc-new.md/keep.txt', b'a folder\n')   # ... where the reference has a folder
        before = snapshot(os.path.join(self.tmp, 'refuse'))
        for flags in (('--dry-run',), ()):
            code, out = self.capture(k, '--lww', '--provenance', 'live', *flags)
            self.assertEqual(code, 3, out)
            self.assertEqual(snapshot(os.path.join(self.tmp, 'refuse')), before)
        self.assertFalse(os.path.exists(k.conflict))

    def test_literal_pathspecs(self):
        # 'a[1].md' is a file name, never a pattern: the dirty sibling 'a1.md' is not committed.
        k = self.sync_case('literal', seed=True)
        put(k.ref, 'commands/sdlc/a1.md', b'unrelated draft\n')
        put(k.live, 'commands/sdlc/a[1].md', b'bracket\n')
        code, out = self.capture(k)
        self.assertEqual(code, 0, out)
        self.assertEqual(git(k.repo, 'show', '--name-only', '--format=', 'HEAD').splitlines(),
                         ['claude/commands/sdlc/a[1].md'])
        self.assertIn('?? claude/commands/sdlc/a1.md', git(k.repo, 'status', '--porcelain', '-uall'))

    def test_e5_r1_02_state_path_through_a_junction_or_dotdot(self):
        k = self.sync_case('junc')
        sentinel = os.path.join(self.tmp, 'sentinel')
        os.makedirs(sentinel)
        link = os.path.join(k.live, 'state')
        if not make_junction(link, sentinel):
            self.skipTest('cannot create a junction or symlink here')
        for flags in (['--manifest-path', os.path.join(link, '.sync-manifest.json')],
                      ['--manifest-path', k.manifest, '--conflict-log', os.path.join(link, 'conflicts.log')],
                      ['--manifest-path', os.path.join(k.state, '..', 'state', 'm.json')]):
            code, out = run_cli(['capture', '--ref', k.repo, '--live', k.live, '--lww'] + flags)
            self.assertEqual(code, 3, out)
        self.assertEqual(os.listdir(sentinel), [])
        self.assertFalse(os.path.exists(k.manifest))

    def test_e5_r1_03_state_files_overlap(self):
        k = self.sync_case('overlap', seed=True)
        put(k.ref, A, b'alpha-REF\n')
        put(k.live, A, b'alpha-LIVE\n')
        before = snapshot(os.path.join(self.tmp, 'overlap'))
        for log in (k.manifest, os.path.join(k.live, *B.split('/'))):
            code, out = run_cli(['capture', '--ref', k.repo, '--live', k.live, '--manifest-path', k.manifest,
                                 '--conflict-log', log, '--lww'])
            self.assertEqual(code, 2, out)
        self.assertEqual(snapshot(os.path.join(self.tmp, 'overlap')), before)

    def test_e5_r1_04_ignored_addition_never_published(self):
        k = self.sync_case('ignored', seed=True)
        put(k.repo, '.gitignore', b'claude/agents/sdlc-ign.md\n')
        git(k.repo, 'add', '.gitignore')
        git(k.repo, 'commit', '-q', '-m', 'ignore rule')
        put(k.live, 'agents/sdlc-ign.md', b'ignored addition\n')
        before = get(k.state, '.sync-manifest.json')
        for _run in range(2):
            code, out = self.capture(k)
            self.assertEqual(code, 4, out)
            self.assertEqual(get(k.state, '.sync-manifest.json'), before)
        self.assertNotIn('claude/agents/sdlc-ign.md', git(k.repo, 'ls-tree', '-r', '--name-only', 'HEAD'))

    def test_e5_r1_06_log_refused_in_dry_run_too(self):
        k = self.sync_case('logdir', seed=True)
        put(k.ref, A, b'alpha-REF\n')
        put(k.live, A, b'alpha-LIVE\n')
        os.makedirs(k.conflict)
        for flags in (('--dry-run',), ()):
            code, out = self.capture(k, '--lww', *flags)
            self.assertEqual(code, 3, out)

    def test_e5_r1_08_long_pathspec_list(self):
        k = self.sync_case('many', seed=True)
        names = ['agents/sdlc-%s-%04d.md' % ('x' * 80, i) for i in range(400)]     # > 32 767 characters in all
        self.assertGreater(sum(len('claude/' + n) + 1 for n in names), 32767)
        for name in names:
            put(k.live, name, name.encode('ascii') + b'\n')
        n = commits(k.repo)
        code, out = self.capture(k)
        self.assertEqual(code, 0, out)
        self.assertEqual(commits(k.repo), n + 1)
        self.assertEqual(len(git(k.repo, 'show', '--name-only', '--format=', 'HEAD').splitlines()), 400)

    def test_e5_r2_03_hard_linked_log_refused(self):
        k = self.sync_case('hardlink', seed=True)
        put(k.ref, A, b'alpha-REF\n')
        put(k.live, A, b'alpha-LIVE\n')
        try:
            os.link(k.manifest, k.conflict)
        except OSError:
            self.skipTest('hard links not available here')
        before = get(k.state, '.sync-manifest.json')
        code, out = self.capture(k, '--lww')
        self.assertEqual(code, 3, out)
        self.assertEqual(get(k.state, '.sync-manifest.json'), before)

    def test_e5_r2_04_backup_root_reserved(self):
        k = self.sync_case('bkroot', seed=True)
        put(k.ref, A, b'alpha-REF\n')
        put(k.live, A, b'alpha-LIVE\n')
        for flags in (('--dry-run',), ()):
            code, out = run_cli(['capture', '--ref', k.repo, '--live', k.live, '--manifest-path', k.manifest,
                                 '--conflict-log', os.path.join(k.live, '_backups'), '--lww', '--provenance', 'live']
                                + list(flags))
            self.assertEqual(code, 2, out)
            self.assertFalse(os.path.lexists(os.path.join(k.live, '_backups')))

    def test_e5_r2_05_interrupted_capture_with_a_staged_change(self):
        k = self.sync_case('staged', seed=True)                 # base: beta-v1
        put(k.ref, B, b'beta-B\n')
        git(k.repo, 'commit', '-q', '-am', 'B landed')            # HEAD and working tree: B
        put(k.live, B, b'beta-B\n')
        put(k.ref, B, b'beta-C\n')
        git(k.repo, 'add', '--', 'claude/' + B)                  # index: C
        put(k.ref, B, b'beta-B\n')                               # working tree back to B
        before, n = get(k.state, '.sync-manifest.json'), commits(k.repo)
        for flags in (('--dry-run',), ()):
            code, out = self.capture(k, *flags)
            self.assertEqual(code, 3, out)
        self.assertEqual((get(k.state, '.sync-manifest.json'), commits(k.repo)), (before, n))
        self.assertEqual(git(k.repo, 'show', ':claude/' + B), 'beta-C')    # the staged change is kept

    def test_e5_r2_06_staged_rename_seen_on_both_paths(self):
        from sdlc_installer import capture as capture_mod
        k = self.sync_case('rename', seed=True)
        git(k.repo, 'mv', 'claude/' + B, 'claude/commands/sdlc/beta2.md')
        roots = capture_mod.Roots(k.repo, 'claude', k.ref, k.live, k.manifest, k.conflict, False)
        dirty = capture_mod._dirty_paths(roots)
        self.assertIn('claude/' + B, dirty)
        self.assertIn('claude/commands/sdlc/beta2.md', dirty)

    def test_e5_r2_08_link_in_head_refused_before_any_write(self):
        k = self.sync_case('headlink', seed=True)
        blob = subprocess.run(['git', '-C', k.repo, 'hash-object', '-w', '--stdin'], input=b'sdlc-alpha.md',
                              stdout=subprocess.PIPE, check=True).stdout.decode().strip()
        git(k.repo, 'update-index', '--add', '--cacheinfo', '120000,%s,claude/agents/sdlc-link.md' % blob)
        git(k.repo, 'commit', '-q', '-m', 'a link in the domain')
        if os.path.lexists(os.path.join(k.ref, 'agents', 'sdlc-link.md')):
            os.remove(os.path.join(k.ref, 'agents', 'sdlc-link.md'))
        put(k.live, B, b'beta-v2\n')
        n, before = commits(k.repo), snapshot(k.ref)
        code, out = self.capture(k)
        self.assertEqual(code, 3, out)
        self.assertEqual((commits(k.repo), snapshot(k.ref)), (n, before))
        self.assertFalse(os.path.exists(k.conflict))

    def test_e5_r3_03_resumed_path_changed_by_a_hook_commit(self):
        k = self.sync_case('hookc', seed=True)                  # base: beta-v1
        put(k.ref, B, b'beta-B\n')
        git(k.repo, 'commit', '-q', '-am', 'B landed, base not published')
        put(k.live, B, b'beta-B\n')                              # resumed path (R3-05)
        put(k.live, A, b'alpha-v2\n')                            # a second path to copy
        hook(k.repo, 'post-commit', b'[ -n "$SDLC_TEST_HOOK" ] && exit 0\n'
             b'export SDLC_TEST_HOOK=1\nunset GIT_INDEX_FILE\n'
             b'printf "beta-C\\n" > claude/commands/sdlc/beta.md\n'
             b'git add claude/commands/sdlc/beta.md && git commit -q -m "hook commit"\n')
        before = get(k.state, '.sync-manifest.json')
        code, out = self.capture(k)
        self.assertEqual(code, 7, out)
        self.assertIn('NOT IN HEAD', out)
        self.assertEqual(git(k.repo, 'show', 'HEAD:claude/' + B), 'beta-C')     # the hook did commit C
        self.assertEqual(get(k.state, '.sync-manifest.json'), before)

    def test_e5_r3_04_link_in_head_refused_on_first_run(self):
        k = self.sync_case('headlink1')                         # no base: first run
        blob = subprocess.run(['git', '-C', k.repo, 'hash-object', '-w', '--stdin'], input=b'sdlc-alpha.md',
                              stdout=subprocess.PIPE, check=True).stdout.decode().strip()
        git(k.repo, 'update-index', '--add', '--cacheinfo', '120000,%s,claude/agents/sdlc-link.md' % blob)
        git(k.repo, 'commit', '-q', '-m', 'a link in the domain')
        if os.path.lexists(os.path.join(k.ref, 'agents', 'sdlc-link.md')):
            os.remove(os.path.join(k.ref, 'agents', 'sdlc-link.md'))
        for flags in (('--dry-run',), ()):
            code, out = self.capture(k, *flags)
            self.assertEqual(code, 3, out)
            self.assertFalse(os.path.exists(k.manifest))

    def test_pyi_01_capture_then_install_from_the_commit(self):
        k = self.sync_case('pyi01', files=dict(COMMON, **{
            'skills/sdlc/SKILL.md': b'---\nname: sdlc\n---\nroot\n'}), seed=True)
        put(k.live, B, b'beta-captured\n')
        put(k.live, 'agents/sdlc-new.md', b'new agent\n')
        code, out = self.capture(k)
        self.assertEqual(code, 0, out)
        target = os.path.join(self.tmp, 'pyi01', 'other-live')
        code, out = self.install(k.ref, target)
        self.assertEqual(code, 0, out)
        self.assertEqual(get(target, 'agents/sdlc-new.md'), b'new agent\n')
        code, out = self.install(k.ref, k.live)                   # the captured live files are the bundle's
        self.assertEqual(code, 0, out)
        self.assertNotIn('origin unknown', out)


if __name__ == '__main__':
    unittest.main()
