"""Real installs made by the REAL scripts (design §4 point 1): never JSON written by hand.

build_install(commit, shell) copies bundle/scripts from `commit` (e.g. 667d7ed, the origin/main format with the
aggregate only) into a throw-away repository that holds a small claude/ tree, commits it, and runs the old
install script against an empty live root.
"""
import atexit
import io
import os
import shutil
import subprocess
import tarfile
import tempfile

from tests.helpers import REPO, which

OLD_COMMIT = '667d7ed'       # origin/main: install registry without file_hashes
SCRIPTS_COMMIT = 'c7c437f'   # E6: last commit with every bundle/scripts script (removed in E7)
BASH = which('bash')
PWSH = which('pwsh')

SEED = {
    'skills/sdlc/SKILL.md': b'---\r\nname: sdlc\r\n---\r\nroot skill\r\n',
    'skills/sdlc/scripts/run.py': b'print("run")\n',
    'skills/sdlc-verify/SKILL.md': b'---\nname: sdlc-verify\n---\nverify\n',
    'commands/sdlc/dev.md': b'dev cmd\n',
    'commands/sdlc/brainstorm.md': b'brainstorm cmd\n',
    'agents/sdlc-architect.md': b'architect\n',
    'agents/nested/sdlc-deep.md': b'deep agent\n',
}


def commit_exists(commit):
    res = subprocess.run(['git', '-C', REPO, 'cat-file', '-e', commit + '^{commit}'],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return res.returncode == 0


def _git(repo, *args):
    subprocess.run(['git', '-C', repo] + list(args), check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def _extract_scripts(commit, dest):
    data = subprocess.run(['git', '-C', REPO, 'archive', commit, 'bundle/scripts'],
                          stdout=subprocess.PIPE, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        try:
            tar.extractall(dest, filter='data')
        except TypeError:      # Python < 3.12 without the filter argument
            tar.extractall(dest)


_pinned = []


def pinned_scripts():
    """bundle/scripts of SCRIPTS_COMMIT extracted once into a temporary folder (removed at exit), or None when
    the commit is missing (shallow clone, rewritten history): the parity tests then skip visibly."""
    if not _pinned:
        path = None
        if commit_exists(SCRIPTS_COMMIT):
            tmp = tempfile.mkdtemp(prefix='sdlc-pinned-scripts-')
            atexit.register(shutil.rmtree, tmp, True)
            _extract_scripts(SCRIPTS_COMMIT, tmp)
            path = os.path.join(tmp, 'bundle', 'scripts')
        _pinned.append(path)
    return _pinned[0]


def make_repo(tmp, commit, seed=SEED):
    """<tmp>/repo with the scripts of `commit` and a committed claude/ tree. Returns the repo path."""
    repo = os.path.join(tmp, 'repo')
    os.makedirs(repo)
    _extract_scripts(commit, repo)
    for rel, content in seed.items():
        path = os.path.join(repo, 'claude', *rel.split('/'))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as fh:
            fh.write(content)
    with open(os.path.join(repo, '.gitattributes'), 'wb') as fh:
        fh.write(b'* -text\n')
    _git(repo, 'init', '-q')
    _git(repo, 'config', 'user.email', 't@t')
    _git(repo, 'config', 'user.name', 't')
    _git(repo, 'config', 'commit.gpgsign', 'false')
    _git(repo, 'add', '-A')
    _git(repo, 'commit', '-q', '-m', 'seed')
    return repo


def install_with(shell, repo, live):
    """Run the repo's own install script (.sh with bash, .ps1 with pwsh) on an empty live root."""
    scripts = os.path.join(repo, 'bundle', 'scripts')
    if shell == 'sh':
        cmd = [BASH, os.path.join(scripts, 'install.sh'), '--claude-root', live,
               '--source-root', os.path.join(repo, 'claude')]
    else:
        cmd = [PWSH, '-NoProfile', '-File', os.path.join(scripts, 'install.ps1'), '-ClaudeRoot', live,
               '-SourceRoot', os.path.join(repo, 'claude')]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if res.returncode != 0:
        raise RuntimeError('old install failed (%d): %s' % (res.returncode, res.stdout.decode('utf-8', 'replace')[-2000:]))
    return res.stdout.decode('utf-8', 'replace')
