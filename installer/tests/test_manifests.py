import json
import os
import shutil
import tempfile
import unittest

from sdlc_installer import domain, manifests
from sdlc_installer.errors import SecurityError, UsageError
from sdlc_installer.manifests import CorruptRegistry
from tests import legacy_fixtures as lf
from tests.helpers import TempDirCase, make_junction

HASH_A = 'a' * 64
HASH_B = 'b' * 64


def _registry_path(live):
    return os.path.join(live, 'skills', 'sdlc', '.install-manifest.json')


class RealInstalls(unittest.TestCase):
    """Registries written by the REAL old scripts (design §4 point 1)."""

    def build(self, commit, shell):
        tmp = tempfile.mkdtemp(prefix='sdlc-inst-fix-')
        self.addCleanup(shutil.rmtree, tmp, True)
        repo = lf.make_repo(tmp, commit)
        live = os.path.join(tmp, 'live')
        lf.install_with(shell, repo, live)
        rels = domain.domain_rels(os.path.join(repo, 'claude'))
        return repo, live, manifests.tree_hashes(os.path.join(repo, 'claude'), rels)

    @unittest.skipUnless(lf.BASH and lf.commit_exists(lf.OLD_COMMIT), 'needs bash and commit 667d7ed')
    def test_origin_main_format_aggregate_only(self):
        """PYI-02: the 667d7ed install.sh writes the aggregate and no file_hashes."""
        repo, live, src = self.build(lf.OLD_COMMIT, 'sh')
        reg = manifests.read_install_registry(live)
        self.assertIsNone(reg.file_hashes)
        self.assertCountEqual(reg.skills, ['sdlc', 'sdlc-verify'])
        self.assertFalse(reg.skills_derived)
        self.assertEqual(reg.warnings, [])
        self.assertEqual(reg.checksum, manifests.aggregate_checksum(src, 'ordinal'))
        self.assertTrue(manifests.aggregate_matches(reg.checksum, src))

    @unittest.skipUnless(lf.BASH, 'needs bash')
    def test_current_sh_format_with_file_hashes(self):
        repo, live, src = self.build('HEAD', 'sh')
        reg = manifests.read_install_registry(live)
        self.assertEqual(reg.file_hashes, src)
        self.assertEqual(reg.checksum, manifests.aggregate_checksum(src, 'ordinal'))
        self.assertCountEqual(reg.skills, ['sdlc', 'sdlc-verify'])

    @unittest.skipUnless(lf.PWSH, 'needs pwsh')
    def test_current_ps_format_sorts_case_insensitively(self):
        """install.ps1 sorts with Sort-Object, install.sh with LC_ALL=C: two aggregates for one tree."""
        repo, live, src = self.build('HEAD', 'ps')
        reg = manifests.read_install_registry(live)
        self.assertEqual(reg.file_hashes, src)
        self.assertEqual(reg.checksum, manifests.aggregate_checksum(src, 'casefold'))
        self.assertNotEqual(reg.checksum, manifests.aggregate_checksum(src, 'ordinal'))
        self.assertTrue(manifests.aggregate_matches(reg.checksum, src))


class Matches(unittest.TestCase):
    def reg(self, hashes, checksum):
        return manifests.InstallRegistry('1', ['sdlc'], False, checksum, hashes, None, {}, [])

    def test_file_hashes_are_compared_without_any_ordering(self):
        """E2-R1-08: non-ASCII names sort differently in PowerShell (culture); per-file comparison is exact."""
        src = {'agents/sdlc-z.md': HASH_A, 'agents/sdlc-' + chr(0xe9) + '.md': HASH_B}
        reg = self.reg(dict(src), 'f' * 64)              # aggregate irrelevant when file_hashes exist
        self.assertTrue(manifests.registry_matches_source(reg, src))
        changed = dict(src, **{'agents/sdlc-z.md': HASH_B})
        self.assertFalse(manifests.registry_matches_source(reg, changed))
        self.assertFalse(manifests.registry_matches_source(reg, {'agents/sdlc-z.md': HASH_A}))

    def test_aggregate_only_registry_uses_the_aggregate(self):
        src = {'skills/sdlc/SKILL.md': HASH_A, 'skills/sdlc/scripts/run.py': HASH_B}
        reg = self.reg(None, manifests.aggregate_checksum(src, 'casefold'))
        self.assertTrue(manifests.registry_matches_source(reg, src))
        self.assertFalse(manifests.registry_matches_source(reg, {'skills/sdlc/SKILL.md': HASH_B}))


