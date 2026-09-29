#!/usr/bin/env bash
# sync-lib.sh — shared sourced library of SP2 (bidirectional sync).
#
# BASH port with behavior identical to sync-lib.ps1 (P018:A014). The .ps1 is the
# shipped/tested reference; this file reproduces its blocks, exit codes,
# SHA256 hashes (byte-exact), safeguards and messages in substance.
#
# Contract:
#   - SOURCES with no side effect: this file ONLY defines functions.
#     No code runs on load (except the self-execution guard at the bottom),
#     no scope variable is created, nothing is written, no global `set`
#     (does not pollute the caller's shell options — the equivalent of the
#     per-function Set-StrictMode of the .ps1: functions are written defensively).
#   - ZERO framework dependency. git is used when present
#     (show_conflict_diff), otherwise degrades cleanly. python is required ONLY
#     for the JSON manifest I/O (read/write_sync_manifest); without it,
#     read_sync_manifest fails CLOSED (safe default).
#   - flock NOT available on the host: the lock uses `mkdir` (atomic = O_EXCL
#     semantics). Writes go through temp+`mv -f` (atomic rename on the same FS).
#
# Functions (source):
#   get_sync_exclusion      test_sync_excluded
#   get_sync_domain_skill   get_domain_relpaths   get_rel_path
#   get_file_hash_byteexact get_sync_state
#   show_conflict_diff      resolve_lww
#   write_file_atomic       copy_tree
#   acquire_sync_lock       release_sync_lock
#   write_sync_manifest     read_sync_manifest    get_first_run_plan
#   set_generic_import      set_nestor_import     remove_nestor_import

# ---------------------------------------------------------------------------
# 0. Environment helpers (defined on source, no side effect).
# ---------------------------------------------------------------------------

require_bash4() {
    # Safeguard: this port uses associative arrays (declare -A) and
    # `mapfile` (bash 4.0+). macOS still ships /bin/bash 3.2: fail cleanly
    # with exit 2 rather than a cryptic crash. Called by every entrypoint.
    if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
        printf 'bash 4+ required (found: %s). On macOS: brew install bash.\n' \
            "${BASH_VERSION:-unknown}" >&2
        return 2
    fi
    return 0
}

_sync_py() {
    # Resolves the Python 3 interpreter for the JSON manifest I/O. Order
    # [python, python3]: on Windows `python` is the real binary and bypasses
    # the Microsoft Store `python3` stub; on modern Linux/Mac `python` is
    # missing and we fall back to `python3`. The probe requires
    # version >= 3 (rejects a `python` = py2). Override: $SYNC_PY.
    if [[ -n "${SYNC_PY:-}" ]]; then printf '%s' "$SYNC_PY"; return 0; fi
    local c
    for c in python python3; do
        if command -v "$c" >/dev/null 2>&1 \
           && "$c" -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
            printf '%s' "$c"; return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# 1. Centralized exclusion set (A004) — single source + predicate
# ---------------------------------------------------------------------------

get_sync_exclusion() {
    # SINGLE source of truth for exclusions, consumed by every tool.
    # Emits one "<kind>\t<pattern>" line per rule; kind = dir|file|name.
    #   dir  : a path segment equal to this name => excluded
    #   file : leaf name matched by glob
    #   name : exact leaf name => excluded
    cat <<'EOF'
dir	__pycache__
dir	.pytest_cache
dir	.mypy_cache
dir	.ruff_cache
dir	_backups
dir	_backup
file	*.pyc
file	*.pyo
file	*.bak
name	.sync-manifest.json
name	conflicts.log
name	.install-manifest.json
EOF
}

test_sync_excluded() {
    # Predicate: exit 0 (true) if the relPath must be ignored by the sync;
    # exit 1 (false) otherwise. (Empty relPath => false, like the .ps1.)
    local relpath="${1-}"
    local norm="${relpath//\\//}"
    while [[ "$norm" == /* ]]; do norm="${norm#/}"; done
    while [[ "$norm" == */ ]]; do norm="${norm%/}"; done
    [[ -z "$norm" ]] && return 1
    local leaf="${norm##*/}"
    local kind pat
    while IFS=$'\t' read -r kind pat; do
        case "$kind" in
            dir)  case "/$norm/" in *"/$pat/"*) return 0 ;; esac ;;
            file) case "$leaf" in $pat) return 0 ;; esac ;;
            name) [[ "$leaf" == "$pat" ]] && return 0 ;;
        esac
    done < <(get_sync_exclusion)
    return 1
}

