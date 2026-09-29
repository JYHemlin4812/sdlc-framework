#!/usr/bin/env bash
# test-capture.sh — Self-contained assert-based self-check (ZERO framework) of capture.sh.
#
# Bash mirror of test-capture.ps1 (P012:A006). Creates ALL its fixtures in a single
# TEMP directory (fake git ref repo, fake live dir, machine-local base
# outside the worktree). NEVER operates on the real repo nor ~/.claude. Cleans up via trap.
# Exit != 0 on the first failure.
#
# Covers each Code Lock criterion:
#   (C1) modified-both without --lww -> exit 3 + diff + NOTHING written.
#   (C2) source: commit scoped to claude/ via pathspec, no 'git add -A'.
#   (C2b) real commit scope (S1 out-of-domain/third-party, S2 pre-staged outside claude, S3 deleted-ref skip).
#   (C3) manifest + conflicts.log OUTSIDE the worktree, atomically.
#   (C4) porcelain post-check: worktree dirty after commit -> exit 7, base NOT rewritten.
#   (C5a) added-live captured; (C5b) deleted-live blocked.
#   (C6a) --dry-run 0 writes; (C6b) --dry-run reflects the would-block (exit 3).
#   (D1) first-run seed/block/adopt; (D2) fail-closed on corruption; (D3) modified-live success; (D4) --lww logged+backup.

# No `set -e`: capture.sh legitimately exits != 0 on blocks; the
# harness captures each code. set -u/pipefail for rigor.
set -uo pipefail

pass=0
fail=0
declare -a failures=()
_pass() { pass=$((pass+1)); printf '  [PASS] %s\n' "$1"; }
_fail() { fail=$((fail+1)); failures+=("$1"); printf '  [FAIL] %s\n' "$1"; }

# at <name> <cmd...>: PASS if the command exits 0
at() { local n="$1"; shift; if "$@"; then _pass "$n"; else _fail "$n"; fi; }
# af <name> <cmd...>: PASS if the command exits != 0
af() { local n="$1"; shift; if "$@"; then _fail "$n"; else _pass "$n"; fi; }
# ae <name> <expected> <actual>: PASS if equal
ae() {
    local n="$1" exp="$2" act="$3"
    if [[ "$exp" == "$act" ]]; then _pass "$n"
    else printf '         expected=[%s] got=[%s]\n' "$exp" "$act"; _fail "$n"; fi
}

# --- Locate the scripts -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CAPTURE_PATH="$BASE_DIR/capture.sh"
LIB_PATH="$BASE_DIR/sync-lib.sh"
for p in "$CAPTURE_PATH" "$LIB_PATH"; do
    [[ -f "$p" ]] || { printf 'not found: %s\n' "$p" >&2; exit 2; }
done
# shellcheck source=/dev/null
. "$LIB_PATH"   # helpers for base seed / hashing

# --- Isolated temporary working directory -----------------------------------
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/capture-test-XXXXXX")"
cleanup() { [[ -n "${ROOT:-}" && -d "$ROOT" ]] && rm -rf "$ROOT"; }
trap cleanup EXIT

new_text() {  # new_text <path> <literal-text>
    local d; d=$(dirname "$1"); [[ -d "$d" ]] || mkdir -p "$d"
    printf '%s' "$2" > "$1"
}

# Common contents (ref==live): two domain relPaths.
COMMON_ALPHA=$'alpha-v1\n'
COMMON_BETA=$'beta-v1\n'

# new_case <name>: creates a git repo (ref under <repo>/claude) + live, identical common
# files, seed commit. State (base/lock/logs) under <case>/state OUTSIDE the worktree.
# Publishes: C_DIR C_REPO C_REF C_LIVE C_MANIFEST C_CONFLICT C_LOCK
new_case() {
    local name="$1"
    C_DIR="$ROOT/$name"
    C_REPO="$C_DIR/repo"
    C_REF="$C_REPO/claude"
    C_LIVE="$C_DIR/live"
    local state="$C_DIR/state"
    C_MANIFEST="$state/.sync-manifest.json"
    C_CONFLICT="$state/conflicts.log"
    C_LOCK="$state/.sync.lock"
    mkdir -p "$C_REF" "$C_LIVE" "$state"

    new_text "$C_REF/agents/sdlc-alpha.md"       "$COMMON_ALPHA"
    new_text "$C_REF/commands/sdlc/beta.md"      "$COMMON_BETA"
    new_text "$C_LIVE/agents/sdlc-alpha.md"      "$COMMON_ALPHA"
    new_text "$C_LIVE/commands/sdlc/beta.md"     "$COMMON_BETA"

    git -C "$C_REPO" init -q
    git -C "$C_REPO" config user.email 't@t'
    git -C "$C_REPO" config user.name 'test'
    git -C "$C_REPO" config commit.gpgsign false
    git -C "$C_REPO" add -- claude >/dev/null 2>&1
    git -C "$C_REPO" commit -q -m 'seed ref' >/dev/null 2>&1
}

