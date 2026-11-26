"""uninstall (design §8.6): remove what the bundle installed, and only that.

- Targets: skills/<s> for each skill of the install registry or of its retained_hashes (or discovered with
  --discover), commands/sdlc, and with
  --remove-core every agents/**/sdlc-*. Only SDLC-domain files are candidates; CLAUDE.md and anything outside the
  domain are never touched (§1 decision 1, §8.6 point 3).
- A candidate is deleted only if it is bundle-owned (§3: registry file_hashes or a blob of the reference history);
  otherwise it is kept and reported. Registry without file_hashes AND no readable history: global warning, then
  deletion as the scripts did (§1 decision 3).
- Registry absent or corrupt: code 2 without --discover (nothing touched); with --discover, heuristic discovery.
- Backup of everything deleted (relative paths kept), then deletions, then the registry, then empty folders.
All path checks run on the whole set before the first mutation; every mutation runs under the shared lock.
"""
import collections
import os
import stat

from . import backup, domain, fsops, gitstate, locks, manifests, ownership, paths
from .errors import OK, SecurityError, UsageError

Plan = collections.namedtuple('Plan', 'skills remove keep registry_present legacy_all version prune')
_YES = ('oui', 'o', 'yes', 'y')


def _check_roots(live, ref):
    """§5.1, before the lock: the reference and the live root are disjoint, and the live machine-local state is
    outside the reference worktree (E4-R1-01). A repository Git cannot read is still a worktree for this check."""
    if ref is None:
        return
    if not ref.strip():
        raise UsageError('--ref is empty')                          # E4-R3-01: never "no proof" by accident
    paths.check_disjoint(ref, live, 'reference and live')          # E4-R2-02: even for a missing reference
    probe = os.path.realpath(ref)                                   # E4-R4-01: links resolved before '..'
    while not os.path.isdir(probe) and os.path.dirname(probe) != probe:
        probe = os.path.dirname(probe)                              # E4-R3-02: nearest existing parent
    try:
        top = gitstate.worktree_root(probe)
    except UsageError:
        top = gitstate._git_marker(probe)
    if top:
        paths.check_outside_worktree(top, {
            'live root': live,
            'install registry': os.path.join(live, *manifests.INSTALL_REGISTRY_REL.split('/')),
            'lock': os.path.join(live, locks.LOCK_NAME),
            'backup root': os.path.join(live, backup.BACKUP_DIR),
        })


def _owner(ref, hashes, out):
    """Ownership with the reference history when it can be read; otherwise the registry hashes alone (E4-R1-05)."""
    try:
        top = gitstate.worktree_root(ref) if ref and os.path.isdir(ref) else None
        if top is not None and gitstate.head_commit(top) is not None:
            owner = ownership.Ownership(top, hashes)
            owner.history                       # read now: an error falls back below; an empty history is a
            return owner, True                  # readable one that proves nothing (E4-R2-01)
    except UsageError as exc:
        out.warn('Git history of the reference unreadable, not used as proof: %s' % exc)
    return ownership.Ownership(None, hashes), False


def _prune_dirs(live, roots, shallow=(), skip=None):
    """Every existing folder that may be removed when empty, checked with safe_target BEFORE the first mutation
    (E4-R1-04): `roots` with their sub-folders (links skipped), `shallow` alone (never their other sub-folders,
    e.g. commands/<other namespace>). Deepest first."""
    found = []

    def walk(rel, deep):
        if rel == skip or domain.is_pruned(rel) or domain._h3_dir(rel):
            return                              # E4-R3-04: excluded subtrees are never opened nor removed
        path = paths.safe_target(live, rel)
        if paths.is_link_or_junction(path) or not os.path.isdir(path):
            return
        if deep:
            with os.scandir(path) as it:
                names = sorted(e.name for e in it if e.is_dir(follow_symlinks=False))
            for name in names:
                walk(rel + '/' + name, True)
        found.append((rel, path))
    for rel in roots:
        walk(rel, True)
    for rel in shallow:
        walk(rel, False)
    return sorted(set(found), key=lambda item: -item[0].count('/'))


