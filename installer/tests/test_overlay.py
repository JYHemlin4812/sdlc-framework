import os
import unittest

from sdlc_installer import overlay
from sdlc_installer.errors import InstallerError, SecurityError
from tests.helpers import TempDirCase, make_junction

MARK = '@CLAUDE.local.md'


class Overlay(TempDirCase):
    def md(self):
        return os.path.join(self.tmp, 'CLAUDE.md')

    def local(self):
        return os.path.join(self.tmp, 'CLAUDE.local.md')

    def read(self, path):
        with open(path, 'rb') as fh:
            return fh.read()

    def backups(self):
        base = os.path.join(self.tmp, '_backups')
        return sorted(os.listdir(base)) if os.path.isdir(base) else []

    def test_l1_missing_files_are_created(self):
        res = overlay.set_local_overlay_import(self.tmp)
        self.assertTrue(res.overlay_created)
        self.assertTrue(res.import_added)
        self.assertEqual(self.read(self.local()), b'')
        self.assertEqual(self.read(self.md()), MARK.encode())
        self.assertEqual(self.backups(), [])           # nothing to back up

    def test_l2_existing_overlay_never_overwritten(self):
        self.write('CLAUDE.local.md', b'existing private content\n')
        self.write('CLAUDE.md', b'# mine\n')
        res = overlay.set_local_overlay_import(self.tmp)
        self.assertFalse(res.overlay_created)
        self.assertEqual(self.read(self.local()), b'existing private content\n')
        self.assertEqual(self.read(self.md()), b'# mine\n' + MARK.encode())

    def test_k1_idempotent_and_prefix_preserved(self):
        initial = b'# User preferences\nALWAYS tell the truth.\n'
        self.write('CLAUDE.md', initial)
        for _ in range(6):
            overlay.set_local_overlay_import(self.tmp)
            data = self.read(self.md())
            self.assertEqual(data.count(MARK.encode()), 1)
            self.assertTrue(data.startswith(initial))
        self.assertEqual(len(self.backups()), 1)       # only the run that changed the file

    def test_k2_line_in_the_middle_is_enough(self):
        text = b'line1\n' + MARK.encode() + b'\nline3\n'
        self.write('CLAUDE.md', text)
        res = overlay.set_local_overlay_import(self.tmp)
        self.assertFalse(res.import_added)
        self.assertEqual(self.read(self.md()), text)
        self.assertEqual(self.backups(), [])

    def test_trimmed_line_counts_but_other_text_does_not(self):
        self.write('CLAUDE.md', b'  ' + MARK.encode() + b' \r\n')
        self.assertFalse(overlay.set_local_overlay_import(self.tmp).import_added)
        self.write('CLAUDE.md', MARK.encode() + b' more\n@CLAUDE.local.md.bak\n')
        self.assertTrue(overlay.set_local_overlay_import(self.tmp).import_added)

    def test_k5_no_final_eol_uses_dominant_style(self):
        self.write('CLAUDE.md', b'line-without-eol')
        overlay.set_local_overlay_import(self.tmp)
        self.assertEqual(self.read(self.md()), b'line-without-eol\n' + MARK.encode())
        self.write('CLAUDE.md', b'a\r\nb\r\nc-without-eol')
        overlay.set_local_overlay_import(self.tmp)
        self.assertEqual(self.read(self.md()), b'a\r\nb\r\nc-without-eol\r\n' + MARK.encode())

    def test_final_eol_kept_bytes_untouched(self):
        self.write('CLAUDE.md', b'a\r\nb\n')
        overlay.set_local_overlay_import(self.tmp)
        self.assertEqual(self.read(self.md()), b'a\r\nb\n' + MARK.encode())

    def test_empty_file_gets_the_bare_marker(self):
        self.write('CLAUDE.md', b'')
        overlay.set_local_overlay_import(self.tmp)
        self.assertEqual(self.read(self.md()), MARK.encode())

    def test_marker_match_is_literal_lookalikes_do_not_count(self):
        """E2-R3-03, measured on the real scripts (see overlay._is_marker): the literal rule of the sync-lib header.
        A BOM first line, another case, or a trailing format character is NOT the marker: the import is added
        and the original bytes stay intact (PowerShell would not add, bash would, so the scripts disagree)."""
        for tail in (chr(0xfe0f), chr(0), chr(0x115f)):
            body = (MARK + tail + '\n').encode('utf-8')
            self.write('CLAUDE.md', body)
            res = overlay.set_local_overlay_import(self.tmp)
            self.assertTrue(res.import_added, repr(tail))
            self.assertEqual(self.read(self.md()), body + MARK.encode())
        for body in (b'\xef\xbb\xbf' + MARK.encode() + b'\n', b'@claude.LOCAL.md\r\n'):
            self.write('CLAUDE.md', body)
            self.assertTrue(overlay.set_local_overlay_import(self.tmp).import_added, body)
            self.assertTrue(self.read(self.md()).startswith(body))

    def test_backup_root_that_is_a_file_is_refused_before_anything_is_created(self):
        """E2-R3-04: _backups exists as a regular file; dry-run and real run refuse, nothing created."""
        self.write('CLAUDE.md', b'mine\n')
        self.write('_backups', b'in the way')
        for dry in (True, False):
            with self.assertRaises(InstallerError, msg='dry_run=%s' % dry):
                overlay.set_local_overlay_import(self.tmp, dry_run=dry)
        self.assertFalse(os.path.exists(self.local()))
        self.assertEqual(self.read(self.md()), b'mine\n')

    @unittest.skipUnless(hasattr(os, 'mkfifo'), 'needs POSIX FIFOs')
    def test_fifo_in_place_of_the_overlay_is_kept(self):
        """E2-R2-08: a non-regular overlay is refused, never replaced by an empty file; CLAUDE.md untouched."""
        os.mkfifo(self.local())
        self.write('CLAUDE.md', b'mine\n')
        with self.assertRaises(SecurityError):
            overlay.set_local_overlay_import(self.tmp)
        import stat
        self.assertTrue(stat.S_ISFIFO(os.lstat(self.local()).st_mode))
        self.assertEqual(self.read(self.md()), b'mine\n')

    def test_backup_root_link_is_refused_before_the_overlay_is_created(self):
        """E2-R1-10: refusal leaves nothing behind, the overlay included."""
        outside = os.path.join(self.tmp, 'outside')
        os.makedirs(outside)
        live = os.path.join(self.tmp, 'live')
        os.makedirs(live)
        if not make_junction(os.path.join(live, '_backups'), outside):
            self.skipTest('cannot create a junction here')
        with open(os.path.join(live, 'CLAUDE.md'), 'wb') as fh:
            fh.write(b'mine\n')
        for dry in (False, True):                       # E2-R2-09: the dry-run redoes the deciding checks
            with self.assertRaises(SecurityError, msg='dry_run=%s' % dry):
                overlay.set_local_overlay_import(live, dry_run=dry)
        self.assertFalse(os.path.exists(os.path.join(live, 'CLAUDE.local.md')))
        self.assertEqual(os.listdir(outside), [])
        with open(os.path.join(live, 'CLAUDE.md'), 'rb') as fh:
            self.assertEqual(fh.read(), b'mine\n')

    def test_k6_dry_run_writes_nothing(self):
        overlay.set_local_overlay_import(self.tmp, dry_run=True)
        self.assertEqual(os.listdir(self.tmp), [])
        self.write('CLAUDE.md', b'existing\n')
        overlay.set_local_overlay_import(self.tmp, dry_run=True)
        self.assertEqual(self.read(self.md()), b'existing\n')
        self.assertEqual(sorted(os.listdir(self.tmp)), ['CLAUDE.md'])

    def test_k7_duplicates_warn_without_dedup(self):
        text = (MARK + '\nmiddle\n' + MARK + '\n').encode()
        self.write('CLAUDE.md', text)
        res = overlay.set_local_overlay_import(self.tmp)
        self.assertEqual(len(res.warnings), 1)
        self.assertIn(MARK, res.warnings[0])
        self.assertEqual(self.read(self.md()), text)

    def test_backup_holds_the_original_bytes(self):
        self.write('CLAUDE.md', b'orig\r\n')
        res = overlay.set_local_overlay_import(self.tmp)
        self.assertTrue(os.path.basename(res.backup_folder).startswith('import-'))
        self.assertEqual(self.read(os.path.join(res.backup_folder, 'CLAUDE.md')), b'orig\r\n')

    def test_non_utf8_is_refused_before_any_mutation(self):
        """Design §6: code 3, nothing written (not even the overlay)."""
        raw = b'caf\xe9\n'
        self.write('CLAUDE.md', raw)
        with self.assertRaises(SecurityError) as ctx:
            overlay.set_local_overlay_import(self.tmp)
        self.assertEqual(ctx.exception.code, 3)
        self.assertEqual(self.read(self.md()), raw)
        self.assertFalse(os.path.exists(self.local()))
        self.assertEqual(self.backups(), [])

    def test_directory_in_place_of_claude_md_is_refused(self):
        os.makedirs(self.md())
        with self.assertRaises(SecurityError):
            overlay.set_local_overlay_import(self.tmp)
        self.assertFalse(os.path.exists(self.local()))

    def test_directory_in_place_of_the_overlay_is_refused(self):
        os.makedirs(self.local())
        with self.assertRaises(InstallerError):
            overlay.set_local_overlay_import(self.tmp)
        self.assertFalse(os.path.exists(self.md()))

    def test_linked_claude_md_is_refused_target_untouched(self):
        outside = self.write('outside/real.md', b'elsewhere\n')
        try:
            os.symlink(outside, self.md())
        except (OSError, NotImplementedError):
            self.skipTest('cannot create a symlink here')
        with self.assertRaises(SecurityError):
            overlay.set_local_overlay_import(self.tmp)
        self.assertEqual(self.read(outside), b'elsewhere\n')

    def test_junction_claude_root_is_allowed(self):
        """§5.2 point 3: the live root may itself be a link."""
        real = os.path.join(self.tmp, 'real')
        os.makedirs(real)
        link = os.path.join(self.tmp, 'link')
        if not make_junction(link, real):
            self.skipTest('cannot create a junction here')
        overlay.set_local_overlay_import(link)
        self.assertEqual(self.read(os.path.join(real, 'CLAUDE.md')), MARK.encode())

    def test_only_the_marker_is_ever_added(self):
        """Decision 1: no other import line, whatever CLAUDE.md already imports."""
        body = b'@NESTOR.md\n@RTK.md\n'
        self.write('CLAUDE.md', body)
        overlay.set_local_overlay_import(self.tmp)
        self.assertEqual(self.read(self.md()), body + MARK.encode())


class SplitLines(unittest.TestCase):
    def test_keeps_terminators(self):
        self.assertEqual(overlay.split_lines('a\r\nb\nc'), ['a\r\n', 'b\n', 'c'])
        self.assertEqual(overlay.split_lines('a\n'), ['a\n'])
        self.assertEqual(overlay.split_lines(''), [])
        self.assertEqual(overlay.split_lines('\n\n'), ['\n', '\n'])
        sep = 'a' + chr(0x2028) + 'b\n'
        self.assertEqual(overlay.split_lines(sep), [sep])                       # only \n splits


if __name__ == '__main__':
    unittest.main()
