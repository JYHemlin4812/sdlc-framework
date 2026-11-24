"""Timestamped backups that keep relative paths (design §2 backup). Any error stops before deletion."""
import datetime
import errno
import os
import re
import stat
import tempfile

from . import paths
from .errors import InstallerError, SecurityError
from .fsops import read_bytes, safe_replace

BACKUP_DIR = '_backups'
_PREFIX = re.compile(r'[a-z0-9][a-z0-9-]*')


def _plan(live_root, rels):
    """Preflight of the sources: (rel, src) for each existing regular file; raises on anything else."""
    rels = list(rels)
    sources = paths.check_all(live_root, rels)
    plan = []
    for rel, src in zip(rels, sources):
        try:
            st = os.stat(src)
        except OSError as exc:
            if exc.errno == errno.ENOENT:
                continue
            raise
        if not stat.S_ISREG(st.st_mode):
            raise InstallerError('cannot back up a non-regular file: %s' % src)
        plan.append((rel, src))
    return plan


def backup_files(live_root, rels, prefix, backup_rel=BACKUP_DIR):
    """Back up each existing <live_root>/<rel> to a NEW folder <live_root>/<backup_rel>/<prefix>-<ts>-XXXX/<rel>.
    Order (E1-04, E1-R2-06): sources checked, backup root checked (no link or junction, inside live),
    and only then the folder is created. A refusal creates nothing. Returns (folder or None, rels copied)."""
    if not isinstance(prefix, str) or not _PREFIX.fullmatch(prefix):
        raise SecurityError('invalid backup prefix: %r' % (prefix,))
    plan = _plan(live_root, rels)
    if not plan:
        return None, []
    backup_root = paths.safe_target(live_root, backup_rel)
    os.makedirs(backup_root, exist_ok=True)
    if paths.is_link_or_junction(backup_root):
        raise InstallerError('backup root became a link: %s' % backup_root)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    folder = tempfile.mkdtemp(prefix='%s-%s-' % (prefix, stamp), dir=backup_root)
    done = []
    for rel, src in plan:
        safe_replace(paths.safe_target(folder, rel), read_bytes(src))
        done.append(rel)
    return folder, done
