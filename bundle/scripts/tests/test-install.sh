#!/usr/bin/env bash
# Self-contained, assert-based self-check (ZERO framework) of install.sh (P018:A014).
#
# Bash mirror of test-install.ps1: same TEMP git/live fixtures, same exit codes.
# Creates ALL its fixtures in a single TEMP directory (fake REF = mini claude/ tree
# with skills+commands+agents in a committed git repo OR non-git; fake empty LIVE
# target). NEVER operates on the real repo nor on ~/.claude. Cleans up via trap EXIT.
#
# Covers each Code Lock criterion (mirror of C0..C13 of the .ps1):
#   C0  source invariants (no destructive mirror; sources sync-lib; greenlist;
#       DERIVED skills; copy_tree; verify post-check; invoke_install + auto-run guard;
#       default SourceRoot ../../claude; top-level commands, not the embedded copy).
#   C1  real ref: DERIVED floors for skills / agents / commands (read-only).
#   C2  empty live bootstrap (GIT): greenlist deployed, recursive agent, H3 excluded, verify 0 drift -> 0.
#   C3  verify unavailable (NON-git): deployment done, not fatal -> 0.
#   C4  idempotence: 2nd install with unchanged source -> "already up to date" -> 0, no redeploy.
#   C5  --force: reinstalls despite an unchanged checksum -> timestamped backup created.
#   C6  third-party skill guard: target SKILL.md not sdlc* -> ABORT 3, live intact.
#   C7  --dry-run: 0 writes.
#   (C8 of the .ps1 = PowerShell quirk with Windows 8.3 short paths: NOT APPLICABLE in bash.)
#   C9  F6: extra orphan -> not fatal (no exit 7).
#   C10 F4: self-heal of a damaged live install (intact manifest) -> REPAIR.
#   C11 F3: dirty ref (worktree != HEAD) -> integrity not confirmed (not fatal).
#   C12 F2: target SKILL.md without a readable 'name:' -> ABORT 3 (fail-closed).
#   C13 F8: --force --no-backup -> no backup.

set -uo pipefail

pass=0
fail=0
declare -a failures=()
_pass() { pass=$((pass+1)); printf '  [PASS] %s\n' "$1"; }
_fail() { fail=$((fail+1)); failures+=("$1"); printf '  [FAIL] %s\n' "$1"; }
at() { local n="$1"; shift; if "$@"; then _pass "$n"; else _fail "$n"; fi; }
af() { local n="$1"; shift; if "$@"; then _fail "$n"; else _pass "$n"; fi; }
ae() { local n="$1" exp="$2" act="$3"
    if [[ "$exp" == "$act" ]]; then _pass "$n"
    else printf '         expected=[%s] got=[%s]\n' "$exp" "$act"; _fail "$n"; fi; }
# grep helpers on multi-line text
has()   { grep -qF -- "$2" <<< "$1"; }
hasnot(){ ! grep -qF -- "$2" <<< "$1"; }
hasre() { grep -qE -- "$2" <<< "$1"; }

# --- Script locations ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scriptsDir="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL="$scriptsDir/install.sh"
LIB="$scriptsDir/sync-lib.sh"
VERIFY="$scriptsDir/verify.sh"
for p in "$INSTALL" "$LIB"; do
    [[ -f "$p" ]] || { printf 'not found: %s\n' "$p" >&2; exit 2; }
done
# sync-lib for C1 + greenlist counts on the test side
# shellcheck source=/dev/null
. "$LIB"