# ---------------------------------------------------------------------------
# 2. 3-domain mapping (A003) + sdlc domain scope (H7) + H3 exclusion
# ---------------------------------------------------------------------------

get_rel_path() {
    # '/'-normalized relative path of $2 (FullPath) with respect to $1 (Root).
    local root="${1//\\//}"
    local full="${2//\\//}"
    while [[ "$root" == */ ]]; do root="${root%/}"; done
    local rootlc fulllc
    rootlc=$(printf '%s' "$root" | tr '[:upper:]' '[:lower:]')
    fulllc=$(printf '%s' "$full" | tr '[:upper:]' '[:lower:]')
    if [[ "$fulllc" == "$rootlc/"* ]]; then
        printf '%s' "${full:${#root}+1}"
    else
        local t="$full"
        while [[ "$t" == /* ]]; do t="${t#/}"; done
        printf '%s' "$t"
    fi
}

get_sync_domain_skill() {
    # Scope helper (H7): names of the sdlc* skills under <root>/skills, one per
    # line. THIRD-PARTY skills in live are ignored (never counted nor copied).
    local root="$1"
    local skillsdir="$root/skills"
    [[ -d "$skillsdir" ]] || return 0
    local d
    for d in "$skillsdir"/sdlc*/; do
        [[ -d "$d" ]] || continue
        d="${d%/}"
        printf '%s\n' "${d##*/}"
    done
}

get_domain_relpaths() {
    # Sorted, unique ('/'-normalized) relPaths of the domains (skills, commands,
    # agents), exclusions applied. Excludes skills/sdlc/commands/** (H3).
    # Skills scope derived from get_sync_domain_skill (H7).
    local root="$1"
    local resolved
    resolved=$(realpath "$root" 2>/dev/null) || return 0
    [[ -n "$resolved" ]] || return 0
    root="$resolved"

    {
        # --- skills domain (H7 scope: sdlc* only) ---
        local name f rel
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            local skillpath="$root/skills/$name"
            [[ -d "$skillpath" ]] || continue
            while IFS= read -r f; do
                rel=$(get_rel_path "$root" "$f")
                # H3: embedded commands subtree of the sdlc skill is excluded
                case "$rel" in skills/sdlc/commands/*) continue ;; esac
                test_sync_excluded "$rel" && continue
                printf '%s\n' "$rel"
            done < <(find "$skillpath" -type f 2>/dev/null)
        done < <(get_sync_domain_skill "$root")

        # --- commands domain (canonical top-level = single source) ---
        local cmdpath="$root/commands/sdlc"
        if [[ -d "$cmdpath" ]]; then
            while IFS= read -r f; do
                rel=$(get_rel_path "$root" "$f")
                test_sync_excluded "$rel" && continue
                printf '%s\n' "$rel"
            done < <(find "$cmdpath" -type f 2>/dev/null)
        fi

        # --- agents domain (sdlc-*) ---
        local agentspath="$root/agents"
        if [[ -d "$agentspath" ]]; then
            while IFS= read -r f; do
                rel=$(get_rel_path "$root" "$f")
                test_sync_excluded "$rel" && continue
                printf '%s\n' "$rel"
            done < <(find "$agentspath" -type f \( -name 'sdlc-*' \) 2>/dev/null)
        fi

    } | LC_ALL=C sort -u
}

# ---------------------------------------------------------------------------
# 3. Byte-exact SHA256 hashing (A002) — reads raw BYTES, no text/EOL handling
# ---------------------------------------------------------------------------

get_file_hash_byteexact() {
    # sha256sum reads raw bytes => byte-exact (CRLF != LF, no
    # normalization). 1st field, lowercase (sha256sum already outputs lowercase).
    local path="$1"
    local out
    out=$(sha256sum "$path") || return 1
    printf '%s' "${out%% *}"
}

# ---------------------------------------------------------------------------
# 4. get_sync_state (A005) — base-aware classifier. MODIFIES NOTHING.
# ---------------------------------------------------------------------------

get_sync_state() {
    # Emits the state (string) from (RefHash $1, LiveHash $2, BaseHash $3).
    # Absent = empty string. See the TRUTH TABLE of the P011 mandate.
    local ref="${1-}" live="${2-}" base="${3-}"
    local rp=0 lp=0 bp=0
    [[ -n "$ref" ]]  && rp=1
    [[ -n "$live" ]] && lp=1
    [[ -n "$base" ]] && bp=1
    local state=''

    if   [[ $rp -eq 0 && $lp -eq 0 ]]; then
        state='absent-both'                       # O | O | *
    elif [[ $rp -eq 1 && $lp -eq 0 ]]; then
        if   [[ $bp -eq 0 ]];            then state='added-ref'                    # R | O | O
        elif [[ "$ref" == "$base" ]];    then state='deleted-live'                # =B | O | present
        else                                  state='conflict-deleted-live-modified-ref' # !=B | O | present
        fi
    elif [[ $rp -eq 0 && $lp -eq 1 ]]; then
        if   [[ $bp -eq 0 ]];            then state='added-live'                   # O | L | O (PROTECTED)
        elif [[ "$live" == "$base" ]];   then state='deleted-ref'                 # O | =B | present (base-aware)
        else                                  state='conflict-deleted-ref-modified-live' # O | !=B | present
        fi
    else
        if   [[ "$ref" == "$live" ]];    then state='identical'                    # R==L
        elif [[ $bp -eq 0 ]];            then state='modified-both'             # R!=L without base
        elif [[ "$ref" == "$base" ]];    then state='modified-live'                # R=B, L!=B
        elif [[ "$live" == "$base" ]];   then state='modified-ref'                 # R!=B, L=B
        else                                  state='modified-both'            # R!=B, L!=B (H2)
        fi
    fi
    printf '%s' "$state"
}

# ---------------------------------------------------------------------------
# 5. show_conflict_diff — git diff --no-index, degrades if git is missing
# ---------------------------------------------------------------------------

show_conflict_diff() {
    # Emits the diff on stdout; NEVER throws (exit 0). --no-index exits 1 when
    # the files differ: expected, absorbed by `|| true`.
    local ref="$1" live="$2"
    if ! command -v git >/dev/null 2>&1; then
        printf 'git not found: diff unavailable (%s <-> %s).\n' "$ref" "$live" >&2
        return 0
    fi
    git diff --no-index -- "$ref" "$live" 2>&1 || true
    return 0
}

# ---------------------------------------------------------------------------
# 6. resolve_lww (A008) — opt-in, conservative, append-only log.
#    Never based on the live FS mtime: the default winner protects the ref.
# ---------------------------------------------------------------------------

resolve_lww() {
    # Emits the winner (ref|live) on stdout; logs the line (append-only)
    # to --log (OUTSIDE the worktree, given by the caller), except --dry-run.
    local relpath="" logpath="" refhash="" livehash="" provenance="ref" dryrun=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --relpath)    relpath="$2"; shift 2 ;;
            --log)        logpath="$2"; shift 2 ;;
            --ref)        refhash="$2"; shift 2 ;;
            --live)       livehash="$2"; shift 2 ;;
            --provenance) provenance="$2"; shift 2 ;;
            --dry-run)    dryrun=1; shift ;;
            *)            shift ;;
        esac
    done
    local winner='ref'
    [[ "$provenance" == "live" ]] && winner='live'

    local ts line
    ts=$(date +%Y-%m-%dT%H:%M:%S%z)
    line="$ts | relpath=$relpath | ref=$refhash | live=$livehash | provenance=$provenance | winner=$winner"

    if [[ $dryrun -eq 0 && -n "$logpath" ]]; then
        local dir; dir=$(dirname "$logpath")
        [[ -n "$dir" && ! -d "$dir" ]] && mkdir -p "$dir"
        printf '%s\n' "$line" >> "$logpath"   # append-only: never rewritten
    fi
    printf '%s' "$winner"
}

# ---------------------------------------------------------------------------
# 7. write_file_atomic — temp+rename. Reads BYTES from stdin, writes to
#    $path.tmp-$$-RANDOM then `mv -f` (atomic rename). NEVER writes in place.
# ---------------------------------------------------------------------------

write_file_atomic() {
    local path="$1"
    local dir; dir=$(dirname "$path")
    [[ -d "$dir" ]] || mkdir -p "$dir"
    # temp in the SAME folder (same volume => atomic rename)
    local tmp="$path.tmp-$$-${RANDOM}${RANDOM}"
    if ! cat > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi
    printf '%s' "$path"
}

# ---------------------------------------------------------------------------
# 8. copy_tree (A009) — per-relPath copy, file by file, ONLY greenlisted
#    relPaths. NO cp -r / rsync --delete / destructive mirror.
#    Atomic write per file. Path-traversal guard.
# ---------------------------------------------------------------------------

copy_tree() {
    # Usage: copy_tree <srcroot> <dstroot> [--dry-run] rel1 rel2 ...
    # Emits the copied relPaths (one per line). EXCLUSIVE greenlist.
    local srcroot="$1" dstroot="$2"; shift 2
    local dryrun=0
    local rels=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dryrun=1; shift ;;
            --)        shift; while [[ $# -gt 0 ]]; do rels+=("$1"); shift; done ;;
            *)         rels+=("$1"); shift ;;
        esac
    done

    # Canonical roots (for the defensive boundary check).
    local srcrootfull dstrootfull
    srcrootfull=$(realpath "$srcroot" 2>/dev/null) || srcrootfull=""
    dstrootfull=$(realpath "$dstroot" 2>/dev/null) || dstrootfull=""

    local rel norm src dst srcfull dstfull unsafe rc=0
    for rel in "${rels[@]}"; do
        norm="${rel//\\//}"
        while [[ "$norm" == /* ]]; do norm="${norm#/}"; done
        [[ -z "$norm" ]] && continue

        # Lexical guard (defense in depth, the greenlist is supposed to be sane):
        # a ../. /empty segment or a rooted path would let a relPath escape
        # dstroot and overwrite a file outside the target tree.
        unsafe=0
        if [[ "$norm" == /* ]] || [[ "$norm" =~ ^[A-Za-z]:([\\/]|$) ]]; then
            unsafe=1
        else
            case "/$norm/" in
                */../* | */./* | *//*) unsafe=1 ;;
            esac
        fi
        if [[ $unsafe -eq 1 ]]; then
            printf 'copy_tree: unsafe relPath (escape/rooted), skipped: %s\n' "$rel" >&2
            continue
        fi

        src="$srcroot/$norm"
        dst="$dstroot/$norm"

        # Final check: resolved paths MUST stay under their roots.
        # (realpath -m: normalizes without requiring existence; if unavailable,
        # the lexical guard above is already enough to prevent any escape.)
        if [[ -n "$srcrootfull" && -n "$dstrootfull" ]]; then
            srcfull=$(realpath -m -- "$src" 2>/dev/null) || srcfull=""
            dstfull=$(realpath -m -- "$dst" 2>/dev/null) || dstfull=""
            if [[ -n "$srcfull" && -n "$dstfull" ]]; then
                case "$srcfull/" in "$srcrootfull"/*) : ;; *)
                    printf 'copy_tree: resolved path outside root, skipped: %s\n' "$rel" >&2
                    continue ;;
                esac
                case "$dstfull/" in "$dstrootfull"/*) : ;; *)
                    printf 'copy_tree: resolved path outside root, skipped: %s\n' "$rel" >&2
                    continue ;;
                esac
            fi
        fi

        if [[ ! -e "$src" ]]; then
            printf 'copy_tree: missing source, skipped: %s\n' "$rel" >&2
            continue
        fi
        if [[ $dryrun -eq 1 ]]; then
            printf '%s\n' "$rel"
            continue
        fi

        # Checked write: if the atomic mv fails (read-only target, disk full,
        # different volume), do NOT emit the rel (the caller will not count it as
        # deployed) + rc=1 -> parity with the hard abort of Copy-Tree .ps1 (avoids
        # a manifest that lies about a file never written).
        if ! write_file_atomic "$dst" < "$src" >/dev/null; then
            printf 'copy_tree: write failed, not copied: %s\n' "$rel" >&2
            rc=1
            continue
        fi
        printf '%s\n' "$rel"
    done
    return $rc
}

# ---------------------------------------------------------------------------
# 9. O_EXCL lock (A009) — atomic `mkdir` (fails if it exists = O_EXCL). Writes
#    pid/host/at into the lock; if writing the metadata fails, removes the
#    orphan lock (otherwise every later acquisition would block forever).
#    The caller adds `trap 'release_sync_lock <path>' EXIT`.
# ---------------------------------------------------------------------------

acquire_sync_lock() {
    # Emits the lock path on success (exit 0); exit 1 if already held.
    local path="$1"
    local dir; dir=$(dirname "$path")
    [[ -d "$dir" ]] || mkdir -p "$dir"

    # mkdir = O_EXCL: atomic, fails if the directory already exists.
    if ! mkdir "$path" 2>/dev/null; then
        printf 'Sync lock already held by another process: %s\n' "$path" >&2
        return 1
    fi

    local meta
    meta="pid=$$"$'\n'"host=$(hostname 2>/dev/null || echo unknown)"$'\n'"at=$(date +%Y-%m-%dT%H:%M:%S%z)"
    if ! printf '%s\n' "$meta" > "$path/meta" 2>/dev/null; then
        # Lock created (mkdir) but writing the metadata failed: remove the
        # orphan lock before reporting the failure.
        rmdir "$path" 2>/dev/null || rm -rf "$path"
        return 1
    fi
    printf '%s' "$path"
    return 0
}

release_sync_lock() {
    local path="${1-}"
    [[ -n "$path" ]] || return 0
    [[ -e "$path" ]] || return 0
    rm -rf "$path"
}

# ---------------------------------------------------------------------------
# 10. write_sync_manifest (A006, H4) — MACHINE-LOCAL manifest (outside the
#     worktree, excluded from sync) written atomically (temp+rename), NEVER in
#     place. JSON through python. Entries read from stdin ("relPath<TAB>sha256" lines).
# ---------------------------------------------------------------------------

write_sync_manifest() {
    # Usage: printf 'relpath\tsha\n...' | write_sync_manifest --path P [--version V] [--machine M]
    local path="" version="SP2"
    local machine="${HOSTNAME:-}"
    [[ -n "$machine" ]] || machine="$(hostname 2>/dev/null || echo unknown)"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --path)    path="$2"; shift 2 ;;
            --version) version="$2"; shift 2 ;;
            --machine) machine="$2"; shift 2 ;;
            *)         shift ;;
        esac
    done
    [[ -n "$path" ]] || { printf 'write_sync_manifest: --path required\n' >&2; return 2; }

    local py; py=$(_sync_py) || { printf 'write_sync_manifest: python 3 not found (JSON manifest)\n' >&2; return 1; }
    local json
    json=$("$py" -c '
import sys, json, datetime
version=sys.argv[1]; machine=sys.argv[2]
entries={}
for line in sys.stdin:
    line=line.rstrip("\n").rstrip("\r")
    if not line or "\t" not in line: continue
    k,v=line.split("\t",1)
    entries[k]=v
obj={
  "version": version,
  "machine": machine,
  "synced_at": datetime.datetime.now().astimezone().isoformat(),
  "domains": ["skills/sdlc*","commands/sdlc","agents/sdlc-*"],
  "entries": {k: entries[k] for k in sorted(entries)},
}
sys.stdout.write(json.dumps(obj, indent=2, ensure_ascii=False))
' "$version" "$machine") || { printf 'write_sync_manifest: python required for the JSON manifest\n' >&2; return 1; }

    printf '%s' "$json" | write_file_atomic "$path" >/dev/null
    printf '%s' "$path"
}

# ---------------------------------------------------------------------------
# 11. read_sync_manifest (H4) — parse; corruption/truncation/bad schema =>
#     fail CLOSED (empty base, never 'identical' by default). Missing = first run
#     (distinct from corruption).
#
#     stdout contract:
#       Line 1: "<ok>\t<exists>\t<failclosed>"  (0/1 flags)
#       Following lines: "<relPath>\t<sha256>"  (one per base entry)
# ---------------------------------------------------------------------------

read_sync_manifest() {
    local path="$1"
    if [[ ! -e "$path" ]]; then
        # Missing = first run: Ok=0, Exists=0, FailClosed=0.
        printf '0\t0\t0\n'
        return 0
    fi
    # Corruption/invalid schema/python failure => fail CLOSED: Ok=0 Exists=1 FailClosed=1.
    local py; py=$(_sync_py) || { printf '0\t1\t1\n'; return 0; }
    "$py" -c '
import sys, json
path=sys.argv[1]
def fail_closed():
    sys.stdout.write("0\t1\t1\n"); sys.exit(0)
try:
    with open(path,"rb") as fh:
        raw=fh.read()
except Exception:
    fail_closed()
text=raw.decode("utf-8","replace")
if text.strip()=="":
    fail_closed()
try:
    parsed=json.loads(text)
except Exception:
    fail_closed()
if not isinstance(parsed, dict) or "entries" not in parsed:
    fail_closed()
entries=parsed.get("entries")
if entries is None:
    entries={}
elif not isinstance(entries, dict):
    fail_closed()
sys.stdout.write("1\t1\t0\n")
for k in entries:
    sys.stdout.write("%s\t%s\n" % (k, entries[k]))
' "$path" 2>/dev/null || printf '0\t1\t1\n'
}

# ---------------------------------------------------------------------------
# 12. get_first_run_plan (A007, H5) — without a base, iterates the UNION {ref ∪ live}.
#     All identical => 'seed'. Any asymmetry/difference => 'block'
#     (resolvable only with --adopt). Never freezes a divergence into the base.
# ---------------------------------------------------------------------------

get_first_run_plan() {
    # Usage: get_first_run_plan --ref <file> --live <file> [--adopt]
    # Files: "relPath<TAB>sha" lines. Emits 'seed' or 'block'.
    local reffile="" livefile="" adopt=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ref)   reffile="$2"; shift 2 ;;
            --live)  livefile="$2"; shift 2 ;;
            --adopt) adopt=1; shift ;;
            *)       shift ;;
        esac
    done

    declare -A R L SEEN
    local k v
    # `|| [[ -n "$k" ]]`: handles the last line even without a final newline
    # (read returns non-zero at EOF but did fill k/v) — otherwise the last
    # relPath/hash entry would be silently lost.
    if [[ -n "$reffile" && -f "$reffile" ]]; then
        while IFS=$'\t' read -r k v || [[ -n "$k" ]]; do [[ -n "$k" ]] && R["$k"]="$v"; done < "$reffile"
    fi
    if [[ -n "$livefile" && -f "$livefile" ]]; then
        while IFS=$'\t' read -r k v || [[ -n "$k" ]]; do [[ -n "$k" ]] && L["$k"]="$v"; done < "$livefile"
    fi

    local mism=0 key rp lp rv lv
    for key in "${!R[@]}" "${!L[@]}"; do
        [[ -n "${SEEN[$key]+x}" ]] && continue
        SEEN["$key"]=1
        rp="${R[$key]+x}"; lp="${L[$key]+x}"
        rv="${R[$key]-}";  lv="${L[$key]-}"
        # mismatch if presence differs (asymmetry) or values differ
        if [[ "$rp" != "$lp" || "$rv" != "$lv" ]]; then mism=$((mism+1)); fi
    done

    if [[ $mism -eq 0 ]]; then printf 'seed'; return 0; fi
    [[ $adopt -eq 1 ]] && { printf 'seed'; return 0; }
    printf 'block'; return 0
}

# ---------------------------------------------------------------------------
# 13. set_nestor_import / remove_nestor_import (P022:A019) — adds/removes the
#     canonical '@NESTOR.md' line in a GLOBAL USER file (~/.claude/CLAUDE.md),
#     OUTSIDE the sync domain (never added to get_domain_relpaths/greenlist).
#     Detection = count of lines whose TRIMMED content is EXACTLY '@NESTOR.md'
#     (literal match, never a broad regex). Atomic write (write_file_atomic) +
#     timestamped backup (except --dry-run) BEFORE any mutation; NEVER touches
#     the bytes of other lines. Optional nestor-agents interop.
#     set_nestor_import wraps set_generic_import (P032:A029), which carries the
#     same logic parameterized by an explicit --marker (reusable for any future
#     marker, e.g. a *.local.md overlay).
# ---------------------------------------------------------------------------

_nestor_import_lines_from_content() {
    # Fills the global array _NESTOR_IMPORT_LINES from the STRING $1 (already read),
    # lines keeping their original terminator (CRLF/LF); the last line has NO
    # terminator if the content does not end with an EOL.
    _NESTOR_IMPORT_LINES=()
    local content="$1"
    [[ -n "$content" ]] || return 0
    mapfile _NESTOR_IMPORT_LINES < <(printf '%s' "$content")
}

_nestor_import_trim() {
    # Trim: removes the terminator (\r?\n) then leading/trailing whitespace. Emits on stdout.
    local s="$1"
    s="${s%$'\n'}"; s="${s%$'\r'}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

_nestor_import_backup() {
    # Timestamped backup (file name UNCHANGED, nested in a unique subfolder) —
    # mirrors the install.sh/restore.sh conventions, avoids any clash with the
    # *.tmp-*/*.bak-* patterns reserved for write_file_atomic's TRANSIENT artifacts.
    local path="$1"
    local dir; dir=$(dirname -- "$path")
    local leaf; leaf=$(basename -- "$path")
    local backup_dir="$dir/_backups/nestor-import-$(date +%Y%m%d-%H%M%S)-$$-${RANDOM}"
    write_file_atomic "$backup_dir/$leaf" < "$path" >/dev/null
}

set_generic_import() {
    # Usage: set_generic_import [--dry-run] --marker "<marker>" <path>
    #   (P032:A029 — body extracted from the former set_nestor_import, parameterized
    #   by an explicit marker instead of the '@NESTOR.md' literal.)
    #   count($marker) >= 1 -> no-op (count > 1: stderr warning, NO dedup).
    #   count == 0 -> append at end of file, WITHOUT touching existing bytes;
    #     prefixed with an EOL (file's DOMINANT style: CRLF if CRLF is the majority,
    #     else LF) if the file does not already end with an EOL. Missing file ->
    #     created with that single line. --dry-run: 0 writes (no backup, target or temp).
    local dryrun=0 path="" marker=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dryrun=1; shift ;;
            --marker)  marker="$2"; shift 2 ;;
            *)         path="$1"; shift ;;
        esac
    done
    [[ -n "$path" ]] || { printf 'set_generic_import: path required\n' >&2; return 2; }
    [[ -n "$marker" ]] || { printf 'set_generic_import: marker required (--marker)\n' >&2; return 2; }

    local content=""
    if [[ -f "$path" ]]; then content=$(cat -- "$path"; printf 'X'); content="${content%X}"; fi
    _nestor_import_lines_from_content "$content"

    local raw trimmed count=0
    for raw in "${_NESTOR_IMPORT_LINES[@]}"; do
        trimmed=$(_nestor_import_trim "$raw")
        [[ "$trimmed" == "$marker" ]] && count=$((count + 1))
    done

    if [[ $count -ge 1 ]]; then
        if [[ $count -gt 1 ]]; then
            printf 'set_generic_import: WARNING — %d %s lines found in %s (no automatic dedup)\n' "$count" "$marker" "$path" >&2
        fi
        return 0
    fi

    # count == 0: build the content to write (file's dominant EOL style).
    local crlf_n=0 lf_n=0
    for raw in "${_NESTOR_IMPORT_LINES[@]}"; do
        if [[ "$raw" == *$'\r\n' ]]; then crlf_n=$((crlf_n + 1))
        elif [[ "$raw" == *$'\n' ]];  then lf_n=$((lf_n + 1)); fi
    done
    local dominant=$'\n'
    [[ $crlf_n -gt $lf_n ]] && dominant=$'\r\n'

    local newcontent
    if [[ -z "$content" ]]; then
        newcontent="$marker"
    elif [[ "$content" == *$'\n' ]]; then
        newcontent="${content}${marker}"
    else
        newcontent="${content}${dominant}${marker}"
    fi

    [[ $dryrun -eq 1 ]] && return 0

    [[ -f "$path" ]] && _nestor_import_backup "$path"
    printf '%s' "$newcontent" | write_file_atomic "$path" >/dev/null
}

set_nestor_import() {
    # Usage: set_nestor_import [--dry-run] <path>
    # Adds the canonical '@NESTOR.md' line to <path>. Wrapper of set_generic_import
    # (P032:A029) — byte-identical behavior to the original implementation.
    set_generic_import --marker '@NESTOR.md' "$@"
}

set_local_overlay_import() {
    # Usage: set_local_overlay_import [--dry-run] <path> <local-file-name>
    # P033:A029 — ensures the private overlay <local-file-name> exists (next to
    # <path>), then adds the "@<local-file-name>" import line to <path> (via
    # set_generic_import). If the overlay is missing AND this is NOT --dry-run, it
    # is created EMPTY (write_file_atomic) before the import is added — never the
    # other way round. An existing overlay (empty or not) is never overwritten.
    # --dry-run: 0 writes (no overlay, no import line).
    local dryrun=0 path="" localname=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dryrun=1; shift ;;
            *)
                if [[ -z "$path" ]]; then path="$1";
                else localname="$1"; fi
                shift ;;
        esac
    done
    [[ -n "$path" ]] || { printf 'set_local_overlay_import: path required\n' >&2; return 2; }
    [[ -n "$localname" ]] || { printf 'set_local_overlay_import: local file name required\n' >&2; return 2; }

    local dir; dir=$(dirname -- "$path")
    local localpath="$dir/$localname"
    if [[ ! -f "$localpath" && $dryrun -eq 0 ]]; then
        printf '' | write_file_atomic "$localpath" >/dev/null
    fi

    if [[ $dryrun -eq 1 ]]; then
        set_generic_import --dry-run --marker "@$localname" "$path"
    else
        set_generic_import --marker "@$localname" "$path"
    fi
}

