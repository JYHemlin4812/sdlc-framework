"""Proof that a live file belongs to the bundle (design §3).

A live file <rel> of the domain is bundle-owned if its bytes equal one of:
  1. the source version being installed;
  2. a blob committed at claude/<rel> in the history of the reference branch (git log --raw);
  3. the sha256 recorded in the install registry (file_hashes), which covers an archive install.
Otherwise its origin is unknown. Git blobs equal the file bytes because .gitattributes holds '* -text'.
"""
import hashlib
import os
import stat
import subprocess

from . import domain, paths
from .errors import SecurityError, UsageError
from .inventory import _git

SOURCE = 'source'
HISTORY = 'history'
REGISTRY = 'registry'
UNKNOWN = 'unknown'

_REGULAR = (b'100644', b'100755')


def git_blob_id(data, algo='sha1'):
    """The Git blob id (hash of 'blob <size>\\0' + bytes) of `data`; `algo` is the repository's object format."""
    return hashlib.new(algo, b'blob %d\0' % len(data) + data).hexdigest()


def object_format(repo):
    """'sha1' or 'sha256' (E2-R3-08): the repository's object format; git older than 2.29 has only sha1."""
    res = _git(repo, 'rev-parse', '--show-object-format')
    fmt = res.stdout.decode('ascii', 'replace').strip() if res.returncode == 0 else 'sha1'
    return fmt if fmt in ('sha1', 'sha256') else 'sha1'


def history_blobs(repo, subdir='claude'):
    """rel -> set of blob ids ever committed at <subdir>/<rel> on HEAD's history (domain paths only).
    --root and -m cover the root commit and merges; --full-history is a safety net against Git dropping a merged
    side branch whose tree the merge did not keep (E2-R1-11; measured: with -m Git already visits every parent,
    so the flag changes nothing today); --no-renames keeps one path per record."""
    res = _git(repo, 'log', '--format=', '--raw', '--no-abbrev', '--root', '-m', '--full-history', '--no-renames',
               '-z', '--', subdir)
    if res.returncode != 0:
        raise UsageError('cannot read the history of %s: %s' % (repo, res.stderr.decode('utf-8', 'replace').strip()))
    prefix = subdir.rstrip('/') + '/'
    blobs = {}
    tokens = res.stdout.split(b'\0')
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        i += 1
        if not tok.startswith(b':'):
            continue
        fields = tok[1:].split(b' ')
        if i >= len(tokens) or len(fields) < 5:
            break
        path = tokens[i].decode('utf-8', 'surrogateescape')
        i += 1
        new_mode, new_id = fields[1], fields[3].decode('ascii', 'replace')
        if new_mode not in _REGULAR or not new_id.strip('0') or not path.startswith(prefix):
            continue
        rel = path[len(prefix):]
        if domain.in_domain(rel):
            blobs.setdefault(rel, set()).add(new_id)
    return blobs


def is_shallow(repo):
    """True for a shallow clone (history incomplete: 'historique incomplet')."""
    res = _git(repo, 'rev-parse', '--is-shallow-repository')
    return res.returncode == 0 and res.stdout.strip() == b'true'


class Ownership(object):
    """Classifies live files. `repo`: the reference Git repository (None for an archive source);
    `registry_hashes`: file_hashes of the install registry, or None."""

    def __init__(self, repo=None, registry_hashes=None, subdir='claude'):
        self.repo = repo
        self.registry_hashes = registry_hashes or {}
        self.subdir = subdir
        self._history = None
        self._algo = None

    @property
    def algo(self):
        if self._algo is None:
            self._algo = object_format(self.repo) if self.repo else 'sha1'
        return self._algo

    @property
    def history(self):
        if self._history is None:
            self._history = history_blobs(self.repo, self.subdir) if self.repo else {}
        return self._history

    @property
    def history_incomplete(self):
        return bool(self.repo) and is_shallow(self.repo)

    def classify(self, rel, live_bytes, source_bytes=None):
        """SOURCE, HISTORY, REGISTRY or UNKNOWN for the live content of <rel>.
        Only a path of the SDLC domain can be bundle-owned (E2-R1-05): anything else is UNKNOWN;
        an unsafe relative path raises SecurityError."""
        paths.validate_rel(rel)                    # E2-R2-05: a lexically unsafe path is refused, not classified
        if not domain.in_domain(rel):
            return UNKNOWN
        if source_bytes is not None and live_bytes == source_bytes:
            return SOURCE
        if self.repo and git_blob_id(live_bytes, self.algo) in self.history.get(rel, ()):
            return HISTORY
        recorded = self.registry_hashes.get(rel)
        if recorded and hashlib.sha256(live_bytes).hexdigest() == recorded.lower():
            return REGISTRY
        return UNKNOWN

    def classify_file(self, live_root, rel, source_bytes=None):
        """Like classify, reading <live_root>/<rel> through the confined path (E2-R1-04: a link anywhere in
        the chain is SecurityError, never read through). Absent file: None. Not a regular file: SecurityError."""
        path = paths.safe_target(live_root, rel)
        try:
            st = os.lstat(path)
        except FileNotFoundError:
            return None
        if not stat.S_ISREG(st.st_mode):
            raise SecurityError('not a regular file: %s' % path)
        with open(path, 'rb') as fh:
            data = fh.read()
        return self.classify(rel, data, source_bytes)
