"""install (design §8.1): deploy the SDLC domain of a source into the live root.

Source modes (decision JYH 2026-11-24, E3):
- 'head': the source is in a clean Git worktree with a HEAD; the bytes deployed are the HEAD blobs (git cat-file),
  so what is deployed is the commit by construction, whatever happens to the working tree during the run (R3-09);
- 'worktree': --allow-dirty on a dirty worktree; the working tree is deployed (§7), post-check against HEAD non-blocking;
- 'archive': no Git worktree or no commit; the files on disk are deployed and checked byte for byte.
Every source byte is read once and hashed from that copy; deployment, registry and post-check use the same copy.

Order: read-only prechecks (source, roots §5.1, dirty tree §7) -> dry-run stops here -> lock -> the same checks
again under the lock -> idempotence -> third-party guard, path checks (§5.2), CLAUDE.md check -> backup ->
atomic replacement -> post-check (real difference: 7, registry untouched) -> registry -> overlay -> unlock.
install is additive: it never deletes an orphan (restore does).
"""
import collections
import os

from . import backup, domain, gitstate, inventory, locks, manifests, overlay, ownership, paths
from . import verify as verify_mod
from .errors import DRIFT, OK, USAGE, DirtyReference, SecurityError, UsageError
from .fsops import read_bytes, safe_replace

VERSION = '3.2.0'          # same constant as install.sh / install.ps1 (decision JYH 2026-11-24)

Source = collections.namedtuple('Source', 'root mode repo worktree subdir commit files hashes skills')
Options = collections.namedtuple('Options', 'source live force dry_run no_backup allow_dirty')
Options.__new__.__defaults__ = (False, False, False, False)


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


# --- source -----------------------------------------------------------------------------------

def load_source(root, allow_dirty=False):
    """Read the source once. Raises UsageError (2) for a missing or incomplete source, DirtyReference (5)."""
    _refuse_source_link(root)
    if not os.path.isdir(root):
        raise UsageError('source not found: %s' % root)
    root = os.path.realpath(root)
    worktree = gitstate.worktree_root(root)      # kept for §5.1 even without a commit (E3-R1-02)
    repo = worktree
    commit = gitstate.head_commit(repo) if repo else None
    subdir = gitstate.subdir_of(repo, root) if commit else None
    if commit and not subdir:
        raise UsageError('the source must be a folder inside the repository, not its root: %s' % root)
    if commit:
        dirty = gitstate.is_dirty(repo, subdir)
        if dirty and not allow_dirty:
            raise DirtyReference('%s has uncommitted changes: commit them, or pass --allow-dirty' % root)
        if dirty:
            mode = 'worktree'
            files, folders = _read_tree(root)
        else:
            mode = 'head'
            ids = inventory.head_blob_ids(repo, subdir)
            blobs = gitstate.read_blobs(repo, ids.values())
            files = dict((rel, blobs[oid]) for rel, oid in ids.items())
            folders = gitstate.head_skill_folders(repo, subdir)
    else:
        mode, repo = 'archive', None
        files, folders = _read_tree(root)
    hashes = dict((rel, manifests.sha256_hex(data)) for rel, data in files.items())
    skills = _check_source(files, folders)
    return Source(root, mode, repo, worktree, subdir, commit, files, hashes, skills)


def _refuse_source_link(root):
    """§5.2 point 3: only the live root may be a link (E3-R1-01, E3-R2-01). The given spelling is normalised
    lexically ('alias/.' is 'alias'); its last component must not be a link, and the lexical form must reach the
    same physical folder as the given one ('alias/../x' through a link on POSIX does not)."""
    lexical = os.path.abspath(root)
    if paths.is_link_or_junction(root):
        raise SecurityError('the source root is a link or junction: %s' % root)
    # E3-R3-01: every component of the given path, parents included (§5.2 point 3).
    current = lexical
    while True:
        if paths.is_link_or_junction(current):
            raise SecurityError('the source path goes through a link or junction (%s): %s' % (current, root))
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    if os.path.lexists(root) and os.path.realpath(lexical) != os.path.realpath(root):
        raise SecurityError('the source path goes through a link: %s' % root)


def _read_tree(root):
    """(rel -> bytes, sdlc* skill folder names) of the files on disk."""
    files = dict((rel, read_bytes(paths.safe_target(root, rel))) for rel in inventory.tree_inventory(root))
    skills_dir = os.path.join(root, 'skills')
    folders = []
    if os.path.isdir(skills_dir):
        folders = [n for n in os.listdir(skills_dir)
                   if n.startswith('sdlc') and os.path.isdir(os.path.join(skills_dir, n))]
    return files, folders


