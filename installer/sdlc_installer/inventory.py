"""Derived inventory (design §2, R3-01, E1-08): never a versioned file.

- head_inventory: regular blobs committed at HEAD under <subdir>/ (recursive, NUL-separated, with modes).
  An in-domain symlink, submodule or undecodable name is refused (SecurityError), whatever the working tree holds.
- tree_inventory: files present on disk (archive source, or --allow-dirty), same domain and exclusions.
"""
import subprocess

from . import domain, paths
from .errors import SecurityError, UsageError

REGULAR_MODES = (b'100644', b'100755')


def _git(repo, *args):
    cmd = ['git', '--no-optional-locks', '-C', repo] + list(args)
    try:
        return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except OSError as exc:
        raise UsageError('git not found: %s' % exc)


def head_inventory(repo, subdir='claude'):
    """Domain relative paths (relative to <repo>/<subdir>) committed at HEAD as regular files."""
    res = _git(repo, 'ls-tree', '-r', '-z', 'HEAD', '--', subdir)
    if res.returncode != 0:
        raise UsageError('cannot read HEAD of %s: %s' % (repo, res.stderr.decode('utf-8', 'replace').strip()))
    prefix = subdir.rstrip('/') + '/'
    rels = []
    for record in res.stdout.split(b'\0'):
        if not record:
            continue
        meta, _, raw_path = record.partition(b'\t')
        mode = meta.split(b' ')[0]
        # E1-R4-04: undecodable bytes survive classification (surrogateescape); validate_rel refuses
        # them only for a managed path, so an excluded or unrelated name does not block the bundle.
        path = raw_path.decode('utf-8', 'surrogateescape')
        if path == prefix.rstrip('/'):
            # E1-R5-01: ls-tree -r lists no tree records, so an exact record for the source root is a
            # link, gitlink or file standing where the bundle directory should be.
            raise SecurityError('the source root in HEAD is not a directory (mode %s): %s' % (mode.decode(), path))
        if not path.startswith(prefix):
            continue
        rel = path[len(prefix):]
        if domain.is_pruned(rel):
            continue
        if mode not in REGULAR_MODES:
            # E1-R2-03: a link or submodule at a domain file OR a domain root/ancestor is refused,
            # whatever the working tree holds (Git lists no descendants for it).
            if domain.may_hold_domain(rel):
                raise SecurityError('not a regular file in HEAD (mode %s): %s' % (mode.decode(), rel))
            continue
        if not domain.in_domain(rel):
            continue
        rels.append(paths.validate_rel(rel))
    paths.check_unique(rels)
    return sorted(rels)


def tree_inventory(root):
    """Domain relative paths present on disk under `root`."""
    rels = domain.domain_rels(root)
    for rel in rels:
        paths.validate_rel(rel)
    paths.check_unique(rels)
    return rels