class Aggregate(unittest.TestCase):
    def test_orders_differ_and_both_are_accepted(self):
        h = {'skills/sdlc/SKILL.md': HASH_A, 'skills/sdlc/scripts/run.py': HASH_B}
        ordinal = manifests.aggregate_checksum(h, 'ordinal')
        folded = manifests.aggregate_checksum(h, 'casefold')
        self.assertNotEqual(ordinal, folded)
        self.assertTrue(manifests.aggregate_matches(ordinal, h))
        self.assertTrue(manifests.aggregate_matches(folded.upper(), h))
        self.assertFalse(manifests.aggregate_matches('0' * 64, h))
        self.assertFalse(manifests.aggregate_matches(None, h))
        self.assertFalse(manifests.aggregate_matches('nothex', h))

    def test_empty(self):
        self.assertEqual(manifests.aggregate_checksum({}), manifests.sha256_hex(b''))


class ReadRegistry(TempDirCase):
    def put(self, doc, raw=None):
        if doc is not None:
            doc = dict({'checksum_sha256': HASH_A}, **doc)
        path = _registry_path(self.tmp)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as fh:
            fh.write(raw if raw is not None else json.dumps(doc).encode('utf-8'))

    def test_absent(self):
        self.assertIsNone(manifests.read_install_registry(self.tmp))

    def test_corrupt_is_usage_error(self):
        for raw in (b'{ not json', b'', b'[1]', b'\xff\xfe\x00'):
            self.put(None, raw)
            with self.assertRaises(CorruptRegistry) as ctx:
                manifests.read_install_registry(self.tmp)
            self.assertEqual(ctx.exception.code, 2)
        self.assertTrue(issubclass(CorruptRegistry, UsageError))

    def test_bad_checksum_and_file_hashes_are_corrupt(self):
        for doc in ({'checksum_sha256': 'xyz', 'skills': []},
                    {'checksum_sha256': None, 'skills': []},
                    {'skills': [], 'file_hashes': [1]},
                    {'skills': [], 'file_hashes': {'skills/sdlc/a': 'short'}}):
            self.put(doc)
            with self.assertRaises(CorruptRegistry):
                manifests.read_install_registry(self.tmp)

    def test_unsafe_skill_name_is_security_error(self):
        """R3-02: a skill name from the registry is one component, sdlc or sdlc-*."""
        for name in ('../x', 'sdlc/../x', 'sdlc\\x', 'other', 'sdlc-', 'sdlc.x', ''):
            self.put({'skills': ['sdlc', name]})
            with self.assertRaises(SecurityError, msg=name) as ctx:
                manifests.read_install_registry(self.tmp)
            self.assertEqual(ctx.exception.code, 3)

    def test_registry_without_an_aggregate_proves_nothing(self):
        """E2-R1-02: both historical formats carry checksum_sha256; {} must not open the legacy uninstall path."""
        for raw in (b'{}', b'{"skills": ["sdlc"]}', b'{"version": "3.2.0"}'):
            self.put(None, raw)
            with self.assertRaises(CorruptRegistry, msg=raw):
                manifests.read_install_registry(self.tmp)

    def test_file_hashes_null_is_corrupt_absent_is_legacy_empty_is_empty(self):
        """E2-R1-01: absent key = legacy (None); present key must be an object, an empty one included."""
        self.put({'skills': ['sdlc']})
        self.assertIsNone(manifests.read_install_registry(self.tmp).file_hashes)
        self.put({'skills': ['sdlc'], 'file_hashes': {}})
        self.assertEqual(manifests.read_install_registry(self.tmp).file_hashes, {})
        self.put({'skills': ['sdlc'], 'file_hashes': None})
        with self.assertRaises(CorruptRegistry):
            manifests.read_install_registry(self.tmp)

    def test_skills_key_present_but_not_a_list_is_corrupt_never_derived(self):
        """E2-R2-01: only an ABSENT key is derived; a string or null next to a personal skill is refused."""
        self.write('skills/sdlc-perso/SKILL.md', b'---\nname: sdlc-perso\n---\n')
        for value in ('sdlc', None, {'a': 1}, 3):
            self.put({'skills': value})
            with self.assertRaises(CorruptRegistry, msg=repr(value)):
                manifests.read_install_registry(self.tmp)

    def test_field_names_are_read_without_case_like_powershell(self):
        """E2-R2-02: 'File_Hashes' is file_hashes (never None => never the legacy remove-everything path)."""
        self.put({'skills': ['sdlc'], 'File_Hashes': {'agents/sdlc-x.md': HASH_B}, 'Checksum_SHA256': HASH_A})
        os.remove(_registry_path(self.tmp))
        self.put(None, json.dumps({'Skills': ['sdlc'], 'File_Hashes': {'agents/sdlc-x.md': HASH_B},
                                   'Checksum_SHA256': HASH_A}).encode())
        reg = manifests.read_install_registry(self.tmp)
        self.assertEqual(reg.file_hashes, {'agents/sdlc-x.md': HASH_B})
        self.assertEqual(reg.skills, ['sdlc'])
        self.assertEqual(reg.checksum, HASH_A)
        self.put(None, json.dumps({'file_hashes': {}, 'FILE_HASHES': {}, 'skills': ['sdlc'],
                                   'checksum_sha256': HASH_A}).encode())
        with self.assertRaises(CorruptRegistry):                      # same field spelled twice: ambiguous
            manifests.read_install_registry(self.tmp)

    def test_mixed_skills_list_is_refused_not_derived(self):
        """E2-R1-07: one bad element refuses the whole list, whatever else it holds."""
        for skills in (['../x', None], [None, '../x'], ['sdlc', 7], ['sdlc', None]):
            self.put({'skills': skills})
            with self.assertRaises(SecurityError, msg=repr(skills)):
                manifests.read_install_registry(self.tmp)

    def test_unsafe_file_hashes_key_is_security_error(self):
        self.put({'skills': ['sdlc'], 'file_hashes': {'../x': HASH_A}})
        with self.assertRaises(SecurityError):
            manifests.read_install_registry(self.tmp)

    def test_missing_skills_derived_from_disk_with_warning(self):
        """R3-04: unknown schema, skills derived from skills/sdlc* whose SKILL.md name starts with sdlc."""
        self.write('skills/sdlc/SKILL.md', b'---\nname: sdlc\n---\n')
        self.write('skills/sdlc-b/SKILL.md', b'---\nname: sdlc-b\n---\n')
        self.write('skills/sdlc-mine/SKILL.md', b'---\nname: mine\n---\n')      # third party under the prefix
        self.write('skills/sdlc_bad/SKILL.md', b'---\nname: sdlc_bad\n---\n')   # not a valid name
        self.write('skills/other/SKILL.md', b'---\nname: sdlc-x\n---\n')
        self.put({'version': '1', 'checksum_sha256': HASH_A})
        reg = manifests.read_install_registry(self.tmp)
        self.assertEqual(reg.skills, ['sdlc', 'sdlc-b'])
        self.assertTrue(reg.skills_derived)
        self.assertEqual(len(reg.warnings), 2)

    def test_registry_with_non_json_constant_or_deep_nesting_is_corrupt(self):
        """E2-R4-04, E2-R4-05: even with a valid aggregate and skills, NaN or nesting is not a registry."""
        good = b'{"checksum_sha256": "' + HASH_A.encode() + b'", "skills": ["sdlc"], "x": '
        for tail in (b'NaN}', b'Infinity}'):
            self.put(None, good + tail)
            with self.assertRaises(CorruptRegistry):
                manifests.read_install_registry(self.tmp)
        # deep nesting: CPython on Windows raises RecursionError (mapped to corrupt), on Linux it parses it;
        # either way the reader must not let RecursionError escape.
        self.put(None, good + b'[' * 5000 + b']' * 5000 + b'}')
        try:
            manifests.read_install_registry(self.tmp)
        except CorruptRegistry:
            pass

    def test_plain_file_next_to_skill_folders_does_not_break_derivation(self):
        """E2-R4-06."""
        self.write('skills/sdlc-notes', b'just a file')
        self.write('skills/sdlc/SKILL.md', b'---\nname: sdlc\n---\n')
        self.put({'version': '1'})
        self.assertEqual(manifests.read_install_registry(self.tmp).skills, ['sdlc'])

    def test_derived_skills_never_read_through_a_link(self):
        """E2-R1-03: a sibling skills/sdlc-extra junction to an outside folder is refused (code 3)."""
        outside = os.path.join(self.tmp, 'outside')
        os.makedirs(outside)
        with open(os.path.join(outside, 'SKILL.md'), 'wb') as fh:
            fh.write(b'---\nname: sdlc-extra\n---\n')
        os.makedirs(os.path.join(self.tmp, 'skills'))
        if not make_junction(os.path.join(self.tmp, 'skills', 'sdlc-extra'), outside):
            self.skipTest('cannot create a junction here')
        self.put({'version': '1'})
        with self.assertRaises(SecurityError) as ctx:
            manifests.read_install_registry(self.tmp)
        self.assertEqual(ctx.exception.code, 3)

    def test_file_hashes_key_through_a_link_is_refused(self):
        """E2-R1-06: the physical parent chain of every key is checked, not only its spelling."""
        outside = os.path.join(self.tmp, 'outside')
        os.makedirs(outside)
        os.makedirs(os.path.join(self.tmp, 'skills'))
        if not make_junction(os.path.join(self.tmp, 'skills', 'sdlc-extra'), outside):
            self.skipTest('cannot create a junction here')
        self.put({'skills': ['sdlc'], 'file_hashes': {'skills/sdlc-extra/a.md': HASH_A}})
        with self.assertRaises(SecurityError):
            manifests.read_install_registry(self.tmp)
        # and a writer never records such a key (registry left byte for byte identical)
        self.put({'skills': ['sdlc'], 'file_hashes': {'agents/sdlc-x.md': HASH_A}})
        with open(_registry_path(self.tmp), 'rb') as fh:
            before = fh.read()
        with self.assertRaises(SecurityError):
            manifests.update_file_hashes(self.tmp, {'skills/sdlc-extra/a.md': HASH_B})
        with self.assertRaises(SecurityError):
            manifests.write_install_registry(self.tmp, '1', ['sdlc'], {'skills/sdlc-extra/a.md': HASH_B})
        with open(_registry_path(self.tmp), 'rb') as fh:
            self.assertEqual(fh.read(), before)

    def test_bom_and_uppercase_hash_accepted(self):
        self.put(None, b'\xef\xbb\xbf' + json.dumps(
            {'version': '3.2.0', 'skills': ['sdlc'], 'checksum_sha256': HASH_A.upper(),
             'file_hashes': {'skills/sdlc/SKILL.md': HASH_B.upper()}}).encode())
        reg = manifests.read_install_registry(self.tmp)
        self.assertEqual(reg.checksum, HASH_A)
        self.assertEqual(reg.file_hashes, {'skills/sdlc/SKILL.md': HASH_B})
        self.assertEqual(reg.version, '3.2.0')