# explicit base seed = current hashes of the ref domain (reuses the lib).
seed_base() {  # seed_base <ref> <manifest>
    {
        local rel
        while IFS= read -r rel; do
            [[ -n "$rel" ]] || continue
            printf '%s\t%s\n' "$rel" "$(get_file_hash_byteexact "$1/$rel")"
        done < <(get_domain_relpaths "$1")
    } | write_sync_manifest --path "$2" >/dev/null
}

commit_count() { git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }
hash_safe()    { [[ -f "$1" ]] && get_file_hash_byteexact "$1" || echo ''; }

# run_capture <args...>: runs capture.sh as a subprocess; publishes CAP_OUT CAP_RC
run_capture() { CAP_OUT=$(bash "$CAPTURE_PATH" "$@" 2>&1); CAP_RC=$?; }

# standard args for a case
cargs() { printf '%s' "--ref $C_REF --live $C_LIVE --git-root $C_REPO --manifest $C_MANIFEST --conflict-log $C_CONFLICT --lock $C_LOCK"; }

printf '\n=== test-capture.sh: self-check P012:A006 (bash mirror) ===\n'

# =======================================================================
# (C2) Source scan: exclusive pathspec, no 'git add -A'
# =======================================================================
printf -- '-- (C2) commit scoped to claude/ (no -A) --\n'
# global stage forbidden: 'git add' followed by -A / --all / -u / '.' (never the whole worktree).
# NB: must NOT match 'local -A' (array declaration) — hence the anchor on 'add'.
af "C2. no global 'git add' (-A/--all/-u/.)"      grep -qE 'add[[:space:]]+(-A|--all|-u|\.)([[:space:]]|$)' "$CAPTURE_PATH"
at "C2. 'git add' uses a pathspec ('--')"         grep -qF 'add -- "${pathspecs[@]}"' "$CAPTURE_PATH"
at "C2. 'git commit' carries a pathspec ('--')"   grep -qF 'commit -m "$msg" -- "${pathspecs[@]}"' "$CAPTURE_PATH"

# =======================================================================
# (C2b) REAL commit scope: only greenlisted rels are committed.
# =======================================================================
printf -- '-- (C2b) real commit scope (S1/S2/S3) --\n'
new_case c2scope
seed_base "$C_REF" "$C_MANIFEST"
# S1: files OUTSIDE the sdlc domain in claude/ (WIP secret + third-party skill), uncommitted
new_text "$C_REF/settings.local.json"          '{"secret":"WIP"}'
new_text "$C_REF/skills/other-tool/SKILL.md"   $'tiers\n'
# S3: ref-side deletion of a domain file -> deleted-ref -> skip
rm -f "$C_REF/agents/sdlc-alpha.md"
# S2: file OUTSIDE claude/ pre-staged before capture
new_text "$C_REPO/README.md"                   $'readme\n'
git -C "$C_REPO" add -- README.md >/dev/null 2>&1
# modified-live on beta -> greenlisted, triggers the commit
new_text "$C_LIVE/commands/sdlc/beta.md"     $'beta-scope\n'
run_capture $(cargs)
ae "C2b. capture OK (post-check scoped to the copied rels)" 0 "$CAP_RC"
HEAD_FILES=$(git -C "$C_REPO" show --pretty=format: --name-only HEAD)
at "C2b. HEAD commits the greenlisted rel (beta)"      grep -qF 'commands/sdlc/beta.md' <<< "$HEAD_FILES"
af "C2b. S1: out-of-domain secret NOT committed"       grep -qF 'settings.local.json'    <<< "$HEAD_FILES"
af "C2b. S1: third-party skill NOT committed"          grep -qF 'other-tool'             <<< "$HEAD_FILES"
af "C2b. S2: pre-staged file outside claude/ NOT committed" grep -qF 'README.md'         <<< "$HEAD_FILES"
af "C2b. S3: skipped deletion NOT committed"           grep -qF 'sdlc-alpha.md'        <<< "$HEAD_FILES"
TREE=$(git -C "$C_REPO" ls-tree -r --name-only HEAD)
at "C2b. S3: the tip keeps sdlc-alpha.md (not deleted)" grep -qF 'claude/agents/sdlc-alpha.md' <<< "$TREE"
af "C2b. S2: README.md absent from the tip (never committed)" grep -qF 'README.md'       <<< "$TREE"

