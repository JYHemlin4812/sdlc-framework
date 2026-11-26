"""scan-fuites (design §8.5): Python port of bundle/scripts/scan-fuites.ps1 / .sh, with a byte parity test of the
report against each script that is available. Temporary repositories only. The leak-like fixtures are assembled
at run time so that this file never matches a level-1 pattern itself."""
import codecs
import os
import subprocess
import sys
import unittest
from unittest import mock

from sdlc_installer import scanfuites
from tests.helpers import INSTALLER, TempDirCase, which
from tests.legacy_fixtures import SCRIPTS_COMMIT, pinned_scripts
from tests.test_install import get, git, put, run_cli, snapshot

AT = '@'
EMAIL = 'jane.doe' + AT + 'example.org'
WINPATH = 'C:' + '\\' + 'Users' + '\\' + 'jane'
MARK2 = 'sdlc' + 'v2'


def ps_exe():
    return which('pwsh') or which('powershell')


class ScanCase(TempDirCase):
    def setUp(self):
        super().setUp()
        self.base = os.path.realpath(self.tmp)       # long, physical spelling: the scripts print it as given

    def repo(self, name='repo'):
        repo = os.path.join(self.base, name)
        os.makedirs(repo)
        git(repo, 'init', '-q')
        for k, v in (('user.email', 't' + AT + 't'), ('user.name', 't'), ('commit.gpgsign', 'false'),
                     ('core.autocrlf', 'false')):
            git(repo, 'config', k, v)
        put(repo, 'README.md', ('contact: %s\n' % EMAIL).encode())            # (a) root commit: contaminated
        git(repo, 'add', '-A')
        git(repo, 'commit', '-q', '-m', 'root')
        put(repo, 'README.md', b'clean readme\n')
        git(repo, 'commit', '-q', '-am', 'clean')
        put(repo, 'docs/a.md', ('line one\npath %s\\x and %s\n' % (WINPATH, MARK2)).encode())
        put(repo, 'docs/b.txt', b'nothing\r\nhas Secret-Token here\r\n')
        put(repo, 'SDLC_PM/notes.md', ('%s %s\nplain\n%s\n' % (EMAIL, MARK2, MARK2)).encode())
        put(repo, 'img/logo.png', ('%s\n' % EMAIL).encode())                    # binary extension: skipped
        put(repo, 'data.bin.txt', b'\0' + EMAIL.encode())                       # NUL byte: skipped
        put(repo, 'pkg/__pycache__/m.txt', EMAIL.encode())                      # sync exclusion: skipped
        put(repo, 'bundle/scripts/scan-fuites.ps1', EMAIL.encode())            # the scanner itself: skipped
        git(repo, 'add', '-A')
        git(repo, 'commit', '-q', '-m', 'SP4 starts here')
        return repo

    def motifs(self, text=b'# private tokens\n\nsecret-token\n'):
        return put(self.base, 'motifs.txt', text)

    def scan(self, repo, motifs, report, *extra):
        return run_cli(['scan-fuites', '--repo-root', repo, '--motifs-path', motifs, '--report-path', report]
                       + list(extra))


