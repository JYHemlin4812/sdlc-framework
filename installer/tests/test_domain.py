import unittest

from sdlc_installer import domain, inventory
from tests.helpers import REPO, TempDirCase


class DomainRules(unittest.TestCase):
    def test_in_domain(self):
        yes = ['skills/sdlc/SKILL.md', 'skills/sdlc-verify/x/y.md', 'commands/sdlc/dev.md',
               'agents/sdlc-a.md', 'agents/nested/sdlc-deep.md']
        no = ['skills/other/SKILL.md', 'skills/sdlc/commands/dev.md', 'commands/other/x.md',
              'agents/autre-clara.md', 'CLAUDE.md', 'PERSO.md', 'skills/sdlc/__pycache__/a.pyc',
              'skills/sdlc/.install-manifest.json', 'skills/sdlc/x.bak', 'skills/SDLC/SKILL.md',
              'commands/sdlc', 'skills/sdlc', 'skills/sdlc/local.BAK', 'skills/sdlc/Commands/old.md',
              'skills/sdlc/__PYCACHE__/x.py', 'skills/sdlc/.Install-Manifest.json']
        yes.append('skills/sdlc/commands')   # a regular FILE named commands is not a descendant (H3)
        for rel in yes:
            self.assertTrue(domain.in_domain(rel), rel)
        for rel in no:
            self.assertFalse(domain.in_domain(rel), rel)

    def test_sync_state_files_are_excluded(self):
        for rel in ('commands/sdlc/conflicts.log', '.sync-manifest.json'):
            self.assertTrue(domain.is_excluded(rel), rel)
            self.assertFalse(domain.in_domain(rel), rel)

    def test_skill_names(self):
        for ok in ('sdlc', 'sdlc-verify', 'sdlc-wave-orchestrator'):
            self.assertTrue(domain.is_valid_skill_name(ok), ok)
        for bad in ('../x', 'sdlc/../x', 'sdlc\\x', 'other', 'sdlc..', 'C:sdlc', '', None, 'sdlc-X',
                    'sdlcother', 'sdlc123', 'sdlc-', 'sdlc--x/'):
            self.assertFalse(domain.is_valid_skill_name(bad), bad)


class DomainOnDisk(TempDirCase):
    def test_walk_matches_rules(self):
        self.write('skills/sdlc/SKILL.md')
        self.write('skills/sdlc/commands/old.md')
        self.write('skills/other/SKILL.md')
        self.write('commands/sdlc/dev.md')
        self.write('agents/nested/sdlc-deep.md')
        self.write('agents/autre.md')
        self.write('skills/sdlc/_backups/old/SKILL.md')
        self.assertEqual(domain.domain_rels(self.tmp),
                         ['agents/nested/sdlc-deep.md', 'commands/sdlc/dev.md', 'skills/sdlc/SKILL.md'])


class DomainLinks(TempDirCase):
    """E1-02: a link or junction inside the domain is refused during discovery."""

    def test_linked_commands_dir_refused(self):
        import os
        from sdlc_installer.errors import SecurityError
        from tests.helpers import make_junction
        os.makedirs(os.path.join(self.tmp, 'src', 'commands'))
        os.makedirs(os.path.join(self.tmp, 'elsewhere'))
        self.write('elsewhere/dev.md')
        if not make_junction(os.path.join(self.tmp, 'src', 'commands', 'sdlc'), os.path.join(self.tmp, 'elsewhere')):
            self.skipTest('cannot create a junction here')
        with self.assertRaises(SecurityError):
            inventory.tree_inventory(os.path.join(self.tmp, 'src'))

    def test_linked_dir_inside_skill_refused(self):
        import os
        from sdlc_installer.errors import SecurityError
        from tests.helpers import make_junction
        self.write('src/skills/sdlc/SKILL.md')
        os.makedirs(os.path.join(self.tmp, 'elsewhere'))
        if not make_junction(os.path.join(self.tmp, 'src', 'skills', 'sdlc', 'sub'), os.path.join(self.tmp, 'elsewhere')):
            self.skipTest('cannot create a junction here')
        with self.assertRaises(SecurityError):
            domain.domain_rels(os.path.join(self.tmp, 'src'))


