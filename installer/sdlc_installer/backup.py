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


def _check_prefix(prefix):
    if not isinstance(prefix, str) or not _PREFIX.fullmatch(prefix):
        raise SecurityError('invalid backup prefix: %r' % (prefix,))


def _new_folder(live_root, prefix, backup_rel):
    """Backup root checked (no link or junction, inside live), then a NEW timestamped folder created in it."""
    backup_root = paths.safe_target(live_root, backup_rel)
    os.makedirs(backup_root, exist_ok=True)
    if paths.is_link_or_junction(backup_root):
        raise InstallerError('backup root became a link: %s' % backup_root)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    return tempfile.mkdtemp(prefix='%s-%s-' % (prefix, stamp), dir=backup_root)


def backup_files(live_root, rels, prefix, backup_rel=BACKUP_DIR):
    """Back up each existing <live_root>/<rel> to a NEW folder <live_root>/<backup_rel>/<prefix>-<ts>-XXXX/<rel>.
    Order (E1-04, E1-R2-06): sources checked, backup root checked (no link or junction, inside live),
    and only then the folder is created. A refusal creates nothing. Returns (folder or None, rels copied)."""
    _check_prefix(prefix)
    plan = _plan(live_root, rels)
    if not plan:
        return None, []
    folder = _new_folder(live_root, prefix, backup_rel)
    done = []
    for rel, src in plan:
        safe_replace(paths.safe_target(folder, rel), read_bytes(src))
        done.append(rel)
    return folder, done


def backup_bytes(live_root, files, prefix, backup_rel=BACKUP_DIR):
    """Save bytes read elsewhere (capture: the losing reference file of an LWW resolution) under the live backup
    root, relative paths kept: <live_root>/<backup_rel>/<prefix>-<ts>-XXXX/<rel>. `files`: rel -> bytes.
    Paths are validated before the folder is created. Returns (folder or None, rels saved)."""
    _check_prefix(prefix)
    rels = sorted(files)
    if not rels:
        return None, []
    for rel in rels:
        paths.validate_rel(rel)
    paths.check_unique(rels)
    folder = _new_folder(live_root, prefix, backup_rel)
    for rel in rels:
        safe_replace(paths.safe_target(folder, rel), files[rel])
    return folder, rels
