"""restore (design §8.4): make the live root match the COMMITTED reference (HEAD:<subdir>).

- git is required; the canonical guard refuses a dirty <subdir>/ (5); with an upstream, the plan is made against the
  upstream commit when HEAD is its ancestor (divergence: 4, dry-run included) and the fast-forward is applied only
  after every refusal (E5-R1-01), never in dry-run; a corrupt base fails closed (6); an absent base is an empty one.
- The reference side is read from the blobs of that commit (design §3, decision E3), never from the working tree.
- States: modified-ref, added-ref, deleted-live -> deployed; deleted-ref (live == base) -> removed from live;
  modified-live -> blocked (3) unless --force-restore; modified-both and conflict-* -> blocked (3) always;
  added-live -> protected; identical, absent-both -> ignored. One block: nothing written.
- Backup of every live file replaced or removed, atomic replacement, removals, then verify against HEAD: any
  difference (EXTRA included, as restore.ps1) or verify unavailable gives 7.
- Once the files are written, the deployment trace goes into the install registry when it exists (§4, R3-06), whether
  the post-check passes or not (FINAL-R1-03): it holds the files restore itself wrote, never one it left alone
  (FINAL-R2-01), so a rerun after a post-check failure (7) needs no heuristic.
restore never writes the sync manifest (capture owns it, §4 point 2).
"""
import collections
import os

from . import backup, fsops, gitstate, inventory, locks, manifests, paths, syncstate
from . import verify as verify_mod
from .capture import Side, _Out, check_backup_root, check_union, live_side, read_base, resolve_roots, show_diff
from .domain import is_valid_skill_name
from .errors import BLOCKED, CORRUPT_BASE, DIRTY, DRIFT, GIT_FAILED, OK, SecurityError, UsageError
from .fsops import safe_replace
from .inventory import _git
from .uninstall import _remove

Options = collections.namedtuple('Options', 'ref live subdir manifest force_restore dry_run')
Options.__new__.__defaults__ = ('claude', None, False, False)


