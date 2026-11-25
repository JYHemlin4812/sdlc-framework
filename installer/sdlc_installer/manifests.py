"""The two registries (design §4) and the aggregate checksum.

- Install registry `skills/sdlc/.install-manifest.json`: written by install, read by install and uninstall.
  Two historical formats are accepted: aggregate only (origin/main 667d7ed) and aggregate + file_hashes.
- Sync manifest `.sync-manifest.json` at the live root: the BASE of the three-way sync (capture writes it).
  Reading fails CLOSED (an empty base, never "identical by default"), like Read-SyncManifest.
"""
import collections
import datetime
import hashlib
import json
import os
import platform
import re
import stat
import sys

from . import domain, paths
from .errors import SecurityError, UsageError
from .fsops import safe_replace

INSTALL_REGISTRY_REL = 'skills/sdlc/.install-manifest.json'
SYNC_MANIFEST_NAME = '.sync-manifest.json'
SYNC_DOMAINS = ('skills/sdlc*', 'commands/sdlc', 'agents/sdlc-*')

_HEX64 = re.compile(r'[0-9a-fA-F]{64}')
_FRONT = re.compile(r'name:\s*(\S+)', re.IGNORECASE)


class CorruptRegistry(UsageError):
    """The registry exists but cannot be trusted (invalid JSON or schema): exit code 2."""


def _strict_json(text):
    """json.loads that rejects NaN/Infinity (not JSON, E2-R4-05) and over-deep nesting (E2-R4-04), always as ValueError."""
    def refuse(name):
        raise ValueError('non-JSON constant %s' % name)
    try:
        return json.loads(text, parse_constant=refuse)
    except RecursionError:
        raise ValueError('JSON nested too deeply')


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def file_sha256(path):
    with open(path, 'rb') as fh:
        return sha256_hex(fh.read())


# --- aggregate checksum --------------------------------------------------------------------

def _casefold_key(rel):
    return (rel.lower(), rel)


def aggregate_checksum(hashes, order='ordinal'):
    """Aggregate of 'rel:sha256\\n' lines (design §4; port of Get-GreenlistChecksum).
    `hashes`: rel -> sha256 of the files that exist. The two historical scripts sort differently:
    install.sh sorts by byte order (LC_ALL=C), install.ps1 by Sort-Object (case-insensitive), so the same
    tree gets two different aggregates. 'ordinal' is what this installer writes; 'casefold' reads the
    PowerShell value (verified on a real install: 122 files, SKILL.md sorts after scripts/)."""
    keys = sorted(hashes) if order == 'ordinal' else sorted(hashes, key=_casefold_key)
    text = ''.join('%s:%s\n' % (k, hashes[k].lower()) for k in keys)
    return sha256_hex(text.encode('utf-8'))


def aggregate_matches(recorded, hashes):
    """True if `recorded` is the aggregate of `hashes` under either historical ordering."""
    if not isinstance(recorded, str) or not _HEX64.fullmatch(recorded):
        return False
    want = recorded.lower()
    return any(aggregate_checksum(hashes, order) == want for order in ('ordinal', 'casefold'))


def registry_matches_source(registry, source_hashes, skills=None):
    """Is the registered install the one that `source_hashes` (rel -> sha256 of the source) would deploy?
    With file_hashes the per-file hashes are compared: no ordering is involved. Only an aggregate-only
    registry (origin/main) falls back to the aggregate, whose PowerShell ordering is culture-dependent for
    names whose culture order is not the byte order (non-ASCII, '_' against digits...): there a mismatch only
    means a redeploy (E2-R1-08, E2-R3-02), never a wrong 'up to date'. The .NET collation cannot be reproduced.
    `skills` (the source's skills): when given they must equal the registered list too, because restore updates
    file_hashes without rewriting the install snapshot (E2-R2-03): 'up to date' must not hide a stale list."""
    if registry.restored:
        return False          # E2-R3-01: restore changed the trace since install; install must rewrite the snapshot
    if skills is not None and set(skills) != set(registry.skills):
        return False
    if registry.file_hashes is not None:
        return registry.file_hashes == {k: v.lower() for k, v in source_hashes.items()}
    return aggregate_matches(registry.checksum, source_hashes)


def tree_hashes(root, rels):
    """rel -> sha256 for the files of `rels` that exist under `root` (missing ones are skipped, as the scripts do)."""
    out = {}
    for rel in rels:
        full = paths.safe_target(root, rel)
        if os.path.isfile(full):
            out[rel] = file_sha256(full)
    return out


# --- SKILL.md name (third-party guard, port of Get-SkillName) -------------------------------

