#!/usr/bin/env bash
# verify.sh — REF-authoritative hash fidelity checker (P018:A014).
#
# BASH port with identical behavior of verify.ps1 (the shipped/tested reference).
# Proves that the LIVE install (~/.claude) is byte-identical to the committed
# canonical REF (repo sdlc-framework/claude/ at git HEAD). Strictly READ-ONLY:
# writes NO file, commits nothing, takes no lock.
#
# Behavior (single source = sync-lib.sh):
#   - sdlc domain scope (H7) on the LIVE side through get_domain_relpaths;
#     THIRD-PARTY skills (not sdlc*) are ignored, never counted nor flagged as extra.
#   - Compares the COMMITTED HEAD: REF content is read with
#     `git cat-file blob HEAD:claude/<relpath>` — NOT the working tree.
#   - Reuses the CENTRALIZED exclusion set (test_sync_excluded): real .pyc files
#     in live are NEVER extra.
#   - Reports: MISSING / HASH DIFF / EXTRA / FLOOR (exact markers).
#   - Floors DERIVED from a committed source (never a hard-coded literal).
#
# Exit codes (same as verify.ps1):
#   0 = perfect fidelity (0 differences)
#   1 = at least one difference (MISSING / HASH DIFF / EXTRA / FLOOR)
#   2 = unavailable (LIVE not found OR git missing / no committed HEAD)
#
# Drivable: the body does NOT run when sourced (BASH_SOURCE guard at the bottom),
# which lets tests source it and call invoke_verify on fixtures.
#
# CLI args (mirror of -RefRoot/-LiveRoot/-Quiet):
#   --ref-root <dir>   default: two levels above bundle/scripts (the repo)
#   --live-root <dir>  default: $HOME/.claude
#   -q | --quiet

# ponytail: no `set -e` at file scope — this script is SOURCED by the tests;
# changing the caller's shell options would break them. Defensive coding.

_verify_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_verify_dir/sync-lib.sh"