# =======================================================================
# (C1) modified-both without --lww -> exit 3 + diff + NOTHING written
# =======================================================================
printf -- '-- (C1) modified-both blocked --\n'
new_case c1
seed_base "$C_REF" "$C_MANIFEST"
new_text "$C_REF/agents/sdlc-alpha.md"  $'alpha-REF\n'
new_text "$C_LIVE/agents/sdlc-alpha.md" $'alpha-LIVE\n'
REF_BEFORE=$(hash_safe "$C_REF/agents/sdlc-alpha.md")
MAN_BEFORE=$(hash_safe "$C_MANIFEST")
COMMITS_BEFORE=$(commit_count "$C_REPO")
run_capture $(cargs)
ae "C1. exit 3 on modified-both"                     3 "$CAP_RC"
at "C1. modified-both state visible"                 grep -qF 'modified-both' <<< "$CAP_OUT"
ae "C1. ref file NOT overwritten by live"            "$REF_BEFORE"    "$(hash_safe "$C_REF/agents/sdlc-alpha.md")"
ae "C1. manifest NOT rewritten"                      "$MAN_BEFORE"    "$(hash_safe "$C_MANIFEST")"
ae "C1. no new commit"                               "$COMMITS_BEFORE" "$(commit_count "$C_REPO")"
af "C1. conflicts.log NOT created (no --lww)"        test -f "$C_CONFLICT"