def _check_source(files, folders=()):
    """§8.1 point 1: every sdlc* skill folder has a SKILL.md (E3-R1-05: an empty folder too, like install.ps1),
    commands/sdlc not empty, skill names the registry accepts (2)."""
    if not files:
        raise UsageError('empty SDLC domain in the source: nothing to install')
    skills = sorted(set(rel.split('/')[1] for rel in files if rel.startswith('skills/')) | set(folders))
    if not skills:
        raise UsageError('no sdlc* skill in the source')
    for name in skills:
        if not domain.is_valid_skill_name(name):
            raise UsageError('source skill folder with an invalid name (sdlc or sdlc-<a-z0-9->): %s' % name)
        if 'skills/%s/SKILL.md' % name not in files:
            raise UsageError('SKILL.md missing in the source: skills/%s/SKILL.md' % name)
    if not any(rel.startswith('commands/sdlc/') for rel in files):
        raise UsageError('no command under commands/sdlc: incomplete source')
    reserved = manifests.INSTALL_REGISTRY_REL.casefold() + '/'
    for rel in files:
        if rel.casefold().startswith(reserved):
            # E3-R2-02: the registry path is reserved; a source file under it would turn it into a folder.
            raise UsageError('source file under the reserved install registry path: %s' % rel)
    return skills


def check_roots(source, live):
    """§5.1: roots disjoint; machine-local state outside the reference worktree. Before any lock or file."""
    paths.check_disjoint(source.root, live)
    if source.worktree:
        paths.check_outside_worktree(source.worktree, {
            'live root': live,
            'install registry': os.path.join(live, *manifests.INSTALL_REGISTRY_REL.split('/')),
            'lock': os.path.join(live, locks.LOCK_NAME),
            'backup root': os.path.join(live, backup.BACKUP_DIR),
            'sync manifest': os.path.join(live, manifests.SYNC_MANIFEST_NAME),      # E3-R2-04
            'conflicts.log': os.path.join(live, 'conflicts.log'),
        })


# --- checks against the live root -------------------------------------------------------------

def _read_registry(live, out):
    """Install registry, or None. A corrupt one is overwritten with a warning (decision JYH 2026-11-24, like the
    scripts); an unsafe name or path in it is still refused (SecurityError, 3). Something other than a file at
    the registry path is refused too (3), before any mutation: the registry could not be written (E3-R1-03)."""
    path = paths.safe_target(live, manifests.INSTALL_REGISTRY_REL)
    if os.path.lexists(path) and not os.path.isfile(path):
        raise SecurityError('ABORT: the install registry path is not a regular file: %s' % path)
    try:
        reg = manifests.read_install_registry(live)
    except manifests.CorruptRegistry as exc:
        out.warn('unreadable install registry, it will be overwritten (%s)' % exc)
        return None
    if reg is not None:
        for w in reg.warnings:
            out.warn(w)
    return reg


def _guard(source, live, targets):
    """Third-party guard and §5.2 checks on the whole set, before the first mutation."""
    for name in source.skills:
        skill_md = paths.safe_target(live, 'skills/%s/SKILL.md' % name)
        if os.path.lexists(skill_md):
            found = manifests.skill_name(skill_md)
            if not found or not found.strip():
                raise SecurityError("ABORT: %s exists but its 'name:' field is unreadable: unidentifiable skill, "
                                    'refusing to overwrite (fail-closed)' % skill_md)
            if not found.startswith('sdlc'):
                raise SecurityError('ABORT: %s contains a third-party skill (name: %s); rename or remove it'
                                    % (skill_md, found))
    for rel, target in targets.items():
        if os.path.lexists(target) and not os.path.isfile(target):
            raise SecurityError('ABORT: not a regular file where a bundle file goes: %s' % target)


def _live_differences(live, targets, hashes):
    """(missing, different) of the live tree against the source hashes."""
    missing, different = [], []
    for rel in sorted(hashes):
        target = targets[rel]
        if not os.path.isfile(target):
            missing.append(rel)
        elif manifests.file_sha256(target) != hashes[rel]:
            different.append(rel)
    return missing, different


def _counts(files):
    return (len([r for r in files if r.startswith('commands/sdlc/')]),
            len([r for r in files if r.startswith('agents/')]))


