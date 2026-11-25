"""Private overlay import (design §1 decision 1): the ONLY line the installer ever adds to CLAUDE.md is
'@CLAUDE.local.md'. Port of Set-LocalOverlayImport / Set-GenericImport (sync-lib.ps1:728-795), same bytes:
- detection = lines whose trimmed content is literally the marker (see _is_marker), anywhere in the file;
- already present: nothing written (more than one: warning, no dedup);
- absent: appended, other bytes untouched, with the file's dominant EOL if it lacks a final one;
- the overlay file is created EMPTY first when missing, never overwritten;
- dry-run: zero writes. Design §6: a CLAUDE.md that is not UTF-8 is refused (code 3) BEFORE any mutation.
"""
import collections
import os
import re
import stat

from . import backup, paths
from .errors import InstallerError, SecurityError
from .fsops import safe_replace

LOCAL_NAME = 'CLAUDE.local.md'
TARGET_NAME = 'CLAUDE.md'

OverlayResult = collections.namedtuple('OverlayResult', 'overlay_created import_added backup_folder warnings')

_AFTER_NEWLINE = re.compile(r'(?<=\n)')


def _is_marker(line, marker):
    """Literal equality of the trimmed line with the marker, as the header of sync-lib documents ('EXACTLY the
    marker (literal match, never a broad regex)') and as sync-lib.sh does. MEASURED on 2026-11-24 with the real
    scripts: for a first line holding a BOM, '@claude.local.md' (other case), or the marker followed by U+FE0F,
    set_generic_import (.sh) adds the import and Set-GenericImport (.ps1) does not, because PowerShell's culture
    -eq ignores case and format characters; U+115F: .sh adds, .ps1 adds; NUL: bash drops it, .ps1 ignores it.
    The two scripts disagree, so the documented literal rule is the one ported (decision to confirm with JYH):
    a lookalike line never hides the import, at worst the same file is imported twice, which is harmless."""
    return line.strip() == marker


def split_lines(text):
    """Lines that keep their terminator; the last one has none if the text does not end with an EOL."""
    if not text:
        return []
    segs = _AFTER_NEWLINE.split(text)
    if len(segs) >= 2 and segs[-1] == '':
        segs = segs[:-1]
    return segs


def append_marker(text, marker):
    """The new text with `marker` appended, or None if a marker line is already there (see module doc)."""
    lines = split_lines(text)
    if any(_is_marker(line, marker) for line in lines):
        return None
    crlf = sum(1 for ln in lines if ln.endswith('\r\n'))
    lf = sum(1 for ln in lines if ln.endswith('\n') and not ln.endswith('\r\n'))
    eol = '\r\n' if crlf > lf else '\n'
    if not text:
        return marker
    if text.endswith('\n'):
        return text + marker
    return text + eol + marker


def set_local_overlay_import(claude_root, dry_run=False):
    """Ensure <claude_root>/CLAUDE.local.md exists and CLAUDE.md imports it. Caller holds the sync lock."""
    target = paths.safe_target(claude_root, TARGET_NAME)
    local = paths.safe_target(claude_root, LOCAL_NAME)
    marker = '@' + LOCAL_NAME
    warnings = []

    existing = os.path.lexists(target)
    text = ''
    if existing:
        if not os.path.isfile(target):
            raise SecurityError('%s is not a regular file' % target)
        with open(target, 'rb') as fh:
            raw = fh.read()
        try:
            text = raw.decode('utf-8')
        except UnicodeDecodeError:
            raise SecurityError('%s is not valid UTF-8: left untouched' % target)

    count = sum(1 for line in split_lines(text) if _is_marker(line, marker))
    if count > 1:
        warnings.append("%d '%s' lines found in %s (no automatic dedup)" % (count, marker, target))
    new_text = append_marker(text, marker)

    if existing and new_text is not None:
        # E2-R1-10, E2-R2-09, E2-R3-04: refuse BEFORE creating the overlay, and in dry-run too (it redoes the
        # checks): the backup root must be absent or a real directory, never a link or a file.
        backup_root = paths.safe_target(claude_root, backup.BACKUP_DIR)
        if os.path.lexists(backup_root) and not os.path.isdir(backup_root):
            raise InstallerError('backup root exists and is not a directory: %s' % backup_root)

    overlay_created = False
    try:
        local_kind = os.lstat(local).st_mode
    except FileNotFoundError:
        local_kind = None
    if local_kind is not None and not stat.S_ISREG(local_kind):
        # E2-R2-08: a directory, FIFO or other object stands where the overlay should be; never replaced.
        raise SecurityError('%s exists and is not a regular file' % local)
    if local_kind is None and not dry_run:
        safe_replace(local, b'')
        overlay_created = True
    if new_text is None or dry_run:
        return OverlayResult(overlay_created, False, None, warnings)

    folder = None
    if existing:
        folder, _ = backup.backup_files(claude_root, [TARGET_NAME], 'import')
    safe_replace(target, new_text.encode('utf-8'))
    return OverlayResult(overlay_created, True, folder, warnings)
