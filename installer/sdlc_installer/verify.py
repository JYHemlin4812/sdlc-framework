"""verify (design §8.2): is the live tree byte-identical to the COMMITTED HEAD of the reference?

Read-only: no file, no lock, no index refresh (git --no-optional-locks). Port of verify.ps1:
- reference = regular blobs of HEAD:<subdir>/ in the SDLC domain (never the working tree);
- live = domain files on disk (third-party skills ignored, sync exclusions never counted);
- MISSING, HASH DIFF, EXTRA and FLOOR (cardinalities derived from HEAD, never literals).
Comparison by Git blob id: the live bytes are hashed the way Git hashes a blob, so no blob is read.
Codes: 0 identical, 1 at least one difference, 2 unavailable (live missing, git or HEAD missing, unreadable).
"""
import collections
import os

from . import domain, gitstate, inventory, paths
from .errors import FAILED, OK, USAGE, InstallerError
from .fsops import read_bytes
from .ownership import git_blob_id, object_format

VerifyResult = collections.namedtuple(
    'VerifyResult', 'code missing hash_diff extra floor ref_count live_count reason')


def _unavailable(reason):
    return VerifyResult(USAGE, [], [], [], [], 0, 0, reason)


def cardinalities(rels):
    """(skills, agents, commands) of a set of domain paths (port of Get-DomainCardinalities, case-sensitive)."""
    skills, agents, commands = set(), 0, 0
    for rel in rels:
        seg = rel.split('/')
        if seg[0] == 'skills' and len(seg) >= 2:
            skills.add(seg[1])
        elif seg[0] == 'agents':
            agents += 1
        elif rel.startswith('commands/sdlc/'):
            commands += 1
    return len(skills), agents, commands


def verify(ref_repo, live_root, subdir='claude'):
    """Compare <live_root> with HEAD:<subdir> of the repository `ref_repo`. Returns a VerifyResult."""
    if not os.path.isdir(live_root):
        return _unavailable('live root not found: %s' % live_root)
    try:
        # E3-R2-05: identical or nested roots compare a tree with itself; refused (§5.1 point 1).
        paths.check_disjoint(os.path.join(ref_repo, *subdir.split('/')), live_root, 'reference and live')
        top = gitstate.worktree_root(ref_repo) if os.path.isdir(ref_repo) else None
        if top is None:
            return _unavailable('reference is not a Git worktree (or git is missing): %s' % ref_repo)
        if os.path.normcase(top) != os.path.normcase(os.path.realpath(ref_repo)):
            # E3-R3-04: --ref is the repository root; a sub-folder would read the wrong subtree.
            return _unavailable('reference is not the root of its Git worktree (%s): %s' % (top, ref_repo))
        if gitstate.head_commit(ref_repo) is None:
            return _unavailable('reference has no committed HEAD: %s' % ref_repo)
        if not gitstate.has_tree(ref_repo, subdir):
            return _unavailable('HEAD of %s has no %s/ folder' % (ref_repo, subdir))
        ref = inventory.head_blob_ids(ref_repo, subdir)
        algo = object_format(ref_repo)
        live = {}
        for rel in domain.domain_rels(live_root, allow_root_link=True):
            live[rel] = git_blob_id(read_bytes(paths.safe_target(live_root, rel)), algo)
    except (InstallerError, OSError) as exc:
        return _unavailable(str(exc))

    missing = sorted(rel for rel in ref if rel not in live)
    hash_diff = sorted(rel for rel in ref if rel in live and live[rel] != ref[rel])
    extra = sorted(rel for rel in live if rel not in ref)
    floor = []
    for name, want, got in zip(('skills', 'agents', 'commands'), cardinalities(ref), cardinalities(live)):
        if want != got:
            floor.append('%s: floor=%d live=%d' % (name, want, got))
    differences = len(missing) + len(hash_diff) + len(extra) + len(floor)
    return VerifyResult(FAILED if differences else OK, missing, hash_diff, extra, floor, len(ref), len(live), None)


def report(result, write):
    """Print a VerifyResult with the markers of verify.ps1 ([MISSING], [HASH DIFF], [EXTRA], [FLOOR])."""
    if result.code == USAGE:
        write('  verify unavailable: %s' % result.reason)
        return
    write('  ref (committed HEAD) : %d domain files' % result.ref_count)
    write('  live (sdlc scope)    : %d domain files' % result.live_count)
    for label, items in (('MISSING', result.missing), ('HASH DIFF', result.hash_diff),
                         ('EXTRA', result.extra), ('FLOOR', result.floor)):
        for item in items:
            write('  [%s]%s%s' % (label, ' ' * max(1, 14 - len(label)), item))
    if result.code == OK:
        write('  PERFECT fidelity: live == committed ref HEAD (0 differences).')
    else:
        total = len(result.missing) + len(result.hash_diff) + len(result.extra) + len(result.floor)
        write('  FAIL: %d difference(s) found. Live != canonical ref.' % total)