class Behaviour(ScanCase):
    def test_report_content(self):
        repo = self.repo()
        report = os.path.join(self.tmp, 'out', 'report.md')
        code, out = self.scan(repo, self.motifs(), report)
        self.assertEqual(code, 0, out)
        text = get(self.tmp, 'out/report.md').decode('utf-8')
        self.assertIn('(1 pattern(s))', text)
        self.assertIn('3 hit(s) found:', text)
        self.assertIn('- `docs/a.md:2:windows-profile-path`', text)
        self.assertIn('- `docs/a.md:2:%s`' % MARK2, text)
        self.assertIn('- `docs/b.txt:2:level2`', text)                       # case-insensitive, CRLF lines
        self.assertIn('- `SDLC_PM/notes.md`: 2 hit(s)', text)                 # a line counts once
        for skipped in ('logo.png', 'data.bin.txt', '__pycache__', 'scan-fuites.ps1'):
            self.assertNotIn(skipped, text)
        self.assertIn('history contaminated', text)
        self.assertIn('| (b) last commit before SP4 | `%s` | 0 |' % git(repo, 'rev-parse', 'HEAD~1'), text)
        self.assertIn('| (a) repository root commit |', text)

    def test_generic_mode_and_read_only(self):
        repo = self.repo()
        before, index = snapshot(repo), get(repo, '.git/index')
        report = os.path.join(self.tmp, 'r.md')
        code, out = self.scan(repo, os.path.join(self.tmp, 'absent.txt'), report)
        self.assertEqual(code, 0, out)
        self.assertIn('**Generic mode only**', get(self.tmp, 'r.md').decode('utf-8'))
        self.assertEqual(snapshot(repo), before)
        self.assertEqual(get(repo, '.git/index'), index)

    def test_default_report_under_sdlc_pm(self):
        repo = self.repo()
        code, out = run_cli(['scan-fuites', '--repo-root', repo])
        self.assertEqual(code, 0, out)
        folder = os.path.join(repo, 'SDLC_PM', 'SP6-productisation')
        self.assertEqual(len([f for f in os.listdir(folder) if f.startswith('rapport-scan-fuites-')]), 1)

    def test_codes_2(self):
        repo = self.repo()
        self.assertEqual(run_cli(['scan-fuites', '--repo-root', os.path.join(self.tmp, 'missing')])[0], 2)
        self.assertEqual(self.scan(repo, self.motifs(), self.tmp)[0], 2)                  # report path is a folder
        bad = self.motifs(b'ok\n([unclosed\n')
        report = os.path.join(self.tmp, 'never.md')
        code, out = self.scan(repo, bad, report)
        self.assertEqual(code, 2, out)
        self.assertIn('line 2', out)
        self.assertFalse(os.path.exists(report))

    def test_no_git(self):
        plain = os.path.join(self.tmp, 'plain')
        put(plain, 'a.md', EMAIL.encode())
        report = os.path.join(self.tmp, 'p.md')
        code, out = self.scan(plain, os.path.join(self.tmp, 'absent.txt'), report)
        self.assertEqual(code, 0, out)
        self.assertIn('| (c) HEAD | `(unavailable)` | unavailable |', get(self.tmp, 'p.md').decode('utf-8'))


