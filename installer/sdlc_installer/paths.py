"""Path safety (design §5): relative path validation, physical parent chain, root confinement."""
import os
import re
import stat

from .errors import SecurityError, UsageError

_REPARSE = getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0x400)
_WIN_RESERVED = re.compile(r'(con|prn|aux|nul|conin\$|conout\$|com[0-9¹²³]|lpt[0-9¹²³])(\..*)?', re.IGNORECASE)
_WIN_BAD_CHARS = set('<>:"|?*\\')


def validate_rel(rel):
    """Return `rel` if it is a safe '/' relative path, else raise SecurityError (E1-07).
    Components are checked raw: a backslash is a character, never a separator, so it is refused.
    Names that do not round-trip on Windows (reserved names, trailing dot or space, ':' streams,
    control characters) are refused on every platform, so the inventory is the same everywhere."""
    if not isinstance(rel, str) or not rel:
        raise SecurityError('empty relative path')
    if rel.startswith('/'):
        raise SecurityError('absolute path refused: %r' % rel)
    for seg in rel.split('/'):
        if seg in ('', '.', '..'):
            raise SecurityError('unsafe relative path refused: %r' % rel)
        if any(c in _WIN_BAD_CHARS or ord(c) < 32 or 0xD800 <= ord(c) <= 0xDFFF for c in seg):
            raise SecurityError('character not portable in path refused: %r' % rel)
        stem = seg.split('.')[0].rstrip(' ')
        if seg[-1] in '. ' or _WIN_RESERVED.fullmatch(seg) or _WIN_RESERVED.fullmatch(stem):
            raise SecurityError('name not portable to Windows refused: %r' % rel)
    return rel


def check_unique(rels):
    """Refuse entries that cannot coexist on a case-insensitive filesystem (E1-07, E1-R2-04):
    two files with the same folded name, or a file whose folded name is also a folded parent directory."""
    files = {}
    dirs = {}   # folded prefix -> original spelling
    for rel in rels:
        key = rel.casefold()
        if key in files and files[key] != rel:
            raise SecurityError('paths collide on a case-insensitive filesystem: %r / %r' % (files[key], rel))
        files[key] = rel
        orig = rel.split('/')
        for i in range(1, len(orig)):
            prefix = '/'.join(orig[:i])
            known = dirs.setdefault(prefix.casefold(), prefix)
            if known != prefix:
                raise SecurityError('one directory spelled two ways: %r / %r' % (known, prefix))
    for key, rel in files.items():
        if key in dirs:
            raise SecurityError('a file is also needed as a directory: %r / %r' % (rel, dirs[key]))


def is_link_or_junction(path):
    """True for a symlink or any reparse point (Windows junction included). False if absent."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return False
    if stat.S_ISLNK(st.st_mode):
        return True
    return bool(getattr(st, 'st_file_attributes', 0) & _REPARSE)


def safe_target(root, rel):
    """Native path of <root>/<rel> after checking that no existing component below root is a link
    or junction, and that the physical location stays under the physical root. Raises SecurityError."""
    norm = validate_rel(rel)
    root_real = os.path.realpath(root)
    current = root
    for seg in norm.split('/'):
        parent = current
        current = os.path.join(current, seg)
        if is_link_or_junction(current):
            raise SecurityError('link or junction refused in path: %s' % current)
        # E1-R4-03: on a case-insensitive filesystem an existing entry may answer to another spelling.
        if os.path.lexists(current) and seg not in os.listdir(parent):
            raise SecurityError('existing entry has a different spelling than %r in %s' % (seg, parent))
    if not _is_within(os.path.realpath(current), root_real):
        raise SecurityError('path escapes its root: %s' % current)
    return current


def check_all(root, rels):
    """Validate every path before the first mutation (§5.2 point 4). Returns the native targets."""
    rels = list(rels)
    check_unique(rels)
    return [safe_target(root, rel) for rel in rels]


def _norm(path):
    return os.path.normcase(os.path.realpath(path))


def _is_within(child, parent):
    """Component-wise containment (E1-R4-01): no string prefix, no stripping of name characters."""
    c, p = _norm(child), _norm(parent)
    try:
        return os.path.commonpath([c, p]) == p
    except ValueError:   # different Windows drives
        return False


def check_disjoint(a, b, what='source and live'):
    """§5.1 point 1: two roots neither equal nor nested (physical paths). Raises UsageError."""
    if _is_within(a, b) or _is_within(b, a):
        raise UsageError('%s must not be equal or nested: %s / %s' % (what, a, b))


def check_outside_worktree(worktree, paths):
    """§5.1 point 2: machine-local state must be outside the reference Git worktree."""
    for label, path in paths.items():
        if path and _is_within(path, worktree):
            raise UsageError('%s is inside the Git worktree %s: %s' % (label, worktree, path))