# --- command ------------------------------------------------------------------------------------

def run(opts, write=print):
    """install command. Returns the exit code; InstallerError carries its own code to the caller."""
    out = _Out(write)
    live_arg = opts.live
    source = load_source(opts.source, opts.allow_dirty)
    live = os.path.realpath(live_arg)
    check_roots(source, live)
    commands, agents = _counts(source.files)
    out.ok('Source (%s): %d skills + %d commands + %d agents (%d domain files)'
           % (source.mode, len(source.skills), commands, agents, len(source.files)))
    if source.mode == 'worktree':
        out.warn('--allow-dirty: the working tree is deployed; integrity is NOT confirmed against HEAD')

    if opts.dry_run:
        return _dry_run(source, live, opts, out)

    os.makedirs(live, exist_ok=True)
    with locks.live_lock(live):
        # R3-09: everything that decides is redone under the lock, from a fresh read of the source.
        source = load_source(opts.source, opts.allow_dirty)
        check_roots(source, live)
        return _install_locked(source, live, opts, out)


def _dry_run(source, live, opts, out):
    """Same decisions, in the same order, as _install_locked (E3-R3-05), without lock or write."""
    targets = dict((rel, paths.safe_target(live, rel)) for rel in source.files)
    paths.check_unique(list(targets))
    registry = _read_registry(live, out)
    out.write('DRY-RUN: no writes')
    if _up_to_date(source, live, targets, registry, opts):
        overlay.set_local_overlay_import(live, dry_run=True)
        out.ok('Already up to date (checksum unchanged): nothing would be deployed')
        return OK
    _guard(source, live, targets)
    overlay.set_local_overlay_import(live, dry_run=True)
    to_backup = _backup_plan(source, live, targets, registry, opts, out)
    if to_backup:
        out.step('%d live file(s) would be backed up' % len(to_backup))
    out.step('%d domain file(s) would be deployed source -> live:' % len(source.files))
    for rel in sorted(source.files):
        out.write('    ~ %s' % rel)
    return OK


def _up_to_date(source, live, targets, registry, opts):
    """Registry describes this source (and its skills) and the live files equal it: nothing to deploy."""
    return (registry is not None and not opts.force
            and manifests.registry_matches_source(registry, source.hashes, source.skills)
            and not any(_live_differences(live, targets, source.hashes)))


def _backup_plan(source, live, targets, registry, opts, out):
    """Files to back up (§3): bundle-owned ones unless --no-backup, origin unknown ALWAYS (warning per file).
    Shared by dry-run and install (E3-R1-06), so the backup root is checked in both before any mutation."""
    present = [rel for rel in sorted(targets) if os.path.lexists(targets[rel])]
    if not present:
        return []
    owner = ownership.Ownership(source.repo, manifests.owned_hashes(registry), source.subdir or 'claude')
    unknown = [rel for rel in present if owner.classify_file(live, rel, source.files[rel]) == ownership.UNKNOWN]
    if unknown and owner.history_incomplete:
        out.warn('historique incomplet (shallow clone): some bundle files cannot be recognised')
    for rel in unknown:
        out.warn('origin unknown (not a bundle version): %s is backed up, then replaced' % rel)
    to_backup = unknown if opts.no_backup else present
    if to_backup:
        root = paths.safe_target(live, backup.BACKUP_DIR)            # a link is refused here (3)
        if os.path.lexists(root) and not os.path.isdir(root):
            raise SecurityError('ABORT: the backup root exists and is not a directory: %s' % root)
    return to_backup