# --- Isolated temporary working directory ---
WORK="$(mktemp -d "${TMPDIR:-/tmp}/install-test-XXXXXX")"
cleanup() { [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf "$WORK"; }
trap cleanup EXIT

new_text() { local d; d=$(dirname "$1"); [[ -d "$d" ]] || mkdir -p "$d"; printf '%s' "$2" > "$1"; }
# read_raw_into VARNAME PATH: BYTE-EXACT content (trailing EOL included), mirror of
# test-sync-lib.sh (never through an enclosing $(...), which would strip trailing \n).
read_raw_into() {
    local __v="$1" __p="$2" __c
    __c=$(cat -- "$__p" 2>/dev/null; printf 'X')
    printf -v "$__v" '%s' "${__c%X}"
}

# Canonical mini claude/ tree: 2 skills (sdlc, sdlc-verify), 2 commands, 2 agents
# (one of them RECURSIVE under agents/nested/), + an excluded embedded DECOY copy (H3).
seed_fixture() {
    local ref="$1"
    new_text "$ref/skills/sdlc/SKILL.md"                 $'---\nname: sdlc\n---\nroot skill\n'
    new_text "$ref/skills/sdlc-verify/SKILL.md"          $'---\nname: sdlc-verify\n---\nverify skill\n'
    new_text "$ref/skills/sdlc/commands/sdlc/decoy.md" $'embedded DECOY — must NEVER be deployed\n'
    new_text "$ref/commands/sdlc/brainstorm.md"          $'brainstorm cmd\n'
    new_text "$ref/commands/sdlc/dev.md"                 $'dev cmd\n'
    new_text "$ref/agents/sdlc-architect.md"             $'architect agent\n'
    new_text "$ref/agents/nested/sdlc-deep.md"           $'deep nested agent\n'
}

# new_case <name> [git] -> exports CASE_REPO / CASE_REF / CASE_LIVE
new_case() {
    local name="$1" git="${2:-}"
    local c="$WORK/$name"
    CASE_REPO="$c/repo"
    CASE_REF="$CASE_REPO/claude"
    CASE_LIVE="$c/live"
    mkdir -p "$CASE_REF" "$CASE_LIVE"
    seed_fixture "$CASE_REF"
    if [[ "$git" == "git" ]]; then
        git -C "$CASE_REPO" init -q
        git -C "$CASE_REPO" config user.email 't@t'
        git -C "$CASE_REPO" config user.name 'test'
        git -C "$CASE_REPO" config commit.gpgsign false
        git -C "$CASE_REPO" config core.autocrlf false   # byte fidelity blob == worktree
        git -C "$CASE_REPO" add -- claude
        git -C "$CASE_REPO" commit -q -m 'seed ref'
    fi
}

# run_install <args...> -> RC + OUT
run_install() { OUT=$(bash "$INSTALL" "$@" 2>&1); RC=$?; }
live_has()  { [[ -f "$CASE_LIVE/$1" ]]; }
read_text() { [[ -f "$1" ]] && cat "$1"; }

printf '\n=== test-install.sh: self-check P018:A014 (bash mirror) ===\n'

# =======================================================================
# (C0) source invariants
# =======================================================================
printf -- '-- (C0) source invariants --\n'
SRC="$(cat "$INSTALL")"
at "C0. no rsync (destructive mirror)"               hasnot "$SRC" 'rsync'
at "C0. no cp -r (destructive mirror)"               hasnot "$SRC" 'cp -r'
at "C0. no --delete (destructive mirror)"            hasnot "$SRC" '--delete'
at "C0. sources sync-lib.sh"                         has "$SRC" 'sync-lib.sh'
at "C0. deployment via the get_domain_relpaths greenlist" has "$SRC" 'get_domain_relpaths'
at "C0. skills DERIVED via get_sync_domain_skill"    has "$SRC" 'get_sync_domain_skill'
at "C0. deployment via copy_tree (atomic per relpath)" has "$SRC" 'copy_tree'
at "C0. verify post-check present"                   has "$SRC" 'invoke_verify_post_check'
at "C0. verify.sh run as a subprocess"               has "$SRC" 'verify.sh'
at "C0. logic wrapped in invoke_install"             has "$SRC" 'invoke_install'
at "C0. auto-run guard (BASH_SOURCE)"                has "$SRC" 'BASH_SOURCE[0]'
at "C0. default SourceRoot = ../../claude"           has "$SRC" '../../claude'
at "C0. commands sourced from top-level commands/sdlc" has "$SRC" 'commands/sdlc'
at "C0. commands NOT from the embedded copy"         hasnot "$SRC" 'skills/sdlc/commands/sdlc'

# =======================================================================
# (C1) real ref: DERIVED floors 10 / 12 / 18 (read-only)
# =======================================================================
printf -- '-- (C1) derived floors on the real ref (read-only) --\n'
realRef="$(cd "$scriptsDir/../.." && pwd)/claude"
if [[ -d "$realRef" ]]; then
    realSkills=$(get_sync_domain_skill "$realRef" | grep -c .)
    realGreen=$(get_domain_relpaths "$realRef")
    realCmd=$(printf '%s\n' "$realGreen" | grep -c '^commands/sdlc/')
    realAgents=$(printf '%s\n' "$realGreen" | grep -c '^agents/')
    realCore=$(printf '%s\n' "$realGreen" | grep -cx 'NESTOR.md')
    ae "C1. real ref: 10 sdlc* skills (derived)"     10 "$realSkills"
    ae "C1. real ref: 18 commands (derived)"         18 "$realCmd"
    ae "C1. real ref: 12 agents (sdlc-*, derived)"   12 "$realAgents"
    ae "C1. real ref: 0 NESTOR.md core (outside the SDLC domain)" 0 "$realCore"
else
    printf '  (C1 skipped: real ref not found at %s)\n' "$realRef"
fi

# =======================================================================
# (C2) empty live bootstrap (GIT): greenlist deployed + recursion + H3 + verify 0 drift
# =======================================================================
printf -- '-- (C2) empty live bootstrap (git fixture) --\n'
new_case c2 git
green2=$(get_domain_relpaths "$CASE_REF" | grep -c .)
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE"
ae "C2. git bootstrap: exit 0 (deploys + verify post-check 0 drift)" 0 "$RC"
at "C2. root skill deployed"                        live_has 'skills/sdlc/SKILL.md'
at "C2. sdlc-verify skill deployed"                 live_has 'skills/sdlc-verify/SKILL.md'
at "C2. top-level command deployed"                 live_has 'commands/sdlc/brainstorm.md'
at "C2. top-level command deployed (2)"             live_has 'commands/sdlc/dev.md'
at "C2. agent deployed"                             live_has 'agents/sdlc-architect.md'
at "C2. RECURSIVE agent (subfolder) deployed"       live_has 'agents/nested/sdlc-deep.md'
af "C2. embedded copy (H3) NOT deployed"            live_has 'skills/sdlc/commands/sdlc/decoy.md'
liveDomain2=$(get_domain_relpaths "$CASE_LIVE" | grep -c .)
ae "C2. live domain file count == ref greenlist"    "$green2" "$liveDomain2"
at "C2. verify post-check reports 0 drift"          has "$OUT" '0 drift'
at "C2. .install-manifest.json manifest written"    test -f "$CASE_LIVE/skills/sdlc/.install-manifest.json"
# remember the c2 live tree for C4/C5
C2_REF="$CASE_REF"; C2_LIVE="$CASE_LIVE"

# =======================================================================
# (C3) verify unavailable (NON-git): deployment done, not fatal -> 0
# =======================================================================
printf -- '-- (C3) non-git source: verify unavailable, not fatal --\n'
new_case c3
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE"
ae "C3. non-git source: exit 0 (verify unavailable is NOT fatal)" 0 "$RC"
at "C3. deployment done despite verify being unavailable" live_has 'skills/sdlc/SKILL.md'
at "C3. recursive agent deployed (non-git)"         live_has 'agents/nested/sdlc-deep.md'
at "C3. 'verify unavailable' message present"       has "$OUT" 'unavailable'

# =======================================================================
# (C4) idempotence: 2nd install with unchanged source -> already up to date, no redeploy
# =======================================================================
printf -- '-- (C4) idempotence (2nd install) --\n'
CASE_REF="$C2_REF"; CASE_LIVE="$C2_LIVE"
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE"
ae "C4. 2nd install: exit 0" 0 "$RC"
at "C4. 2nd install: 'Already up to date' (checksum unchanged)" has "$OUT" 'Already up to date'
at "C4. 2nd install: no (re)deployment"             hasnot "$OUT" 'deployed'

# =======================================================================
# (C5) --force: reinstalls despite an unchanged checksum -> timestamped backup created
# =======================================================================
printf -- '-- (C5) --force reinstalls + timestamped backup --\n'
CASE_REF="$C2_REF"; CASE_LIVE="$C2_LIVE"
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE" --force
ae "C5. --force: exit 0 (reinstalls despite an unchanged checksum)" 0 "$RC"
at "C5. --force: bypasses idempotence"              hasnot "$OUT" 'Already up to date'
backups5=$(find "$CASE_LIVE/_backups" -type f -name '*.md' 2>/dev/null | grep -c .)
at "C5. --force: timestamped backup of live files before replacement" test "$backups5" -gt 0

# =======================================================================
# (C6) third-party skill guard: target SKILL.md not sdlc* -> ABORT 3
# =======================================================================
printf -- '-- (C6) third-party skill guard (ABORT exit 3) --\n'
new_case c6 git
new_text "$CASE_LIVE/skills/sdlc/SKILL.md" $'---\nname: evil-third-party\n---\nSQUAT\n'
cp "$CASE_LIVE/skills/sdlc/SKILL.md" "$WORK/c6-expected"   # byte-exact pre-image
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE"
ae "C6. third-party skill -> ABORT exit 3" 3 "$RC"
at "C6. ABORT reported"                             has "$OUT" 'ABORT'
at "C6. third-party skill NOT overwritten (live intact, byte-exact)" cmp -s "$CASE_LIVE/skills/sdlc/SKILL.md" "$WORK/c6-expected"
af "C6. no deployment (abort before writing)"       live_has 'agents/sdlc-architect.md'

# =======================================================================
# (C7) --dry-run: 0 writes
# =======================================================================
printf -- '-- (C7) --dry-run: 0 writes --\n'
new_case c7 git
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE" --dry-run
ae "C7. dry-run: exit 0" 0 "$RC"
dry7=$(find "$CASE_LIVE" -type f 2>/dev/null | grep -c .)
ae "C7. dry-run: no file written on the live side" 0 "$dry7"
af "C7. dry-run: no backup"                         test -d "$CASE_LIVE/_backups"
at "C7. dry-run reported (would-deploy list)"       has "$OUT" 'DRY-RUN'

# =======================================================================
# (C9) F6: extra orphan -> not fatal (no exit 7)
# =======================================================================
printf -- '-- (C9) F6: extra orphan -> not fatal --\n'
new_case c9 git
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE"
ae "C9. initial install: exit 0" 0 "$RC"
new_text "$CASE_LIVE/commands/sdlc/oldcmd.md" $'orphan cmd\n'   # orphan absent from HEAD
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE" --force
ae "C9. upgrade+orphan: exit 0, NOT fatal (F6: no more exit 7)" 0 "$RC"
at "C9. orphan classified as extra (not fatal)"     hasre "$OUT" 'EXTRA|orphan'
at "C9. additive install: orphan NOT removed"       live_has 'commands/sdlc/oldcmd.md'
at "C9. manifest written despite the extra file"    test -f "$CASE_LIVE/skills/sdlc/.install-manifest.json"

# =======================================================================
# (C10) F4: self-heal of a damaged live install (intact manifest) -> REPAIR
# =======================================================================
printf -- '-- (C10) F4: self-heal of a damaged live install --\n'
new_case c10 git
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE"
ae "C10. initial install: exit 0" 0 "$RC"
at "C10. file present before damage"                live_has 'agents/nested/sdlc-deep.md'
rm -f "$CASE_LIVE/agents/nested/sdlc-deep.md"      # DAMAGE (manifest intact)
af "C10. file damaged before repair"                live_has 'agents/nested/sdlc-deep.md'
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE"   # without --force
ae "C10. re-install: exit 0 (self-heal)" 0 "$RC"
at "C10. damage detected -> REPAIR"                 has "$OUT" 'REPAIR'
at "C10. F4: no 'already up to date' shortcut"      hasnot "$OUT" 'Already up to date'
at "C10. F4: file RESTORED by the self-heal"        live_has 'agents/nested/sdlc-deep.md'

# =======================================================================
# (C11) F3: dirty ref (worktree != HEAD) -> integrity not confirmed (not fatal)
# =======================================================================
printf -- '-- (C11) F3: dirty ref -> integrity not confirmed (not fatal) --\n'
new_case c11 git
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE"
ae "C11. initial install: exit 0" 0 "$RC"
new_text "$CASE_REF/skills/sdlc/SKILL.md" $'---\nname: sdlc\n---\nMODIFIED not committed\n'  # DIRTY
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE" --force
ae "C11. dirty ref + verify difference: exit 0, NOT fatal (F3: no exit 7)" 0 "$RC"
at "C11. F3: message 'integrity NOT confirmed / worktree'" hasre "$OUT" 'NOT confirmed|worktree'

# =======================================================================
# (C12) F2: target SKILL.md without a readable 'name:' -> ABORT 3 (fail-closed)
# =======================================================================
printf -- '-- (C12) F2: fail-closed guard on an unreadable name: --\n'
new_case c12 git
new_text "$CASE_LIVE/skills/sdlc/SKILL.md" $'# no name frontmatter\nopaque content\n'
cp "$CASE_LIVE/skills/sdlc/SKILL.md" "$WORK/c12-expected"   # byte-exact pre-image
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE"
ae "C12. F2: target SKILL.md without name: -> ABORT exit 3" 3 "$RC"
at "C12. F2: abort reported (unidentifiable skill)" hasre "$OUT" 'unreadable|fail-closed'
at "C12. F2: unidentifiable target NOT overwritten (byte-exact)" cmp -s "$CASE_LIVE/skills/sdlc/SKILL.md" "$WORK/c12-expected"

# =======================================================================
# (C13) F8: --force --no-backup -> no backup
# =======================================================================
printf -- '-- (C13) F8: --force --no-backup -> no backup --\n'
new_case c13 git
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE"
ae "C13. initial install: exit 0" 0 "$RC"
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE" --force --no-backup
ae "C13. --force --no-backup: exit 0" 0 "$RC"
# --no-backup ONLY governs the backup of DOMAIN files ('sdlc-' prefix) — separate from
# the independent set_generic_import backup ('nestor-import-' prefix, P022/A019, never
# gated by --no-backup), which can legitimately appear here: the 1st install adds 2 markers
# (@NESTOR.md + @CLAUDE.local.md, P033:A029) to a freshly created CLAUDE.md, and the 2nd
# marker finds an "existing" file (created by the 1st call in the same run).
domainBackups13=$(find "$CASE_LIVE/_backups" -maxdepth 1 -type d -name 'sdlc-*' 2>/dev/null | wc -l)
ae "C13. F8: --no-backup -> no DOMAIN backup folder (sdlc-*) created" 0 "$domainBackups13"
at "C13. F8: deployment done despite --no-backup"   live_has 'skills/sdlc/SKILL.md'

# =======================================================================
# (C14) P022:A019 — install no longer adds the '@NESTOR.md' import to
#       CLAUDE_ROOT/CLAUDE.md; --remove-import removes it instead of installing.
# =======================================================================
printf -- '-- (C14) P022:A019: @NESTOR.md import added/removed --\n'
new_case c14 git
CLAUDE_MD14="$CASE_LIVE/CLAUDE.md"
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE"
ae "C14a. nominal install: exit 0" 0 "$RC"
at "C14a. CLAUDE.md created at the end of a nominal run" test -f "$CLAUDE_MD14"
ae "C14a. install no longer adds @NESTOR.md (0 lines)" 0 "$(grep -c -E '^[[:space:]]*@NESTOR\.md[[:space:]]*$' "$CLAUDE_MD14")"
DOMAIN14=$(get_domain_relpaths "$CASE_LIVE")
at "C14a. CLAUDE.md OUTSIDE the sync domain (never in the greenlist)" hasnot "$DOMAIN14" 'CLAUDE.md'
# 2nd install (idempotent, unchanged checksum): does not duplicate the line.
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE"
ae "C14b. 2nd install (already up to date): exit 0" 0 "$RC"
ae "C14b. 2nd install: still 0 @NESTOR.md lines" 0 "$(grep -c -E '^[[:space:]]*@NESTOR\.md[[:space:]]*$' "$CLAUDE_MD14")"
# --remove-import: removes the line and does NOT run the rest of the installation.
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE" --remove-import
ae "C14c. --remove-import: exit 0" 0 "$RC"
ae "C14c. --remove-import: line removed" 0 "$(grep -c -E '^[[:space:]]*@NESTOR\.md[[:space:]]*$' "$CLAUDE_MD14")"
# --dry-run: 0 writes to CLAUDE.md (C7 already covers the rest of the live tree).
new_case c14d git
CLAUDE_MD14D="$CASE_LIVE/CLAUDE.md"
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE" --dry-run
ae "C14d. --dry-run: exit 0" 0 "$RC"
af "C14d. --dry-run: CLAUDE.md NOT created" test -f "$CLAUDE_MD14D"

# =======================================================================
# (C15) P033:A029 — install calls set_local_overlay_import in addition to set_nestor_import:
#       CLAUDE.local.md created (empty) on an empty live tree, idempotent on the 2nd run,
#       never overwritten when it already has private content, --dry-run = 0 writes.
# =======================================================================
printf -- '-- (C15) P033:A029: CLAUDE.local.md ensured by install --\n'
# NB: CASE_LIVE already points to c14d (new_case c14d above) -> go back explicitly
# to case c14 (the one with the nominal install + its CLAUDE.md).
CASE_LIVE_C14="$WORK/c14/live"
CLAUDE_MD14="$CASE_LIVE_C14/CLAUDE.md"
CLAUDE_LOCAL14="$CASE_LIVE_C14/CLAUDE.local.md"
at "C15a. CLAUDE.local.md created at the end of a nominal run (empty live)" test -f "$CLAUDE_LOCAL14"
read_raw_into c15aLocal "$CLAUDE_LOCAL14"
ae "C15a. CLAUDE.local.md created EMPTY" '' "$c15aLocal"
ae "C15a. exactly 1 @CLAUDE.local.md line" 1 "$(grep -c -E '^[[:space:]]*@CLAUDE\.local\.md[[:space:]]*$' "$CLAUDE_MD14")"
DOMAIN15=$(get_domain_relpaths "$CASE_LIVE_C14")
at "C15a. CLAUDE.local.md OUTSIDE the sync domain (never in the greenlist)" hasnot "$DOMAIN15" 'CLAUDE.local.md'

# C15b. Private content written to CLAUDE.local.md BEFORE a reinstall (--force): never overwritten.
new_text "$CLAUDE_LOCAL14" $'private content\n'
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE_C14" --force
ae "C15b. reinstall --force: exit 0" 0 "$RC"
read_raw_into c15bLocal "$CLAUDE_LOCAL14"
ae "C15b. existing NON-empty CLAUDE.local.md: never overwritten by install" $'private content\n' "$c15bLocal"
ae "C15b. reinstall: still exactly 1 line (idempotent)" 1 "$(grep -c -E '^[[:space:]]*@CLAUDE\.local\.md[[:space:]]*$' "$CLAUDE_MD14")"

# C15c. --dry-run on an empty live tree: neither CLAUDE.md nor CLAUDE.local.md created.
new_case c15c git
CLAUDE_MD15C="$CASE_LIVE/CLAUDE.md"
CLAUDE_LOCAL15C="$CASE_LIVE/CLAUDE.local.md"
run_install --source-root "$CASE_REF" --claude-root "$CASE_LIVE" --dry-run
ae "C15c. --dry-run: exit 0" 0 "$RC"
af "C15c. --dry-run: CLAUDE.md NOT created" test -f "$CLAUDE_MD15C"
af "C15c. --dry-run: CLAUDE.local.md NOT created" test -f "$CLAUDE_LOCAL15C"

# --- Summary ---
printf '\n=== Summary: %d PASS / %d FAIL ===\n' "$pass" "$fail"
if [[ $fail -gt 0 ]]; then
    for f in "${failures[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
printf 'OK: install.sh compliant (P018:A014).\n'
exit 0
