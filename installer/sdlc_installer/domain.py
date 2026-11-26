"""SDLC domain: which relative paths belong to the bundle (port of sync-lib Get-DomainRelPaths).

Relative paths always use '/'. Policy (E1-05):
- the sdlc / sdlc- prefixes are case-sensitive (PowerShell -clike, Bash globs);
- exclusions and the H3 embedded-commands rule are case-insensitive (PowerShell -like / -contains),
  so a mixed-case excluded name is excluded on every platform (excluding more is the safe side).
"""
import errno
import fnmatch
import os
import re
import stat

from .errors import SecurityError

EXCLUDED_DIRS = ('__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache', '_backups', '_backup')
EXCLUDED_FILES = ('*.pyc', '*.pyo', '*.bak')
EXCLUDED_NAMES = ('.sync-manifest.json', 'conflicts.log', '.install-manifest.json')

_DIRS_L = tuple(d.lower() for d in EXCLUDED_DIRS)
_NAMES_L = tuple(n.lower() for n in EXCLUDED_NAMES)
_REPARSE = getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0x400)
_MANIFEST_SKILL = re.compile(r'sdlc(-[a-z0-9][a-z0-9-]*)?')


def is_excluded(rel):
    """True if the sync ignores this relative path (Test-SyncExcluded, case-insensitive)."""
    norm = rel.strip('/')
    if not norm:
        return False
    segments = norm.split('/')
    if any(seg.lower() in _DIRS_L for seg in segments):
        return True
    leaf = segments[-1].lower()
    if any(fnmatch.fnmatchcase(leaf, pat) for pat in EXCLUDED_FILES):
        return True
    return leaf in _NAMES_L


def is_pruned(rel):
    """True if a segment of `rel` is an excluded DIRECTORY name (the whole subtree is ignored).
    File-name exclusions (*.bak, manifest names) apply to regular files only, never to links (E1-R4-02)."""
    return any(seg.lower() in _DIRS_L for seg in rel.strip('/').split('/'))


def in_domain(rel):
    """True if a '/' relative path (from the claude root) is in the SDLC domain, exclusions applied."""
    norm = rel.strip('/')
    parts = norm.split('/')
    if len(parts) < 2 or is_excluded(norm):
        return False
    top = parts[0]
    if top == 'skills':
        if len(parts) < 3 or not parts[1].startswith('sdlc'):
            return False
        # H3: DESCENDANTS of skills/sdlc/commands are excluded (case-insensitive, like -like).
        return not (parts[1] == 'sdlc' and parts[2].lower() == 'commands' and len(parts) > 3)
    if top == 'commands':
        return len(parts) >= 3 and parts[1] == 'sdlc'
    if top == 'agents':
        return parts[-1].startswith('sdlc-')
    return False


def is_valid_skill_name(name):
    """A skill name read from a manifest (§5.2, E1-06): exactly 'sdlc' or 'sdlc-<suffix>', one component.
    Disk discovery is broader (sdlc*); the manifest is not trusted that far."""
    return isinstance(name, str) and _MANIFEST_SKILL.fullmatch(name) is not None


def _is_link(st):
    return stat.S_ISLNK(st.st_mode) or bool(getattr(st, 'st_file_attributes', 0) & _REPARSE)


def may_hold_domain(rel):
    """True if `rel` is a domain file, a domain root or ancestor, or a directory that may contain
    domain files (anything under agents/, skills/sdlc*, commands/sdlc). Used to refuse links there."""
    norm = rel.strip('/')
    parts = norm.split('/')
    if is_pruned(norm):
        return False
    if norm in ('skills', 'commands', 'agents', 'commands/sdlc'):
        return True
    if parts[0] == 'agents':
        return True
    if parts[0] == 'commands':
        return len(parts) >= 2 and parts[1] == 'sdlc'
    if parts[0] == 'skills' and len(parts) >= 2 and parts[1].startswith('sdlc'):
        # Descendants of the embedded skills/sdlc/commands directory are excluded (H3);
        # the entry skills/sdlc/commands itself is not (it may be an in-domain file).
        return not (parts[1] == 'sdlc' and len(parts) >= 4 and parts[2].lower() == 'commands')
    return False


def _h3_dir(rel):
    parts = rel.split('/')
    return len(parts) == 3 and parts[0] == 'skills' and parts[1] == 'sdlc' and parts[2].lower() == 'commands'


