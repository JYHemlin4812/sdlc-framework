#!/usr/bin/env bash
# test-restore.sh — self-contained assert-based self-check (ZERO framework) of restore.sh
# (P013:A009 / P018:A014). Exit != 0 on the first failure.
#
# Mirror of test-restore.ps1: creates ALL its fixtures in a single TEMP directory
# (fake committed git ref repo, fake live dir, machine-local base + backups OUTSIDE
# worktree/live). NEVER operates on the real repo nor on ~/.claude. Cleans up via trap.
#
# Covers each Code Lock criterion of P013:A009:
#   (C0) source invariants: per-relpath copy_tree, verify post-check, no mirror.
#   (C1) staging+swap: modified-ref/added-ref -> deployed, verify 0, exit 0.
#   (C2) base-aware deletion (H6): deleted-ref -> DELETE live + backup, verify 0.
#   (C3) modified-live-only BLOCKED without --force-restore; deployed with it.
#   (C4) modified-both BLOCKED even with --force-restore.
#   (C5) added-live PROTECTED (H6): never deleted.
#   (C6) --dry-run: 0 writes (live/backup), would-restore reflected.
#   (C7) atomic swap: no leftover temp/bak on the live side.
#   (C8) canonical guard: dirty REF worktree -> abort exit 5, no LIVE write.
#   (C9) dry-run does NOT advance the branch (ff-only skipped in dry-run).
#   (D1) fail-closed on a corrupt manifest (H4) -> exit != 0, no write.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)"
RESTORE_SH="$SCRIPTS_DIR/restore.sh"
VERIFY_SH="$SCRIPTS_DIR/verify.sh"
LIB_SH="$SCRIPTS_DIR/sync-lib.sh"
for p in "$RESTORE_SH" "$VERIFY_SH" "$LIB_SH"; do
    [[ -f "$p" ]] || { printf 'not found: %s\n' "$p" >&2; exit 2; }
done

# Source restore.sh (it sources sync-lib.sh itself; the BASH_SOURCE guard prevents
# the auto-run). Exposes invoke_restore + helpers + the whole lib.
. "$RESTORE_SH"

