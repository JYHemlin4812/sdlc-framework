import os
import shutil
import subprocess
import tempfile
import unittest

INSTALLER = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(INSTALLER)


class TempDirCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='sdlc-inst-test-')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write(self, rel, data=b'x\n'):
        path = os.path.join(self.tmp, *rel.split('/'))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as fh:
            fh.write(data)
        return path


def make_junction(link, target):
    """Windows junction (or symlink elsewhere). Returns False if the platform refuses."""
    try:
        if os.name == 'nt':
            res = subprocess.run(['cmd', '/c', 'mklink', '/J', link, target],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            return res.returncode == 0
        os.symlink(target, link, target_is_directory=True)
        return True
    except OSError:
        return False


def which(name):
    return shutil.which(name)