_SKILL_READ_CAP = 256 * 1024 * 1024      # never read more than this looking for 30 lines


def skill_name(skill_md_path):
    """The `name:` field of the YAML front matter, or None (port of Get-SkillName, E2-R1-12).
    Like Get-Content -Encoding UTF8 -TotalCount 30: lines end at CRLF, CR or LF only (not U+2028), invalid
    bytes become U+FFFD instead of failing, only the first 30 lines are read, 'name:' matches without case.
    Lines are interpreted as they are read and the function returns at the name or at the closing '---'
    (E2-R4-02), so a huge body or description is consumed without being kept."""
    try:
        if not os.path.isfile(skill_md_path):           # E2-R3-07: never block on a FIFO or open a directory
            return None
        with open(skill_md_path, 'r', encoding='utf-8-sig', errors='replace', newline=None) as fh:
            budget = _SKILL_READ_CAP
            inside = False
            for _ in range(30):
                kept, first, dropped_text = '', True, False
                while True:                              # one logical line, possibly many fragments
                    chunk = fh.readline(1 << 16)
                    budget -= len(chunk)
                    if budget < 0:
                        return None
                    if first or len(kept) < (1 << 16):
                        kept += chunk
                    elif chunk.strip():
                        dropped_text = True              # E2-R5-02: text beyond what is kept still counts
                    first = False
                    if not chunk or chunk.endswith('\n'):
                        break
                if not kept and not chunk:
                    return None                          # end of file
                line = kept.rstrip('\n')
                if re.fullmatch(r'---\s*', line) and not dropped_text:
                    if inside:
                        return None
                    inside = True
                elif inside:
                    m = _FRONT.match(line)
                    if m:
                        return m.group(1)
                if not chunk:
                    return None
    except OSError:
        return None
    return None


# --- install registry -----------------------------------------------------------------------

InstallRegistry = collections.namedtuple(
    'InstallRegistry', 'version skills skills_derived checksum file_hashes source_commit raw warnings restored')
InstallRegistry.__new__.__defaults__ = (False,)


def _derive_skills(live_root, warnings):
    base = os.path.join(live_root, 'skills')
    names = []
    if os.path.isdir(base):
        for entry in sorted(os.listdir(base)):
            if not entry.startswith('sdlc'):
                continue
            if not domain.is_valid_skill_name(entry):
                warnings.append('skill folder ignored (not a valid sdlc name): %s' % entry)
                continue
            # E2-R1-03: a sibling folder or file that is a link is refused, never read through.
            folder = paths.safe_target(live_root, 'skills/%s' % entry)       # E2-R4-06: a link is refused...
            if not os.path.isdir(folder):
                continue                                                      # ...a plain file is ignored
            found = skill_name(paths.safe_target(live_root, 'skills/%s/SKILL.md' % entry))
            if found and found.startswith('sdlc'):
                names.append(entry)
    return names


