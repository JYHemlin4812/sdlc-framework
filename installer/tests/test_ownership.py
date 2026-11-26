import os
import subprocess
import unittest

from sdlc_installer import inventory, ownership
from sdlc_installer.ownership import HISTORY, REGISTRY, SOURCE, UNKNOWN, Ownership
from tests.helpers import REPO, TempDirCase, make_junction

CRLF = b'line1\r\nline2\r\n'


def git(repo, *args):
    res = subprocess.run(['git', '-C', repo] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if res.returncode != 0:
        raise RuntimeError(res.stderr.decode('utf-8', 'replace'))
    return res.stdout.decode('utf-8', 'replace').strip()


class GitCase(TempDirCase):
    def setUp(self):
        super().setUp()
        git(self.tmp, 'init', '-q')
        git(self.tmp, 'config', 'user.email', 't@t')
        git(self.tmp, 'config', 'user.name', 't')
        git(self.tmp, 'config', 'commit.gpgsign', 'false')
        self.write('.gitattributes', b'* -text\n')

    def commit(self, msg='c'):
        git(self.tmp, 'add', '-A')
        git(self.tmp, 'commit', '-q', '-m', msg)


class BlobIds(GitCase):
    def test_matches_git_hash_object_for_crlf_bytes(self):
        """§3: '* -text' makes the blob equal the file, so the id of the live bytes is the id in Git."""
        self.write('claude/agents/sdlc-a.md', CRLF)
        self.commit()
        self.assertEqual(ownership.git_blob_id(CRLF), git(self.tmp, 'rev-parse', 'HEAD:claude/agents/sdlc-a.md'))
        self.assertEqual(ownership.git_blob_id(b''), 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391')


class History(GitCase):
    def test_every_committed_version_is_known_including_root_and_merge(self):
        self.write('claude/agents/sdlc-a.md', b'v1\n')                  # root commit
        self.write('claude/agents/sdlc-gone.md', b'gone\n')
        self.write('claude/other/x.md', b'not domain\n')
        self.commit('root')
        self.write('claude/agents/sdlc-a.md', b'v2\n')
        self.commit('v2')
        os.remove(os.path.join(self.tmp, 'claude', 'agents', 'sdlc-gone.md'))
        self.commit('delete')
        main = git(self.tmp, 'rev-parse', '--abbrev-ref', 'HEAD')
        git(self.tmp, 'checkout', '-q', '-b', 'side')
        self.write('claude/agents/sdlc-a.md', b'side\n')
        self.write('claude/agents/sdlc-side.md', b'only on the branch\n')
        self.commit('side')
        git(self.tmp, 'checkout', '-q', main)
        self.write('claude/agents/sdlc-b.md', b'b\n')
        self.commit('main moves')
        git(self.tmp, 'merge', '-q', '--no-ff', '-X', 'theirs', '-m', 'merge', 'side')
        blobs = ownership.history_blobs(self.tmp)
        want = ownership.git_blob_id
        self.assertEqual(blobs['agents/sdlc-a.md'], {want(b'v1\n'), want(b'v2\n'), want(b'side\n')})
        self.assertEqual(blobs['agents/sdlc-gone.md'], {want(b'gone\n')})
        self.assertIn(want(b'only on the branch\n'), blobs['agents/sdlc-side.md'])
        self.assertNotIn('other/x.md', blobs)                       # outside the domain

    def test_side_branch_dropped_by_the_merge_is_still_known(self):
        """E2-R1-11: a merge that keeps the first parent's tree must not hide the side branch's versions, nor a
        blob that only the merge resolution creates. (Measured 2026-11-24: -m alone already guarantees it; the
        test pins the behaviour so that a change of git options cannot lose it.)"""
        self.write('claude/agents/sdlc-a.md', b'base\n')
        self.commit('root')
        main = git(self.tmp, 'rev-parse', '--abbrev-ref', 'HEAD')
        git(self.tmp, 'checkout', '-q', '-b', 'side')
        self.write('claude/agents/sdlc-a.md', b'side only\n')
        self.commit('side')
        git(self.tmp, 'checkout', '-q', main)
        self.write('claude/agents/sdlc-a.md', b'main\n')
        self.commit('main')
        git(self.tmp, 'merge', '-q', '--no-ff', '-s', 'ours', '-m', 'keep ours', 'side')
        # right after an 'ours' merge the tree equals the first parent's: this is the case Git simplifies away
        got = ownership.history_blobs(self.tmp)['agents/sdlc-a.md']
        for data in (b'base\n', b'side only\n', b'main\n'):
            self.assertIn(ownership.git_blob_id(data), got, data)
        self.write('claude/agents/sdlc-a.md', b'resolved by hand\n')
        git(self.tmp, 'add', '-A')
        git(self.tmp, 'commit', '-q', '--amend', '--no-edit')       # the merge itself now holds a new blob
        got = ownership.history_blobs(self.tmp)['agents/sdlc-a.md']
        for data in (b'base\n', b'side only\n', b'main\n', b'resolved by hand\n'):
            self.assertIn(ownership.git_blob_id(data), got, data)

    def test_deleted_state_is_not_a_blob(self):
        self.write('claude/agents/sdlc-a.md', b'v1\n')
        self.commit()
        os.remove(os.path.join(self.tmp, 'claude', 'agents', 'sdlc-a.md'))
        self.commit('delete')
        self.assertEqual(ownership.history_blobs(self.tmp)['agents/sdlc-a.md'],
                         {ownership.git_blob_id(b'v1\n')})

    def test_unreadable_repository_is_a_usage_error(self):
        from sdlc_installer.errors import UsageError
        with self.assertRaises(UsageError):
            ownership.history_blobs(os.path.join(self.tmp, 'absent'))

    def test_shallow_clone_is_reported(self):
        self.write('claude/agents/sdlc-a.md', b'v1\n')
        self.commit()
        self.write('claude/agents/sdlc-a.md', b'v2\n')
        self.commit()
        clone = os.path.join(self.tmp, 'clone')
        git(self.tmp, 'clone', '-q', '--depth', '1', 'file://' + self.tmp.replace('\\', '/'), clone)
        self.assertFalse(ownership.is_shallow(self.tmp))
        self.assertTrue(ownership.is_shallow(clone))
        self.assertTrue(Ownership(repo=clone).history_incomplete)
        self.assertEqual(ownership.history_blobs(clone)['agents/sdlc-a.md'], {ownership.git_blob_id(b'v2\n')})


class Classify(GitCase):
    def setUp(self):
        super().setUp()
        self.write('claude/agents/sdlc-a.md', b'v1\n')
        self.commit()
        self.write('claude/agents/sdlc-a.md', CRLF)
        self.commit()

    def test_four_verdicts(self):
        own = Ownership(self.tmp, {'agents/sdlc-a.md': ownership.hashlib.sha256(b'archive\n').hexdigest().upper()})
        rel = 'agents/sdlc-a.md'
        self.assertEqual(own.classify(rel, b'new source\n', source_bytes=b'new source\n'), SOURCE)
        self.assertEqual(own.classify(rel, b'v1\n', b'new source\n'), HISTORY)
        self.assertEqual(own.classify(rel, CRLF), HISTORY)                      # CRLF kept byte for byte
        self.assertEqual(own.classify(rel, b'archive\n'), REGISTRY)
        self.assertEqual(own.classify(rel, b'hand edited\n', b'new source\n'), UNKNOWN)
        self.assertEqual(own.classify(rel, b'v1\r\n'), UNKNOWN)                 # one byte of difference
        self.assertEqual(own.classify('agents/sdlc-other.md', b'v1\n'), UNKNOWN)  # blob of ANOTHER path

    def test_only_domain_paths_can_be_owned(self):
        """E2-R1-05: a recorded hash or an identical source never makes a non-domain file bundle-owned."""
        digest = ownership.hashlib.sha256(b'x').hexdigest()
        own = Ownership(self.tmp, {'settings.json': digest, 'skills/sdlc/.install-manifest.json': digest,
                                   'agents/other.md': digest})
        for rel in ('settings.json', 'skills/sdlc/.install-manifest.json', 'agents/other.md', 'CLAUDE.md'):
            self.assertEqual(own.classify(rel, b'x', source_bytes=b'x'), UNKNOWN, rel)

    def test_sha256_object_format_repository(self):
        """E2-R3-08: blob ids follow the repository's object format (64 hex digits for sha256)."""
        res = subprocess.run(['git', 'init', '-q', '--object-format=sha256', os.path.join(self.tmp, 'h256')],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if res.returncode != 0:
            self.skipTest('this git cannot create sha256 repositories')
        repo = os.path.join(self.tmp, 'h256')
        git(repo, 'config', 'user.email', 't@t')
        git(repo, 'config', 'user.name', 't')
        git(repo, 'config', 'commit.gpgsign', 'false')
        for name, data in (('.gitattributes', b'* -text\n'), ('claude/agents/sdlc-a.md', b'old\n')):
            path = os.path.join(repo, *name.split('/'))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'wb') as fh:
                fh.write(data)
        git(repo, 'add', '-A')
        git(repo, 'commit', '-q', '-m', 'one')
        with open(os.path.join(repo, 'claude', 'agents', 'sdlc-a.md'), 'wb') as fh:
            fh.write(b'new\n')
        git(repo, 'add', '-A')
        git(repo, 'commit', '-q', '-m', 'two')
        own = Ownership(repo)
        self.assertEqual(own.algo, 'sha256')
        self.assertEqual(own.classify('agents/sdlc-a.md', b'old\n', b'newer\n'), HISTORY)
        self.assertEqual(own.classify('agents/sdlc-a.md', b'other\n', b'newer\n'), UNKNOWN)
        self.assertEqual(ownership.git_blob_id(b'new\n', 'sha256'), git(repo, 'rev-parse', 'HEAD:claude/agents/sdlc-a.md'))

    def test_unsafe_relative_path_is_refused_not_classified(self):
        """E2-R2-05: classify validates the path itself, whatever the bytes say."""
        from sdlc_installer.errors import SecurityError
        for rel in ('skills/sdlc/../../settings.json', '/abs', 'agents//x', 'skills/sdlc/a:b'):
            with self.assertRaises(SecurityError, msg=rel):
                Ownership().classify(rel, b'x', b'x')

    def test_classify_file_never_reads_through_a_link(self):
        """E2-R1-04: a pre-existing junction live/agents -> outside must not turn outside bytes into HISTORY."""
        from sdlc_installer.errors import SecurityError
        live = os.path.join(self.tmp, 'live')
        outside = os.path.join(self.tmp, 'outside')
        os.makedirs(live)
        os.makedirs(outside)
        with open(os.path.join(outside, 'sdlc-a.md'), 'wb') as fh:
            fh.write(b'v1\n')                                         # would be HISTORY
        if not make_junction(os.path.join(live, 'agents'), outside):
            self.skipTest('cannot create a junction here')
        with self.assertRaises(SecurityError):
            Ownership(self.tmp).classify_file(live, 'agents/sdlc-a.md')

    def test_classify_file_refuses_a_directory(self):
        from sdlc_installer.errors import SecurityError
        live = os.path.join(self.tmp, 'live')
        os.makedirs(os.path.join(live, 'agents', 'sdlc-a.md'))
        with self.assertRaises(SecurityError):
            Ownership(self.tmp).classify_file(live, 'agents/sdlc-a.md')

    def test_archive_source_has_no_history(self):
        own = Ownership(repo=None, registry_hashes=None)
        self.assertEqual(own.classify('agents/sdlc-a.md', b'v1\n'), UNKNOWN)
        self.assertFalse(own.history_incomplete)

    def test_classify_file(self):
        live = os.path.join(self.tmp, 'live')
        os.makedirs(os.path.join(live, 'agents'))
        with open(os.path.join(live, 'agents', 'sdlc-a.md'), 'wb') as fh:
            fh.write(b'v1\n')
        own = Ownership(self.tmp)
        self.assertEqual(own.classify_file(live, 'agents/sdlc-a.md'), HISTORY)
        self.assertIsNone(own.classify_file(live, 'agents/sdlc-absent.md'))


class RealRepository(unittest.TestCase):
    def test_every_head_blob_is_in_the_history(self):
        """§3 claim (checked 2026-11-24 by hand): all HEAD blobs of claude/ are in the history."""
        if not os.path.exists(os.path.join(REPO, '.git')):
            self.skipTest('not a Git checkout')
        try:
            rels = inventory.head_inventory(REPO)
        except Exception as exc:        # e.g. no claude/ at HEAD in a stripped checkout
            self.skipTest(str(exc))
        if not rels:
            self.skipTest('no domain at HEAD')
        own = Ownership(REPO)
        missing = []
        for rel in rels:
            blob = git(REPO, 'rev-parse', 'HEAD:claude/' + rel)
            if blob not in own.history.get(rel, ()):
                missing.append(rel)
        self.assertEqual(missing, [])


if __name__ == '__main__':
    unittest.main()
