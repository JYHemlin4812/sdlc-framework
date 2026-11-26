"""capture (design §8.3): propose the live changes to the reference (repo/claude) and commit them.

- The reference side is the WORKING TREE of <ref>/<subdir> (an interrupted capture and a modified-both depend on
  what is not committed yet); the live side is the SDLC domain of the live root; the base is the sync manifest.
- States (syncstate.classify): modified-live and added-live are copied live -> reference; modified-both blocks (3)
  unless --lww; deleted-live and conflict-* block (3); identical with base != reference finishes an interrupted
  capture (R3-05); everything else is ignored. One block: nothing written (files, base, Git, conflicts.log).
- git add and git commit are limited to the copied paths (literal pathspecs): changes staged elsewhere stay staged.
- Post-check: those paths clean in git status, otherwise 7 and the base is not rewritten.

Order: roots (§5.1, before any lock or file) -> lock (none in dry-run) -> union of the domains -> base (absent: first
run; corrupt: 6) -> classification -> blocks (3) -> LWW -> path checks on the whole write set -> backup of the
losing references -> copy -> add/commit (4) -> post-check (7) -> base. Every file is read once; the bytes that were
classified are the bytes copied and recorded.
"""
import collections
import difflib
import os
import re
import subprocess

from . import backup, domain, gitstate, inventory, locks, manifests, paths, syncstate
from .errors import (BLOCKED, CORRUPT_BASE, DIRTY, DRIFT, GIT_FAILED, OK, SecurityError, UsageError)
from .fsops import read_bytes, safe_replace
from .ownership import git_blob_id, object_format

Options = collections.namedtuple('Options', 'ref live subdir manifest conflict_log lww provenance adopt dry_run')
Options.__new__.__defaults__ = ('claude', None, None, False, 'ref', False, False)
Roots = collections.namedtuple('Roots', 'repo subdir ref live manifest conflict_log manifest_in_live')
Side = collections.namedtuple('Side', 'files hashes')

CONFLICT_LOG_NAME = 'conflicts.log'
_DIFF_LINES = 200


class _Out(object):
    def __init__(self, write):
        self.write = write

    def ok(self, msg):
        self.write('  [OK] %s' % msg)

    def step(self, msg):
        self.write('  - %s' % msg)

    def warn(self, msg):
        self.write('  [WARN] %s' % msg)

    def err(self, msg):
        self.write('  [ERR] %s' % msg)


# --- roots (shared with restore) ------------------------------------------------------------------

def _explicit(value, label):
    if value is not None and not value.strip():
        raise UsageError('%s is empty' % label)          # never falls back to a default by accident
    return value


def _lexical_rel(path, root):
    """'/' path of `path` below `root` compared lexically (no link resolved), '' for the root itself, None outside."""
    p, r = os.path.normcase(path), os.path.normcase(root)
    try:
        if os.path.commonpath([p, r]) != r:
            return None
    except ValueError:                                   # different Windows drives
        return None
    return os.path.relpath(path, root).replace(os.sep, '/') if p != r else ''


def _state_path(arg, live_arg, live, default_name, label):
    """(path, inside_live) of a machine-local state file (E5-R1-02). The raw argument is checked before any
    normalisation ('..' refused); below the live root (given or physical spelling) every component is checked
    with safe_target; an explicit outside location must not go through a link or junction anywhere."""
    if arg is None:
        return paths.safe_target(live, default_name), True
    if '..' in re.split(r'[\\/]', arg):
        raise SecurityError('%s contains "..": %s' % (label, arg))
    path = os.path.abspath(arg)
    for root in (os.path.abspath(live_arg), live):
        rel = _lexical_rel(path, root)
        if rel == '':
            raise UsageError('%s is the live root itself: %s' % (label, arg))
        if rel is not None:
            return paths.safe_target(live, rel), True
    current = path
    while True:
        if paths.is_link_or_junction(current):
            raise SecurityError('%s goes through a link or junction (%s): %s' % (label, current, arg))
        parent = os.path.dirname(current)
        if parent == current:
            return path, False
        current = parent