def _plan(live, ref, discover, remove_core, out):
    if not os.path.isdir(live):
        raise UsageError('live root not found: %s' % live)
    registry_path = paths.safe_target(live, manifests.INSTALL_REGISTRY_REL)
    try:
        reg = manifests.read_install_registry(live)
    except manifests.CorruptRegistry as exc:
        if not discover:
            raise UsageError('%s; nothing removed (to force a heuristic removal: --discover)' % exc)
        out.warn('corrupt install registry, --discover: heuristic discovery (%s)' % exc)
        reg = None
    else:
        if reg is None and not discover:
            raise UsageError('install registry missing: %s; refusing to uninstall without it (the origin of the '
                             'files cannot be proven). To force a heuristic removal: --discover' % registry_path)
    warnings = []
    if reg is not None:
        skills, version = list(reg.skills), reg.version
        warnings.extend(reg.warnings)
        if reg.file_hashes is not None:
            # FINAL-R1-02: a skill an earlier install or restore deployed, omitted by the last source, is still
            # scanned when retained_hashes proves one of its files (each file is still checked below).
            kept = set(rel.split('/')[1] for rel in reg.retained if rel.startswith('skills/') and rel.count('/') >= 2)
            skills += sorted(s for s in kept - set(skills) if domain.is_valid_skill_name(s))
    else:
        out.warn('--discover: heuristic search for sdlc* skills; only files proven by the Git history are removed')
        skills, version = manifests._derive_skills(live, warnings), '(unknown)'
    for w in warnings:
        out.warn(w)
    for name in skills:
        if not domain.is_valid_skill_name(name):
            raise SecurityError('invalid skill name: %r' % (name,))

    # E4-R2-04: only the selected roots are scanned (agents/ only with --remove-core, only the listed skills).
    tops = ('skills', 'commands', 'agents') if remove_core else ('skills', 'commands')
    prefixes = tuple('skills/%s/' % s for s in skills) + ('commands/sdlc/',)
    reg_rel = manifests.INSTALL_REGISTRY_REL
    # A corrupt registry FILE is removed with the rest under --discover; a directory there is left alone, with its
    # whole content (E4-R1-06, E4-R2-03).
    registry_dir = os.path.lexists(registry_path) and not os.path.isfile(registry_path)
    candidates = [rel for rel in domain.domain_rels(live, allow_root_link=True, tops=tops, skills=skills,
                                                    skip=reg_rel if registry_dir else None)
                  if (rel.startswith(prefixes) or (remove_core and rel.startswith('agents/')))
                  and not (registry_dir and rel.startswith(reg_rel + '/'))]
    registry_present = os.path.isfile(registry_path) and not paths.is_link_or_junction(registry_path)
    roots = ['skills/%s' % s for s in skills] + ['commands/sdlc']
    shallow = ['commands'] + (['skills/sdlc'] if registry_present else [])     # E4-R1-07: registry parent
    paths.check_all(live, candidates + ([manifests.INSTALL_REGISTRY_REL] if registry_present else []))
    prune = _prune_dirs(live, roots, shallow, skip=reg_rel if registry_dir else None)

    hashes = reg.file_hashes if reg is not None else None
    owner, has_history = _owner(ref, manifests.owned_hashes(reg), out)
    # §1 decision 3 (E4-R1-02): only a READABLE registry without file_hashes, and no history, removes everything.
    legacy_all = reg is not None and hashes is None and not has_history
    remove, keep = [], []
    for rel in candidates:
        if legacy_all or owner.classify_file(live, rel) != ownership.UNKNOWN:
            remove.append(rel)
        else:
            keep.append(rel)
    doomed = remove + ([reg_rel] if registry_present else [])
    fsops.check_removable(dict((rel, paths.safe_target(live, rel)) for rel in doomed))     # registry included
    if reg is not None and hashes is None:
        if legacy_all:
            out.warn('Legacy install (registry has no file_hashes, and no readable Git history): every file in the '
                     'SDLC folders will be removed, personal files included. A backup is made first.')
        else:
            out.warn('registry has no file_hashes: ownership proven by the Git history of %s' % owner.repo)
    if owner.repo is not None and keep and owner.history_incomplete:
        out.warn('historique incomplet (shallow clone): some bundle files cannot be recognised')
    return Plan(skills, remove, keep, registry_present, legacy_all, version, prune)