# --- Minimal assertion harness ---------------------------------------------
PASS=0; FAIL=0; FAILURES=()
pass() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); printf '  [FAIL] %s\n' "$1"; [[ -n "${2-}" ]] && printf '         %s\n' "$2"; }
assert_eq()          { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3" "expected=[$1] got=[$2]"; fi; }
assert_ne()          { if [[ "$1" != "$2" ]]; then pass "$3"; else fail "$3" "unexpected=[$1]"; fi; }
assert_contains()    { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3" "'$2' missing from the text"; fi; }
assert_not_contains(){ if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3" "'$2' present (forbidden)"; fi; }
assert_present()     { if [[ -e "$1" ]]; then pass "$2"; else fail "$2" "missing: $1"; fi; }
assert_absent()      { if [[ ! -e "$1" ]]; then pass "$2"; else fail "$2" "present: $1"; fi; }

# --- Isolated temporary working directory ----------------------------------
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/restore-test-XXXXXXXX")
cleanup() { cd / 2>/dev/null; rm -rf "$ROOT" 2>/dev/null; }
trap cleanup EXIT

new_text_file() {
    local p="$1" c="$2"
    mkdir -p "$(dirname "$p")"
    printf '%s\n' "$c" > "$p"
}

# Fixture: git repo (ref under <repo>/claude) + live, identical common files,
# committed (HEAD == ref working tree). Base/lock/backups under <case>/state (OUTSIDE
# the worktree and OUTSIDE live). Sets the CASE_* globals.
new_case() {
    local name="$1"; shift
    local c="$ROOT/$name"
    CASE_DIR="$c"
    CASE_REPO="$c/repo"
    CASE_REF="$c/repo/claude"
    CASE_LIVE="$c/live"
    local state="$c/state"
    CASE_MANIFEST="$state/.sync-manifest.json"
    CASE_LOCK="$state/.sync.lock"
    CASE_BACKUP="$state/_backups"
    mkdir -p "$CASE_REF" "$CASE_LIVE" "$state"
    local pair rel content
    for pair in "$@"; do
        rel="${pair%%=*}"; content="${pair#*=}"
        new_text_file "$CASE_REF/$rel" "$content"
        new_text_file "$CASE_LIVE/$rel" "$content"
    done
    git -C "$CASE_REPO" init -q
    git -C "$CASE_REPO" config user.email t@t
    git -C "$CASE_REPO" config user.name test
    git -C "$CASE_REPO" config commit.gpgsign false
    git -C "$CASE_REPO" add -- claude
    git -C "$CASE_REPO" commit -q -m 'seed ref'
}

# Commits the CURRENT state of the ref working tree (add -A to pick up changes/additions/deletions).
update_ref_commit() {
    git -C "$CASE_REPO" add -A -- claude >/dev/null 2>&1
    git -C "$CASE_REPO" commit -q -m "${1:-update ref}" >/dev/null 2>&1
}

# Seeds the base = current hashes of the ref domain (before any scenario mutation).
set_seed_base() {
    local tmp r
    tmp=$(mktemp)
    while IFS= read -r r; do
        [[ -n "$r" ]] || continue
        printf '%s\t%s\n' "$r" "$(get_file_hash_byteexact "$CASE_REF/$r")" >> "$tmp"
    done < <(get_domain_relpaths "$CASE_REF")
    write_sync_manifest --path "$CASE_MANIFEST" < "$tmp" >/dev/null
    rm -f "$tmp"
}

base_params() {
    printf '%s\0' --ref-root "$CASE_REF" --live-root "$CASE_LIVE" --git-root "$CASE_REPO" \
        --manifest-path "$CASE_MANIFEST" --lock-path "$CASE_LOCK" --backup-root "$CASE_BACKUP"
}

# Runs invoke_restore capturing (RC, TEXT). Args passed through as is.
run_restore() {
    local out
    out=$(invoke_restore "$@" 2>&1); RC=$?
    TEXT="$out"
}

backup_count() {
    local leaf="$1"
    [[ -d "$CASE_BACKUP" ]] || { printf '0'; return; }
    find "$CASE_BACKUP" -type f -name "$leaf" 2>/dev/null | wc -l | tr -d ' '
}
backup_first() {
    find "$CASE_BACKUP" -type f -name "$1" 2>/dev/null | head -n1
}

# COMMON: agents/sdlc-alpha.md=alpha-v1, commands/sdlc/beta.md=beta-v1
A='agents/sdlc-alpha.md'
B='commands/sdlc/beta.md'
COMMON=("$A=alpha-v1" "$B=beta-v1")

printf '\n=== test-restore: self-check P013:A009 (bash) ===\n'

# =======================================================================
# (C0) Source invariants: per-relpath copy_tree, verify post-check, no mirror
# =======================================================================
printf -- '-- (C0) source invariants --\n'
SRC=$(cat "$RESTORE_SH")
assert_not_contains "$SRC" "rsync"              "C0. no rsync (destructive mirror) in the source"
assert_not_contains "$SRC" "cp -r"              "C0. no cp -r (destructive mirror) in the source"
assert_contains     "$SRC" "copy_tree"          "C0. deployment via copy_tree (atomic per relpath)"
assert_contains     "$SRC" "invoke_verify_postcheck" "C0. verify post-check present"

# =======================================================================
# (C1) staging+swap: modified-ref + added-ref -> deployed, verify 0, exit 0
# =======================================================================
printf -- '-- (C1) nominal restore (modified-ref + added-ref) --\n'
new_case c1 "${COMMON[@]}"
set_seed_base
new_text_file "$CASE_REF/$B" "beta-v2"                          # modified-ref
new_text_file "$CASE_REF/agents/sdlc-gamma.md" "gamma-new"    # added-ref
update_ref_commit 'ref: modify beta + add gamma'
run_restore --ref-root "$CASE_REF" --live-root "$CASE_LIVE" --git-root "$CASE_REPO" \
    --manifest-path "$CASE_MANIFEST" --lock-path "$CASE_LOCK" --backup-root "$CASE_BACKUP"
assert_eq 0 "$RC" "C1. exit 0 (deployed + verify post-check 0 drift)"
assert_eq "beta-v2" "$(cat "$CASE_LIVE/$B")" "C1. modified-ref: live receives the canonical file (beta-v2)"
assert_present "$CASE_LIVE/agents/sdlc-gamma.md" "C1. added-ref: new file deployed to live"
assert_eq "alpha-v1" "$(cat "$CASE_LIVE/$A")" "C1. identical: alpha unchanged"
assert_eq 1 "$(backup_count 'beta.md')" "C1. backup of the old live beta created"
assert_eq "beta-v1" "$(cat "$(backup_first 'beta.md')")" "C1. backup holds the old live content (recoverable)"

# =======================================================================
# (C2) base-aware deletion (H6): deleted-ref -> DELETE live + backup
# =======================================================================
printf -- '-- (C2) base-aware deletion (H6) --\n'
new_case c2 "${COMMON[@]}"
set_seed_base
rm -f "$CASE_REF/$A"                                # ref deletes alpha; live==base
update_ref_commit 'ref: delete alpha'
assert_present "$CASE_LIVE/$A" "C2. (pre) alpha present on the live side"
run_restore --ref-root "$CASE_REF" --live-root "$CASE_LIVE" --git-root "$CASE_REPO" \
    --manifest-path "$CASE_MANIFEST" --lock-path "$CASE_LOCK" --backup-root "$CASE_BACKUP"
assert_eq 0 "$RC" "C2. exit 0 (deletion propagated + verify 0)"
assert_absent "$CASE_LIVE/$A" "C2. base-aware: alpha deleted on the live side"
assert_eq 1 "$(backup_count 'sdlc-alpha.md')" "C2. backup of alpha before deletion (recoverable)"
assert_eq "alpha-v1" "$(cat "$(backup_first 'sdlc-alpha.md')")" "C2. backup holds the deleted alpha"

# =======================================================================
# (C3) modified-live-only: BLOCKED without --force-restore; deployed with it
# =======================================================================
printf -- '-- (C3) modified-live-only (block / force) --\n'
new_case c3 "${COMMON[@]}"
set_seed_base
new_text_file "$CASE_LIVE/$B" "beta-LOCAL"          # live modified, ref==base
# (a) without force -> block, live intact, no backup
run_restore --ref-root "$CASE_REF" --live-root "$CASE_LIVE" --git-root "$CASE_REPO" \
    --manifest-path "$CASE_MANIFEST" --lock-path "$CASE_LOCK" --backup-root "$CASE_BACKUP"
assert_eq 3 "$RC" "C3a. exit 3 (modified-live blocked without --force-restore)"
assert_contains "$TEXT" "modified-live-only" "C3a. modified-live-only state reported"
assert_eq "beta-LOCAL" "$(cat "$CASE_LIVE/$B")" "C3a. live NOT overwritten (blocked)"
assert_absent "$CASE_BACKUP" "C3a. no backup created (nothing written)"
# (b) with --force-restore -> deploys the canonical file, backs up the losing live, verify 0
run_restore --ref-root "$CASE_REF" --live-root "$CASE_LIVE" --git-root "$CASE_REPO" \
    --manifest-path "$CASE_MANIFEST" --lock-path "$CASE_LOCK" --backup-root "$CASE_BACKUP" --force-restore
assert_eq 0 "$RC" "C3b. exit 0 (--force-restore deploys the canonical file)"
assert_eq "beta-v1" "$(cat "$CASE_LIVE/$B")" "C3b. live overwritten by the canonical file (beta-v1)"
assert_eq 1 "$(backup_count 'beta.md')" "C3b. backup of the losing live change"
assert_eq "beta-LOCAL" "$(cat "$(backup_first 'beta.md')")" "C3b. backup holds the overwritten live change (recoverable)"

# =======================================================================
# (C4) modified-both: BLOCKED even with --force-restore
# =======================================================================
printf -- '-- (C4) modified-both (blocked even with force) --\n'
new_case c4 "${COMMON[@]}"
set_seed_base
new_text_file "$CASE_REF/$B" "beta-REF"
update_ref_commit 'ref: modify beta'
new_text_file "$CASE_LIVE/$B" "beta-LIVE"           # both diverge from the base
run_restore --ref-root "$CASE_REF" --live-root "$CASE_LIVE" --git-root "$CASE_REPO" \
    --manifest-path "$CASE_MANIFEST" --lock-path "$CASE_LOCK" --backup-root "$CASE_BACKUP" --force-restore
assert_eq 3 "$RC" "C4. exit 3 (modified-both blocked even with --force-restore)"
assert_contains "$TEXT" "modified-both" "C4. modified-both state reported"
assert_eq "beta-LIVE" "$(cat "$CASE_LIVE/$B")" "C4. live NOT overwritten (blocked)"

# =======================================================================
# (C5) added-live PROTECTED (H6): never deleted
# =======================================================================
printf -- '-- (C5) added-live protected (H6) --\n'
new_case c5 "${COMMON[@]}"
set_seed_base
new_text_file "$CASE_LIVE/agents/sdlc-extra.md" "live-only"   # added-live (missing from ref+base)
run_restore --ref-root "$CASE_REF" --live-root "$CASE_LIVE" --git-root "$CASE_REPO" \
    --manifest-path "$CASE_MANIFEST" --lock-path "$CASE_LOCK" --backup-root "$CASE_BACKUP"
# The live-only file SURVIVES (never deleted). The verify post-check reports an
# extra file -> exit != 0: an honest signal, NOT a deletion. Protection is proven
# by survival.
assert_present "$CASE_LIVE/agents/sdlc-extra.md" "C5. added-live NOT deleted (protected H6)"
assert_eq "live-only" "$(cat "$CASE_LIVE/agents/sdlc-extra.md")" "C5. live-only content intact"
assert_ne 0 "$RC" "C5. exit != 0 (extra reported by the post-check, not a deletion)"

# =======================================================================
# (C6) --dry-run: 0 writes (live/backup), would-restore reflected
# =======================================================================
printf -- '-- (C6) dry-run 0 writes --\n'
new_case c6 "${COMMON[@]}"
set_seed_base
new_text_file "$CASE_REF/$B" "beta-v2"
update_ref_commit 'ref: modify beta'
LIVE_BEFORE6=$(cat "$CASE_LIVE/$B")
run_restore --ref-root "$CASE_REF" --live-root "$CASE_LIVE" --git-root "$CASE_REPO" \
    --manifest-path "$CASE_MANIFEST" --lock-path "$CASE_LOCK" --backup-root "$CASE_BACKUP" --dry-run
assert_eq 0 "$RC" "C6. dry-run without block -> exit 0"
assert_eq "$LIVE_BEFORE6" "$(cat "$CASE_LIVE/$B")" "C6. dry-run: live unchanged"
assert_absent "$CASE_BACKUP" "C6. dry-run: no backup created"
assert_contains "$TEXT" "dry-run" "C6. dry-run reported (would-restore list)"

# =======================================================================
# (C7) atomicity: no leftover temp/bak on the live side after deployment (C1)
# =======================================================================
printf -- '-- (C7) atomic swap: no leftover temp/bak --\n'
RESIDUE=$(find "$ROOT/c1/live" -type f \( -name '*.tmp-*' -o -name '*.bak-*' \) 2>/dev/null | wc -l | tr -d ' ')
assert_eq 0 "$RESIDUE" "C7. no leftover .tmp-/.bak- file on the live side (C1)"

# =======================================================================
# (C8) CANONICAL GUARD: dirty (uncommitted) REF tree -> abort exit 5, no write
# =======================================================================
printf -- '-- (C8) canonical guard: dirty REF worktree blocked before writing --\n'
new_case c8 "${COMMON[@]}"
set_seed_base
new_text_file "$CASE_REF/$B" "beta-UNCOMMITTED"     # modified-ref NOT committed (dirty tree)
LIVE_BEFORE8=$(cat "$CASE_LIVE/$B")
run_restore --ref-root "$CASE_REF" --live-root "$CASE_LIVE" --git-root "$CASE_REPO" \
    --manifest-path "$CASE_MANIFEST" --lock-path "$CASE_LOCK" --backup-root "$CASE_BACKUP"
assert_eq 5 "$RC" "C8. exit 5 (REF tree not clean -> abort before any write)"
assert_contains "$TEXT" "not clean" "C8. REF tree not clean reported"
assert_eq "$LIVE_BEFORE8" "$(cat "$CASE_LIVE/$B")" "C8. LIVE unchanged (no non-canonical content deployed)"
assert_absent "$CASE_BACKUP" "C8. no backup (nothing written)"

# =======================================================================
# (C9) dry-run does NOT advance the branch: ff-only never runs in dry-run
# =======================================================================
printf -- '-- (C9) dry-run does not advance the branch (ff-only skipped in dry-run) --\n'
new_case c9 "${COMMON[@]}"
set_seed_base
ORIGIN9="$CASE_DIR/origin.git"
git init --bare -q "$ORIGIN9"
git -C "$CASE_REPO" remote add origin "$ORIGIN9"
git -C "$CASE_REPO" push -q -u origin HEAD
HEAD_BASE9=$(git -C "$CASE_REPO" rev-parse HEAD)
new_text_file "$CASE_REF/agents/sdlc-gamma.md" "gamma"
update_ref_commit 'ref: add gamma (upstream ahead)'
git -C "$CASE_REPO" push -q origin HEAD
git -C "$CASE_REPO" reset --hard -q "$HEAD_BASE9"
HEAD_BEFORE9=$(git -C "$CASE_REPO" rev-parse HEAD)
run_restore --ref-root "$CASE_REF" --live-root "$CASE_LIVE" --git-root "$CASE_REPO" \
    --manifest-path "$CASE_MANIFEST" --lock-path "$CASE_LOCK" --backup-root "$CASE_BACKUP" --dry-run
HEAD_AFTER9=$(git -C "$CASE_REPO" rev-parse HEAD)
assert_eq 0 "$RC" "C9. dry-run exit 0"
assert_eq "$HEAD_BEFORE9" "$HEAD_AFTER9" "C9. dry-run does NOT advance the local branch (ff-only skipped in dry-run)"

# =======================================================================
# (D1) corrupt manifest -> FAIL CLOSED (no write, exit != 0)
# =======================================================================
printf -- '-- (D1) fail-closed on corrupt manifest (H4) --\n'
new_case d1 "${COMMON[@]}"
new_text_file "$CASE_MANIFEST" '{ this is : not json'
new_text_file "$CASE_REF/$B" "beta-v2"
update_ref_commit 'ref: modify beta'
LIVE_BEFORE_D1=$(cat "$CASE_LIVE/$B")
run_restore --ref-root "$CASE_REF" --live-root "$CASE_LIVE" --git-root "$CASE_REPO" \
    --manifest-path "$CASE_MANIFEST" --lock-path "$CASE_LOCK" --backup-root "$CASE_BACKUP"
assert_ne 0 "$RC" "D1. corrupt manifest -> exit != 0 (fail closed)"
assert_contains "$TEXT" "FAIL CLOSED" "D1. fail-closed reported"
assert_eq "$LIVE_BEFORE_D1" "$(cat "$CASE_LIVE/$B")" "D1. fail-closed: live unchanged"
assert_absent "$CASE_BACKUP" "D1. fail-closed: no backup"

# --- Summary ---------------------------------------------------------------
printf '\n=== Summary: %d PASS / %d FAIL ===\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
printf 'OK: restore.sh compliant (P013:A009).\n'
exit 0