remove_nestor_import() {
    # Usage: remove_nestor_import [--dry-run] <path>
    # Removes ALL lines whose trimmed content is EXACTLY '@NESTOR.md', and ONLY
    # those: the rest of the file stays byte-identical. Missing file ->
    # no-op. --dry-run: 0 writes.
    local dryrun=0 path=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dryrun=1; shift ;;
            *)         path="$1"; shift ;;
        esac
    done
    [[ -n "$path" ]] || { printf 'remove_nestor_import: path required\n' >&2; return 2; }
    [[ -f "$path" ]] || return 0

    local content; content=$(cat -- "$path"; printf 'X'); content="${content%X}"
    _nestor_import_lines_from_content "$content"

    local raw trimmed newcontent="" removed_any=0
    for raw in "${_NESTOR_IMPORT_LINES[@]}"; do
        trimmed=$(_nestor_import_trim "$raw")
        if [[ "$trimmed" == '@NESTOR.md' ]]; then
            removed_any=1
            continue
        fi
        newcontent="${newcontent}${raw}"
    done

    [[ $removed_any -eq 1 ]] || return 0
    [[ $dryrun -eq 1 ]] && return 0

    _nestor_import_backup "$path"
    printf '%s' "$newcontent" | write_file_atomic "$path" >/dev/null
}

# ---------------------------------------------------------------------------
# Self-execution guard: sourcing this file only defines the functions above.
# Run directly, it has no effect.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf 'sync-lib.sh is a library: source it (. sync-lib.sh).\n' >&2
    exit 0
fi