def _scan(root, rel_dir, found, skip=None):
    """Recursive scan of <root>/<rel_dir>: refuses links/junctions that may hold domain files,
    propagates errors, accepts regular files only, prunes excluded and H3 subtrees before descent."""
    full = os.path.join(root, *rel_dir.split('/'))
    with os.scandir(full) as it:
        entries = sorted(it, key=lambda e: e.name)
    for entry in entries:
        rel = rel_dir + '/' + entry.name
        st = entry.stat(follow_symlinks=False)
        if _is_link(st):
            # Same rule as HEAD inventory (may_hold_domain), which cannot see a link's target type:
            # every link that may hold or be a domain file is refused, including any link under
            # agents/ and the entry skills/sdlc/commands itself; excluded subtrees are ignored.
            if may_hold_domain(rel):
                raise SecurityError('link or junction refused in the SDLC domain: %s' % rel)
            continue
        if stat.S_ISDIR(st.st_mode):
            if entry.name.lower() in _DIRS_L or _h3_dir(rel) or rel == skip:
                continue
            _scan(root, rel, found, skip)
        elif stat.S_ISREG(st.st_mode):
            if in_domain(rel):
                found.add(rel)
        elif in_domain(rel):
            raise SecurityError('not a regular file in the SDLC domain: %s' % rel)


def _lstat_or_none(path):
    """lstat, or None if the path is absent. Any other error propagates (E1-R2-01)."""
    try:
        return os.lstat(path)
    except OSError as exc:
        if exc.errno == errno.ENOENT:
            return None
        raise


def domain_rels(root, allow_root_link=False, tops=('skills', 'commands', 'agents'), skills=None, skip=None):
    """Sorted domain relative paths on disk under `root` (E1-02, E1-R2-01).
    Every domain ancestor (skills, commands, commands/sdlc, agents, skills/sdlc*) is inspected without
    following links: a link or junction there is refused (SecurityError), never treated as absent.
    An unreadable directory raises instead of looking empty.
    `tops` and `skills` restrict the scan to some domain roots (uninstall, E4-R2-04): a root that is not
    selected is not opened at all, so a link there neither blocks nor is followed. `skip`: one relative folder that
    is never opened (uninstall: a directory standing at the registry path, E4-R3-03)."""
    # E1-R5-01: the root itself must not be a link or junction (a source root); the live root may be
    # one by design (§5.2 point 3), and its callers pass allow_root_link=True.
    rst = _lstat_or_none(root)
    if rst is None:
        return []
    if _is_link(rst) and not allow_root_link:
        raise SecurityError('the inventory root is a link or junction: %s' % root)
    if not os.path.isdir(root):
        return []
    found = set()
    to_scan = []
    # E1-R5-02: names are matched by their exact enumerated spelling, as Git does, never by opening
    # a hard-coded name that a case-insensitive filesystem would also resolve for SDLC/Skills.
    top_names = set(os.listdir(root))
    for top in ('skills', 'commands', 'agents'):
        if top not in top_names or top not in tops or top == skip:
            continue
        st = _lstat_or_none(os.path.join(root, top))
        if st is None:
            continue
        if _is_link(st):
            raise SecurityError('link or junction refused at a domain root: %s' % top)
        if not stat.S_ISDIR(st.st_mode):
            continue
        if top == 'skills':
            with os.scandir(os.path.join(root, 'skills')) as it:
                skill_entries = sorted(it, key=lambda e: e.name)
            for entry in skill_entries:
                if not entry.name.startswith('sdlc') or (skills is not None and entry.name not in skills):
                    continue
                est = entry.stat(follow_symlinks=False)
                if _is_link(est):
                    raise SecurityError('link or junction refused at a domain root: skills/%s' % entry.name)
                if stat.S_ISDIR(est.st_mode):
                    to_scan.append('skills/' + entry.name)
        elif top == 'commands':
            if 'sdlc' not in os.listdir(os.path.join(root, 'commands')):
                continue
            st2 = _lstat_or_none(os.path.join(root, 'commands', 'sdlc'))
            if st2 is None:
                continue
            if _is_link(st2):
                raise SecurityError('link or junction refused at a domain root: commands/sdlc')
            if stat.S_ISDIR(st2.st_mode):
                to_scan.append('commands/sdlc')
        else:
            to_scan.append('agents')
    for rel_dir in to_scan:
        if rel_dir == skip:
            continue                    # E4-R4-03: a skipped folder is never opened, a selected root included
        _scan(root, rel_dir, found, skip)
    return sorted(found)
