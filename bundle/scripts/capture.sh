#!/usr/bin/env bash
# capture.sh — BASH port of capture.ps1 with identical behavior (P012:A006, port P018:A014).
#
# Canonical direction (A001): REF = source of truth = repo sdlc-framework/claude/
# (tracked by git). LIVE = the ~/.claude/ install. The BASE (3rd state) is a
# machine-local manifest stored OUTSIDE the git worktree (under ~/.claude/, H1).
#
# Behavior (mirror of the .ps1):
#   - Acquires an O_EXCL lockfile (mkdir) around every mutation; released via trap EXIT.
#   - Loads the base (read_sync_manifest). Missing -> get_first_run_plan (union
#     ref+live): seed if equal, otherwise BLOCKED (requires --adopt). Corrupt -> fail
#     CLOSED (refuses to act on an untrusted base).
#   - Classifies each relPath of the UNION of the domains (get_sync_state):
#       modified-live / added-live      -> CAPTURE (copy live->ref)
#       modified-both                   -> BLOCKED (diff), unless --lww (logged)
#       deleted-live / conflict-*       -> BLOCKED (never propagated without a direction)
#       identical / modified-ref / ...  -> skip
#   - >=1 unresolved block: exit 3, WRITES NOTHING (no files, no manifest, no git).
#   - Copies the greenlisted relPaths with copy_tree (per-relpath, never a mirror).
#   - Commit: stage AND commit LIMITED to the copied rels ONLY (explicit pathspec
#     'claude/<rel>' on both 'git add' AND 'git commit') — never a global stage nor a commit without a pathspec.
#   - BEFORE any LWW winner=live overwrite of an existing ref file: timestamped backup
#     of the losing ref OUTSIDE the worktree (recoverable).
#   - POST-CHECK (A4): after the commit, 'git status --porcelain -- <pathspecs>' must be
#     empty; otherwise exit 7 and the base is NOT rewritten (partial failure).
#   - On success only: rewrites the base (atomic write_sync_manifest).
#   - --dry-run: 0 writes; the exit code reflects the would-block (!=0 if it would have blocked).
#
# Exit codes (same as capture.ps1):
#   0 success / nothing to capture / first-run seed / dry-run without block
#   2 RefRoot|LiveRoot not found, or git not found
#   3 hard block (modified-both without --lww, deleted-live, conflict-*)
#   4 'git add' or 'git commit' failed
#   5 first-run BLOCKED (asymmetry/divergence without a base)
#   6 corrupt manifest (FAIL CLOSED)
#   7 POST-CHECK failed (worktree still dirty after the commit)
#
# ZERO framework dependency. Sources the sync-lib.sh foundation (does not re-implement
# hashing, lock, atomic write, greenlist or manifest).

# NB: no `set -e` — several commands have an expected failure (acquire lock,
# git add/commit/status classified by exit code). set -u/pipefail for rigor.
set -uo pipefail

CAPTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$CAPTURE_DIR/sync-lib.sh"

# --- Lock: released via trap EXIT (the script runs as a standalone process) ---
_CAPTURE_LOCK=""
_capture_release() { [[ -n "${_CAPTURE_LOCK:-}" ]] && release_sync_lock "$_CAPTURE_LOCK"; }

