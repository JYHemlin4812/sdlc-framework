"""Three-way sync state (design §8.3, §8.4): port of sync-lib Get-SyncState, Get-FirstRunPlan and Resolve-LWW.

classify and first_run_plan are pure. resolve_lww appends one line to conflicts.log (append only), except in dry-run.
A hash is absent when it is None or '' (read_sync_manifest gives '' for a null entry). Hashes are compared without
case, like PowerShell -eq (the Bash port compares lower-case hex too).
"""
import collections
import datetime
import os

from . import paths
from .errors import SecurityError, UsageError

ABSENT_BOTH = 'absent-both'
ADDED_REF = 'added-ref'
ADDED_LIVE = 'added-live'
DELETED_REF = 'deleted-ref'
DELETED_LIVE = 'deleted-live'
IDENTICAL = 'identical'
MODIFIED_REF = 'modified-ref'
MODIFIED_LIVE = 'modified-live'
MODIFIED_BOTH = 'modified-both'
CONFLICT_DELETED_LIVE = 'conflict-deleted-live-modified-ref'
CONFLICT_DELETED_REF = 'conflict-deleted-ref-modified-live'

FirstRunPlan = collections.namedtuple('FirstRunPlan', 'signal adopted mismatches union')
LwwResult = collections.namedtuple('LwwResult', 'rel winner logged line')


def _norm(value):
    return value.lower() if value else None


def classify(ref_hash, live_hash, base_hash):
    """State of one relative path from the hashes of the reference, the live tree and the base (Get-SyncState)."""
    ref, live, base = _norm(ref_hash), _norm(live_hash), _norm(base_hash)
    if ref is None and live is None:
        return ABSENT_BOTH
    if live is None:
        if base is None:
            return ADDED_REF
        return DELETED_LIVE if ref == base else CONFLICT_DELETED_LIVE
    if ref is None:
        if base is None:
            return ADDED_LIVE                       # protected: never deleted, never guessed
        return DELETED_REF if live == base else CONFLICT_DELETED_REF
    if ref == live:
        return IDENTICAL
    if base is None:
        return MODIFIED_BOTH                        # added on both sides, different: handled as modified-both
    if ref == base:
        return MODIFIED_LIVE
    if live == base:
        return MODIFIED_REF
    return MODIFIED_BOTH


def first_run_plan(ref_hashes, live_hashes, adopt=False):
    """Without a base (Get-FirstRunPlan): the union is iterated; all equal gives 'seed'; any asymmetry or difference
    gives 'block', unless `adopt`, which seeds anyway (adopted=True). Never freezes a divergence silently."""
    union = sorted(set(ref_hashes) | set(live_hashes))
    mismatches = [rel for rel in union if _norm(ref_hashes.get(rel)) != _norm(live_hashes.get(rel))]
    if not mismatches:
        return FirstRunPlan('seed', False, [], union)
    if adopt:
        return FirstRunPlan('seed', True, mismatches, union)
    return FirstRunPlan('block', False, mismatches, union)


def seed_entries(plan, ref_hashes, live_hashes):
    """Base written by a first-run seed: the reference hash when present, otherwise the live one."""
    seed = {}
    for rel in plan.union:
        if rel in ref_hashes:
            seed[rel] = ref_hashes[rel]
        elif rel in live_hashes:
            seed[rel] = live_hashes[rel]
    return seed


def check_log(log_path):
    """conflicts.log must be a regular file (or absent), never a link or junction (§5.2 point 3)."""
    if paths.is_link_or_junction(log_path):
        raise SecurityError('conflicts.log is a link or junction: %s' % log_path)
    if os.path.lexists(log_path) and not os.path.isfile(log_path):
        raise SecurityError('conflicts.log is not a regular file: %s' % log_path)
    if os.path.isfile(log_path) and os.stat(log_path).st_nlink > 1:
        raise SecurityError('conflicts.log has other hard links, refusing to append to it: %s' % log_path)


def resolve_lww(rel, log_path, ref_hash, live_hash, provenance='ref', dry_run=False, now=None):
    """Opt-in resolution of a modified-both path (Resolve-LWW). The winner is the reference unless provenance is
    'live'; a modification time is never used. Appends one line to `log_path` (never rewritten in place), except
    in dry-run. The log must not be a link or junction (§5.2 point 3)."""
    if provenance not in ('ref', 'live'):
        raise UsageError('provenance must be ref or live: %r' % (provenance,))
    winner = 'live' if provenance == 'live' else 'ref'
    stamp = (now or datetime.datetime.now(datetime.timezone.utc).astimezone()).isoformat()
    line = '%s | relpath=%s | ref=%s | live=%s | provenance=%s | winner=%s' % (
        stamp, rel, ref_hash or '', live_hash or '', provenance, winner)
    if dry_run:
        return LwwResult(rel, winner, False, line)
    check_log(log_path)
    parent = os.path.dirname(log_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(log_path, 'a', encoding='utf-8', newline='\n') as fh:
        fh.write(line + '\n')
    return LwwResult(rel, winner, True, line)