def _target(roots):
    """(commit to deploy, fast-forward needed) read-only (E5-R1-01): HEAD when no upstream is configured or it is
    HEAD; the upstream commit when HEAD is its ancestor; (None, False) when they diverged. Never fetches."""
    head = gitstate.head_commit(roots.repo)
    if head is None:
        raise UsageError('restore: the reference has no committed HEAD: %s' % roots.repo)
    up = _git(roots.repo, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
    if up.returncode != 0:
        return head, False
    tip = _git(roots.repo, 'rev-parse', '--verify', '--quiet', '@{u}^{commit}')
    upstream = tip.stdout.decode('ascii', 'replace').strip()
    if tip.returncode != 0 or not upstream:
        raise UsageError('restore: the upstream of %s is not a readable commit' % roots.repo)
    if upstream == head:
        return head, False
    if _git(roots.repo, 'merge-base', '--is-ancestor', head, upstream).returncode == 0:
        return upstream, True
    if _git(roots.repo, 'merge-base', '--is-ancestor', upstream, head).returncode == 0:
        return head, False                                # E5-R2-02: local commits not pushed yet, nothing to apply
    return None, False


def _fast_forward_refused(roots, head, target):
    """E5-R2-01, E5-R3-01, E5-R3-02: what the fast-forward would overwrite in the working tree of the reference,
    anywhere in the repository (read-only; `git read-tree -n` does not see ignored files, measured with Git 2.54):
    - a path the target adds where something already exists (untracked or ignored file, or a folder);
    - a file (or link) standing where the target needs a folder, unless the target deletes that tracked file;
    - a tracked path the target changes that has local changes (staged or not).
    The merge itself runs with --no-overwrite-ignore as a second guard. Returns the sorted list of paths."""
    diff = _git(roots.repo, 'diff', '--name-status', '-z', '--no-renames', head, target)
    local = _git(roots.repo, 'diff', '--name-only', '-z', '--no-renames', 'HEAD')
    if diff.returncode != 0 or local.returncode != 0:
        raise UsageError('restore: cannot compare the fast-forward with the working tree of %s' % roots.repo)
    tokens = [t.decode('utf-8', 'surrogateescape') for t in diff.stdout.split(b'\0')]
    entries = [(tokens[i], tokens[i + 1]) for i in range(0, len(tokens) - 1, 2) if tokens[i]]
    deleted = set(path for status, path in entries if status.startswith('D'))
    changed_locally = set(t.decode('utf-8', 'surrogateescape') for t in local.stdout.split(b'\0') if t)
    found = set()
    for status, path in entries:
        if status.startswith('A'):
            if os.path.lexists(os.path.join(roots.repo, *path.split('/'))):
                found.add(path)
            parts = path.split('/')
            for i in range(1, len(parts)):
                parent = '/'.join(parts[:i])
                full = os.path.join(roots.repo, *parts[:i])
                if os.path.lexists(full) and (not os.path.isdir(full) or paths.is_link_or_junction(full)) \
                        and parent not in deleted:
                    found.add(parent)
        elif path in changed_locally:
            found.add(path)
    return sorted(found)


def _ref_side(roots, rev):
    """The committed reference at `rev`: its blobs of the domain under <subdir>/ (no SKILL.md requirement: restore
    deploys what the commit holds, as restore.ps1)."""
    if not gitstate.has_tree(roots.repo, roots.subdir, rev):
        raise UsageError('restore: %s of %s has no %s/ folder' % (rev[:12], roots.repo, roots.subdir))
    ids = inventory.head_blob_ids(roots.repo, roots.subdir, rev)
    blobs = gitstate.read_blobs(roots.repo, ids.values())
    files = dict((rel, blobs[oid]) for rel, oid in ids.items())
    return Side(files, dict((rel, manifests.sha256_hex(data)) for rel, data in files.items()))


def run(opts, write=print):
    out = _Out(write)
    roots = resolve_roots(opts.ref, opts.subdir, opts.live, opts.manifest, None, 'restore')
    write('restore %s: ref=%s  live=%s' % ('[dry-run] ' if opts.dry_run else '', roots.ref, roots.live))
    if opts.dry_run:
        with gitstate.local_objects_only():             # FINAL-R1-04: never fetch a missing object
            return _restore(roots, opts, out)          # design §2: no lock and no fast-forward in dry-run
    with locks.live_lock(roots.live):
        return _restore(roots, opts, out)


def _restore(roots, opts, out):
    gitstate.require_local_objects(roots.repo)          # dry-run only, before the first object read
    if gitstate.is_dirty(roots.repo, roots.subdir):
        out.err('restore: REF tree (%s/) not clean - commit/reconcile the ref before restoring. Nothing written.'
                % roots.subdir)
        return DIRTY
    # E5-R1-01: the plan is made against the commit the run will deploy, and the fast-forward is applied only
    # after every refusal, so a block leaves HEAD, the index and the reference untouched.
    target, fast_forward = _target(roots)
    if target is None:
        out.err('restore: ref diverged from upstream (not fast-forward) - abort. Nothing written.')
        out.warn('Reconcile the ref (rebase/merge) before restoring.')
        return GIT_FAILED
    if fast_forward:
        refused = _fast_forward_refused(roots, gitstate.head_commit(roots.repo), target)
        if refused:
            out.err('restore: the fast-forward would overwrite local file(s) in the reference. Nothing written.')
            for name in refused:
                out.err('[IN THE WAY] %s' % name)
            out.warn('Move these files away (or commit them), then run restore again.')
            return DIRTY
    ref = _ref_side(roots, target)
    live = live_side(roots.live)
    union = check_union(ref, live)
    base = read_base(roots)
    if base.fail_closed:
        out.err('restore: unreadable/corrupt manifest -> FAIL CLOSED (no action): %s' % roots.manifest)
        out.err('No restore is attempted on an untrusted base.')
        return CORRUPT_BASE

    deploy, delete, blocks = [], [], []
    for rel in union:
        state = syncstate.classify(ref.hashes.get(rel), live.hashes.get(rel), base.entries.get(rel))
        if state in (syncstate.MODIFIED_REF, syncstate.ADDED_REF, syncstate.DELETED_LIVE):
            deploy.append(rel)
        elif state == syncstate.MODIFIED_LIVE:
            if opts.force_restore:
                deploy.append(rel)
            else:
                blocks.append((rel, 'modified-live-only'))
        elif state == syncstate.DELETED_REF:
            delete.append(rel)
        elif state in (syncstate.IDENTICAL, syncstate.ADDED_LIVE, syncstate.ABSENT_BOTH):
            pass
        else:
            blocks.append((rel, state))                 # modified-both and conflict-*: never guessed

    if blocks:
        out.err('restore: BLOCKED - %d unresolved conflict(s). Nothing written.' % len(blocks))
        for rel, state in blocks:
            out.err('[BLOCK] %s  (%s)' % (rel, state))
            if rel in ref.files and rel in live.files:
                show_diff(out, rel, ref.files[rel], live.files[rel])
        out.warn("'modified-live': --force-restore overwrites the live change with the canonical file.")
        return BLOCKED

    # --- every path checked before the first mutation, dry-run included (§5.2 point 4) ---------
    touched = deploy + delete
    targets = dict(zip(touched, paths.check_all(roots.live, touched)))
    for rel in touched:
        if os.path.lexists(targets[rel]) and not os.path.isfile(targets[rel]):
            raise SecurityError('not a regular file where a canonical file goes: %s' % targets[rel])
    fsops.check_removable(dict((rel, targets[rel]) for rel in delete))        # FINAL-R1-01
    present = [rel for rel in touched if os.path.lexists(targets[rel])]
    if present:
        check_backup_root(roots.live)

    trace, registry = _trace_plan(roots, ref, deploy, out)                  # E5-R1-05, E5-R1-07: both modes

    if opts.dry_run:
        if fast_forward:
            out.write('restore [dry-run]: the reference would be fast-forwarded to %s.' % target[:12])
        out.write('restore [dry-run]: %d restore(s), %d deletion(s) - nothing written.' % (len(deploy), len(delete)))
        for rel in deploy:
            out.write('    ~ %s' % rel)
        for rel in delete:
            out.write('    - %s' % rel)
        return OK

    if fast_forward:
        res = _git(roots.repo, 'merge', '--ff-only', '--no-overwrite-ignore', target)
        if res.returncode != 0 or gitstate.head_commit(roots.repo) != target:
            out.err('restore: fast-forward to %s failed - nothing written to live.' % target[:12])
            out.err((res.stdout + res.stderr).decode('utf-8', 'replace').strip())
            return GIT_FAILED
        out.ok('restore: reference fast-forwarded to %s.' % target[:12])
    if present:
        folder, saved = backup.backup_files(roots.live, present, 'restore')
        out.warn('[BACKUP] %d live file(s) backed up -> %s' % (len(saved), folder))
    written = []
    try:
        for rel in deploy:
            safe_replace(targets[rel], ref.files[rel])
            written.append(rel)
    finally:
        _record_trace(roots, trace, registry, written, out)     # what was written, even if a write failed
    if deploy:
        out.ok('restore: %d file(s) deployed ref->live.' % len(deploy))
    for rel in delete:
        if os.path.lexists(targets[rel]):
            _remove(targets[rel])
    if delete:
        out.ok('restore: %d file(s) deleted (base-aware H6).' % len(delete))
    if not deploy and not delete:
        out.ok('restore: nothing to restore (live already matches the greenlisted canonical tree).')

    res = verify_mod.verify(roots.repo, roots.live, roots.subdir)
    if res.code != OK:
        verify_mod.report(res, out.err)
        if res.code == 2:
            out.err('restore: POST-CHECK not run - verify unavailable. Deployed but NOT verified.')
        else:
            out.err('restore: POST-CHECK verify found a difference - live != ref HEAD.')
        out.warn("Run 'verify' again for details. The timestamped backups are recoverable.")
        return DRIFT

    out.ok('restore: OK - live matches the canonical REF (verify post-check 0 drift).')
    return OK


def _trace_plan(roots, ref, deploy, out):
    """(rel -> sha256, registry) for the install registry trace, or (None, None) when restore has
    nothing to deploy (the registry is then not even read, FINAL-R2-02), when there is no modern registry, or when it
    is corrupt (left alone with a warning: it is install's to fix). The trace covers the files to deploy only
    (FINAL-R2-01); computed and validated before the first mutation."""
    if not deploy:
        return None, None
    try:
        reg = manifests.read_install_registry(roots.live)
    except manifests.CorruptRegistry as exc:
        out.warn('install registry unreadable, no deployment trace written (%s)' % exc)
        return None, None
    if reg is None or reg.file_hashes is None:
        return None, None
    trace = dict((rel, ref.hashes[rel]) for rel in deploy)
    manifests.check_trace(roots.live, reg, trace)            # E5-R2-07: both tables, parents included
    return trace, reg


def _record_trace(roots, trace, registry, written, out):
    """Records the hashes of the files restore actually wrote (a subset of the planned trace when a write failed)."""
    if trace is None or not written:
        return
    done = dict((rel, trace[rel]) for rel in written)
    # skills published: those already registered plus those of the files actually written (FINAL-R3-01)
    wrote = set(rel.split('/')[1] for rel in written if rel.startswith('skills/'))
    skills = sorted(set(registry.skills) | set(s for s in wrote if is_valid_skill_name(s)))
    if manifests.update_file_hashes(roots.live, done, skills, registry):
        out.ok('install registry: deployment trace recorded for %d file(s).' % len(done))