# --- Core --------------------------------------------------------------------
# invoke_capture <refroot> <liveroot> <gitroot> <manifest> <conflictlog> <lockpath>
#                <lww:0/1> <provenance> <adopt:0/1> <dryrun:0/1>
invoke_capture() {
    local refroot="$1" liveroot="$2" gitroot="$3" manifest="$4" conflictlog="$5"
    local lockpath="$6" lww="$7" provenance="$8" adopt="$9" dryrun="${10}"

    # --- Path resolution (Resolve-Path -> realpath) ---
    local r
    r=$(realpath "$refroot" 2>/dev/null) || { printf 'capture: RefRoot not found: %s\n' "$refroot"; return 2; }
    [[ -n "$r" ]] || { printf 'capture: RefRoot not found: %s\n' "$refroot"; return 2; }
    refroot="$r"
    r=$(realpath "$liveroot" 2>/dev/null) || { printf 'capture: LiveRoot not found: %s\n' "$liveroot"; return 2; }
    [[ -n "$r" ]] || { printf 'capture: LiveRoot not found: %s\n' "$liveroot"; return 2; }
    liveroot="$r"

    [[ -n "$gitroot" ]] || gitroot="$(dirname "$refroot")"
    local refleaf="${refroot##*/}"
    [[ -n "$manifest" ]]    || manifest="$liveroot/.sync-manifest.json"
    [[ -n "$conflictlog" ]] || conflictlog="$liveroot/conflicts.log"
    [[ -n "$lockpath" ]]    || lockpath="$liveroot/.sync.lock"

    local mode=''
    [[ $dryrun -eq 1 ]] && mode='[dry-run] '
    printf 'capture %s: ref=%s  live=%s\n' "$mode" "$refroot" "$liveroot"

    # --- Exclusive lock around all analysis + mutation ---
    if ! acquire_sync_lock "$lockpath" >/dev/null; then
        printf 'capture: sync lock already held — aborting.\n'
        return 1
    fi
    _CAPTURE_LOCK="$lockpath"
    trap _capture_release EXIT

    # --- UNION of the domain relPaths (ref + live) ---
    local union
    union=$( { get_domain_relpaths "$refroot"; get_domain_relpaths "$liveroot"; } | LC_ALL=C sort -u )

    # --- Load the base (3rd state) ---
    local ok exists failclosed k v
    local -A base=()
    {
        IFS=$'\t' read -r ok exists failclosed
        # read_sync_manifest may emit CRLF (python in text mode on
        # Windows): strip a trailing \r from the flags AND the values, otherwise
        # the base hash carries a \r and every base comparison fails.
        failclosed="${failclosed%$'\r'}"; exists="${exists%$'\r'}"; ok="${ok%$'\r'}"
        while IFS=$'\t' read -r k v; do
            k="${k%$'\r'}"; v="${v%$'\r'}"
            [[ -n "$k" ]] && base["$k"]="$v"
        done
    } < <(read_sync_manifest "$manifest")

    # ---- FIRST-RUN (H5): seed if the union is equal, otherwise block ----
    if [[ "$exists" == "0" ]]; then
        local reftsv livetsv
        reftsv=$(mktemp "${TMPDIR:-/tmp}/cap-ref-XXXXXX")
        livetsv=$(mktemp "${TMPDIR:-/tmp}/cap-live-XXXXXX")
        local -A seed=()
        local rel rh lh
        while IFS= read -r rel; do
            [[ -n "$rel" ]] || continue
            rh=""; lh=""
            [[ -f "$refroot/$rel" ]]  && rh=$(get_file_hash_byteexact "$refroot/$rel")
            [[ -f "$liveroot/$rel" ]] && lh=$(get_file_hash_byteexact "$liveroot/$rel")
            [[ -n "$rh" ]] && printf '%s\t%s\n' "$rel" "$rh" >> "$reftsv"
            [[ -n "$lh" ]] && printf '%s\t%s\n' "$rel" "$lh" >> "$livetsv"
            if   [[ -n "$rh" ]]; then seed["$rel"]="$rh"
            elif [[ -n "$lh" ]]; then seed["$rel"]="$lh"; fi
        done <<< "$union"

        local signal
        if [[ $adopt -eq 1 ]]; then
            signal=$(get_first_run_plan --ref "$reftsv" --live "$livetsv" --adopt)
        else
            signal=$(get_first_run_plan --ref "$reftsv" --live "$livetsv")
        fi
        rm -f "$reftsv" "$livetsv"

        if [[ "$signal" == "block" ]]; then
            printf 'capture: first-run BLOCKED (asymmetry/divergence without a base).\n'
            printf '        Run again with --adopt to adopt the current state.\n'
            return 5
        fi

        local adopted_tag=''
        [[ $adopt -eq 1 ]] && adopted_tag=' (adopted)'
        if [[ $dryrun -eq 1 ]]; then
            printf 'capture: first-run seed%s — %d entry(ies) [dry-run, base not written].\n' "$adopted_tag" "${#seed[@]}"
            return 0
        fi
        {
            local sk
            for sk in "${!seed[@]}"; do printf '%s\t%s\n' "$sk" "${seed[$sk]}"; done
        } | write_sync_manifest --path "$manifest" >/dev/null
        printf 'capture: first-run seed%s — base written (%d entry(ies)).\n' "$adopted_tag" "${#seed[@]}"
        return 0
    fi

    # ---- FAIL CLOSED (H4): corrupt base -> refuse to act ----
    if [[ "$failclosed" == "1" ]]; then
        printf 'capture: unreadable/corrupt manifest -> FAIL CLOSED (no action).\n'
        printf '        No capture is attempted on an untrusted base.\n'
        return 6
    fi

    # ---- NORMAL PASS (trusted base) ----
    local -a capturerels=()
    local -A capturehash=()
    local -a lww_rel=() lww_refh=() lww_liveh=()
    local -a blk_rel=() blk_state=() blk_refh=() blk_liveh=()

    local rel refh liveh baseh st
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        refh=""; liveh=""; baseh=""
        [[ -f "$refroot/$rel" ]]  && refh=$(get_file_hash_byteexact "$refroot/$rel")
        [[ -f "$liveroot/$rel" ]] && liveh=$(get_file_hash_byteexact "$liveroot/$rel")
        [[ -n "${base[$rel]+x}" ]] && baseh="${base[$rel]}"
        st=$(get_sync_state "$refh" "$liveh" "$baseh")
        case "$st" in
            modified-live|added-live)
                capturerels+=("$rel"); capturehash["$rel"]="$liveh" ;;
            modified-both)
                if [[ $lww -eq 1 ]]; then
                    lww_rel+=("$rel"); lww_refh+=("$refh"); lww_liveh+=("$liveh")
                else
                    blk_rel+=("$rel"); blk_state+=("$st"); blk_refh+=("$refh"); blk_liveh+=("$liveh")
                fi ;;
            identical|modified-ref|added-ref|deleted-ref|absent-both)
                : ;;
            *)
                # deleted-live and every conflict-*: never propagated without a direction.
                blk_rel+=("$rel"); blk_state+=("$st"); blk_refh+=("$refh"); blk_liveh+=("$liveh") ;;
        esac
    done <<< "$union"

    # ---- HARD BLOCKS: exit 3, NOTHING written ----
    if [[ ${#blk_rel[@]} -gt 0 ]]; then
        printf 'capture: BLOCKED — %d unresolved conflict(s). Nothing written.\n' "${#blk_rel[@]}"
        local i
        for i in "${!blk_rel[@]}"; do
            printf '  [BLOCK] %s  (%s)\n' "${blk_rel[$i]}" "${blk_state[$i]}"
            if [[ -n "${blk_refh[$i]}" && -n "${blk_liveh[$i]}" ]]; then
                show_conflict_diff "$refroot/${blk_rel[$i]}" "$liveroot/${blk_rel[$i]}"
            fi
        done
        printf '        Resolve manually, or use --lww (opt-in, logged) for modified-both.\n'
        return 3
    fi

    # At this point: no hard block. Writing is allowed.

    # ---- Opt-in LWW resolution (logged) ----
    # modified-both implies an uncommitted REF change: winner=live will
    # overwrite it. Remember these rels so they are backed up BEFORE the copy.
    local -a lwwwinnerslive=()
    local j winner found x
    for (( j = 0; j < ${#lww_rel[@]}; j++ )); do
        rel="${lww_rel[$j]}"; refh="${lww_refh[$j]}"; liveh="${lww_liveh[$j]}"
        if [[ $dryrun -eq 1 ]]; then
            winner=$(resolve_lww --relpath "$rel" --log "$conflictlog" --ref "$refh" --live "$liveh" --provenance "$provenance" --dry-run)
        else
            winner=$(resolve_lww --relpath "$rel" --log "$conflictlog" --ref "$refh" --live "$liveh" --provenance "$provenance")
        fi
        printf '  [LWW] %s -> winner=%s\n' "$rel" "$winner"
        if [[ "$winner" == "live" ]]; then
            found=0
            if [[ ${#capturerels[@]} -gt 0 ]]; then
                for x in "${capturerels[@]}"; do [[ "$x" == "$rel" ]] && { found=1; break; }; done
            fi
            [[ $found -eq 0 ]] && capturerels+=("$rel")
            capturehash["$rel"]="$liveh"
            lwwwinnerslive+=("$rel")
        fi
        # winner=ref: keep the canonical file, nothing to capture.
    done

    if [[ ${#capturerels[@]} -eq 0 ]]; then
        printf 'capture: nothing to capture (no greenlisted live change).\n'
        return 0
    fi

    if [[ $dryrun -eq 1 ]]; then
        printf 'capture [dry-run]: %d file(s) WOULD be captured — nothing written.\n' "${#capturerels[@]}"
        local rr
        for rr in "${capturerels[@]}"; do printf '  + %s\n' "$rr"; done
        return 0
    fi

    # ---- git available (required to commit) ----
    if ! command -v git >/dev/null 2>&1; then
        printf 'capture: git not found — cannot commit. Nothing written.\n'
        return 2
    fi

    # ---- Timestamped backup of losing refs BEFORE the LWW overwrite ----
    if [[ ${#lwwwinnerslive[@]} -gt 0 ]]; then
        local backuproot="$(dirname "$conflictlog")/_backups/$(date +%Y%m%d-%H%M%S)-$RANDOM$RANDOM"
        local bak
        for rel in "${lwwwinnerslive[@]}"; do
            if [[ -f "$refroot/$rel" ]]; then
                bak="$backuproot/$rel"
                write_file_atomic "$bak" < "$refroot/$rel" >/dev/null
                printf '  [BACKUP] ref %s backed up -> %s\n' "$rel" "$bak"
            fi
        done
    fi

    # ---- Copy live -> ref (per-relpath, never a mirror) ----
    local -a copiedarr=()
    local c
    while IFS= read -r c; do [[ -n "$c" ]] && copiedarr+=("$c"); done \
        < <(copy_tree "$liveroot" "$refroot" -- "${capturerels[@]}")
    printf 'capture: %d file(s) copied live->ref.\n' "${#copiedarr[@]}"

    if [[ ${#copiedarr[@]} -eq 0 ]]; then
        # No source actually copied: commit NOTHING (a commit without a
        # pathspec would pull in the whole index).
        printf 'capture: no file actually copied — nothing to commit, base unchanged.\n'
        return 0
    fi

    # ---- Commit: EXPLICIT pathspec limited to the copied rels ONLY ----
    local -a pathspecs=()
    for c in "${copiedarr[@]}"; do pathspecs+=("$refleaf/$c"); done

    local out code
    out=$(git -C "$gitroot" add -- "${pathspecs[@]}" 2>&1); code=$?
    if [[ $code -ne 0 ]]; then
        printf 'capture: git add (copied rels) failed (code %d). Base not rewritten.\n' "$code"
        [[ -n "$out" ]] && printf '%s\n' "$out"
        return 4
    fi
    local msg="capture: sync live -> ref (P012:A006) - ${#copiedarr[@]} file(s)"
    out=$(git -C "$gitroot" commit -m "$msg" -- "${pathspecs[@]}" 2>&1); code=$?
    if [[ $code -ne 0 ]]; then
        printf 'capture: git commit failed (code %d). Base not rewritten.\n' "$code"
        [[ -n "$out" ]] && printf '%s\n' "$out"
        return 4
    fi

    # ---- POST-CHECK (A4): the committed rels ONLY must be clean ----
    out=$(git -C "$gitroot" status --porcelain -- "${pathspecs[@]}" 2>&1); code=$?
    local trimmed="${out//[$' \t\r\n']/}"
    if [[ $code -ne 0 || -n "$trimmed" ]]; then
        printf 'capture: POST-CHECK FAILED — committed rels still dirty (partial failure).\n'
        [[ -n "$out" ]] && printf '%s\n' "$out"
        printf '        Base NOT rewritten (untrusted state).\n'
        return 7
    fi

    # ---- Success: atomic rewrite of the base ----
    # base += hashes of the files actually copied ONLY. Base first, copies
    # second (write_sync_manifest: the last value of a key wins).
    {
        local bk
        for bk in "${!base[@]}"; do printf '%s\t%s\n' "$bk" "${base[$bk]}"; done
        for c in "${copiedarr[@]}"; do
            [[ -n "${capturehash[$c]+x}" ]] && printf '%s\t%s\n' "$c" "${capturehash[$c]}"
        done
    } | write_sync_manifest --path "$manifest" >/dev/null

    printf 'capture: OK — %d file(s) captured and committed; base rewritten.\n' "${#copiedarr[@]}"
    return 0
}

# --- Parse CLI + defaults + auto-run ----------------------------------------
main() {
    local refroot="$CAPTURE_DIR/../../claude" liveroot="$HOME/.claude"
    local gitroot="" manifest="" conflictlog="" lockpath=""
    local lww=0 provenance="ref" adopt=0 dryrun=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ref|--ref-root)       refroot="$2"; shift 2 ;;
            --live|--live-root)     liveroot="$2"; shift 2 ;;
            --git-root)             gitroot="$2"; shift 2 ;;
            --manifest)             manifest="$2"; shift 2 ;;
            --conflict-log)         conflictlog="$2"; shift 2 ;;
            --lock)                 lockpath="$2"; shift 2 ;;
            --lww)                  lww=1; shift ;;
            --provenance)           provenance="$2"; shift 2 ;;
            --adopt)                adopt=1; shift ;;
            --dry-run)              dryrun=1; shift ;;
            *) printf 'capture: unknown option: %s\n' "$1" >&2; return 2 ;;
        esac
    done
    invoke_capture "$refroot" "$liveroot" "$gitroot" "$manifest" "$conflictlog" \
        "$lockpath" "$lww" "$provenance" "$adopt" "$dryrun"
}

# Auto-run only when executed directly (not when sourced by a test).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_bash4 || exit $?   # get_first_run_plan uses declare -A (bash 4+)
    main "$@"
    exit $?
fi
