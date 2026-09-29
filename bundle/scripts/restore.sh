#!/usr/bin/env bash
# restore.sh — deploys the canonical REF (git) to the LIVE install (P013:A009).
#
# BASH port of restore.ps1 with identical behavior (restore.ps1 is the shipped/tested
# reference, P018:A014). Reproduces its blocks, exit codes, byte-exact SHA256 hashes,
# safeguards and, in substance, its messages.
#
# Direction: REF = source of truth = repo sdlc-framework/claude/ at git HEAD.
# LIVE = the ~/.claude/ install. restore takes the committed REF and makes LIVE
# match it, with safeguards against data loss.
#
# Behavior (single source = sync-lib.sh):
#   - Requires git (ff-only + dependent verify post-check). Missing -> exit 2.
#   - Acquires an O_EXCL lock (mkdir) around every mutation (released on exit).
#   - UNDER the lock: `git merge --ff-only @{u}` if an upstream is configured
#     (fast-forward ONLY; non-ff divergence -> abort exit 4; no upstream ->
#     skip; NEVER run in --dry-run so that it stays 100% read-only).
#   - CANONICAL GUARD: the REF working tree (claude/) must be clean (== HEAD),
#     otherwise abort (exit 5) BEFORE any write.
#   - Loads the base (read_sync_manifest). Corrupt -> FAIL CLOSED (exit 6).
#     Missing -> empty base (first-run / bootstrap).
#   - Classifies each relPath of the UNION of the domains (get_sync_state, base-aware):
#       modified-ref / added-ref / deleted-live   -> RESTORE (copy ref->live)
#       deleted-ref (live==base)                  -> DELETE live (base-aware H6)
#       modified-live                             -> BLOCKED, unless --force-restore
#       modified-both / conflict-*                -> BLOCKED (always)
#       added-live                                -> PROTECTED (never touched, H6)
#       identical / absent-both                   -> skip
#   - >=1 block: exit 3, WRITES NOTHING, shows the diffs.
#   - Deployment: temp STAGING -> timestamped BACKUP -> atomic SWAP -> base-aware DELETE.
#     Never a destructive in-place copy; never a bulk mirror (global recursive
#     copy / mirror deletion): per-relPath greenlist only.
#   - POST-CHECK: runs verify.sh as a SUBPROCESS (read-only isolation);
#     0 drift required, otherwise exit 7.
#   - --dry-run: 0 writes (staging/backup/live).
#
# Usage:
#   restore.sh [--ref-root <dir>] [--live-root <dir>] [--git-root <dir>]
#              [--manifest-path <f>] [--lock-path <f>] [--backup-root <dir>]
#              [--force-restore] [--dry-run]

# ponytail: no `set -e` at file scope — this script is SOURCED by the tests,
# and many commands have an EXPECTED failure (git status/rev-parse, hash of a
# missing file, verify != 0, mkdir of the lock). Defensive coding per function, like
# sync-lib.sh (mirror of the per-function Set-StrictMode of the .ps1).

_restore_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_restore_dir/sync-lib.sh"

# --- Path/hash helpers (mirror of restore.ps1) ------------------------------

get_restore_fullpath() {
    # "$root/$rel" (rel normalized to '/'). No native conversion: bash handles '/'.
    printf '%s' "$1/$2"
}

get_restore_hash_or_null() {
    # Byte-exact sha256 if the file exists, otherwise an empty string (= missing).
    local full="$1/$2"
    if [[ -f "$full" ]]; then get_file_hash_byteexact "$full"; fi
}

update_ref_fastforward() {
    # `git merge --ff-only @{u}`. Emits 'skip' (no upstream), 'ok' (up to date /
    # fast-forward applied) or 'diverged' (non-ff). Does NOT fetch.
    local git_root="$1"
    if ! git -C "$git_root" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        printf 'skip'; return 0
    fi
    if ! git -C "$git_root" merge --ff-only '@{u}' >/dev/null 2>&1; then
        printf 'diverged'; return 0
    fi
    printf 'ok'; return 0
}

