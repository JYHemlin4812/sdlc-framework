"""Git state of the reference (design §2 gitstate, §7). Every call goes through inventory._git
(git --no-optional-locks), so reading the state never rewrites the index (design §9)."""
import contextlib
import os
import subprocess

from . import inventory
from .errors import UsageError
from .inventory import _git

_LOCAL_ONLY = []                 # non-empty inside local_objects_only
_SWITCH = []                     # cached answer of no_lazy_fetch_supported


def _out(res):
    return res.stdout.decode('utf-8', 'surrogateescape').strip()


def _git_marker(path):
    """Nearest ancestor of `path` (itself included) holding a '.git' entry, or None."""
    current = os.path.realpath(path)
    while True:
        if os.path.lexists(os.path.join(current, '.git')):
            return current
        parent = os.path.dirname(current)
        if parent == current:
            return None
        current = parent


def worktree_root(path):
    """Physical root of the Git worktree holding `path`, or None when no repository is there.
    E3-R2-03: a repository that is present but unreadable (git missing, 'dubious ownership'...) is a UsageError,
    never 'no repository': the worktree confinement (§5.1 point 2) cannot be skipped."""
    try:
        res = _git(path, 'rev-parse', '--show-toplevel')
    except UsageError:
        res = None
    # E3-R3-02: only the line terminator Git adds is removed; a path may end with a space.
    top = res.stdout.decode('utf-8', 'surrogateescape') if res is not None else ''
    top = top[:-1] if top.endswith('\n') else top
    if res is not None and res.returncode == 0 and top:
        return os.path.realpath(top)
    marker = _git_marker(path)
    if marker is not None:
        detail = res.stderr.decode('utf-8', 'replace').strip() if res is not None else 'git not found'
        raise UsageError('a Git repository is present at %s but git cannot read it: %s' % (marker, detail))
    return None


def head_commit(repo):
    """Full id of the HEAD commit, or None when the branch has no commit yet (unborn).
    E3-R3-03: HEAD that names an object Git cannot read as a commit is a UsageError, never 'no commit'."""
    res = _git(repo, 'rev-parse', '--verify', '--quiet', 'HEAD^{commit}')
    if res.returncode == 0 and _out(res):
        return _out(res)
    named = _git(repo, 'rev-parse', '--verify', '--quiet', 'HEAD')
    if named.returncode == 0 and _out(named):
        raise UsageError('HEAD of %s names %s, which is not a readable commit' % (repo, _out(named)))
    return None


def has_tree(repo, subdir, rev='HEAD'):
    """True if <rev>:<subdir> is a tree (the reference folder exists in the commit)."""
    res = _git(repo, 'cat-file', '-t', rev + ':' + subdir)
    return res.returncode == 0 and _out(res) == 'tree'


def subdir_of(repo, path):
    """'/' path of `path` relative to the worktree `repo` ('' for the root itself), or None if outside."""
    rel = os.path.relpath(os.path.realpath(path), os.path.realpath(repo))
    if rel == os.curdir:
        return ''
    if rel == os.pardir or rel.startswith(os.pardir + os.sep) or os.path.isabs(rel):
        return None
    return rel.replace(os.sep, '/')


def is_dirty(repo, subdir):
    """True if `subdir` has staged, unstaged or untracked (not ignored) changes against HEAD."""
    res = _git(repo, 'status', '--porcelain', '-z', '--untracked-files=all', '--', subdir)
    if res.returncode != 0:
        raise UsageError('git status failed in %s: %s' % (repo, res.stderr.decode('utf-8', 'replace').strip()))
    return bool(res.stdout.strip(b'\0'))


def head_skill_folders(repo, subdir):
    """Names of the sdlc* folders directly under HEAD:<subdir>/skills (E3-R1-05: a folder whose files are all
    excluded still needs its SKILL.md, as install.ps1 checks the folders it finds)."""
    res = _git(repo, 'ls-tree', '-z', 'HEAD', '--', subdir.rstrip('/') + '/skills/')
    if res.returncode != 0:
        raise UsageError('cannot read HEAD of %s: %s' % (repo, res.stderr.decode('utf-8', 'replace').strip()))
    names = []
    for record in res.stdout.split(b'\0'):
        meta, _, raw = record.partition(b'\t')
        fields = meta.split(b' ')
        name = raw.decode('utf-8', 'surrogateescape').rsplit('/', 1)[-1]
        if len(fields) == 3 and fields[1] == b'tree' and name.startswith('sdlc'):
            names.append(name)
    return names