class WriteRegistry(TempDirCase):
    def test_round_trip(self):
        hashes = {'skills/sdlc/SKILL.md': HASH_A, 'agents/sdlc-x.md': HASH_B}
        manifests.write_install_registry(self.tmp, '4.0.0', ['sdlc'], hashes, source='C:\\a\\claude',
                                         source_commit='abc', commands_count=3, agents_count=1)
        reg = manifests.read_install_registry(self.tmp)
        self.assertEqual(reg.file_hashes, hashes)
        self.assertEqual(reg.skills, ['sdlc'])
        self.assertEqual(reg.source_commit, 'abc')
        self.assertTrue(manifests.aggregate_matches(reg.checksum, hashes))
        self.assertEqual(reg.raw['source'], 'C:/a/claude')
        self.assertEqual(reg.raw['files_count'], 2)
        self.assertEqual(reg.raw['installer'], 'install.py')
        with open(_registry_path(self.tmp), 'rb') as fh:
            self.assertFalse(fh.read().startswith(b'\xef\xbb\xbf'))

    def test_refuses_unsafe_input_before_writing(self):
        with self.assertRaises(SecurityError):
            manifests.write_install_registry(self.tmp, '1', ['../x'], {})
        with self.assertRaises(SecurityError):
            manifests.write_install_registry(self.tmp, '1', ['sdlc'], {'../x': HASH_A})
        self.assertFalse(os.path.exists(_registry_path(self.tmp)))

    def test_update_file_hashes_adds_and_keeps_other_fields(self):
        manifests.write_install_registry(self.tmp, '4.0.0', ['sdlc'], {'agents/sdlc-x.md': HASH_A},
                                         source_commit='abc')
        before = manifests.read_install_registry(self.tmp)
        self.assertTrue(manifests.update_file_hashes(
            self.tmp, {'agents/sdlc-x.md': HASH_B, 'agents/sdlc-y.md': HASH_A}))
        after = manifests.read_install_registry(self.tmp)
        self.assertEqual(after.file_hashes, {'agents/sdlc-x.md': HASH_B, 'agents/sdlc-y.md': HASH_A})
        self.assertEqual(after.checksum, before.checksum)
        self.assertEqual(after.source_commit, 'abc')
        self.assertEqual(after.raw['files_count'], 2)

    def test_update_file_hashes_never_creates_a_registry(self):
        """§4 point 1: without an install registry, restore creates none."""
        self.assertFalse(manifests.update_file_hashes(self.tmp, {'agents/sdlc-x.md': HASH_A}))
        self.assertFalse(os.path.exists(_registry_path(self.tmp)))

    def test_update_file_hashes_leaves_a_legacy_registry_alone(self):
        path = _registry_path(self.tmp)
        os.makedirs(os.path.dirname(path))
        body = json.dumps({'version': '3.2.0', 'skills': ['sdlc'], 'checksum_sha256': HASH_A}).encode()
        with open(path, 'wb') as fh:
            fh.write(body)
        self.assertFalse(manifests.update_file_hashes(self.tmp, {'agents/sdlc-x.md': HASH_B}))
        with open(path, 'rb') as fh:
            self.assertEqual(fh.read(), body)

    def test_restore_trace_keeps_the_skills_list_current(self):
        """E2-R2-03: install A (sdlc), restore B (adds sdlc-extra): the snapshot must not claim 'up to date'."""
        a = {'skills/sdlc/SKILL.md': HASH_A}
        b = {'skills/sdlc/SKILL.md': HASH_A, 'skills/sdlc-extra/SKILL.md': HASH_B}
        manifests.write_install_registry(self.tmp, '4.0.0', ['sdlc'], a)
        self.assertTrue(manifests.registry_matches_source(manifests.read_install_registry(self.tmp), a))
        manifests.update_file_hashes(self.tmp, {'skills/sdlc-extra/SKILL.md': HASH_B})
        stale = manifests.read_install_registry(self.tmp)
        self.assertEqual(stale.file_hashes, b)
        self.assertTrue(stale.restored)
        self.assertFalse(manifests.registry_matches_source(stale, b))                     # E2-R3-01: never 'up to date'
        self.assertFalse(manifests.registry_matches_source(stale, b, skills=['sdlc', 'sdlc-extra']))
        manifests.update_file_hashes(self.tmp, {'skills/sdlc-extra/SKILL.md': HASH_B}, skills=['sdlc', 'sdlc-extra'])
        fresh = manifests.read_install_registry(self.tmp)
        self.assertEqual(fresh.skills, ['sdlc', 'sdlc-extra'])
        self.assertFalse(manifests.registry_matches_source(fresh, b, skills=['sdlc-extra', 'sdlc']))
        # only install rewrites the snapshot (and so clears the mark): then 'up to date' is true again
        manifests.write_install_registry(self.tmp, '4.0.1', ['sdlc', 'sdlc-extra'], b)
        again = manifests.read_install_registry(self.tmp)
        self.assertFalse(again.restored)
        self.assertTrue(manifests.registry_matches_source(again, b, skills=['sdlc-extra', 'sdlc']))
        with self.assertRaises(SecurityError):
            manifests.update_file_hashes(self.tmp, {'skills/sdlc/SKILL.md': HASH_A}, skills=['../x'])

    def test_content_only_change_after_restore_is_not_up_to_date(self):
        """E2-R3-01: restore B changes only the content of an existing file; skills list is constant."""
        manifests.write_install_registry(self.tmp, '4.0.0', ['sdlc'], {'skills/sdlc/SKILL.md': HASH_A})
        manifests.update_file_hashes(self.tmp, {'skills/sdlc/SKILL.md': HASH_B})
        reg = manifests.read_install_registry(self.tmp)
        self.assertFalse(manifests.registry_matches_source(reg, {'skills/sdlc/SKILL.md': HASH_B}, skills=['sdlc']))

    @unittest.skipUnless(hasattr(os, 'mkfifo'), 'needs POSIX FIFOs')
    def test_fifo_registry_never_blocks(self):
        """E2-R3-07: a FIFO in place of the registry is corrupt, not an endless wait."""
        path = _registry_path(self.tmp)
        os.makedirs(os.path.dirname(path))
        os.mkfifo(path)
        with self.assertRaises(CorruptRegistry):
            manifests.read_install_registry(self.tmp)

    def test_update_keeps_a_registry_readable(self):
        """E2-R2-04: the MERGED key set is checked and the registry stays readable. E5-R1-05: a key spelled like an
        updated one apart from case is superseded (one file on a case-insensitive filesystem); a file on disk
        spelled differently from the update is still refused, bytes kept."""
        manifests.write_install_registry(self.tmp, '4.0.0', ['sdlc'], {'agents/sdlc-A.md': HASH_A})
        self.assertTrue(manifests.update_file_hashes(self.tmp, {'agents/sdlc-a.md': HASH_B}))
        self.assertEqual(manifests.read_install_registry(self.tmp).file_hashes, {'agents/sdlc-a.md': HASH_B})
        manifests.write_install_registry(self.tmp, '4.0.0', ['sdlc'], {'agents/sdlc-A.md': HASH_A})
        os.makedirs(os.path.join(self.tmp, 'agents'), exist_ok=True)
        with open(os.path.join(self.tmp, 'agents', 'sdlc-A.md'), 'wb') as fh:
            fh.write(b'A\n')
        with open(_registry_path(self.tmp), 'rb') as fh:
            before = fh.read()
        if os.path.exists(os.path.join(self.tmp, 'agents', 'sdlc-a.md')):      # case-insensitive filesystem
            with self.assertRaises(SecurityError):
                manifests.update_file_hashes(self.tmp, {'agents/sdlc-a.md': HASH_B})
            with open(_registry_path(self.tmp), 'rb') as fh:
                self.assertEqual(fh.read(), before)
        self.assertIsNotNone(manifests.read_install_registry(self.tmp))

    def test_update_refuses_unsafe_key(self):
        with self.assertRaises(SecurityError):
            manifests.update_file_hashes(self.tmp, {'../x': HASH_A})


