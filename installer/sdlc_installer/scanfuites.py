"""scan-fuites (design §8.5): read-only leak scan of the repository, port of bundle/scripts/scan-fuites.ps1.

A reporting tool, not a gate: a scan that writes its report succeeds (0), with or without hits; 2 when the root,
a prerequisite or the report path is unusable. The only write is the report (atomic replacement).

- Level 1 patterns: embedded, frozen, not tied to anyone (Windows profile path, e-mail, version markers).
- Level 2 patterns: optional file SDLC_PM/scan-fuites-motifs.txt, one Python `re` per line, '#' and blank lines
  ignored. A pattern Python cannot compile stops the scan (2): a skipped pattern would hide leaks silently.
- Zoning (fail-safe): SDLC_PM/ is internal (counts per file); every other path is public (each hit listed).
- History probe: root commit, last commit before the first 'SP4' commit, HEAD; read from the Git objects with the
  same Python patterns (no checkout, no second regex dialect). A hit on (a) or (b) marks the history contaminated.
Matching is case-insensitive, line by line, as in the PowerShell script.
"""
import codecs
import collections
import datetime
import os
import pathlib
import re
import shutil
import stat

from . import domain, gitstate, paths
from .errors import OK, UsageError
from .fsops import safe_replace
from .inventory import _git