# =======================================================================
# (C3) manifest + conflicts.log OUTSIDE the worktree, atomically + (D3) success
# =======================================================================
printf -- '-- (C3)+(D3) state outside the worktree + modified-live success --\n'
new_case c3
REPO_FULL=$(realpath "$C_REPO")
case "$(realpath -m "$C_MANIFEST")/" in "$REPO_FULL"/*) _fail "C3. ManifestPath outside the git worktree" ;; *) _pass "C3. ManifestPath outside the git worktree" ;; esac
case "$(realpath -m "$C_CONFLICT")/" in "$REPO_FULL"/*) _fail "C3. ConflictLogPath outside the git worktree" ;; *) _pass "C3. ConflictLogPath outside the git worktree" ;; esac
seed_base "$C_REF" "$C_MANIFEST"
new_text "$C_LIVE/commands/sdlc/beta.md" $'beta-v2\n'   # modified-live
run_capture $(cargs)
ae "C3. nominal capture OK (modified-live)"          0 "$CAP_RC"
at "C3. manifest written outside the worktree"       test -f "$C_MANIFEST"
IN_REPO_MAN=$(find "$C_REPO" -name '.sync-manifest.json' | grep -c . || true)
ae "C3. no manifest in the git worktree"             0 "$IN_REPO_MAN"
TMP_LEFT=$(find "$(dirname "$C_MANIFEST")" \( -name '*.tmp-*' -o -name '*.bak-*' \) | grep -c . || true)
ae "C3. atomic write: no leftover temp/bak"          0 "$TMP_LEFT"
# (D3) success: ref==live, clean worktree, base rewritten with the new hash
ae "D3. ref == live after capture" \
    "$(get_file_hash_byteexact "$C_LIVE/commands/sdlc/beta.md")" \
    "$(get_file_hash_byteexact "$C_REF/commands/sdlc/beta.md")"
PORC=$(git -C "$C_REPO" status --porcelain -- claude)
at "D3. post-check: claude/ worktree clean"          test -z "${PORC//[$' \t\r\n']/}"
D3_BASE=$(read_sync_manifest "$C_MANIFEST" | tail -n +2 | awk -F'\t' '$1=="commands/sdlc/beta.md"{print $2}')
ae "D3. base rewritten with the new hash" \
    "$(get_file_hash_byteexact "$C_REF/commands/sdlc/beta.md")" "$D3_BASE"

# =======================================================================
# (C4) porcelain post-check: worktree dirty after commit -> exit 7, base NOT rewritten
# =======================================================================
printf -- '-- (C4) post-check partial failure --\n'
new_case c4
seed_base "$C_REF" "$C_MANIFEST"
MAN4_BEFORE=$(hash_safe "$C_MANIFEST")
HOOK="$C_REPO/.git/hooks/post-commit"
new_text "$HOOK" $'#!/bin/sh\necho dirty >> claude/commands/sdlc/beta.md\n'
chmod +x "$HOOK"
new_text "$C_LIVE/commands/sdlc/beta.md" $'beta-capture\n'   # modified-live -> triggers the commit
run_capture $(cargs)
ae "C4. exit 7 when the worktree is dirty after commit" 7 "$CAP_RC"
at "C4. post-check failure reported"                 grep -qF 'POST-CHECK' <<< "$CAP_OUT"
ae "C4. base NOT rewritten on partial failure"       "$MAN4_BEFORE" "$(hash_safe "$C_MANIFEST")"

# =======================================================================
# (C5a) added-live -> captured
# =======================================================================
printf -- '-- (C5a) added-live captured --\n'
new_case c5a
seed_base "$C_REF" "$C_MANIFEST"
new_text "$C_LIVE/agents/sdlc-new.md" $'brand-new\n'   # live-only, missing from the base
C5_BEFORE=$(commit_count "$C_REPO")
run_capture $(cargs)
ae "C5a. exit 0 (added-live captured)"               0 "$CAP_RC"
at "C5a. new file present in ref"                    test -f "$C_REF/agents/sdlc-new.md"
ae "C5a. one new commit created"                     $((C5_BEFORE + 1)) "$(commit_count "$C_REPO")"
SHOW5=$(git -C "$C_REPO" show --name-only HEAD)
at "C5a. added file present in the HEAD commit"      grep -qF 'sdlc-new.md' <<< "$SHOW5"
C5_ENTRY=$(read_sync_manifest "$C_MANIFEST" | tail -n +2 | awk -F'\t' '$1=="agents/sdlc-new.md"{print $2}')
at "C5a. base includes the new relPath"              test -n "$C5_ENTRY"

# =======================================================================
# (C5b) deleted-live -> blocked
# =======================================================================
printf -- '-- (C5b) deleted-live blocked --\n'
new_case c5b
seed_base "$C_REF" "$C_MANIFEST"
rm -f "$C_LIVE/agents/sdlc-alpha.md"   # live missing, ref==base
C5B_BEFORE=$(commit_count "$C_REPO")
MAN5B_BEFORE=$(hash_safe "$C_MANIFEST")
run_capture $(cargs)
af "C5b. exit != 0 (deleted-live blocked)"           test "$CAP_RC" -eq 0
at "C5b. ref file NOT deleted"                       test -f "$C_REF/agents/sdlc-alpha.md"
ae "C5b. no commit"                                  "$C5B_BEFORE" "$(commit_count "$C_REPO")"
ae "C5b. base NOT rewritten"                         "$MAN5B_BEFORE" "$(hash_safe "$C_MANIFEST")"

# =======================================================================
# (C6a) --dry-run: 0 commit, 0 ref file, 0 manifest
# =======================================================================
printf -- '-- (C6a) dry-run 0 writes --\n'
new_case c6
seed_base "$C_REF" "$C_MANIFEST"
new_text "$C_LIVE/agents/sdlc-new.md"    $'would-add\n'      # added-live pending
new_text "$C_LIVE/commands/sdlc/beta.md" $'would-modify\n'   # modified-live pending
MAN6_BEFORE=$(hash_safe "$C_MANIFEST")
C6_BEFORE=$(commit_count "$C_REPO")
run_capture $(cargs) --dry-run
ae "C6a. dry-run without block -> exit 0"            0 "$CAP_RC"
ae "C6a. dry-run: 0 commit created"                  "$C6_BEFORE" "$(commit_count "$C_REPO")"
af "C6a. dry-run: 0 ref file created"                test -f "$C_REF/agents/sdlc-new.md"
ae "C6a. dry-run: manifest unchanged"                "$MAN6_BEFORE" "$(hash_safe "$C_MANIFEST")"

# =======================================================================
# (C6b) --dry-run reflects the would-block (modified-both) -> exit 3
# =======================================================================
printf -- '-- (C6b) dry-run would-block --\n'
new_case c6b
seed_base "$C_REF" "$C_MANIFEST"
new_text "$C_REF/agents/sdlc-alpha.md"  $'alpha-REF\n'
new_text "$C_LIVE/agents/sdlc-alpha.md" $'alpha-LIVE\n'
MAN6B_BEFORE=$(hash_safe "$C_MANIFEST")
run_capture $(cargs) --dry-run
ae "C6b. dry-run reflects the would-block (exit 3)"  3 "$CAP_RC"
ae "C6b. dry-run would-block: nothing written"       "$MAN6B_BEFORE" "$(hash_safe "$C_MANIFEST")"
af "C6b. dry-run: conflicts.log not created"         test -f "$C_CONFLICT"

# =======================================================================
# (D1) first-run: seed (equal), block (asymmetry), adopt
# =======================================================================
printf -- '-- (D1) first-run H5 --\n'
new_case d1seed   # ref==live, no base
run_capture $(cargs)
ae "D1. first-run seed (ref==live) -> exit 0"        0 "$CAP_RC"
at "D1. first-run seed writes the base"              test -f "$C_MANIFEST"
new_case d1block  # asymmetry (live-only), no base
new_text "$C_LIVE/agents/sdlc-extra.md" $'extra\n'
run_capture $(cargs)
ae "D1. first-run asymmetry -> BLOCKED (exit 5)"     5 "$CAP_RC"
af "D1. first-run block: base NOT written"           test -f "$C_MANIFEST"
run_capture $(cargs) --adopt   # same asymmetry, --adopt -> forced seed
ae "D1. first-run --adopt -> forced seed (exit 0)"   0 "$CAP_RC"
at "D1. --adopt writes the base"                     test -f "$C_MANIFEST"

# =======================================================================
# (D2) corrupt manifest -> FAIL CLOSED (exit 6)
# =======================================================================
printf -- '-- (D2) fail-closed on corrupt manifest --\n'
new_case d2
new_text "$C_MANIFEST" '{ this is : not json'
new_text "$C_LIVE/commands/sdlc/beta.md" $'beta-v2\n'   # modified-live
D2_BEFORE=$(commit_count "$C_REPO")
run_capture $(cargs)
ae "D2. corrupt manifest -> exit 6 (fail closed)"    6 "$CAP_RC"
at "D2. fail-closed reported"                        grep -qF 'FAIL CLOSED' <<< "$CAP_OUT"
ae "D2. fail-closed: no commit"                      "$D2_BEFORE" "$(commit_count "$C_REPO")"

# =======================================================================
# (D4) --lww: logged (conflicts.log outside the worktree) + backup of the losing ref
# =======================================================================
printf -- '-- (D4) --lww logged+backup --\n'
new_case d4
seed_base "$C_REF" "$C_MANIFEST"
new_text "$C_REF/agents/sdlc-alpha.md"  $'alpha-REF\n'
new_text "$C_LIVE/agents/sdlc-alpha.md" $'alpha-LIVE\n'
D4_BEFORE=$(commit_count "$C_REPO")
run_capture $(cargs) --lww --provenance live
ae "D4. --lww resolves the conflict (exit 0)"        0 "$CAP_RC"
at "D4. conflicts.log written (logged)"              test -f "$C_CONFLICT"
IN_REPO_LOG=$(find "$C_REPO" -name 'conflicts.log' | grep -c . || true)
ae "D4. conflicts.log OUTSIDE the git worktree"      0 "$IN_REPO_LOG"
ae "D4. winner=live: ref adopts the live content"    "$(printf 'alpha-LIVE\n')" "$(cat "$C_REF/agents/sdlc-alpha.md")"
ae "D4. --lww winner=live: commit created"           $((D4_BEFORE + 1)) "$(commit_count "$C_REPO")"
BAKS=$(find "$(dirname "$C_CONFLICT")/_backups" -type f -name 'sdlc-alpha.md' 2>/dev/null || true)
BAK_COUNT=$(printf '%s' "$BAKS" | grep -c . || true)
ae "D4. timestamped backup of the losing ref created" 1 "$BAK_COUNT"
if [[ "$BAK_COUNT" == "1" ]]; then
    ae "D4. backup holds the overwritten ref change" "$(printf 'alpha-REF\n')" "$(cat "$BAKS")"
    case "$(realpath -m "$BAKS")/" in "$(realpath "$C_REPO")"/*) _fail "D4. backup OUTSIDE the git worktree" ;; *) _pass "D4. backup OUTSIDE the git worktree" ;; esac
fi

# --- Report -----------------------------------------------------------------
printf '\n=== Result: %d PASS / %d FAIL ===\n' "$pass" "$fail"
if [[ $fail -gt 0 ]]; then
    printf 'Failures:\n'
    for f in "${failures[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
printf 'OK: capture.sh compliant (P012:A006).\n'
exit 0