def _check_state_overlap(live, states):
    """E5-R1-03: the state files are distinct files, and none of them is a managed live file (SDLC domain, install
    registry, lock). Raises UsageError (2), before any lock or file."""
    seen = {}
    for label, path in states.items():
        key = os.path.normcase(os.path.realpath(path))
        if key in seen:
            raise UsageError('%s and %s are the same file: %s' % (seen[key], label, path))
        seen[key] = label
        rel = _lexical_rel(os.path.realpath(path), live)
        if rel is None:
            continue
        reserved = (manifests.INSTALL_REGISTRY_REL.casefold(), locks.LOCK_NAME.casefold())
        top = rel.split('/')[0].casefold()
        if (domain.in_domain(rel) or domain.may_hold_domain(rel) or rel.casefold() in reserved
                or top == backup.BACKUP_DIR.casefold()):          # E5-R2-04: the backup root is reserved too
            raise UsageError('%s must not be a managed live file: %s' % (label, path))
    log = states.get('conflicts.log')
    if log and os.path.isfile(log) and os.stat(log).st_nlink > 1:
        # E5-R2-03: conflicts.log is appended in place; a hard link would write into another file (the base...).
        raise SecurityError('conflicts.log has other hard links, refusing to append to it: %s' % log)


def resolve_roots(ref_repo, subdir, live, manifest=None, conflict_log=None, command='capture'):
    """§5.1, before any lock or file: the reference is the root of a Git worktree holding <subdir>/; the live root
    exists; both are disjoint; the machine-local state (live, base, conflicts.log, lock, backups) is outside the
    worktree, confined (E5-R1-02) and distinct from the managed live files (E5-R1-03). Raises UsageError (2) or
    SecurityError (3)."""
    _explicit(ref_repo, '--ref')
    _explicit(manifest, '--manifest-path')
    _explicit(conflict_log, '--conflict-log')
    if not os.path.isdir(ref_repo):
        raise UsageError('%s: reference repository not found: %s' % (command, ref_repo))
    top = gitstate.worktree_root(ref_repo)
    if top is None:
        raise UsageError('%s: the reference is not a Git worktree (or git is missing): %s' % (command, ref_repo))
    if os.path.normcase(top) != os.path.normcase(os.path.realpath(ref_repo)):
        raise UsageError('%s: --ref must be the root of its Git worktree (%s): %s' % (command, top, ref_repo))
    paths.validate_rel(subdir)
    ref = paths.safe_target(top, subdir)
    if not os.path.isdir(ref):
        raise UsageError('%s: reference folder not found: %s' % (command, ref))
    if not os.path.isdir(live):
        raise UsageError('%s: live root not found: %s' % (command, live))
    live_arg, live = live, os.path.realpath(live)
    paths.check_disjoint(ref, live, 'reference and live')
    manifest, manifest_in = _state_path(manifest, live_arg, live, manifests.SYNC_MANIFEST_NAME, '--manifest-path')
    conflict_log, log_in = _state_path(conflict_log, live_arg, live, CONFLICT_LOG_NAME, '--conflict-log')
    paths.check_outside_worktree(top, {
        'live root': live,
        'sync manifest': manifest,
        'conflicts.log': conflict_log,
        'lock': os.path.join(live, locks.LOCK_NAME),
        'backup root': os.path.join(live, backup.BACKUP_DIR),
    })
    _check_state_overlap(live, {'sync manifest': manifest, 'conflicts.log': conflict_log})
    return Roots(top, subdir, ref, live, manifest, conflict_log, manifest_in)


def read_base(roots):
    """The sync manifest, confined to the live root when it lives there. A base key that is not a safe relative
    path makes the base untrusted (fail closed), before any mutation."""
    base = manifests.read_sync_manifest(roots.manifest, roots.live if roots.manifest_in_live else None)
    if base.ok:
        try:
            for rel in base.entries:
                paths.validate_rel(rel)
        except SecurityError:
            return manifests._fail_closed()
    return base


def write_base(roots, entries):
    return manifests.write_sync_manifest(roots.manifest, entries, root=roots.live if roots.manifest_in_live else None)


def read_side(root, rels):
    files = dict((rel, read_bytes(paths.safe_target(root, rel))) for rel in rels)
    return Side(files, dict((rel, manifests.sha256_hex(data)) for rel, data in files.items()))