LEVEL1 = (
    ('windows-profile-path', r'[A-Za-z]:\\Users\\[^\\ "\']+'),
    ('generic-email', r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
    ('sdlcv2', 'sdlcv2'),
    ('sdlcv3', 'sdlcv3'),
)
MOTIFS_REL = 'SDLC_PM/scan-fuites-motifs.txt'
REPORT_REL = 'SDLC_PM/SP6-productisation/rapport-scan-fuites-%s.md'
BINARY_EXT = frozenset(('.png', '.jpg', '.jpeg', '.gif', '.ico', '.bmp', '.pdf', '.zip', '.gz', '.7z', '.exe', '.dll',
                        '.pyc', '.pyo', '.bin', '.woff', '.woff2', '.ttf', '.eot', '.otf', '.mp3', '.mp4', '.mov',
                        '.class', '.so', '.dylib', '.jar'))
# The scanner's own sources embed the level-1 catalogue in clear text: a self-match is not a leak (P045).
SELF_EXCLUDE = frozenset(('bundle/scripts/scan-fuites.ps1', 'bundle/scripts/scan-fuites.sh',
                          'installer/sdlc_installer/scanfuites.py'))
_LINES = re.compile(r'\r\n|\n|\r')

Pattern = collections.namedtuple('Pattern', 'label regex')
TreeScan = collections.namedtuple('TreeScan', 'public internal')        # [(rel, line, label)], {rel: lines}
HistoryRow = collections.namedtuple('HistoryRow', 'id label hash available count')


class _Out(object):
    def __init__(self, write):
        self.write = write

    def ok(self, msg):
        self.write('  [OK] %s' % msg)

    def step(self, msg):
        self.write('  - %s' % msg)

    def warn(self, msg):
        self.write('  [WARN] %s' % msg)


def level1():
    return [Pattern(label, re.compile(rx, re.IGNORECASE)) for label, rx in LEVEL1]


_BOMS = ((codecs.BOM_UTF32_LE, 'utf-32-le'), (codecs.BOM_UTF32_BE, 'utf-32-be'), (codecs.BOM_UTF8, 'utf-8'),
         (codecs.BOM_UTF16_LE, 'utf-16-le'), (codecs.BOM_UTF16_BE, 'utf-16-be'))


def _decode_motifs(data, path):
    """E6-R1-03: the byte-order marks Get-Content recognises, otherwise UTF-8; decoded strictly, never guessed."""
    for bom, encoding in _BOMS:
        if data.startswith(bom):
            data, chosen = data[len(bom):], encoding
            break
    else:
        chosen = 'utf-8'
    try:
        return data.decode(chosen)
    except UnicodeDecodeError as exc:
        raise UsageError('level-2 pattern file is not valid %s text (%s): %s' % (chosen, exc, shown(path)))


def level2(path, explicit=False):
    """(present, patterns) of the optional level-2 file. Raises UsageError for a file that cannot be read or decoded,
    or a pattern Python cannot compile (re.error, or a limit: OverflowError, RecursionError; E6-R1-06).
    E6-R3-03, E6-R4-03: an explicit --motifs-path is absent (generic mode) only when its parent folder exists; a
    missing parent, a file on the way or a non-file target gives 2. The default file keeps the scripts' rule: anything
    but a readable file there is generic mode."""
    try:
        st = os.stat(path)
    except (FileNotFoundError, NotADirectoryError):
        if explicit and not os.path.isdir(os.path.dirname(os.path.abspath(path))):
            raise UsageError('level-2 pattern file: its folder does not exist: %s' % shown(path))
        return False, []
    except OSError as exc:
        # E6-R2-06: a pattern file that exists but cannot be reached is not "absent" (generic mode would hide hits).
        raise UsageError('level-2 pattern file unreadable: %s' % exc)
    if not stat.S_ISREG(st.st_mode):
        if explicit:
            raise UsageError('level-2 pattern path is not a regular file: %s' % shown(path))
        return False, []
    try:
        with open(path, 'rb') as fh:
            text = _decode_motifs(fh.read(), path)
    except OSError as exc:
        raise UsageError('level-2 pattern file unreadable: %s' % exc)
    out = []
    for number, line in enumerate(_LINES.split(text), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        try:
            out.append(Pattern('level2', re.compile(line, re.IGNORECASE)))
        except (re.error, OverflowError, RecursionError, ValueError) as exc:
            raise UsageError('level-2 pattern line %d is not a valid Python regex (%s): %s' % (number, exc, line))
    return True, out


def zone(rel):
    return 'internal' if rel.lower().startswith('sdlc_pm/') else 'public'


def is_text(data, name=''):
    """Known binary extension, or a NUL byte in the first 8000 bytes (git's own test for -I)."""
    if os.path.splitext(name)[1].lower() in BINARY_EXT:
        return False
    return b'\0' not in data[:8000]


def _ordinal(rel):
    """E6-R1-17: .NET StringComparer.Ordinal compares UTF-16 code units, which is the byte order of UTF-16-BE."""
    return rel.encode('utf-16-be', 'surrogatepass')


def _unreadable(exc):
    # E6-R1-05: a folder that cannot be listed is a scan that would silently miss files: fail closed (2).
    raise UsageError('cannot list %s: %s' % (shown(os.fsdecode(exc.filename or '')), exc.strerror or exc))


def file_list(root):
    """Working-tree files (relative, '/'), without .git/, the sync exclusions, the scanner itself and links;
    sorted in .NET ordinal order (the scripts sort ordinally). An unreadable folder stops the scan (2)."""
    out = []
    for current, dirs, files in os.walk(root, onerror=_unreadable):
        rel_dir = os.path.relpath(current, root).replace(os.sep, '/')
        rel_dir = '' if rel_dir == '.' else rel_dir + '/'
        if rel_dir == '':
            dirs[:] = [d for d in dirs if d != '.git']
        # E6-R2-05: excluded subtrees are never opened, so an unreadable __pycache__ cannot stop the scan.
        dirs[:] = [d for d in dirs if not domain.is_pruned(rel_dir + d)]
        dirs[:] = [d for d in dirs if not paths.is_link_or_junction(os.path.join(current, d))]
        for name in files:
            rel = rel_dir + name
            full = os.path.join(current, name)
            if rel == '.git' or domain.is_excluded(rel) or rel in SELF_EXCLUDE:
                continue
            st = os.lstat(full)
            if stat.S_ISREG(st.st_mode) and not paths.is_link_or_junction(full):
                out.append(rel)
    return sorted(out, key=_ordinal)


def lines_of(data, decode):
    """Lines as Get-Content and git grep see them: no line at all for an empty file, a BOM alone included
    (E6-R1-10, E6-R2-08), no trailing empty line after the final terminator."""
    text = decode(data)
    if not text:
        return []
    if text.endswith(('\r\n', '\n', '\r')):
        text = text[:-2] if text.endswith('\r\n') else text[:-1]
    return _LINES.split(text)


def _matches(lines, patterns):
    """Per line: (line number, labels of the matching patterns), for lines with at least one match."""
    for number, line in enumerate(lines, 1):
        labels = [p.label for p in patterns if p.regex.search(line)]
        if labels:
            yield number, labels


def tree_scan(root, rels, patterns):
    public, internal = [], collections.OrderedDict()
    for rel in rels:
        try:
            with open(os.path.join(root, *rel.split('/')), 'rb') as fh:
                data = fh.read()
        except OSError:
            continue
        if not is_text(data, rel):
            continue
        lines = lines_of(data, lambda b: b.decode('utf-8-sig', 'replace'))
        for number, labels in _matches(lines, patterns):
            if zone(rel) == 'public':
                public.extend((rel, number, label) for label in labels)
            else:
                internal[rel] = internal.get(rel, 0) + 1                    # a line counts once
    return TreeScan(public, internal)


def _first_line(res):
    lines = res.stdout.decode('utf-8', 'replace').splitlines() if res.returncode == 0 else []
    return lines[0].strip() if lines and lines[0].strip() else None


def revisions(root):
    """(a) root commit, (b) parent of the first commit whose message matches SP4, (c) HEAD; None when unknown."""
    root_hash = _first_line(_git(root, 'rev-list', '--max-parents=0', 'HEAD'))
    sp4 = _first_line(_git(root, 'log', '--reverse', '--grep=SP4', '--format=%H'))
    sp4_parent = None
    if sp4:
        parents = _first_line(_git(root, 'log', '-1', '--format=%P', sp4))
        sp4_parent = parents.split()[0] if parents else None
    head = _first_line(_git(root, 'rev-parse', 'HEAD'))
    return [('a', 'repository root commit', root_hash), ('b', 'last commit before SP4', sp4_parent),
            ('c', 'HEAD', head)]


def partial_clone(root):
    """E6-R1-11, E6-R2-02: in a partial clone (extensions.partialClone, or any remote.<name>.promisor set to true),
    reading an old object may fetch it and write under .git/objects; the whole probe is then skipped."""
    res = _git(root, 'config', '--get', 'extensions.partialclone')
    if res.returncode == 0 and res.stdout.strip():
        return True
    res = _git(root, 'config', '--bool', '--get-regexp', r'^remote\..*\.promisor$')
    return res.returncode == 0 and any(line.split()[-1:] == [b'true'] for line in res.stdout.splitlines())


def revision_count(root, rev, patterns):
    """Number of matching lines in the regular text files of `rev` (git grep -n -I -i counts lines; links are not
    searched), or None if unreadable."""
    res = _git(root, 'ls-tree', '-r', '-z', rev)
    if res.returncode != 0:
        return None
    ids = {}
    for record in res.stdout.split(b'\0'):
        meta, _, raw = record.partition(b'\t')
        fields = meta.split(b' ')
        if len(fields) == 3 and fields[1] == b'blob' and fields[0] in (b'100644', b'100755'):   # E6-R1-09
            ids[raw.decode('utf-8', 'surrogateescape')] = fields[2].decode('ascii')
    try:
        blobs = gitstate.read_blobs(root, ids.values())
    except UsageError:
        return None
    count = 0
    for name, oid in ids.items():
        data = blobs[oid]
        if b'\0' in data[:8000] or not data:
            continue
        text = data.decode('utf-8', 'replace')
        if text.endswith('\n'):
            text = text[:-1]
        count += sum(1 for line in text.split('\n') if any(p.regex.search(line) for p in patterns))
    return count


def shown(rel):
    """E6-R1-12: a file name that is not valid UTF-8 (surrogateescape) is shown with escapes, never dropped."""
    return rel.encode('utf-8', 'surrogateescape').decode('utf-8', 'backslashreplace')


def report(root, motifs, level2_present, level2_count, scan, rows, contaminated, git_available, today):
    lines = ['# Leak scan report - sdlc-framework', '']
    root, motifs = shown(root), shown(motifs)                         # E6-R2-04: headers escaped too
    if level2_present:
        lines.append('**Level-2 patterns**: loaded from `%s` (%d pattern(s)).' % (motifs, level2_count))
    else:
        lines.append('**Generic mode only** - `%s` missing: only the 4 embedded level-1 patterns are applied. '
                     'Not a failure: normal run.' % motifs)
    lines += ['', '**Date**: %s' % today, '**Scanned root**: `%s`' % root, '',
              '## Candidate public zone (zero tolerance)', '']
    if not scan.public:
        lines.append('No hits.')
    else:
        lines += ['%d hit(s) found:' % len(scan.public), '']
        lines += ['- `%s:%d:%s`' % (shown(f), n, label) for f, n, label in scan.public]
    lines += ['', '## Internal zone (informational counts - no zero tolerance)', '']
    if not scan.internal:
        lines.append('No hits.')
    else:
        lines += ['- `%s`: %d hit(s)' % (shown(f), n) for f, n in scan.internal.items()]
    lines += ['', '## History probe (3 key revisions)', '']
    if not git_available:
        lines.append('git unavailable or repository inaccessible - probe not run.')
    else:
        lines += ['| Revision | Hash | Hits |', '|---|---|---|']
        for row in rows:
            lines.append('| (%s) %s | `%s` | %s |' % (row.id, row.label, row.hash or '(unavailable)',
                                                      row.count if row.available else 'unavailable'))
    lines += ['', '**History verdict**: ' + (
        'history contaminated: any public release requires a squash/new repository or a filter-repo.'
        if contaminated else
        'no hits on the probed revisions (a)/(b) - history clean on this sample (no guarantee for the unprobed '
        'intermediate revisions, nor when the git probe is unavailable).'), '', '']
    # E6-R1-07: the line separator of the reference (StringBuilder.AppendLine: CRLF on Windows, LF elsewhere).
    return os.linesep.join(lines)


def _git_dirs(root):
    """Physical Git metadata folders of the repository holding `root` (git dir and common dir); [] outside Git or
    when git is missing (E6-R2-03: the path-component check below still applies)."""
    out = []
    for flag in ('--absolute-git-dir', '--git-common-dir'):
        try:
            res = _git(root, 'rev-parse', flag)
        except UsageError:
            return out
        value = res.stdout.decode('utf-8', 'surrogateescape').strip() if res.returncode == 0 else ''
        if value:
            out.append(os.path.realpath(os.path.join(root, value)))
    return out


_GIT_HEAD = re.compile(rb'(ref: refs/\S+|[0-9a-f]{40}|[0-9a-f]{64})\s*')


def _looks_like_git_dir(path):
    """A Git metadata folder by its structure (bare repository, .git folder, common dir), without running git:
    objects/ and refs/ folders, and a HEAD file Git would accept (E6-R4-02: a symbolic ref, valid even before the
    first commit, or an object id)."""
    if not (os.path.isdir(os.path.join(path, 'objects')) and os.path.isdir(os.path.join(path, 'refs'))):
        return False
    try:
        with open(os.path.join(path, 'HEAD'), 'rb') as fh:
            head = fh.read(512)
    except OSError:
        return False
    return _GIT_HEAD.fullmatch(head) is not None


def _in_git_metadata(target, root):
    """E6-R1-01, E6-R2-01, E6-R3-01, E6-R3-02, E6-R3-05: the report must not land in Git metadata. Refused when the
    target is named .git (the link file of a linked worktree), when a component of the physical path of its first
    existing ancestor is named .git, when that ancestor or one of its parents has the structure of a Git folder (a
    bare repository included; checked without git), or, when git is available, when it lies in the Git folders of
    the scanned repository or of the repository holding the target. Paths are split with the platform's rules."""
    if pathlib.PurePath(target).name.lower() == '.git':
        return True
    probe = os.path.dirname(target)
    while not os.path.lexists(probe) and os.path.dirname(probe) != probe:
        probe = os.path.dirname(probe)
    physical = os.path.realpath(probe)
    # E6-R4-01: the names still to be created count too (export/.git/report.md with export/.git absent).
    suffix = pathlib.PurePath(os.path.relpath(target, probe)).parts
    if any(part.lower() == '.git' for part in pathlib.Path(physical).parts + suffix):
        return True
    current = physical
    while True:
        if os.path.isdir(current) and _looks_like_git_dir(current):
            return True
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    holders = [root] + ([physical] if os.path.isdir(physical) else [])
    return any(paths._is_within(physical, meta) for holder in holders for meta in _git_dirs(holder))


def _report_target(path, root):
    """§5.1 point 3: the report path must be a file (absent or regular), never a folder or a link, and never inside
    the Git metadata of the scanned repository (E6-R1-01: .git/index must not become a report). Raises UsageError."""
    if not path or not path.strip():
        raise UsageError('--report-path is empty')
    path = os.path.abspath(path)
    try:
        if os.path.isdir(path) or paths.is_link_or_junction(path):
            raise UsageError('the report path is a folder or a link: %s' % shown(path))
        if os.path.lexists(path) and not os.path.isfile(path):
            raise UsageError('the report path is not a regular file: %s' % shown(path))
        if _in_git_metadata(path, root):
            raise UsageError('the report path is inside Git metadata: %s' % shown(path))
    except OSError as exc:
        raise UsageError('the report path is unusable: %s' % exc)
    return path


def run(repo_root, motifs=None, report_path=None, write=print, today=None):
    out = _Out(write)
    write('Leak scan - read-only (P045)')
    if not repo_root or not os.path.isdir(repo_root):
        raise UsageError('RepoRoot not found: %s' % shown(repo_root or ''))
    root = os.path.realpath(repo_root)
    today = today or datetime.date.today().isoformat()
    explicit = motifs is not None
    motifs = os.path.abspath(motifs) if motifs else os.path.join(root, *MOTIFS_REL.split('/'))
    target = _report_target(report_path if report_path is not None
                            else os.path.join(root, *(REPORT_REL % today).split('/')), root)

    patterns = level1()
    present, extra = level2(motifs, explicit)
    if present:
        out.ok('Level-2 patterns: %d loaded from %s' % (len(extra), shown(motifs)))     # E6-R3-04
    else:
        out.warn('Level-2 patterns missing (%s) - generic mode only.' % shown(motifs))
    patterns += extra

    out.step('Enumerating the working tree (excluding .git/)')
    files = file_list(root)
    out.step('%d candidate file(s)' % len(files))
    scan = tree_scan(root, files, patterns)
    out.ok('Public zone   : %d hit(s)' % len(scan.public))
    out.ok('Internal zone : %d file(s) with hits' % len(scan.internal))

    out.step('History probe (3 revisions)')
    git_available = shutil.which('git') is not None
    rows, contaminated = [], False
    probe = git_available and not partial_clone(root)
    if git_available and not probe:
        out.warn('partial clone: the history probe is not run (reading old objects could fetch them)')
        rows = [HistoryRow(rid, label, None, False, 0) for rid, label in
                (('a', 'repository root commit'), ('b', 'last commit before SP4'), ('c', 'HEAD'))]
    if probe:
        for rid, label, rev in revisions(root):
            count = revision_count(root, rev, patterns) if rev else None
            rows.append(HistoryRow(rid, label, rev, count is not None, count or 0))
            if rid in ('a', 'b') and count:
                contaminated = True
    out.ok('History: %s' % ('contaminated (expected, see F5)' if contaminated else 'clean on the probed sample'))

    text = report(root, motifs, present, len(extra), scan, rows, contaminated, git_available, today)
    try:
        safe_replace(target, text.encode('utf-8'))
    except OSError as exc:
        raise UsageError('cannot write the report %s: %s' % (shown(target), exc))          # E6-R1-04: code 2, not 1
    out.ok('Report written: %s' % shown(target))
    if scan.public:
        out.warn('%d hit(s) in the public zone - see the report.' % len(scan.public))
    else:
        out.ok('0 hits in the public zone.')
    return OK