def _install_locked(source, live, opts, out):
    targets = dict(zip(sorted(source.files), paths.check_all(live, sorted(source.files))))
    registry = _read_registry(live, out)

    # --- idempotence + self-repair (F4) ---
    if registry is not None and not opts.force and manifests.registry_matches_source(
            registry, source.hashes, source.skills):
        missing, different = _live_differences(live, targets, source.hashes)
        if not missing and not different:          # same test as _up_to_date (dry-run)
            out.ok('Already up to date (checksum unchanged); installed version: %s' % registry.version)
            _report_verify(source, live, out, fatal=False)        # E3-R1-07: orphans are reported, not hidden
            _overlay(live, out)
            return OK
        out.warn('Source unchanged BUT live install damaged (%d missing, %d hash-diff): REPAIR in progress.'
                 % (len(missing), len(different)))
    elif registry is not None:
        out.warn('Existing installation detected (v%s): reinstall/upgrade to v%s.' % (registry.version, VERSION))

    _guard(source, live, targets)
    overlay.set_local_overlay_import(live, dry_run=True)       # §6: a non-UTF-8 CLAUDE.md refuses (3) before writing
    to_backup = _backup_plan(source, live, targets, registry, opts, out)
    retained = _retained(live, targets, registry)
    if to_backup:
        folder, done = backup.backup_files(live, to_backup, 'sdlc')
        out.ok('Backup: %d live file(s) saved -> %s' % (len(done), folder))

    # --- atomic replacement, file by file ---
    for rel in sorted(targets):
        safe_replace(targets[rel], source.files[rel])
    out.ok('%d file(s) deployed source -> %s' % (len(targets), live))

    # --- post-check: bytes against the deployed source first (every mode, §8.1 point 5), then HEAD ---
    missing, different = _live_differences(live, targets, source.hashes)
    if missing or different:
        for rel in missing:
            out.err('[MISSING]   %s' % rel)
        for rel in different:
            out.err('[HASH DIFF] %s' % rel)
        out.err('post-check: real DRIFT (%d missing, %d hash-diff): live != deployed source. Deployment NOT '
                'reliable; the registry was not written. Recover the backups, then run again with --force.'
                % (len(missing), len(different)))
        return DRIFT
    code = _report_verify(source, live, out, fatal=True)
    if code != OK:
        return code

    live_hashes = manifests.tree_hashes(live, sorted(targets))
    commands, agents = _counts(source.files)
    path = manifests.write_install_registry(live, VERSION, source.skills, live_hashes, source=source.root,
                                            source_commit=source.commit, commands_count=commands,
                                            agents_count=agents, retained=retained)
    out.ok('Manifest written: %s' % path)
    _overlay(live, out)
    out.write('Installation complete: version %s, %d skills (%s), %d commands, %d agents, %d files'
              % (VERSION, len(source.skills), ', '.join(source.skills), commands, agents, len(targets)))
    return OK


def _retained(live, targets, registry):
    """R3-06 (decision JYH 2026-11-25, option 1.4.1): files an earlier install or restore recorded that this source does
    not ship, still present and byte-identical to their record, stay provable in retained_hashes. A file changed
    since, or gone, is dropped. Read-only; computed before the first mutation."""
    retained = {}
    for rel, recorded in sorted((manifests.owned_hashes(registry) or {}).items()):
        if rel in targets:
            continue
        path = paths.safe_target(live, rel)
        if os.path.isfile(path) and not paths.is_link_or_junction(path) and manifests.file_sha256(path) == recorded:
            retained[rel] = recorded
    return retained


def _report_verify(source, live, out, fatal):
    """verify against HEAD, classified as in install.ps1. The live files already equal the source here.
    fatal: after a deployment from HEAD, a difference with HEAD means HEAD moved during the run (7)."""
    if source.repo is None:
        out.warn('verify post-check unavailable (source outside a Git repository): live checked byte for byte '
                 'against the source (0 drift).')
        return OK
    res = verify_mod.verify(source.repo, live, source.subdir)
    if res.code == OK:
        out.ok('verify post-check: 0 drift (live == committed ref HEAD).')
    elif res.code == USAGE:
        out.warn('verify post-check unavailable (%s): live checked against the source only.' % res.reason)
    elif not res.missing and not res.hash_diff:
        out.warn('verify post-check: %d EXTRA file(s) on the live side (orphans from a previous version).'
                 % len(res.extra))
        out.warn('Canonical deployment is correct; install is additive: run restore to clean up the orphans.')
    elif source.mode == 'worktree' or not fatal:
        out.warn('verify post-check reports %d missing, %d hash-diff against HEAD: integrity NOT confirmed '
                 'against HEAD (non-blocking).' % (len(res.missing), len(res.hash_diff)))
    else:
        verify_mod.report(res, out.err)
        out.err('post-check: HEAD changed during the install (live != committed HEAD); the registry was not '
                'written. Run install again.')
        return DRIFT
    return OK


def _overlay(live, out):
    res = overlay.set_local_overlay_import(live)
    for w in res.warnings:
        out.warn(w)
    if res.overlay_created:
        out.ok('CLAUDE.local.md created (empty)')
    if res.import_added:
        out.ok('@CLAUDE.local.md import added to CLAUDE.md')