def read_install_registry(live_root):
    """Parsed install registry, or None if absent. Invalid JSON or schema: CorruptRegistry (code 2).
    A skill name or a file_hashes key that is not a safe name/path: SecurityError (code 3, §5.2 points 1-2).
    A `skills` key that is absent is derived from the disk with a warning (R3-04); present, it must be a list.
    Field names are read without case, like the PowerShell readers."""
    path = paths.safe_target(live_root, INSTALL_REGISTRY_REL)
    if not os.path.lexists(path):
        return None
    if not os.path.isfile(path):                      # E2-R3-07: a FIFO or directory must not block or confuse
        raise CorruptRegistry('install registry is not a regular file: %s' % path)
    try:
        with open(path, 'rb') as fh:
            raw = _strict_json(fh.read().decode('utf-8-sig'))
    except (OSError, ValueError) as exc:    # UnicodeDecodeError and JSONDecodeError are ValueErrors
        raise CorruptRegistry('corrupt install registry %s: %s' % (path, exc))
    if not isinstance(raw, dict):
        raise CorruptRegistry('corrupt install registry (not an object): %s' % path)
    # E2-R2-02: PowerShell reads these properties without case (uninstall.ps1 PSObject.Properties), so
    # 'File_Hashes' is the same field; two spellings of one name are ambiguous, hence corrupt.
    fields = {}
    for key, value in raw.items():
        if key.lower() in fields:
            raise CorruptRegistry('corrupt install registry (key spelled twice, case apart: %r): %s' % (key, path))
        fields[key.lower()] = value
    warnings = []
    version = fields.get('version')
    version = version if isinstance(version, str) else '(unknown)'
    # E2-R1-02: both historical formats carry the aggregate; a document without it proves no install.
    checksum = fields.get('checksum_sha256')
    if not (isinstance(checksum, str) and _HEX64.fullmatch(checksum)):
        raise CorruptRegistry('corrupt install registry (checksum_sha256 missing or invalid): %s' % path)
    checksum = checksum.lower()

    # E2-R1-01: an absent key is the legacy format; a present key must be an object (null is corrupt).
    hashes = None
    if 'file_hashes' in fields:
        hashes = fields['file_hashes']
        if not isinstance(hashes, dict) or not all(
                isinstance(v, str) and _HEX64.fullmatch(v) for v in hashes.values()):
            raise CorruptRegistry('corrupt install registry (file_hashes): %s' % path)
        # E2-R1-06: lexical check AND physical parent chain, before any caller acts on a key.
        paths.check_all(live_root, list(hashes))
        hashes = {rel: v.lower() for rel, v in hashes.items()}

    derived = False
    if 'skills' in fields:
        # E2-R2-01: the key is there, so it must be a list; a string or null is a corrupt registry, never
        # a license to derive the list from the disk (that could pull a personal skill into uninstall).
        skills = fields['skills']
        if not isinstance(skills, list):
            raise CorruptRegistry('corrupt install registry (skills is not a list): %s' % path)
        # E2-R1-07: every element is validated (null or ../x: code 3).
        for name in skills:
            if not domain.is_valid_skill_name(name):
                raise SecurityError('invalid skill name in the install registry: %r' % (name,))
    else:
        skills = _derive_skills(live_root, warnings)
        derived = True
        warnings.append('install registry has no "skills" key: derived from the disk (%d)' % len(skills))

    commit = fields.get('source_commit')
    return InstallRegistry(version, list(skills), derived, checksum, hashes,
                           commit if isinstance(commit, str) else None, raw, warnings,
                           'restored_at' in fields)


def write_install_registry(live_root, version, skills, hashes, source=None, source_commit=None,
                           commands_count=0, agents_count=0, now=None):
    """Write the install registry atomically (call only after an acceptable post-check, §8.1 step 6).
    `hashes`: rel -> sha256 read back from the live tree. Returns the registry path."""
    for name in skills:
        if not domain.is_valid_skill_name(name):
            raise SecurityError('invalid skill name: %r' % (name,))
    paths.check_all(live_root, list(hashes))          # E2-R1-06
    stamp = (now or datetime.datetime.now(datetime.timezone.utc).astimezone()).isoformat()
    doc = {}  # type: dict
    doc.update([
        ('version', version),
        ('installed_at', stamp),
        ('source', (source or '').replace('\\', '/')),
        ('skills', list(skills)),
        ('commands_namespace', 'sdlc'),
        ('commands_count', commands_count),
        ('agents_count', agents_count),
        ('files_count', len(hashes)),
        ('checksum_sha256', aggregate_checksum(hashes)),
        ('file_hashes', dict((k, hashes[k].lower()) for k in sorted(hashes))),
    ])
    if source_commit:
        doc['source_commit'] = source_commit
    doc['installer'] = 'install.py'
    doc['python_version'] = '.'.join(str(n) for n in sys.version_info[:3])
    return _write_json(paths.safe_target(live_root, INSTALL_REGISTRY_REL), doc)


def update_file_hashes(live_root, updates, skills=None):
    """restore's deployment trace (§4 point 1, R3-06): add or update file_hashes[rel] under the same lock.
    Never creates a registry, and never creates `file_hashes` in a registry that has none (that would turn
    a legacy install, which uninstall removes whole, into one where unlisted files look foreign).
    `skills`: the skills now deployed, when restore knows them; the registry list is replaced so that uninstall
    forgets nothing (E2-R2-03). Returns True if the registry was updated."""
    paths.check_all(live_root, list(updates))         # E2-R1-06
    if skills is not None:
        for name in skills:
            if not domain.is_valid_skill_name(name):
                raise SecurityError('invalid skill name: %r' % (name,))
    reg = read_install_registry(live_root)
    if reg is None or reg.file_hashes is None:
        return False
    merged = dict(reg.file_hashes)
    merged.update({rel: h.lower() for rel, h in updates.items()})
    paths.check_all(live_root, list(merged))          # E2-R2-04: the merged set must stay readable
    replaced = ('file_hashes', 'files_count', 'restored_at') + (('skills',) if skills is not None else ())
    doc = dict((k, v) for k, v in reg.raw.items() if k.lower() not in replaced)
    doc['file_hashes'] = dict((k, merged[k]) for k in sorted(merged))
    doc['files_count'] = len(merged)
    # E2-R3-01: the version, commit and aggregate still describe the last install; this marks the trace as
    # changed by restore, so registry_matches_source never reports 'up to date' until install rewrites it.
    doc['restored_at'] = datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat()
    if skills is not None:
        doc['skills'] = list(skills)
    _write_json(paths.safe_target(live_root, INSTALL_REGISTRY_REL), doc)
    return True