# ---------------------------------------------------------------------------
# Projection of the sync domain (A003 + core A018 SP3) onto a relPath from the
# git tree (no FS). FAITHFUL mirror of get_domain_relpaths; reuses
# test_sync_excluded.
# ponytail: any new domain added to get_domain_relpaths must be mirrored here.
# ---------------------------------------------------------------------------
test_in_sdlc_domain() {
    local relpath="${1-}"
    local norm="${relpath//\\//}"
    while [[ "$norm" == /* ]]; do norm="${norm#/}"; done
    while [[ "$norm" == */ ]]; do norm="${norm%/}"; done
    [[ -z "$norm" ]] && return 1
    test_sync_excluded "$norm" && return 1

    # core domain (A018 SP3): the LITERAL NESTOR.md only — no root pattern.

    local leaf="${norm##*/}"
    local nseg=1 rest="$norm"
    while [[ "$rest" == */* ]]; do rest="${rest#*/}"; nseg=$((nseg+1)); done
    local seg0="${norm%%/*}"
    local seg1=""
    if [[ "$norm" == */* ]]; then local tail="${norm#*/}"; seg1="${tail%%/*}"; fi

    # skills domain: skills/<sdlc*dir>/<file...> (>=3 segments), except
    # skills/sdlc/commands/** (H3). A loose 2-segment file is never scanned on the
    # LIVE side, so it is never in-domain on the REF side either.
    if [[ "$seg0" == "skills" && $nseg -ge 3 && "$seg1" == sdlc* ]]; then
        case "$norm" in skills/sdlc/commands/*) return 1 ;; esac
        return 0
    fi
    # commands domain: canonical top-level commands/sdlc/**
    case "$norm" in commands/sdlc/*) return 0 ;; esac
    # agents domain: agents/**/<sdlc-*> (A018 SP3)
    if [[ "$seg0" == "agents" && $nseg -ge 2 ]] \
       && [[ "$leaf" == sdlc-* ]]; then return 0; fi
    return 1
}

test_git_ref_usable() {
    local reporoot="$1"
    command -v git >/dev/null 2>&1 || return 1
    git -C "$reporoot" rev-parse --verify --quiet HEAD >/dev/null 2>&1
}

get_ref_domain_relpaths() {
    # relPaths (claude/ prefix removed) of the sdlc domain COMMITTED at HEAD —
    # enumerates the git tree, not the working tree. Sorted + unique. Non-zero if git fails.
    local reporoot="$1"
    local out rc p rel
    out=$(git -C "$reporoot" -c core.quotepath=false ls-tree -r --name-only HEAD -- claude 2>/dev/null)
    rc=$?
    [[ $rc -eq 0 ]] || return 1
    {
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            p="${p//\\//}"
            case "$p" in claude/*) : ;; *) continue ;; esac
            rel="${p#claude/}"
            test_in_sdlc_domain "$rel" && printf '%s\n' "$rel"
        done <<< "$out"
    } | LC_ALL=C sort -u
}

git_blob_sha256() {
    # Byte-exact lowercase sha256 hex of the committed blob HEAD:claude/<rel>. git
    # streams the raw BYTES to sha256sum (no EOL normalization) — identical to
    # get_file_hash_byteexact on the live side.
    # ponytail: rel is enumerated from the same HEAD => the blob always exists; if
    # cat-file failed, sha256sum('') would give a bogus hash (difference, not exit 2).
    local reporoot="$1" rel="$2" out
    out=$(git -C "$reporoot" cat-file blob "HEAD:claude/$rel" 2>/dev/null | sha256sum) || return 1
    printf '%s' "${out%% *}"
}

get_domain_cardinalities() {
    # Reads relPaths (one per line) on stdin; prints "skills agents commands core".
    # skills = number of first-level sdlc* folders; agents/commands = files;
    # core = 0/1 on the literal NESTOR.md (A018 SP3). No hard-coded number.
    awk -F'/' '
        $0 == "" { next }
        $0 == "NESTOR.md"         { co++; next }
        $1 == "skills" && NF >= 2 { sk[$2] = 1; next }
        $1 == "agents"            { ag++; next }
        /^commands\/sdlc\//     { cm++; next }
        END { n = 0; for (k in sk) n++; printf "%d %d %d %d\n", n, ag, cm, co }
    '
}

# ---------------------------------------------------------------------------
# Core: invoke_verify (returns 0 = identical, 1 = difference, 2 = unavailable)
# ---------------------------------------------------------------------------
_verify_quiet=0
_vsay() { [[ "$_verify_quiet" == "1" ]] || printf '%s\n' "$*"; }

invoke_verify() {
    local ref_root="" live_root=""
    _verify_quiet=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ref-root)  ref_root="$2"; shift 2 ;;
            --live-root) live_root="$2"; shift 2 ;;
            -q|--quiet)  _verify_quiet=1; shift ;;
            *)           shift ;;
        esac
    done

    local bar="======================================================================"
    _vsay ""
    _vsay "$bar"
    _vsay "  verify — REF-authoritative fidelity (committed HEAD vs live)"
    _vsay "$bar"

    # -e (not -d): mirror of Test-Path in the .ps1 (true for a file OR a folder). A
    # live_root that is a file passes the guard and is then classified [MISSING] ->
    # exit 1 (ps1 parity), instead of a divergent exit 2 'unavailable'.
    if [[ ! -e "$live_root" ]]; then
        _vsay "LIVE not found: $live_root"
        return 2
    fi
    if ! test_git_ref_usable "$ref_root"; then
        _vsay "REF unusable (git missing or no committed HEAD): $ref_root"
        return 2
    fi

    # --- REF (committed HEAD) ---
    local -A refHash liveHash
    local rel
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        refHash["$rel"]=$(git_blob_sha256 "$ref_root" "$rel")
    done < <(get_ref_domain_relpaths "$ref_root")

    # --- LIVE (domain scope via sync-lib, H7 + exclusions) ---
    local full
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        full="$live_root/$rel"
        [[ -f "$full" ]] || continue
        liveHash["$rel"]=$(get_file_hash_byteexact "$full")
    done < <(get_domain_relpaths "$live_root")

    # --- Fidelity comparison ---
    local -a missing=() hashdiff=() surplus=()
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        if [[ -z "${liveHash[$rel]+x}" ]]; then
            missing+=("$rel")
        elif [[ "${liveHash[$rel]}" != "${refHash[$rel]}" ]]; then
            hashdiff+=("$rel")
        fi
    done < <(printf '%s\n' "${!refHash[@]}" | LC_ALL=C sort)
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        [[ -z "${refHash[$rel]+x}" ]] && surplus+=("$rel")
    done < <(printf '%s\n' "${!liveHash[@]}" | LC_ALL=C sort)

    # --- Derived floors: committed ref == live ---
    local rsk rag rcm rco lsk lag lcm lco
    read -r rsk rag rcm rco < <(printf '%s\n' "${!refHash[@]}"  | get_domain_cardinalities)
    read -r lsk lag lcm lco < <(printf '%s\n' "${!liveHash[@]}" | get_domain_cardinalities)
    local -a carddrift=()
    [[ "$lsk" != "$rsk" ]] && carddrift+=("skills: floor=$rsk live=$lsk")
    [[ "$lag" != "$rag" ]] && carddrift+=("agents: floor=$rag live=$lag")
    [[ "$lcm" != "$rcm" ]] && carddrift+=("commands: floor=$rcm live=$lcm")
    [[ "$lco" != "$rco" ]] && carddrift+=("core: floor=$rco live=$lco")

    # --- Report ---
    _vsay ""
    _vsay "  ref (committed HEAD) : ${#refHash[@]} domain files"
    _vsay "  live (sdlc scope)    : ${#liveHash[@]} domain files"
    _vsay "  derived floors       : skills=$rsk agents=$rag commands=$rcm core=$rco"

    local m
    for m in "${missing[@]}";   do _vsay "  [MISSING]      $m"; done
    for m in "${hashdiff[@]}";  do _vsay "  [HASH DIFF]    $m"; done
    for m in "${surplus[@]}";   do _vsay "  [EXTRA]        $m"; done
    for m in "${carddrift[@]}"; do _vsay "  [FLOOR]        $m"; done

    local ecarts=$(( ${#missing[@]} + ${#hashdiff[@]} + ${#surplus[@]} + ${#carddrift[@]} ))

    _vsay ""
    if [[ $ecarts -eq 0 ]]; then
        _vsay "  PERFECT fidelity: live == committed ref HEAD (0 differences)."
        return 0
    fi
    _vsay "  FAIL: $ecarts difference(s) found. Live != canonical ref."
    return 1
}

# ---------------------------------------------------------------------------
# Execution guard: run nothing when sourced (drivable by tests).
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_bash4 || exit $?   # local -A refHash/liveHash (bash 4+); exit 2 = unavailable
    ref_root="$(cd "$_verify_dir/../.." && pwd)"
    live_root="$HOME/.claude"
    quiet_flag=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ref-root)  ref_root="$2"; shift 2 ;;
            --live-root) live_root="$2"; shift 2 ;;
            -q|--quiet)  quiet_flag="-q"; shift ;;
            *)           shift ;;
        esac
    done
    invoke_verify --ref-root "$ref_root" --live-root "$live_root" $quiet_flag
    exit $?
fi