class SyncManifest(TempDirCase):
    def path(self):
        return os.path.join(self.tmp, '.sync-manifest.json')

    def put(self, raw):
        with open(self.path(), 'wb') as fh:
            fh.write(raw)

    def test_missing_is_first_run_not_fail_closed(self):
        m = manifests.read_sync_manifest(self.path())
        self.assertEqual((m.ok, m.exists, m.fail_closed, m.entries), (False, False, False, {}))

    def test_fail_closed_cases(self):
        """H4: anything unreadable gives an empty base, never 'identical by default'."""
        for raw in (b'', b'   \n', b'{ "entries": ', b'[1]', b'null', b'{"version": "SP2"}',
                    b'{"entries": [1, 2]}', b'{"entries": "x"}', b'\xff\xfe'):
            self.put(raw)
            m = manifests.read_sync_manifest(self.path())
            self.assertEqual((m.ok, m.exists, m.fail_closed, m.entries), (False, True, True, {}), raw)

    def test_sentinels_are_fresh_objects(self):
        """E2-R1-13: mutating a result must not change the next fail-closed or first-run base."""
        first = manifests.read_sync_manifest(self.path())
        first.entries['x'] = HASH_A
        first.domains.append('x')
        self.assertEqual(manifests.read_sync_manifest(self.path()).entries, {})
        self.assertEqual(manifests.read_sync_manifest(self.path()).domains, [])
        self.put(b'')
        bad = manifests.read_sync_manifest(self.path())
        bad.entries['y'] = HASH_A
        self.assertEqual(manifests.read_sync_manifest(self.path()).entries, {})

    def test_field_names_without_case_but_paths_keep_theirs(self):
        """E2-R3-05: PowerShell -contains finds 'Entries'; the spelling of the paths inside is untouched."""
        self.put(json.dumps({'Version': 'SP2', 'Entries': {'Agents/Sdlc-X.md': HASH_A}}).encode())
        m = manifests.read_sync_manifest(self.path())
        self.assertTrue(m.ok)
        self.assertEqual(m.entries, {'Agents/Sdlc-X.md': HASH_A})
        self.assertEqual(m.version, 'SP2')
        self.put(json.dumps({'entries': {}, 'ENTRIES': {}}).encode())          # same name twice: ambiguous
        self.assertTrue(manifests.read_sync_manifest(self.path()).fail_closed)

    @unittest.skipUnless(hasattr(os, 'mkfifo'), 'needs POSIX FIFOs')
    def test_fifo_sync_manifest_fails_closed_without_blocking(self):
        os.mkfifo(self.path())
        self.assertTrue(manifests.read_sync_manifest(self.path()).fail_closed)

    def test_individual_null_entry_is_an_empty_string(self):
        """E2-R4-03: [string]$null is '' in PowerShell, never 'None'."""
        self.put(b'{"entries": {"commands/sdlc/dev.md": null, "a": 5}}')
        self.assertEqual(manifests.read_sync_manifest(self.path()).entries, {'commands/sdlc/dev.md': '', 'a': '5'})

    def test_non_json_constants_and_deep_nesting_fail_closed(self):
        """E2-R4-04, E2-R4-05."""
        for raw in (b'{"entries": {}, "x": NaN}', b'{"entries": {}, "x": Infinity}'):
            self.put(raw)
            self.assertTrue(manifests.read_sync_manifest(self.path()).fail_closed, raw[:40])
        self.put(b'{"entries": {}, "x": ' + b'[' * 5000 + b']' * 5000 + b'}')   # Windows: fail closed; Linux: parsed
        manifests.read_sync_manifest(self.path())                                # must simply not raise

    def test_linked_manifest_is_never_read_or_written(self):
        """E2-R4-01: a link as the file, or a junction above it, is refused (fail closed / code 3)."""
        real = os.path.join(self.tmp, 'real')
        os.makedirs(real)
        with open(os.path.join(real, '.sync-manifest.json'), 'wb') as fh:
            fh.write(b'{"entries": {"a/b": "' + HASH_A.encode() + b'"}}')
        live = os.path.join(self.tmp, 'live')
        if not make_junction(live, real):
            self.skipTest('cannot create a junction here')
        # the live root itself may be a link (§5.2 point 3): reading below it is fine
        self.assertTrue(manifests.read_sync_manifest(os.path.join(live, '.sync-manifest.json'), root=live).ok)
        sub = os.path.join(self.tmp, 'live2')
        os.makedirs(sub)
        os.makedirs(os.path.join(self.tmp, 'out'))
        if not make_junction(os.path.join(sub, 'state'), os.path.join(self.tmp, 'out')):
            self.skipTest('cannot create a junction here')
        target = os.path.join(sub, 'state', '.sync-manifest.json')
        with self.assertRaises(SecurityError):
            manifests.write_sync_manifest(target, {'a/b': HASH_A}, root=sub)
        self.assertEqual(os.listdir(os.path.join(self.tmp, 'out')), [])
        self.assertTrue(manifests.read_sync_manifest(target, root=sub).fail_closed)   # E2-R5-03: forbidden, not a first run

    def test_array_values_and_scalar_domains_follow_powershell(self):
        """E2-R5-04, E2-R5-05."""
        self.put(json.dumps({'entries': {'a': [], 'b': [HASH_A], 'c': {'x': 1}}, 'domains': 'skills/sdlc*'}).encode())
        m = manifests.read_sync_manifest(self.path())
        self.assertEqual(m.entries, {'a': '', 'b': HASH_A, 'c': ''})
        self.assertEqual(m.domains, ['skills/sdlc*'])

    def test_dotdot_in_the_manifest_path_is_refused(self):
        """E2-R5-01 (the POSIX parent-link-then-.. variant needs a POSIX link; the refusal is lexical)."""
        bad = os.path.join(self.tmp, 'a', '..', '.sync-manifest.json')
        self.assertTrue(manifests.read_sync_manifest(bad, root=self.tmp).fail_closed)
        with self.assertRaises(SecurityError):
            manifests.write_sync_manifest(bad, {'a/b': HASH_A}, root=self.tmp)
        self.assertEqual(os.listdir(self.tmp), [])

    def test_forbidden_parent_with_absent_file_is_not_a_first_run(self):
        """E2-R5-03."""
        out = os.path.join(self.tmp, 'out')
        sub = os.path.join(self.tmp, 'live')
        os.makedirs(out)
        os.makedirs(sub)
        if not make_junction(os.path.join(sub, 'state'), out):
            self.skipTest('cannot create a junction here')
        m = manifests.read_sync_manifest(os.path.join(sub, 'state', '.sync-manifest.json'), root=sub)
        self.assertTrue(m.fail_closed)

    def test_null_entries_is_valid_and_empty(self):
        self.put(b'{"entries": null}')
        m = manifests.read_sync_manifest(self.path())
        self.assertTrue(m.ok)
        self.assertEqual(m.entries, {})

    def test_round_trip_and_atomic(self):
        entries = {'skills/sdlc/SKILL.md': HASH_A, 'agents/sdlc-x.md': HASH_B}
        manifests.write_sync_manifest(self.path(), entries, machine='M1')
        m = manifests.read_sync_manifest(self.path())
        self.assertTrue(m.ok)
        self.assertEqual(m.entries, entries)
        self.assertEqual((m.version, m.machine), ('SP2', 'M1'))
        self.assertEqual(m.domains, list(manifests.SYNC_DOMAINS))
        self.assertEqual(os.listdir(self.tmp), ['.sync-manifest.json'])

    def test_bom_accepted(self):
        self.put(b'\xef\xbb\xbf' + json.dumps({'entries': {'a/b': HASH_A}, 'version': 'SP2'}).encode())
        self.assertEqual(manifests.read_sync_manifest(self.path()).entries, {'a/b': HASH_A})

    def test_write_refuses_unsafe_key(self):
        with self.assertRaises(SecurityError):
            manifests.write_sync_manifest(self.path(), {'../x': HASH_A})
        self.assertFalse(os.path.exists(self.path()))


