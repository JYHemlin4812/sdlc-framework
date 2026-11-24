import os
import subprocess

from sdlc_installer import inventory
from sdlc_installer.errors import UsageError
from tests.helpers import TempDirCase


def git(repo, *args):
    subprocess.run(['git', '-C', repo] + list(args), check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


class DirtyTree(TempDirCase):
    """R3-01: HEAD inventory and working-tree inventory differ on a dirty tree."""

    def setUp(self):
        super().setUp()
        self.write('claude/skills/sdlc/SKILL.md')
        self.write('claude/agents/sdlc-gone.md')
        git(self.tmp, 'init', '-q')
        git(self.tmp, 'config', 'user.email', 't@t')
        git(self.tmp, 'config', 'user.name', 't')
        git(self.tmp, 'config', 'commit.gpgsign', 'false')
        git(self.tmp, 'add', '--', 'claude')
        git(self.tmp, 'commit', '-q', '-m', 'seed')
        self.write('claude/agents/sdlc-new.md')                       # untracked addition
        os.remove(os.path.join(self.tmp, 'claude', 'agents', 'sdlc-gone.md'))  # local deletion

    def test_head(self):
        self.assertEqual(inventory.head_inventory(self.tmp),
                         ['agents/sdlc-gone.md', 'skills/sdlc/SKILL.md'])

    def test_tree(self):
        self.assertEqual(inventory.tree_inventory(os.path.join(self.tmp, 'claude')),
                         ['agents/sdlc-new.md', 'skills/sdlc/SKILL.md'])

    def test_committed_symlink_refused(self):
        from sdlc_installer.errors import SecurityError
        blob = subprocess.run(['git', '-C', self.tmp, 'hash-object', '-w', '--stdin'], input=b'../../elsewhere',
                              stdout=subprocess.PIPE, check=True).stdout.decode().strip()
        git(self.tmp, 'update-index', '--add', '--cacheinfo', '120000,%s,claude/agents/sdlc-link.md' % blob)
        git(self.tmp, 'commit', '-q', '-m', 'link')
        with self.assertRaises(SecurityError):
            inventory.head_inventory(self.tmp)

    def test_committed_link_at_domain_root_refused(self):
        from sdlc_installer.errors import SecurityError
        blob = subprocess.run(['git', '-C', self.tmp, 'hash-object', '-w', '--stdin'], input=b'../elsewhere',
                              stdout=subprocess.PIPE, check=True).stdout.decode().strip()
        git(self.tmp, 'update-index', '--add', '--cacheinfo', '120000,%s,claude/commands/sdlc' % blob)
        git(self.tmp, 'commit', '-q', '-m', 'root link')
        with self.assertRaises(SecurityError):
            inventory.head_inventory(self.tmp)

    def _link(self, path, target=b'x'):
        blob = subprocess.run(['git', '-C', self.tmp, 'hash-object', '-w', '--stdin'], input=target,
                              stdout=subprocess.PIPE, check=True).stdout.decode().strip()
        git(self.tmp, 'update-index', '--add', '--cacheinfo', '120000,%s,%s' % (blob, path))
        git(self.tmp, 'commit', '-q', '-m', 'link ' + path)

    def test_committed_link_in_excluded_subtree_ignored(self):
        self._link('claude/skills/sdlc/_backups/old.md')
        self.assertEqual(inventory.head_inventory(self.tmp), ['agents/sdlc-gone.md', 'skills/sdlc/SKILL.md'])

    def test_committed_agent_link_refused(self):
        from sdlc_installer.errors import SecurityError
        self._link('claude/agents/team')
        with self.assertRaises(SecurityError):
            inventory.head_inventory(self.tmp)

    def test_committed_bak_agent_link_refused(self):
        from sdlc_installer.errors import SecurityError
        self._link('claude/agents/team.bak')
        with self.assertRaises(SecurityError):
            inventory.head_inventory(self.tmp)

    def test_committed_bak_skill_root_link_refused(self):
        from sdlc_installer.errors import SecurityError
        self._link('claude/skills/sdlc-tools.bak')
        with self.assertRaises(SecurityError):
            inventory.head_inventory(self.tmp)

    def _add_raw(self, raw_path):
        blob = subprocess.run(['git', '-C', self.tmp, 'hash-object', '-w', '--stdin'], input=b'x',
                              stdout=subprocess.PIPE, check=True).stdout.decode().strip()
        subprocess.run(['git', '-C', self.tmp, 'update-index', '--index-info'],
                       input=b'100644 blob ' + blob.encode() + b'\t' + raw_path + b'\n', check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        git(self.tmp, 'commit', '-q', '-m', 'raw')

    def test_undecodable_name(self):
        from sdlc_installer.errors import SecurityError
        try:
            self._add_raw(b'claude/skills/sdlc/_backups/\xff.md')
        except (subprocess.CalledProcessError, OSError):
            self.skipTest('git refuses raw byte paths here')
        self.assertEqual(inventory.head_inventory(self.tmp), ['agents/sdlc-gone.md', 'skills/sdlc/SKILL.md'])
        self._add_raw(b'claude/skills/sdlc/\xff.md')
        with self.assertRaises(SecurityError):
            inventory.head_inventory(self.tmp)

    def test_committed_source_root_link_refused(self):
        from sdlc_installer.errors import SecurityError
        git(self.tmp, 'rm', '-r', '-q', '--cached', 'claude')
        self._link('claude', b'../elsewhere')
        with self.assertRaises(SecurityError):
            inventory.head_inventory(self.tmp)

    def test_no_repo(self):
        other = os.path.join(self.tmp, 'claude')
        with self.assertRaises(UsageError):
            inventory.head_inventory(os.path.dirname(self.tmp) + os.sep + 'does-not-exist')
        self.assertTrue(os.path.isdir(other))
