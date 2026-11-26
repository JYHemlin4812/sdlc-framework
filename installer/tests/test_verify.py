"""verify (design §8.2): Python port of test-verify.sh / test-verify.ps1 (T1 to T9e) plus the unavailable cases."""
import os
import re

from sdlc_installer import domain, inventory
from sdlc_installer import verify as verify_mod
from tests.helpers import INSTALLER, REPO, TempDirCase
from tests.test_install import git, put, run_cli, snapshot

DOMAIN = {
    'skills/sdlc/SKILL.md': b'main skill\n',
    'skills/sdlc-wave-orchestrator/SKILL.md': b'wave orchestrator\n',
    'skills/sdlc-lang-dispatcher/SKILL.md': b'lang dispatcher\n',
    'commands/sdlc/brainstorm.md': b'brainstorm cmd\n',
    'commands/sdlc/plan.md': b'plan cmd\n',
    'agents/sdlc-python.md': b'python agent\n',
    'agents/sdlc-js.md': b'js agent\n',
}
REF_ONLY = {
    'skills/sdlc/commands/embedded.md': b'stale embedded command\n',
    'skills/other-thirdparty/SKILL.md': b'third-party skill\n',
    'skills/sdlc-standalone.md': b'loose 2-segment sdlc file\n',
    'README.md': b'outside the domain\n',
    'OTHER.md': b'arbitrary root file\n',
}