def _remove(path):
    """os.remove; on Windows a read-only file (confirmed and backed up) is made writable first, like
    Remove-Item -Force (E4-R3-05); its mode is put back if the removal still fails."""
    mode = os.stat(path).st_mode
    if os.name == 'nt' and not mode & stat.S_IWRITE:
        os.chmod(path, mode | stat.S_IWRITE)
        try:
            os.remove(path)
        except OSError:
            os.chmod(path, mode)
            raise
        return
    os.remove(path)


def _confirm(read):
    try:
        answer = read('  Confirm uninstall? (yes/N) ')
    except EOFError:
        return False
    return answer.strip().lower() in _YES


def run(live, ref=None, force=False, discover=False, remove_core=False, write=print, read=None):
    """uninstall command. Returns the exit code; InstallerError carries its own code to the caller.
    The plan is computed, shown, confirmed and executed under the lock: what is confirmed is what runs (E4-R1-03)."""
    out = _Out(write)
    if not os.path.isdir(live):
        raise UsageError('live root not found: %s' % live)
    live = os.path.realpath(live)
    _check_roots(live, ref)
    with locks.live_lock(live):
        plan = _plan(live, ref, discover, remove_core, out)
        if not plan.remove and not plan.keep and not plan.registry_present and not [
                rel for rel, _p in plan.prune if rel != 'commands']:
            out.warn('No SDLC artifact found under %s. Nothing to remove.' % live)
            return OK
        registry = [manifests.INSTALL_REGISTRY_REL] if plan.registry_present else []
        doomed = plan.remove + registry                 # E4-R2-05: what is shown is what is removed
        write('  Will be removed (%d file(s)), then the folders left empty:' % len(doomed))
        for rel in doomed:
            write('    - %s' % rel)
        for rel in plan.keep:
            out.warn('will be kept (not from the bundle, or modified): %s' % rel)
        if not force and not _confirm(read or input):
            out.warn('Cancelled.')
            return OK
        targets = dict(zip(doomed, paths.check_all(live, doomed)))
        folder, saved = backup.backup_files(live, doomed, 'uninstall')
        if folder:
            out.ok('Backup: %d file(s) -> %s' % (len(saved), folder))
        for rel in plan.remove:
            _remove(targets[rel])
            out.step('rm %s' % rel)
        for rel in registry:
            _remove(targets[rel])
        for rel, path in plan.prune:
            if os.path.isdir(path) and not paths.is_link_or_junction(path) and not os.listdir(path):
                os.rmdir(path)
        for rel in plan.keep:
            out.warn('kept (not from the bundle, or modified): %s' % rel)
        for rel, path in plan.prune:
            if rel != 'commands' and os.path.isdir(path) and rel.count('/') == 1:
                out.warn('kept (not empty): %s' % rel)
    write('Uninstall complete: version %s, %d file(s) removed, %d kept' % (plan.version, len(doomed),
                                                                          len(plan.keep)))
    return OK


class _Out(object):
    def __init__(self, write):
        self.write = write

    def ok(self, msg):
        self.write('  [OK] %s' % msg)

    def step(self, msg):
        self.write('  - %s' % msg)

    def warn(self, msg):
        self.write('  [WARN] %s' % msg)