def live_side(live):
    return read_side(live, domain.domain_rels(live, allow_root_link=True))


def check_union(*sides):
    union = sorted(set().union(*[set(s.files) for s in sides]))
    for rel in union:
        paths.validate_rel(rel)
    paths.check_unique(union)
    return union


def show_diff(out, rel, ref_data, live_data):
    """Readable difference of a blocked path (Show-ConflictDiff), cut after a few hundred lines."""
    a = ref_data.decode('utf-8', 'replace').splitlines()
    b = live_data.decode('utf-8', 'replace').splitlines()
    lines = list(difflib.unified_diff(a, b, 'ref/' + rel, 'live/' + rel, lineterm=''))
    for line in lines[:_DIFF_LINES]:
        out.write('      ' + line)
    if len(lines) > _DIFF_LINES:
        out.write('      ... (%d more lines)' % (len(lines) - _DIFF_LINES))


def check_backup_root(live):
    """The live backup root must be a folder (or absent) and not a link, before any mutation."""
    root = paths.safe_target(live, backup.BACKUP_DIR)              # a link is refused here (3)
    if os.path.lexists(root) and not os.path.isdir(root):
        raise SecurityError('ABORT: the backup root exists and is not a directory: %s' % root)


def git_pathspecs(roots, rels):
    return [roots.subdir + '/' + rel for rel in rels]


def git_run(roots, *args, **kwargs):
    """git with literal pathspecs (a '[' in a name is never a pattern). `stdin`: bytes for --pathspec-from-file=-,
    so a long list never reaches the command line (E5-R1-08)."""
    cmd = ['git', '--no-optional-locks', '-C', roots.repo, '--literal-pathspecs'] + list(args)
    try:
        return subprocess.run(cmd, input=kwargs.get('stdin'), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              check=False)
    except OSError as exc:
        raise UsageError('git not found: %s' % exc)


def _nul_list(items):
    return b''.join(item.encode('utf-8', 'surrogateescape') + b'\0' for item in items)


def head_blobs(roots):
    """rel -> blob id at HEAD under <subdir>/ ({} on an unborn branch), with the repository's hash function."""
    if gitstate.head_commit(roots.repo) is None:
        return {}, object_format(roots.repo)
    return inventory.head_blob_ids(roots.repo, roots.subdir), object_format(roots.repo)


def _dirty_paths(roots):
    """'/' paths under <subdir>/ that git status reports (staged, unstaged or untracked)."""
    # E5-R2-06: --no-renames reports a staged rename as a deletion plus an addition, so both paths are seen.
    res = git_run(roots, 'status', '--porcelain=v1', '-z', '--no-renames', '--untracked-files=all', '--', roots.subdir)
    if res.returncode != 0:
        return None
    found, tokens, i = set(), res.stdout.split(b'\0'), 0
    while i < len(tokens):
        tok = tokens[i]
        i += 1
        if len(tok) < 4:
            continue
        found.add(tok[3:].decode('utf-8', 'surrogateescape'))
        if tok[0:1] in (b'R', b'C') or tok[1:2] in (b'R', b'C'):
            i += 1                                        # rename/copy: the origin path follows
    return found


def _text(res):
    return (res.stdout + res.stderr).decode('utf-8', 'replace').strip()


# --- command --------------------------------------------------------------------------------------

def run(opts, write=print):
    out = _Out(write)
    if opts.provenance not in ('ref', 'live'):
        raise UsageError('--provenance must be ref or live')
    if opts.provenance == 'live' and not opts.lww:
        raise UsageError('--provenance live only applies with --lww')
    roots = resolve_roots(opts.ref, opts.subdir, opts.live, opts.manifest, opts.conflict_log, 'capture')
    write('capture %s: ref=%s  live=%s' % ('[dry-run] ' if opts.dry_run else '', roots.ref, roots.live))
    if opts.dry_run:
        return _capture(roots, opts, out)              # design §2: no lock in dry-run
    with locks.live_lock(roots.live):
        return _capture(roots, opts, out)