def is_partial_clone(repo):
    """E6-R1-11, E6-R2-02, FINAL-R2-03: extensions.partialClone, any remote.<name>.promisor set to true, or any
    remote.<name>.partialclonefilter (an older Git treats that alone as a remote able to supply missing objects).
    Reading a missing object of such a clone may fetch it and write under .git/objects."""
    res = _git(repo, 'config', '--get', 'extensions.partialclone')
    if res.returncode == 0 and res.stdout.strip():
        return True
    res = _git(repo, 'config', '--bool', '--get-regexp', r'^remote\..*\.promisor$')
    if res.returncode == 0 and any(line.split()[-1:] == [b'true'] for line in res.stdout.splitlines()):
        return True
    res = _git(repo, 'config', '--get-regexp', r'^remote\..*\.partialclonefilter$')
    return res.returncode == 0 and any(len(line.split()) > 1 for line in res.stdout.splitlines())


def no_lazy_fetch_supported():
    """True if this Git accepts --no-lazy-fetch (an unknown global option makes git fail). Probed once."""
    if not _SWITCH:
        try:
            res = subprocess.run(['git', '--no-lazy-fetch', 'version'], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, check=False)
            _SWITCH.append(res.returncode == 0)
        except OSError:
            return False
    return _SWITCH[0]


@contextlib.contextmanager
def local_objects_only(active=True):
    """FINAL-R1-04: a dry-run never fetches a missing object of a partial clone. Inside the block every git call
    passes --no-lazy-fetch when Git has it (a missing object is then an error, code 2); otherwise
    require_local_objects refuses a partial clone before any object is read."""
    if not active:
        yield
        return
    saved = list(inventory.GLOBAL_OPTS)
    if no_lazy_fetch_supported():
        inventory.GLOBAL_OPTS[:] = saved + ['--no-lazy-fetch']
    _LOCAL_ONLY.append(True)
    try:
        yield
    finally:
        _LOCAL_ONLY.pop()
        inventory.GLOBAL_OPTS[:] = saved


def require_local_objects(repo):
    """Inside local_objects_only, with a Git without --no-lazy-fetch: a partial clone is refused (2).
    No-op elsewhere."""
    if _LOCAL_ONLY and '--no-lazy-fetch' not in inventory.GLOBAL_OPTS and is_partial_clone(repo):
        raise UsageError('partial clone: this Git cannot read objects without fetching the missing ones '
                         '(--no-lazy-fetch needs a newer Git); dry-run refused: %s' % repo)


def read_blobs(repo, ids):
    """oid -> bytes for each blob id, through one `git cat-file --batch`. A missing object is a UsageError."""
    wanted = sorted(set(ids))
    if not wanted:
        return {}
    try:
        cmd = ['git', '--no-optional-locks'] + inventory.GLOBAL_OPTS + ['-C', repo, 'cat-file', '--batch']
        res = subprocess.run(cmd,
                             input=('\n'.join(wanted) + '\n').encode('ascii'),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except OSError as exc:
        raise UsageError('git not found: %s' % exc)
    if res.returncode != 0:
        raise UsageError('git cat-file failed: %s' % res.stderr.decode('utf-8', 'replace').strip())
    data, pos, out = res.stdout, 0, {}
    for oid in wanted:
        end = data.find(b'\n', pos)
        header = data[pos:end].split(b' ') if end >= 0 else []
        if len(header) == 2 and header[1] == b'missing':
            raise UsageError('git cat-file: blob %s missing locally (partial clone, not fetched)' % oid)
        if len(header) != 3 or header[1] != b'blob' or header[0].decode('ascii', 'replace') != oid:
            raise UsageError('git cat-file: blob %s not readable' % oid)
        size = int(header[2])
        out[oid] = data[end + 1:end + 1 + size]
        pos = end + 1 + size + 1
    return out