def _write_json(path, doc):
    text = json.dumps(doc, indent=2, ensure_ascii=False) + '\n'
    safe_replace(path, text.encode('utf-8'))
    return path


# --- sync manifest --------------------------------------------------------------------------

SyncManifest = collections.namedtuple('SyncManifest', 'ok exists fail_closed version machine synced_at domains entries')

def _no_file():
    return SyncManifest(False, False, False, None, None, None, [], {})


def _fail_closed():
    """A NEW object each time (E2-R1-13): a caller that mutates the result must not alter the next base."""
    return SyncManifest(False, True, True, None, None, None, [], {})


def _confined(path, root):
    """The path to use for every operation on a sync manifest (E2-R4-01, E2-R5-01, E2-R5-03).
    '..' segments are refused before any normalisation; the final component must not be a link; with `root`,
    every component below it is checked and the path returned by safe_target is the one used. Raises SecurityError."""
    if '..' in re.split(r'[\\/]', path):
        raise SecurityError('sync manifest path contains "..": %s' % path)
    if paths.is_link_or_junction(path):
        raise SecurityError('sync manifest is a link: %s' % path)
    if root:
        rel = os.path.relpath(os.path.abspath(path), os.path.abspath(root)).replace(os.sep, '/')
        return paths.safe_target(root, rel)
    return path


def _ps_string(value):
    """[string]$p.Value as Read-SyncManifest does: null and objects give '', an array its items joined by a space."""
    if value is None or isinstance(value, dict):
        return ''
    if isinstance(value, list):
        return ' '.join(_ps_string(v) for v in value)
    if isinstance(value, bool):
        return 'True' if value else 'False'
    return value if isinstance(value, str) else str(value)


def read_sync_manifest(path, root=None):
    """Port of Read-SyncManifest. Missing file: first run (exists=False, not fail-closed). Unreadable,
    empty, truncated, no 'entries', or 'entries' not an object: fail CLOSED (empty base)."""
    try:
        path = _confined(path, root)                  # before the 'absent' test: a forbidden path is never a first run
    except SecurityError:
        return _fail_closed()
    if not os.path.lexists(path):
        return _no_file()
    try:
        if not stat.S_ISREG(os.stat(path).st_mode):   # E2-R3-07: a FIFO would block the reader forever
            return _fail_closed()
        with open(path, 'rb') as fh:
            text = fh.read().decode('utf-8-sig')
        if not text.strip():
            return _fail_closed()
        parsed = _strict_json(text)
    except (OSError, ValueError):
        return _fail_closed()
    if not isinstance(parsed, dict):
        return _fail_closed()
    # E2-R3-05: top-level names are matched without case (PowerShell -contains); a name spelled twice is
    # ambiguous, hence fail closed. Paths inside 'entries' keep their spelling.
    top = {}
    for key, value in parsed.items():
        if key.lower() in top:
            return _fail_closed()
        top[key.lower()] = value
    parsed = top
    if 'entries' not in parsed:
        return _fail_closed()
    raw_entries = parsed['entries']
    if raw_entries is None:
        raw_entries = {}
    if not isinstance(raw_entries, dict):
        return _fail_closed()
    entries = {k: _ps_string(v) for k, v in raw_entries.items()}
    domains = parsed.get('domains')
    return SyncManifest(True, True, False, parsed.get('version'), parsed.get('machine'),
                        parsed.get('synced_at'), (list(domains) if isinstance(domains, list) else ([] if domains is None else [domains])), entries)


def write_sync_manifest(path, entries, version='SP2', machine=None, domains=SYNC_DOMAINS, now=None, root=None):
    """Atomic write of the sync BASE (never in place). `entries`: rel -> sha256."""
    for rel in entries:
        paths.validate_rel(rel)
    path = _confined(path, root)
    stamp = (now or datetime.datetime.now(datetime.timezone.utc).astimezone()).isoformat()
    doc = dict([
        ('version', version),
        ('machine', machine or platform.node()),
        ('synced_at', stamp),
        ('domains', list(domains)),
        ('entries', dict((k, entries[k]) for k in sorted(entries))),
    ])
    return _write_json(path, doc)