def _capture(roots, opts, out):
    ref = read_side(roots.ref, domain.domain_rels(roots.ref))
    live = live_side(roots.live)
    union = check_union(ref, live)
    base = read_base(roots)
    # E5-R2-08, E5-R3-04: the whole HEAD inventory is read (and its domain links refused) before any write,
    # first run included, never after a commit.
    ids, algo = head_blobs(roots)

    if not base.exists:
        return _first_run(roots, opts, out, ref, live)
    if base.fail_closed:
        out.err('capture: unreadable/corrupt manifest -> FAIL CLOSED (no action): %s' % roots.manifest)
        out.err('No capture is attempted on an untrusted base.')
        return CORRUPT_BASE

    copy, blocks, lww, pending = [], [], [], {}
    for rel in union:
        ref_h, live_h, base_h = ref.hashes.get(rel), live.hashes.get(rel), base.entries.get(rel)
        state = syncstate.classify(ref_h, live_h, base_h)
        if state in (syncstate.MODIFIED_LIVE, syncstate.ADDED_LIVE):
            copy.append(rel)
        elif state == syncstate.MODIFIED_BOTH:
            (lww if opts.lww else blocks).append((rel, state))
        elif state == syncstate.IDENTICAL:
            if (base_h or '').lower() != ref_h:
                pending[rel] = ref_h                    # R3-05: an earlier capture did not finish
        elif state in (syncstate.MODIFIED_REF, syncstate.ADDED_REF, syncstate.DELETED_REF, syncstate.ABSENT_BOTH):
            pass
        else:
            blocks.append((rel, state))                 # deleted-live and conflict-*: never without a direction

    if blocks:
        out.err('capture: BLOCKED - %d unresolved conflict(s). Nothing written.' % len(blocks))
        for rel, state in blocks:
            out.err('[BLOCK] %s  (%s)' % (rel, state))
            if rel in ref.files and rel in live.files:
                show_diff(out, rel, ref.files[rel], live.files[rel])
        out.warn('Resolve manually, or use --lww (opt-in, logged) for modified-both.')
        return BLOCKED

    # --- R3-05: finish an interrupted capture -----------------------------------------------
    # E5-R1-04: the base moves only on proof that HEAD holds these bytes; otherwise the path is still to commit
    # (an ignored or index-only file included), never assumed committed because git status is quiet.
    base_fix = {}
    for rel in sorted(pending):
        if ids.get(rel) == git_blob_id(ref.files[rel], algo):
            base_fix[rel] = pending[rel]
        else:
            out.warn('[PENDING] %s (copied earlier, not committed)' % rel)
            copy.append(rel)
    if base_fix:
        # E5-R2-05: HEAD holds the bytes, but a change staged (or made) on that path since is not ours to publish.
        dirty = _dirty_paths(roots)
        unclean = sorted(rel for rel in base_fix if dirty is None or roots.subdir + '/' + rel in dirty)
        if unclean:
            out.err('capture: BLOCKED - %d interrupted capture(s) with uncommitted changes in the reference. '
                    'Nothing written.' % len(unclean))
            for rel in unclean:
                out.err('[BLOCK] %s  (committed, but changed in the index or working tree since)' % rel)
            out.warn('Commit or reset these paths in the reference, then run capture again.')
            return BLOCKED

    # --- opt-in LWW: the winner depends on --provenance only, never on a modification time ------
    live_winners = [rel for rel, _state in lww] if opts.provenance == 'live' else []
    copy = sorted(set(copy) | set(live_winners))

    # --- every path checked before the first mutation, dry-run included (§5.2 point 4) ---------
    targets = dict(zip(copy, paths.check_all(roots.ref, copy)))
    for rel, target in targets.items():
        if os.path.lexists(target) and not os.path.isfile(target):
            raise SecurityError('not a regular file where a captured file goes: %s' % target)
    if live_winners:
        check_backup_root(roots.live)
    if lww:
        syncstate.check_log(roots.conflict_log)              # E5-R1-06: the dry-run refuses as the real run does

    for rel, _state in lww:
        res = syncstate.resolve_lww(rel, roots.conflict_log, ref.hashes[rel], live.hashes[rel], opts.provenance,
                                    dry_run=opts.dry_run)
        out.warn('[LWW] %s -> winner=%s' % (rel, res.winner))
    if not copy:
        if base_fix and not opts.dry_run:
            entries = dict(base.entries)
            entries.update(base_fix)
            write_base(roots, entries)
            out.ok('capture: nothing to capture; base refreshed for %d already-committed file(s).' % len(base_fix))
            return OK
        out.ok('capture: nothing to capture (no greenlisted live change).')
        return OK

    if opts.dry_run:
        out.write('capture [dry-run]: %d file(s) WOULD be captured - nothing written.' % len(copy))
        for rel in copy:
            out.write('    + %s' % rel)
        return OK

    if live_winners:
        losers = dict((rel, ref.files[rel]) for rel in live_winners)
        folder, saved = backup.backup_bytes(roots.live, losers, 'capture-lww')
        for rel in saved:
            out.warn('[BACKUP] ref %s backed up -> %s' % (rel, os.path.join(folder, *rel.split('/'))))

    for rel in copy:
        safe_replace(targets[rel], live.files[rel])
    out.ok('capture: %d file(s) copied live->ref.' % len(copy))

    specs = _nul_list(git_pathspecs(roots, copy))
    res = git_run(roots, 'add', '--pathspec-from-file=-', '--pathspec-file-nul', stdin=specs)
    if res.returncode != 0:
        out.err("capture: 'git add' (copied paths) failed (code %d). Base not rewritten." % res.returncode)
        out.err(_text(res))
        return GIT_FAILED
    message = 'capture: sync live -> ref (P012:A006) - %d file(s)' % len(copy)
    res = git_run(roots, 'commit', '-m', message, '--pathspec-from-file=-', '--pathspec-file-nul', stdin=specs)
    if res.returncode != 0:
        out.err("capture: 'git commit' failed (code %d). Base not rewritten." % res.returncode)
        out.err(_text(res))
        return GIT_FAILED

    # --- post-check: HEAD holds exactly the captured bytes, and those paths are clean -------------
    ids, algo = head_blobs(roots)
    missing = [rel for rel in copy if ids.get(rel) != git_blob_id(live.files[rel], algo)]
    # E5-R3-03: a resumed path must still hold the validated bytes in the final HEAD (a hook may commit again).
    missing += [rel for rel in sorted(base_fix) if ids.get(rel) != git_blob_id(ref.files[rel], algo)]
    dirty = _dirty_paths(roots)
    still = sorted(rel for rel in set(copy) | set(base_fix) if dirty is None or roots.subdir + '/' + rel in dirty)
    if missing or still:
        out.err('capture: POST-CHECK FAILED - committed paths still dirty or not in HEAD (partial failure).')
        for rel in missing:
            out.err('[NOT IN HEAD] %s' % rel)
        for rel in still:
            out.err('[DIRTY] %s' % rel)
        out.warn('Base NOT rewritten (untrusted state).')
        return DRIFT

    entries = dict(base.entries)
    entries.update(base_fix)
    entries.update((rel, live.hashes[rel]) for rel in copy)
    write_base(roots, entries)
    out.ok('capture: OK - %d file(s) captured and committed; base rewritten.' % len(copy))
    return OK


def _first_run(roots, opts, out, ref, live):
    plan = syncstate.first_run_plan(ref.hashes, live.hashes, opts.adopt)
    if plan.signal == 'block':
        out.err('capture: first-run BLOCKED (asymmetry/divergence without a base).')
        for rel in plan.mismatches:
            out.err('[DIVERGENT] %s' % rel)
        out.warn('%d divergent path(s). Run again with --adopt to adopt the current state.' % len(plan.mismatches))
        return DIRTY
    seed = syncstate.seed_entries(plan, ref.hashes, live.hashes)
    tag = ' (adopted)' if plan.adopted else ''
    if opts.dry_run:
        out.ok('capture: first-run seed%s - %d entry(ies) [dry-run, base not written].' % (tag, len(seed)))
        return OK
    write_base(roots, seed)
    out.ok('capture: first-run seed%s - base written (%d entry(ies)).' % (tag, len(seed)))
    return OK