invoke_verify_postcheck() {
    # POST-CHECK A009: runs verify.sh as a SUBPROCESS (read-only isolation).
    # Returns verify's exit code (0 = 0 drift). Missing script -> 2.
    local repo_root="$1" live_target="$2"
    local verify_script="$_restore_dir/verify.sh"
    [[ -f "$verify_script" ]] || return 2
    bash "$verify_script" --ref-root "$repo_root" --live-root "$live_target" --quiet >/dev/null 2>&1
    return $?
}

# --- Core --------------------------------------------------------------------

invoke_restore() {
    local ref_root="" live_root="" git_root="" manifest_path="" lock_path="" backup_root=""
    local force_restore=0 dry_run=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ref-root)      ref_root="$2"; shift 2 ;;
            --live-root)     live_root="$2"; shift 2 ;;
            --git-root)      git_root="$2"; shift 2 ;;
            --manifest-path) manifest_path="$2"; shift 2 ;;
            --lock-path)     lock_path="$2"; shift 2 ;;
            --backup-root)   backup_root="$2"; shift 2 ;;
            --force-restore) force_restore=1; shift ;;
            --dry-run)       dry_run=1; shift ;;
            *)               shift ;;
        esac
    done
    [[ -n "$ref_root" ]]  || ref_root="$_restore_dir/../../claude"
    [[ -n "$live_root" ]] || live_root="$HOME/.claude"

    # --- Path resolution (Resolve-Path: fails if not found -> 2) ---
    # The existence check BEFORE realpath reproduces Resolve-Path (fails on a
    # missing path) portably: `realpath` (without -e) does not fail on a
    # missing leaf, unlike Resolve-Path.
    local resolved
    if [[ ! -e "$ref_root" ]]; then printf 'restore: RefRoot not found: %s\n' "$ref_root"; return 2; fi
    resolved=$(realpath "$ref_root" 2>/dev/null) || { printf 'restore: RefRoot not found: %s\n' "$ref_root"; return 2; }
    ref_root="$resolved"
    if [[ ! -e "$live_root" ]]; then printf 'restore: LiveRoot not found: %s\n' "$live_root"; return 2; fi
    resolved=$(realpath "$live_root" 2>/dev/null) || { printf 'restore: LiveRoot not found: %s\n' "$live_root"; return 2; }
    live_root="$resolved"

    [[ -n "$git_root" ]]      || git_root="$(dirname "$ref_root")"
    [[ -n "$manifest_path" ]] || manifest_path="$live_root/.sync-manifest.json"
    [[ -n "$lock_path" ]]     || lock_path="$live_root/.sync.lock"
    [[ -n "$backup_root" ]]   || backup_root="$live_root/_backups"

    local mode=""
    [[ $dry_run -eq 1 ]] && mode="[dry-run] "
    printf 'restore %s: ref=%s  live=%s\n' "$mode" "$ref_root" "$live_root"

    # git is required: ff-only + dependent verify post-check.
    if ! command -v git >/dev/null 2>&1; then
        printf 'restore: git not found — required (ff-only + verify post-check). Nothing written.\n'
        return 2
    fi

    # --- Exclusive lock around the analysis AND the mutation ---
    local lock
    if ! lock=$(acquire_sync_lock "$lock_path"); then
        printf 'restore: sync lock already held — abort. Nothing written.\n'
        return 1
    fi

    # _staging: set by _restore_locked (dynamic scope), cleaned up here.
    local _staging=""
    local rc=0
    _restore_locked "$ref_root" "$live_root" "$git_root" "$manifest_path" "$backup_root" "$force_restore" "$dry_run" || rc=$?

    [[ -n "$_staging" && -d "$_staging" ]] && rm -rf "$_staging"
    release_sync_lock "$lock"
    return $rc
}