class Verify(TempDirCase):
    def setUp(self):
        super().setUp()
        self.ref = os.path.join(self.tmp, 'ref')
        self.live = os.path.join(self.tmp, 'live')
        for rel, data in list(DOMAIN.items()) + list(REF_ONLY.items()):
            put(os.path.join(self.ref, 'claude'), rel, data)
        git(self.ref, 'init', '-q')
        for k, v in (('user.email', 't@t'), ('user.name', 't'), ('commit.gpgsign', 'false'),
                     ('core.autocrlf', 'false')):
            git(self.ref, 'config', k, v)
        git(self.ref, 'add', '-A')
        git(self.ref, 'commit', '-q', '-m', 'seed ref')
        for rel, data in DOMAIN.items():
            put(self.live, rel, data)

    def code(self):
        return verify_mod.verify(self.ref, self.live).code

    def test_t1_identical(self):
        self.assertEqual(self.code(), 0)

    def test_t2_read_only(self):
        before = (snapshot(self.ref), snapshot(self.live))
        self.assertEqual(run_cli(['verify', '--ref', self.ref, '--live', self.live])[0], 0)
        self.assertEqual((snapshot(self.ref), snapshot(self.live)), before)

    def test_t3_committed_head_not_working_tree(self):
        put(os.path.join(self.ref, 'claude'), 'skills/sdlc/SKILL.md', b'WORKING TREE MODIFIED\n')
        self.assertEqual(self.code(), 0)

    def test_t4_pyc_ignored(self):
        put(self.live, 'skills/sdlc/__pycache__/mod.pyc', b'bytecode')
        put(self.live, 'skills/sdlc/leftover.pyc', b'bytecode2')
        self.assertEqual(self.code(), 0)

    def test_t5_floors_derived(self):
        with open(os.path.join(INSTALLER, 'sdlc_installer', 'verify.py'), encoding='utf-8') as fh:
            src = fh.read()
        self.assertIsNone(re.search(r'\b1[028]\b', src))
        put(self.live, 'agents/sdlc-extra.md', b'x\n')
        self.assertIn('agents: floor=2 live=3', verify_mod.verify(self.ref, self.live).floor)

    def test_t6_differences(self):
        os.remove(os.path.join(self.live, 'agents', 'sdlc-python.md'))
        res = verify_mod.verify(self.ref, self.live)
        self.assertEqual((res.code, res.missing), (1, ['agents/sdlc-python.md']))
        put(self.live, 'agents/sdlc-python.md', DOMAIN['agents/sdlc-python.md'])
        put(self.live, 'commands/sdlc/plan.md', b'DIVERGENT\n')
        res = verify_mod.verify(self.ref, self.live)
        self.assertEqual((res.code, res.hash_diff), (1, ['commands/sdlc/plan.md']))
        put(self.live, 'commands/sdlc/plan.md', DOMAIN['commands/sdlc/plan.md'])
        put(self.live, 'skills/sdlc/EXTRA.md', b'real extra\n')
        res = verify_mod.verify(self.ref, self.live)
        self.assertEqual((res.code, res.extra), (1, ['skills/sdlc/EXTRA.md']))
        code, out = run_cli(['verify', '--ref', self.ref, '--live', self.live])
        self.assertEqual(code, 1)
        self.assertIn('[EXTRA]', out)

    def test_s9a_cli_prints_hash_diff_marker(self):
        put(self.live, 'commands/sdlc/plan.md', b'REWRITTEN\n')
        code, out = run_cli(['verify', '--ref', self.ref, '--live', self.live])
        self.assertEqual(code, 1)
        self.assertIn('[HASH DIFF]', out)
        self.assertNotIn('[MISSING]', out)

    def test_s9b_cli_prints_missing_marker_alone(self):
        # S9b (sync-bdd.tests.ps1): from an identical live, one deleted file is the only difference.
        os.remove(os.path.join(self.live, 'agents', 'sdlc-js.md'))
        code, out = run_cli(['verify', '--ref', self.ref, '--live', self.live])
        self.assertEqual(code, 1)
        self.assertIn('[MISSING]', out)
        self.assertNotIn('[HASH DIFF]', out)

    def test_p4_real_head_inventory_cardinalities(self):
        # (skills, agents, commands) read from HEAD, not from the working tree.
        self.assertEqual(verify_mod.cardinalities(inventory.head_inventory(REPO)), (14, 12, 19))

    def test_t7_third_party_ignored(self):
        put(self.live, 'skills/my-personal-skill/SKILL.md', b'third-party\n')
        put(self.live, 'agents/other-agent.md', b'third-party agent\n')
        self.assertEqual(self.code(), 0)

    def test_t8_t9e_domain_projection(self):
        self.assertFalse(domain.in_domain('skills/sdlc-standalone.md'))
        self.assertTrue(domain.in_domain('skills/sdlc/SKILL.md'))
        self.assertFalse(domain.in_domain('agents/SDLC-py.md'))
        self.assertFalse(domain.in_domain('skills/SDLC-x/SKILL.md'))

    def test_unavailable_gives_2(self):
        self.assertEqual(verify_mod.verify(self.ref, os.path.join(self.tmp, 'missing')).code, 2)
        plain = os.path.join(self.tmp, 'plain')
        os.makedirs(plain)
        self.assertEqual(verify_mod.verify(plain, self.live).code, 2)
        empty = os.path.join(self.tmp, 'empty-repo')
        os.makedirs(empty)
        git(empty, 'init', '-q')
        self.assertEqual(verify_mod.verify(empty, self.live).code, 2)

    def test_n2_reference_without_domain_files_gives_2(self):
        # N2 (sync-bdd.tests.ps1): the scripts gave a vacuous 0; decision JYH 2026-11-26: unavailable (2).
        bare = os.path.join(self.tmp, 'bare-ref')
        put(os.path.join(bare, 'claude'), 'README.md', b'outside the domain\n')
        git(bare, 'init', '-q')
        for k, v in (('user.email', 't@t'), ('user.name', 't'), ('commit.gpgsign', 'false')):
            git(bare, 'config', k, v)
        git(bare, 'add', '-A')
        git(bare, 'commit', '-q', '-m', 'no domain')
        empty_live = os.path.join(self.tmp, 'empty-live')
        os.makedirs(empty_live)
        res = verify_mod.verify(bare, empty_live)
        self.assertEqual(res.code, 2)
        self.assertIn('no file of the SDLC domain', res.reason)
        code, out = run_cli(['verify', '--ref', bare, '--live', empty_live])
        self.assertEqual(code, 2)
        self.assertIn('verify unavailable', out)

    def test_e3_r2_05_same_or_nested_roots_give_2(self):
        for live in (os.path.join(self.ref, 'claude'), os.path.join(self.ref, 'claude', 'skills'), self.ref):
            with self.subTest(live=live):
                self.assertEqual(verify_mod.verify(self.ref, live).code, 2)

    def test_e3_r3_04_ref_must_be_the_worktree_root(self):
        sub = os.path.join(self.ref, 'claude', 'skills')
        empty_live = os.path.join(self.tmp, 'empty-live')
        os.makedirs(empty_live)
        self.assertEqual(verify_mod.verify(sub, empty_live).code, 2)
        self.assertEqual(verify_mod.verify(self.ref, empty_live, subdir='missing').code, 2)

    def test_index_not_rewritten(self):
        index = os.path.join(self.ref, '.git', 'index')
        os.utime(index, (1, 1))
        with open(index, 'rb') as fh:
            before = fh.read()
        self.assertEqual(self.code(), 0)
        with open(index, 'rb') as fh:
            self.assertEqual(fh.read(), before)
        self.assertEqual(int(os.stat(index).st_mtime), 1)