class Contract(ScanCase):
    """E6 review cases (codes, encodings, edge files, read-only promise)."""

    def test_e6_r1_01_report_never_in_git_metadata(self):
        repo = self.repo()
        put(repo, 'staged.md', b'staged\n')
        git(repo, 'add', 'staged.md')
        index = get(repo, '.git/index')
        for target in (os.path.join(repo, '.git', 'index'), os.path.join(repo, '.git', 'new-report.md')):
            code, out = self.scan(repo, self.motifs(), target)
            self.assertEqual(code, 2, out)
        self.assertEqual(get(repo, '.git/index'), index)
        self.assertFalse(os.path.exists(os.path.join(repo, '.git', 'new-report.md')))

    def test_e6_r1_03_utf16_pattern_file(self):
        repo = self.repo()
        motifs = self.motifs(codecs.BOM_UTF16_LE + 'secret-token\r\n'.encode('utf-16-le'))
        code, out = self.scan(repo, motifs, os.path.join(self.base, 'u16.md'))
        self.assertEqual(code, 0, out)
        self.assertIn('docs/b.txt:2:level2', get(self.base, 'u16.md').decode('utf-8'))
        bad = self.motifs(b'\xff\xfe\xfa')                                   # odd UTF-16 length: not decodable
        self.assertEqual(self.scan(repo, bad, os.path.join(self.base, 'bad.md'))[0], 2)

    def test_e6_r1_04_report_parent_is_a_file(self):
        repo = self.repo()
        code, out = self.scan(repo, self.motifs(), os.path.join(repo, 'README.md', 'r.md'))
        self.assertEqual(code, 2, out)

    def test_e6_r1_05_unreadable_folder_fails_closed(self):
        repo = self.repo()

        def walk(root, onerror=None):
            onerror(PermissionError(13, 'Permission denied', root))
            yield from ()
        with mock.patch('sdlc_installer.scanfuites.os.walk', walk):
            code, out = self.scan(repo, self.motifs(), os.path.join(self.base, 'w.md'))
        self.assertEqual(code, 2, out)
        self.assertFalse(os.path.exists(os.path.join(self.base, 'w.md')))

    def test_e6_r1_06_pattern_over_the_limit(self):
        repo = self.repo()
        report = os.path.join(self.base, 'o.md')
        code, out = self.scan(repo, self.motifs(b'a{4294967296}\n'), report)
        self.assertEqual(code, 2, out)
        self.assertIn('line 1', out)
        self.assertFalse(os.path.exists(report))

    def test_e6_r1_09_links_not_searched_in_history(self):
        repo = os.path.join(self.base, 'links')
        os.makedirs(repo)
        git(repo, 'init', '-q')
        for k, v in (('user.email', 't'), ('user.name', 't'), ('commit.gpgsign', 'false')):
            git(repo, 'config', k, v)
        blob = subprocess.run(['git', '-C', repo, 'hash-object', '-w', '--stdin'], input=MARK2.encode(),
                              stdout=subprocess.PIPE, check=True).stdout.decode().strip()
        git(repo, 'update-index', '--add', '--cacheinfo', '120000,%s,link' % blob)
        git(repo, 'commit', '-q', '-m', 'root with a link only')
        code, out = self.scan(repo, os.path.join(self.base, 'absent'), os.path.join(self.base, 'l.md'))
        self.assertEqual(code, 0, out)
        text = get(self.base, 'l.md').decode('utf-8')
        self.assertIn('| (a) repository root commit |', text)
        self.assertNotIn('history contaminated', text)

    def test_e6_r1_10_empty_file_has_no_line(self):
        repo = self.repo()
        put(repo, 'docs/empty.md', b'')
        put(repo, 'docs/one-lf.md', b'\n')
        put(repo, 'docs/two-lf.md', b'\n\n')
        code, out = self.scan(repo, self.motifs(b'^$\n'), os.path.join(self.base, 'e.md'))
        self.assertEqual(code, 0, out)
        text = get(self.base, 'e.md').decode('utf-8')
        self.assertNotIn('docs/empty.md', text)
        self.assertIn('docs/one-lf.md:1:level2', text)
        self.assertNotIn('docs/one-lf.md:2:', text)
        self.assertIn('docs/two-lf.md:2:level2', text)

    def test_e6_r1_11_partial_clone_probe_not_run(self):
        repo = self.repo()
        git(repo, 'config', 'extensions.partialClone', 'origin')
        objects = snapshot(os.path.join(repo, '.git', 'objects'))
        code, out = self.scan(repo, self.motifs(), os.path.join(self.base, 'pc.md'))
        self.assertEqual(code, 0, out)
        text = get(self.base, 'pc.md').decode('utf-8')
        self.assertIn('| (a) repository root commit |', text)
        self.assertIn('| unavailable |', text)
        self.assertEqual(snapshot(os.path.join(repo, '.git', 'objects')), objects)

    @unittest.skipIf(os.name == 'nt', 'Windows file names are always valid Unicode')
    def test_e6_r1_12_undecodable_file_name(self):
        repo = self.repo()
        with open(os.path.join(repo.encode(), b'docs', b'bad\xffname.md'), 'wb') as fh:
            fh.write(EMAIL.encode() + b'\n')
        code, out = self.scan(repo, self.motifs(), os.path.join(self.base, 'n.md'))
        self.assertEqual(code, 0, out)
        self.assertIn('docs/bad' + chr(92) + 'xffname.md:1:generic-email', get(self.base, 'n.md').decode('utf-8'))

    def test_e6_r1_16_git_absent(self):
        repo = self.repo()
        with mock.patch('sdlc_installer.scanfuites.shutil.which', return_value=None):
            code, out = self.scan(repo, self.motifs(), os.path.join(self.base, 'ng.md'))
        self.assertEqual(code, 0, out)
        self.assertIn('git unavailable or repository inaccessible - probe not run.',
                      get(self.base, 'ng.md').decode('utf-8'))

    def test_e6_r1_17_ordinal_utf16_order(self):
        astral, private = chr(0x10000) + 'a.md', chr(0xE000) + 'a.md'
        self.assertLess(scanfuites._ordinal(astral), scanfuites._ordinal(private))
        root = os.path.join(self.base, 'order')
        try:
            put(root, private, b'x')
            put(root, astral, b'x')
        except (OSError, UnicodeError):
            self.skipTest('file system refuses these names')
        self.assertEqual(scanfuites.file_list(root), [astral, private])


    def test_e6_r2_01_report_into_another_repository_metadata(self):
        repo = self.repo()
        other = self.repo('other')
        put(other, 'staged.md', b'x\n')
        git(other, 'add', 'staged.md')
        index = get(other, '.git/index')
        code, out = self.scan(repo, self.motifs(), os.path.join(other, '.git', 'index'))
        self.assertEqual(code, 2, out)
        self.assertEqual(get(other, '.git/index'), index)
        linked = os.path.join(self.base, 'linked')
        git(other, 'worktree', 'add', '-q', '--detach', linked)
        link_file = get(linked, '.git')
        code, out = self.scan(repo, self.motifs(), os.path.join(linked, '.git'))
        self.assertEqual(code, 2, out)
        self.assertEqual(get(linked, '.git'), link_file)

    def test_e6_r2_02_real_partial_clone_stays_untouched(self):
        origin = self.repo('origin')
        git(origin, 'config', 'uploadpack.allowFilter', 'true')
        git(origin, 'config', 'uploadpack.allowAnySHA1InWant', 'true')
        clone = os.path.join(self.base, 'partial')
        url = 'file:///' + origin.replace(os.sep, '/').lstrip('/')
        res = subprocess.run(['git', 'clone', '-q', '--filter=blob:none', url, clone], stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE)
        if res.returncode != 0:
            self.skipTest('partial clone not supported here: %s' % res.stderr.decode('utf-8', 'replace'))
        old = subprocess.run(['git', '-C', origin, 'rev-parse', 'HEAD~2:README.md'], stdout=subprocess.PIPE,
                             check=True).stdout.decode().strip()

        def missing():
            # --missing=print lists absent objects without fetching them (E6-R3-06).
            res = subprocess.run(['git', '-C', clone, 'rev-list', '--objects', '--all', '--missing=print'],
                                 stdout=subprocess.PIPE, check=True)
            return [l[1:] for l in res.stdout.decode().split() if l.startswith('?')]
        self.assertIn(old, missing())                     # the old blob really is absent before the scan
        objects = snapshot(os.path.join(clone, '.git', 'objects'))
        code, out = self.scan(clone, self.motifs(), os.path.join(self.base, 'part.md'))
        self.assertEqual(code, 0, out)
        self.assertIn('partial clone', out)
        self.assertEqual(snapshot(os.path.join(clone, '.git', 'objects')), objects)
        self.assertIn(old, missing())

    def test_e6_r2_03_no_git_on_path(self):
        repo = self.repo()
        with mock.patch.dict(os.environ, {'PATH': ''}):
            code, out = self.scan(repo, self.motifs(), os.path.join(self.base, 'nopath.md'))
        self.assertEqual(code, 0, out)
        self.assertIn('probe not run', get(self.base, 'nopath.md').decode('utf-8'))

    @unittest.skipIf(os.name == 'nt', 'Windows file names are always valid Unicode')
    def test_e6_r2_04_root_with_an_undecodable_name(self):
        root = os.path.join(self.base.encode(), b'root\xff')
        os.makedirs(os.path.join(root, b'docs'))
        with open(os.path.join(root, b'docs', b'a.md'), 'wb') as fh:
            fh.write(b'clean\n')
        report = os.path.join(self.base, 'rootname.md')
        code, out = run_cli(['scan-fuites', '--repo-root', os.fsdecode(root), '--report-path', report])
        self.assertEqual(code, 0, out)
        self.assertIn('root' + chr(92) + 'xff', get(self.base, 'rootname.md').decode('utf-8'))

    def test_e6_r2_05_unreadable_excluded_folder_is_not_opened(self):
        repo = self.repo()
        real_scandir = os.scandir

        def scandir(path='.'):
            if os.path.basename(os.fspath(path)) == '__pycache__':
                raise PermissionError(13, 'Permission denied', path)
            return real_scandir(path)
        with mock.patch('os.scandir', scandir):
            code, out = self.scan(repo, self.motifs(), os.path.join(self.base, 'pyc.md'))
        self.assertEqual(code, 0, out)

    def test_e6_r2_06_unreachable_pattern_file(self):
        repo = self.repo()
        motifs = self.motifs()
        real_stat = os.stat

        def fake_stat(path, *args, **kwargs):
            if os.fspath(path) == motifs:
                raise PermissionError(13, 'Permission denied', path)
            return real_stat(path, *args, **kwargs)
        with mock.patch('sdlc_installer.scanfuites.os.stat', fake_stat):
            code, out = self.scan(repo, motifs, os.path.join(self.base, 'perm.md'))
        self.assertEqual(code, 2, out)

    def test_e6_r2_08_bom_only_file_has_no_line(self):
        repo = self.repo()
        put(repo, 'docs/bom.md', codecs.BOM_UTF8)
        code, out = self.scan(repo, self.motifs(b'^$\n'), os.path.join(self.base, 'bom.md'))
        self.assertEqual(code, 0, out)
        self.assertNotIn('docs/bom.md', get(self.base, 'bom.md').decode('utf-8'))

    def bare(self, name='archive.git'):
        path = os.path.join(self.base, name)
        git(self.base, 'init', '-q', '--bare', path)
        return path

    def test_e6_r3_01_report_into_a_bare_repository(self):
        repo, archive = self.repo(), self.bare()
        target = os.path.join(archive, 'refs', 'heads', 'revue', 'rapport')
        code, out = self.scan(repo, self.motifs(), target)
        self.assertEqual(code, 2, out)
        self.assertFalse(os.path.lexists(os.path.join(archive, 'refs', 'heads', 'revue')))

    def test_e6_r3_02_bare_head_without_git(self):
        repo, archive = self.repo(), self.bare()
        head = get(archive, 'HEAD')
        with mock.patch.dict(os.environ, {'PATH': ''}):
            code, out = self.scan(repo, self.motifs(), os.path.join(archive, 'HEAD'))
        self.assertEqual(code, 2, out)
        self.assertEqual(get(archive, 'HEAD'), head)

    def test_e6_r3_03_pattern_path_through_a_file(self):
        repo = self.repo()
        report = os.path.join(self.base, 'through.md')
        code, out = self.scan(repo, os.path.join(repo, 'README.md', 'motifs.txt'), report)
        self.assertEqual(code, 2, out)
        self.assertFalse(os.path.exists(report))

    @unittest.skipIf(os.name == 'nt', 'Windows file names are always valid Unicode')
    def test_e6_r3_04_strict_utf8_console(self):
        root = os.path.join(self.base.encode(), b'root\xff')
        os.makedirs(os.path.join(root, b'docs'))
        with open(os.path.join(root, b'docs', b'a.md'), 'wb') as fh:
            fh.write(b'clean\n')
        report = os.path.join(self.base, 'strict.md')
        env = dict(os.environ, PYTHONIOENCODING='utf-8:strict')
        res = subprocess.run([sys.executable, '-B', os.path.join(INSTALLER, 'install.py'), 'scan-fuites',
                              '--repo-root', os.fsdecode(root), '--report-path', report],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertTrue(os.path.isfile(report))

    @unittest.skipIf(os.name == 'nt', 'a backslash is a separator on Windows')
    def test_e6_r3_05_backslash_in_a_folder_name(self):
        repo = self.repo()
        folder = os.path.join(self.base, 'export' + chr(92) + '.git')
        os.makedirs(folder)
        code, out = self.scan(repo, self.motifs(), os.path.join(folder, 'rapport.md'))
        self.assertEqual(code, 0, out)

    def test_e6_r4_01_dot_git_still_to_be_created(self):
        repo = self.repo()
        os.makedirs(os.path.join(repo, 'export'))
        code, out = self.scan(repo, self.motifs(), os.path.join(repo, 'export', '.git', 'rapport.md'))
        self.assertEqual(code, 2, out)
        self.assertFalse(os.path.lexists(os.path.join(repo, 'export', '.git')))

    def test_e6_r4_02_ordinary_folder_with_a_head_file(self):
        repo = self.repo()
        folder = os.path.join(self.base, 'export')
        for sub in ('objects', 'refs'):
            os.makedirs(os.path.join(folder, sub))
        put(folder, 'HEAD', b'inventaire\n')
        code, out = self.scan(repo, self.motifs(), os.path.join(folder, 'rapport.md'))
        self.assertEqual(code, 0, out)
        self.assertTrue(os.path.isfile(os.path.join(folder, 'rapport.md')))

    def test_e6_r4_03_explicit_pattern_path_rules(self):
        repo = self.repo()
        report = os.path.join(self.base, 'm.md')
        for motifs in (os.path.join(self.base, 'missing-folder', 'motifs.txt'), os.path.join(repo, 'docs')):
            code, out = self.scan(repo, motifs, report)
            self.assertEqual(code, 2, out)
            self.assertFalse(os.path.exists(report))
        plain = os.path.join(self.base, 'plain')
        put(plain, 'a.md', b'clean\n')                       # default pattern file absent, no SDLC_PM: generic
        code, out = run_cli(['scan-fuites', '--repo-root', plain, '--report-path', report])
        self.assertEqual(code, 0, out)
        self.assertIn('**Generic mode only**', get(self.base, 'm.md').decode('utf-8'))

class ScriptParity(ScanCase):
    """The same fixture through each available script gives the same report, compared as bytes. The scripts are
    those of legacy_fixtures.SCRIPTS_COMMIT (removed from the tree in E7)."""

    def setUp(self):
        if pinned_scripts() is None:
            self.skipTest('commit %s missing: script parity NOT proven' % SCRIPTS_COMMIT)
        super().setUp()

    def run_both(self, cmd, name):
        repo, motifs = self.repo(), self.motifs()
        mine, theirs = os.path.join(self.base, 'py.md'), os.path.join(self.base, name)
        self.assertEqual(self.scan(repo, motifs, mine)[0], 0)
        res = subprocess.run(cmd(repo, motifs, theirs), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             stdin=subprocess.DEVNULL, timeout=300)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        with open(mine, 'rb') as fh:
            got = fh.read()
        with open(theirs, 'rb') as fh:
            want = fh.read()
        return repo, got, want

    @unittest.skipUnless(ps_exe(), 'PowerShell not available')
    def test_ps1(self):
        _repo, got, want = self.run_both(
            lambda repo, motifs, report: [ps_exe(), '-NoProfile', '-File', os.path.join(pinned_scripts(), 'scan-fuites.ps1'),
                                          '-RepoRoot', repo, '-MotifsPath', motifs, '-ReportPath', report], 'ps1.md')
        self.assertEqual(got, want)                       # byte for byte, headers and final blank line included

    @unittest.skipUnless(which('bash'), 'bash not available')
    def test_sh(self):
        """scan-fuites.sh diverges from its declared reference on one point (Python follows scan-fuites.ps1): it scans
        files with a binary extension, so img/logo.png is listed and counted. It writes LF everywhere and, on Windows,
        prints the root with forward slashes."""
        repo, got, want = self.run_both(
            lambda repo, motifs, report: [which('bash'), os.path.join(pinned_scripts(), 'scan-fuites.sh'), '--repo-root', repo,
                                          '--motifs-path', motifs, '--report-path', report], 'sh.md')
        want = want.decode('utf-8')
        logo = '- `img/logo.png:1:generic-email`\n'
        self.assertIn(logo, want)
        self.assertIn('4 hit(s) found:', want)
        want = want.replace(logo, '').replace('4 hit(s) found:', '3 hit(s) found:')
        if os.name == 'nt':
            want = want.replace('`%s`' % repo.replace(os.sep, '/'), '`%s`' % repo).replace('\n', '\r\n')
        self.assertEqual(got.decode('utf-8'), want)


if __name__ == '__main__':
    unittest.main()