_restore_locked() {
    # Body under the lock. Writes '_staging' (visible from the parent invoke_restore
    # through dynamic scope) for cleanup. Emits codes 3/4/5/6/7/0.
    local ref_root="$1" live_root="$2" git_root="$3" manifest_path="$4" backup_root="$5"
    local force_restore="$6" dry_run="$7"
    # P022:A019: GLOBAL USER file, OUTSIDE the sync domain (never in the
    # get_domain_relpaths greenlist). The import is added at the end of a nominal run.
    local claudeMdTarget="$live_root/CLAUDE.md"

    # --- `git --ff-only` (under the lock; NEVER in dry-run) ---
    if [[ $dry_run -eq 0 ]]; then
        local ff
        ff=$(update_ref_fastforward "$git_root")
        if [[ "$ff" == "diverged" ]]; then
            printf 'restore: ref diverged from upstream (not fast-forward) — abort. Nothing written.\n'
            printf '        Reconcile the ref (rebase/merge) before restoring.\n'
            return 4
        fi
    fi

    # --- CANONICAL GUARD: REF working tree (claude/) clean (== HEAD) ---
    local porc porc_code=0
    porc=$(git -C "$git_root" status --porcelain -- claude 2>&1) || porc_code=$?
    if [[ $porc_code -ne 0 ]] || [[ -n "${porc//[[:space:]]/}" ]]; then
        printf 'restore: REF tree (claude/) not clean — commit/reconcile the ref before restoring. Nothing written.\n'
        [[ -n "$porc" ]] && printf '%s\n' "$porc"
        return 5
    fi

    # --- UNION of the domain relPaths (ref u live) ---
    local union
    union=$(
        { get_domain_relpaths "$ref_root"; get_domain_relpaths "$live_root"; } \
            | grep -v '^$' | LC_ALL=C sort -u
    )

    # --- Load the base (3rd state) ---
    # tr -d '\r': on Windows, python (read_sync_manifest) emits its lines as
    # \r\n (text stdout); normalize to LF so that hash comparisons
    # (base vs live) and the fail-closed flag are exact. No loss: a hex sha256
    # / relPath never contains \r.
    local mret first ok exists failclosed
    mret=$(read_sync_manifest "$manifest_path" | tr -d '\r')
    first=$(printf '%s\n' "$mret" | head -n1)
    IFS=$'\t' read -r ok exists failclosed <<< "$first"
    if [[ "$failclosed" == "1" ]]; then
        printf 'restore: unreadable/corrupt manifest -> FAIL CLOSED (no action).\n'
        printf '        No restore is attempted on an untrusted base.\n'
        return 6
    fi
    local -A base
    local k v
    while IFS=$'\t' read -r k v; do
        [[ -n "$k" ]] && base["$k"]="$v"
    done < <(printf '%s\n' "$mret" | tail -n +2)

    # --- Base-aware classification ---
    local -a restore_rels=() delete_rels=() block_rels=() block_states=()
    local rel refh liveh baseh st
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        refh=$(get_restore_hash_or_null "$ref_root" "$rel")
        liveh=$(get_restore_hash_or_null "$live_root" "$rel")
        baseh="${base[$rel]-}"
        st=$(get_sync_state "$refh" "$liveh" "$baseh")
        case "$st" in
            modified-ref|added-ref|deleted-live)
                restore_rels+=("$rel") ;;
            modified-live)
                if [[ $force_restore -eq 1 ]]; then restore_rels+=("$rel")
                else block_rels+=("$rel"); block_states+=("modified-live-only"); fi ;;
            deleted-ref)
                delete_rels+=("$rel") ;;               # base-aware (H6)
            identical|added-live|absent-both)
                : ;;                                    # skip / PROTECTED
            modified-both)
                block_rels+=("$rel"); block_states+=("$st") ;;
            *)
                # conflict-deleted-live-modified-ref / conflict-deleted-ref-modified-live
                block_rels+=("$rel"); block_states+=("$st") ;;
        esac
    done <<< "$union"

    # --- HARD BLOCKS: exit 3, NOTHING written (even in dry-run) ---
    if [[ ${#block_rels[@]} -gt 0 ]]; then
        printf 'restore: BLOCKED — %d unresolved conflict(s). Nothing written.\n' "${#block_rels[@]}"
        local i rp lp
        for i in "${!block_rels[@]}"; do
            printf '  [BLOCK] %s  (%s)\n' "${block_rels[$i]}" "${block_states[$i]}"
            rp="$ref_root/${block_rels[$i]}"
            lp="$live_root/${block_rels[$i]}"
            if [[ -f "$rp" && -f "$lp" ]]; then
                show_conflict_diff "$rp" "$lp"
            fi
        done
        printf "        'modified-live': --force-restore overwrites the live change with the canonical file.\n"
        return 3
    fi

    # --- DRY-RUN: no write, list what WOULD be done ---
    if [[ $dry_run -eq 1 ]]; then
        printf 'restore [dry-run]: %d restore(s), %d deletion(s) — nothing written.\n' \
            "${#restore_rels[@]}" "${#delete_rels[@]}"
        for rel in "${restore_rels[@]}"; do printf '  ~ %s\n' "$rel"; done
        for rel in "${delete_rels[@]}";  do printf '  - %s\n' "$rel"; done
        return 0
    fi

    # --- Deployment: STAGING -> BACKUP -> SWAP -> DELETE ---
    local -a staged=()
    if [[ ${#restore_rels[@]} -gt 0 ]]; then
        _staging=$(mktemp -d "${TMPDIR:-/tmp}/restore-stage-XXXXXXXX")
        # (1) STAGING: assemble the ref content outside live (atomic per file).
        while IFS= read -r rel; do
            [[ -n "$rel" ]] && staged+=("$rel")
        done < <(copy_tree "$ref_root" "$_staging" "${restore_rels[@]}")
    fi

    # (2) Timestamped BACKUP BEFORE any replacement/deletion of a live file.
    local backup_dir="$backup_root/restore-$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
    local backed_up=0 live_full bak
    for rel in "${staged[@]}" "${delete_rels[@]}"; do
        live_full="$live_root/$rel"
        if [[ -f "$live_full" ]]; then
            bak="$backup_dir/$rel"
            # CHECKED backup: if the write fails (disk full, read-only _backups),
            # abort BEFORE the destructive SWAP/DELETE — live stays intact and
            # recoverable. Parity with the abort-on-throw of restore.ps1.
            if ! write_file_atomic "$bak" < "$live_full" >/dev/null; then
                printf '  [BACKUP] backup write FAILED (%s) — aborting BEFORE swap/deletion. Live intact.\n' "$rel" >&2
                return 1
            fi
            backed_up=$((backed_up + 1))
        fi
    done
    [[ $backed_up -gt 0 ]] && printf '  [BACKUP] %d live file(s) backed up -> %s\n' "$backed_up" "$backup_dir"

    # (3) Atomic SWAP: staging -> live (temp+rename per file).
    local -a deployed=()
    if [[ ${#staged[@]} -gt 0 ]]; then
        while IFS= read -r rel; do
            [[ -n "$rel" ]] && deployed+=("$rel")
        done < <(copy_tree "$_staging" "$live_root" "${staged[@]}")
        printf 'restore: %d file(s) deployed ref->live.\n' "${#deployed[@]}"
    fi

    # (4) Base-aware DELETE: propagated canonical deletion (backup already taken).
    local deleted=0
    for rel in "${delete_rels[@]}"; do
        live_full="$live_root/$rel"
        if [[ -f "$live_full" ]]; then
            rm -f "$live_full"
            deleted=$((deleted + 1))
        fi
    done
    [[ $deleted -gt 0 ]] && printf 'restore: %d file(s) deleted (base-aware H6).\n' "$deleted"

    if [[ ${#deployed[@]} -eq 0 && $deleted -eq 0 ]]; then
        printf 'restore: nothing to restore (live already matches the greenlisted canonical tree).\n'
    fi

    # --- verify POST-CHECK (0 drift required) ---
    local verify_rc=0
    invoke_verify_postcheck "$git_root" "$live_root" || verify_rc=$?
    if [[ $verify_rc -ne 0 ]]; then
        if [[ $verify_rc -eq 2 ]]; then
            printf 'restore: POST-CHECK not run — verify unavailable (code 2). Deployed but NOT verified.\n'
        else
            printf 'restore: POST-CHECK verify found a difference (code %d) — live != ref HEAD.\n' "$verify_rc"
        fi
        printf '        Run verify again for details. The timestamped backups are recoverable.\n'
        return 7
    fi

    printf 'restore: OK — live matches the canonical REF (verify post-check 0 drift).\n'
    return 0
}

# --- Auto-run (script) — suppressed when sourced (tests) ---------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_bash4 || exit $?
    invoke_restore "$@"
    exit $?
fi
