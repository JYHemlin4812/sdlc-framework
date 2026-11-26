"""Design §13 PYI-10 (E7): the retired entry points of bundle/scripts are gone, and no active file still points to
them. Only historical references remain (changelog, known issues, the design and parity notes, the docstrings
of the Python ports, the parity fixtures that read the scripts from a pinned commit)."""
import re
import subprocess
import unittest

from tests.helpers import REPO, which

RETIRED_EXTENSIONS = ('.ps1', '.sh')  # E7 commit 2 (PowerShell), commit 3 (bash)
NAMES = ('install', 'uninstall', 'verify', 'capture', 'restore', 'scan-fuites', 'sync-lib', 'test-install',
         'test-uninstall', 'test-verify', 'test-capture', 'test-restore', 'test-sync-lib', 'sync-bdd.tests',
         'planchers.assert', 'test-retrait-nestor', 'test-retrait-nestor-codex', 'test-retrait-nestor-ps')
HISTORICAL = ('CHANGELOG.md', 'docs/KNOWN-ISSUES.md', 'bundle/docs/KNOWN-ISSUES.md', 'installer/')
HISTORICAL_LINES = (('claude/skills/sdlc/SKILL.md', '- **3.1**'),)      # version history line only


def pattern():
    """ERE (git grep -E -i) and Python re alike: a retired script by name, or a glob under bundle/scripts."""
    exts = '|'.join(e.lstrip('.') for e in RETIRED_EXTENSIONS)
    names = '|'.join(n.replace('.', '[.]') for n in NAMES)
    return (r'(^|[^A-Za-z0-9_-])(%s)[.](%s)([^A-Za-z0-9_]|$)|bundle/scripts/([^ ]*/)?[^ /]*[*][^ /]*[.](%s)'
            % (names, exts, exts))


def git(*args):
    return subprocess.run(['git', '-C', REPO] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def historical(line):
    if line.startswith(HISTORICAL):
        return True
    path, _sep, rest = line.partition(':')
    text = rest.partition(':')[2]
    return any(path == p and text.lstrip().startswith(prefix) for p, prefix in HISTORICAL_LINES)


class Pattern(unittest.TestCase):
    def test_catches_names_globs_and_case(self):
        rx = re.compile(pattern(), re.IGNORECASE)
        for text in ('run bundle/scripts/install.ps1 now', '`verify.ps1`', 'bundle/scripts/*.ps1',
                     'bundle/scripts/**/*.ps1', 'bundle/scripts/tests/*.ps1', 'bundle/scripts/test-*.ps1',
                     'Install.PS1', 'sync-bdd.tests.ps1', 'bash bundle/scripts/install.sh', 'test-retrait-nestor.sh',
                     'bundle/scripts/tests/*.sh'):
            with self.subTest(text=text):
                self.assertIsNotNone(rx.search(text))
        for text in ('check_sdlc.ps1', 'deploy_init.ps1', 'deploy_init.sh', 'find-polluter.sh', 'reinstall.ps1x',
                     'my-install.ps1', 'my-install.sh'):
            with self.subTest(text=text):
                self.assertIsNone(rx.search(text))


@unittest.skipUnless(which('git'), 'git missing: PYI-10 NOT proven')
class RetiredScripts(unittest.TestCase):
    def test_no_retired_script_is_tracked(self):
        res = git('ls-files', '-z', '--', 'bundle/scripts')
        self.assertEqual(res.returncode, 0, res.stderr)
        tracked = [p for p in res.stdout.decode('utf-8').split('\0') if p.lower().endswith(RETIRED_EXTENSIONS)]
        self.assertEqual(tracked, [])

    def test_only_historical_references_remain(self):
        res = git('grep', '-I', '-i', '-n', '-E', pattern(), '--', '.')
        self.assertIn(res.returncode, (0, 1), res.stderr)
        hits = [line for line in res.stdout.decode('utf-8', 'replace').splitlines() if not historical(line)]
        self.assertEqual(hits, [])