class SkillName(TempDirCase):
    def test_reads_front_matter_name(self):
        for body in (b'---\nname: sdlc-x\n---\ntext', b'---\r\nname:   sdlc-x  \r\n---\r\n',
                     b'\xef\xbb\xbf---\nname: sdlc-x\n---\n'):
            path = self.write('s/SKILL.md', body)
            self.assertEqual(manifests.skill_name(path), 'sdlc-x', body)

    def test_unreadable_cases_give_none(self):
        self.assertIsNone(manifests.skill_name(os.path.join(self.tmp, 'absent.md')))
        for body in (b'no front matter\nname: sdlc\n', b'---\ndescription: x\n---\nname: sdlc\n', b''):
            self.assertIsNone(manifests.skill_name(self.write('s/SKILL.md', body)), body)

    def test_matches_get_skillname_on_encoding_and_line_endings(self):
        """E2-R1-12: replacement characters instead of failure; CR and LF only; no case on 'name:'."""
        self.assertEqual(manifests.skill_name(self.write('b/SKILL.md', b'---\nname: \xff\n---\n')), chr(0xfffd))
        self.assertEqual(manifests.skill_name(self.write('c/SKILL.md', b'---\rName: sdlc-x\r---\r')), 'sdlc-x')
        # E2-R2-06: a 65 536-character description line must not hide a name on line 3
        long_line = b'---\ndescription: ' + b'y' * 65536 + b'\nname: sdlc\n---\n'
        self.assertEqual(manifests.skill_name(self.write('e/SKILL.md', long_line)), 'sdlc')
        # E2-R3-06: a 3 MiB second line is still only one line of the first 30
        huge = b'---\ndescription: ' + b'z' * (3 * 1024 * 1024) + b'\nname: sdlc\n---\n'
        self.assertEqual(manifests.skill_name(self.write('g/SKILL.md', huge)), 'sdlc')
        # E2-R5-02: '---' followed by 65 533 blanks and a letter is NOT a delimiter (whole logical line)
        fake = b'---' + b' ' * 65533 + b'x\nname: sdlc\n'
        self.assertIsNone(manifests.skill_name(self.write('i/SKILL.md', fake)))
        ok = b'---' + b' ' * 70000 + b'\nname: sdlc\n---\n'
        self.assertEqual(manifests.skill_name(self.write('j/SKILL.md', ok)), 'sdlc')
        # E2-R4-02: the name is found at line 2; a huge body after it is never read
        early = b'---\nname: sdlc\n---\n' + b'b' * (20 * 1024 * 1024) + b'\n'
        self.assertEqual(manifests.skill_name(self.write('h/SKILL.md', early)), 'sdlc')
        self.assertIsNone(manifests.skill_name(os.path.join(self.tmp, 'g')))           # a directory
        # first byte of a 2-byte character exactly at offset 65535 (the old fixed read split it)
        head = b'---\nname: sdlc\n---\ndescription: '
        edge = head + b'x' * (65535 - len(head)) + b'\xc3\xa9\n'
        self.assertEqual(edge.index(b'\xc3'), 65535)
        self.assertEqual(manifests.skill_name(self.write('f/SKILL.md', edge)), 'sdlc')
        sep = ('---\n' + 'description: a' + chr(0x2028) + 'name: sdlc\n---\n').encode('utf-8')
        self.assertIsNone(manifests.skill_name(self.write('d/SKILL.md', sep)))   # U+2028 is not a line end

    def test_name_after_line_30_is_ignored(self):
        body = b'---\n' + b'x: 1\n' * 30 + b'name: sdlc\n---\n'
        self.assertIsNone(manifests.skill_name(self.write('s/SKILL.md', body)))


if __name__ == '__main__':
    unittest.main()