class DomainAncestors(TempDirCase):
    """E1-R2-01/02: links at domain ancestors are refused; the excluded H3 subtree is ignored."""

    def _junction_to_empty(self, rel):
        import os
        from tests.helpers import make_junction
        empty = os.path.join(self.tmp, 'empty-' + rel.replace('/', '-'))
        os.makedirs(empty)
        parent = os.path.join(self.tmp, 'src', *rel.split('/')[:-1])
        os.makedirs(parent, exist_ok=True)
        return make_junction(os.path.join(self.tmp, 'src', *rel.split('/')), empty)

    def test_skills_link_refused(self):
        import os
        from sdlc_installer.errors import SecurityError
        if not self._junction_to_empty('skills'):
            self.skipTest('cannot create a junction here')
        with self.assertRaises(SecurityError):
            inventory.tree_inventory(os.path.join(self.tmp, 'src'))

    def test_commands_link_refused(self):
        import os
        from sdlc_installer.errors import SecurityError
        if not self._junction_to_empty('commands'):
            self.skipTest('cannot create a junction here')
        with self.assertRaises(SecurityError):
            inventory.tree_inventory(os.path.join(self.tmp, 'src'))

    def test_h3_entry_link_refused_like_git(self):
        # Git cannot tell whether a link named skills/sdlc/commands is a file or a directory,
        # so both inventories refuse it (consistency, E1-R3-01/02).
        import os
        from sdlc_installer.errors import SecurityError
        from tests.helpers import make_junction
        self.write('src/skills/sdlc/SKILL.md')
        os.makedirs(os.path.join(self.tmp, 'elsewhere'))
        if not make_junction(os.path.join(self.tmp, 'src', 'skills', 'sdlc', 'commands'), os.path.join(self.tmp, 'elsewhere')):
            self.skipTest('cannot create a junction here')
        with self.assertRaises(SecurityError):
            inventory.tree_inventory(os.path.join(self.tmp, 'src'))

    def test_agents_subdir_junction_refused(self):
        import os
        from sdlc_installer.errors import SecurityError
        from tests.helpers import make_junction
        self.write('src/agents/sdlc-a.md')
        self.write('team/sdlc-review.md')
        if not make_junction(os.path.join(self.tmp, 'src', 'agents', 'team'), os.path.join(self.tmp, 'team')):
            self.skipTest('cannot create a junction here')
        with self.assertRaises(SecurityError):
            inventory.tree_inventory(os.path.join(self.tmp, 'src'))

    def test_bak_named_agent_link_refused(self):
        import os
        from sdlc_installer.errors import SecurityError
        from tests.helpers import make_junction
        self.write('src/agents/sdlc-a.md')
        self.write('team/sdlc-review.md')
        if not make_junction(os.path.join(self.tmp, 'src', 'agents', 'team.bak'), os.path.join(self.tmp, 'team')):
            self.skipTest('cannot create a junction here')
        with self.assertRaises(SecurityError):
            inventory.tree_inventory(os.path.join(self.tmp, 'src'))

    def test_source_root_junction_refused(self):
        import os
        from sdlc_installer.errors import SecurityError
        from tests.helpers import make_junction
        self.write('bundle/skills/sdlc/SKILL.md')
        if not make_junction(os.path.join(self.tmp, 'claude'), os.path.join(self.tmp, 'bundle')):
            self.skipTest('cannot create a junction here')
        with self.assertRaises(SecurityError):
            inventory.tree_inventory(os.path.join(self.tmp, 'claude'))
        self.assertEqual(domain.domain_rels(os.path.join(self.tmp, 'claude'), allow_root_link=True),
                         ['skills/sdlc/SKILL.md'])

    def test_exact_spelling_like_git(self):
        import os
        self.write('src/commands/SDLC/dev.md')
        self.write('src/Skills/sdlc/SKILL.md')
        self.assertEqual(domain.domain_rels(os.path.join(self.tmp, 'src')), [])

    def test_link_in_excluded_subtree_ignored(self):
        import os
        from tests.helpers import make_junction
        self.write('src/skills/sdlc/SKILL.md')
        os.makedirs(os.path.join(self.tmp, 'src', 'skills', 'sdlc', '_backups'))
        os.makedirs(os.path.join(self.tmp, 'elsewhere'))
        if not make_junction(os.path.join(self.tmp, 'src', 'skills', 'sdlc', '_backups', 'old'), os.path.join(self.tmp, 'elsewhere')):
            self.skipTest('cannot create a junction here')
        self.assertEqual(inventory.tree_inventory(os.path.join(self.tmp, 'src')), ['skills/sdlc/SKILL.md'])


class RealRepo(unittest.TestCase):
    def test_head_inventory_matches_tree(self):
        head = inventory.head_inventory(REPO)
        self.assertGreater(len(head), 100, 'R3-01: recursive HEAD inventory must list files')
        import os
        tree = inventory.tree_inventory(os.path.join(REPO, 'claude'))
        self.assertTrue(set(head) <= set(tree) | set(head))
        # every committed domain file is seen on disk unless deleted locally
        missing = [r for r in head if r not in tree]
        self.assertEqual(missing, [], 'committed files absent from the working tree: %s' % missing[:5])
