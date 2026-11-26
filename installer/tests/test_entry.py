"""Design §9 (PYI-08): the documented entry point writes no __pycache__ and no file anywhere."""
import os
import shutil
import subprocess
import sys

from tests.helpers import INSTALLER, TempDirCase


def snapshot(root):
    out = {}
    for d, dirs, files in os.walk(root):
        for name in dirs:
            out[os.path.relpath(os.path.join(d, name), root) + '/'] = None
        for name in files:
            p = os.path.join(d, name)
            with open(p, 'rb') as fh:
                out[os.path.relpath(p, root)] = fh.read()
    return out


class EntryPoint(TempDirCase):
    def test_no_write_anywhere(self):
        copy = os.path.join(self.tmp, 'installer')
        shutil.copytree(INSTALLER, copy, ignore=shutil.ignore_patterns('__pycache__', 'tests', '_revue'))
        home = os.path.join(self.tmp, 'home')
        os.makedirs(home)
        env = dict(os.environ)
        env.pop('PYTHONDONTWRITEBYTECODE', None)
        env.update({'HOME': home, 'USERPROFILE': home})
        for argv in (['verify'], ['install', '--dry-run']):
            with self.subTest(argv=argv):
                before = snapshot(self.tmp)
                res = subprocess.run([sys.executable, os.path.join(copy, 'install.py')] + argv,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, cwd=self.tmp)
                self.assertEqual(res.returncode, 2, argv)
                self.assertEqual(snapshot(self.tmp), before)
