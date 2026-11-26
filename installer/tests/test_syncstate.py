"""syncstate: port of the Get-SyncState truth table, Get-FirstRunPlan and Resolve-LWW (test-sync-lib.ps1 e., i., bonus)."""
import os
import unittest

from sdlc_installer import syncstate as s
from sdlc_installer.errors import SecurityError, UsageError
from tests.helpers import TempDirCase, make_junction


class Classify(unittest.TestCase):
    def test_truth_table(self):
        rows = [
            ('x', 'x', 'x', s.IDENTICAL),
            ('x', 'x', None, s.IDENTICAL),
            ('r2', 'b', 'b', s.MODIFIED_REF),
            ('b', 'l2', 'b', s.MODIFIED_LIVE),
            ('r2', 'l2', 'b', s.MODIFIED_BOTH),
            ('r2', 'l2', None, s.MODIFIED_BOTH),
            (None, 'l', None, s.ADDED_LIVE),
            (None, 'b', 'b', s.DELETED_REF),
            (None, 'l2', 'b', s.CONFLICT_DELETED_REF),
            ('r', None, None, s.ADDED_REF),
            ('b', None, 'b', s.DELETED_LIVE),
            ('r2', None, 'b', s.CONFLICT_DELETED_LIVE),
            (None, None, 'b', s.ABSENT_BOTH),
            (None, None, None, s.ABSENT_BOTH),
        ]
        for ref, live, base, want in rows:
            self.assertEqual(s.classify(ref, live, base), want, (ref, live, base))

    def test_empty_string_is_absent(self):
        # read_sync_manifest gives '' for a null entry: absent, never a hash.
        self.assertEqual(s.classify('r', '', ''), s.ADDED_REF)
        self.assertEqual(s.classify('r2', 'l2', ''), s.MODIFIED_BOTH)

    def test_hashes_compared_without_case(self):
        self.assertEqual(s.classify('ABC', 'abc', None), s.IDENTICAL)
        self.assertEqual(s.classify('r2', 'L', 'l'), s.MODIFIED_REF)


class FirstRun(unittest.TestCase):
    def test_seed_block_adopt(self):
        same = {'a': '1', 'b': '2'}
        self.assertEqual(s.first_run_plan(same, dict(same)).signal, 'seed')
        # Presence asymmetry in both directions (test-sync-lib.sh: b only in the reference; x only in live).
        for ref, live, key in (({'a': '1', 'b': '2'}, {'a': '1'}, 'b'), ({'a': '1'}, {'a': '1', 'x': '9'}, 'x')):
            with self.subTest(key=key):
                asym = s.first_run_plan(ref, live)
                self.assertEqual((asym.signal, asym.mismatches), ('block', [key]))
                adopted = s.first_run_plan(ref, live, adopt=True)
                self.assertEqual((adopted.signal, adopted.adopted), ('seed', True))
        self.assertEqual(s.first_run_plan({'a': '1'}, {'a': '2'}).signal, 'block')

    def test_seed_prefers_the_reference(self):
        plan = s.first_run_plan({'a': '1'}, {'a': '2', 'x': '9'}, adopt=True)
        self.assertEqual(s.seed_entries(plan, {'a': '1'}, {'a': '2', 'x': '9'}), {'a': '1', 'x': '9'})


class Lww(TempDirCase):
    def test_default_winner_is_ref_and_logged(self):
        log = os.path.join(self.tmp, 'state', 'conflicts.log')
        res = s.resolve_lww('commands/sdlc/a.md', log, 'r', 'l')
        self.assertEqual((res.winner, res.logged), ('ref', True))
        res2 = s.resolve_lww('commands/sdlc/a.md', log, 'r', 'l', provenance='live')
        self.assertEqual(res2.winner, 'live')
        with open(log, 'rb') as fh:
            lines = fh.read().decode('utf-8').splitlines()
        self.assertEqual(len(lines), 2)                         # append only
        self.assertIn('relpath=commands/sdlc/a.md | ref=r | live=l | provenance=ref | winner=ref', lines[0])
        self.assertTrue(lines[1].endswith('provenance=live | winner=live'))

    def test_dry_run_writes_nothing(self):
        log = os.path.join(self.tmp, 'conflicts.log')
        self.assertFalse(s.resolve_lww('a', log, 'r', 'l', dry_run=True).logged)
        self.assertFalse(os.path.lexists(log))

    def test_bad_provenance(self):
        with self.assertRaises(UsageError):
            s.resolve_lww('a', os.path.join(self.tmp, 'c.log'), 'r', 'l', provenance='mtime')

    def test_log_link_refused(self):
        target = os.path.join(self.tmp, 'elsewhere')
        os.makedirs(target)
        link = os.path.join(self.tmp, 'conflicts.log')
        if not make_junction(link, target):
            self.skipTest('cannot create a junction or symlink here')
        with self.assertRaises(SecurityError):
            s.resolve_lww('a', link, 'r', 'l')
        self.assertEqual(os.listdir(target), [])


if __name__ == '__main__':
    unittest.main()
