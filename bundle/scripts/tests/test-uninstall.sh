#!/usr/bin/env bash
# Self-contained, assert-based self-check (ZERO framework) of uninstall.sh (P025:A023).
#
# Bash mirror of test-uninstall.ps1: same LIVE fixtures in TEMP, same exit codes.
# NEVER operates on the real ~/.claude. Cleans up via trap EXIT.
#
# Covers:
#   U0  source invariants (get_domain_relpaths, remove_nestor_import, invoke_uninstall,
#       BASH_SOURCE guard, --remove-core, zero hard-coded agent list).
#   U1  default behavior (WITHOUT --remove-core): agents/core/CLAUDE.md UNTOUCHED.
#   U2  --remove-core: agents + core + import removed, backed up without collision.
#   U3  --remove-core without agents/core present: graceful no-op.
#   U4  confirmation refused (without --force): cancelled, live intact.

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
has()   { grep -qF -- "$2" <<< "$1"; }
hasnot(){ ! grep -qF -- "$2" <<< "$1"; }
hasre() { grep -qE -- "$2" <<< "$1"; }

# --- Script locations ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scriptsDir="$(cd "$SCRIPT_DIR/.." && pwd)"
UNINSTALL="$scriptsDir/uninstall.sh"
LIB="$scriptsDir/sync-lib.sh"
for p in "$UNINSTALL" "$LIB"; do
    [[ -f "$p" ]] || { printf 'not found: %s\n' "$p" >&2; exit 2; }
done
# shellcheck source=/dev/null
. "$LIB"

# --- Isolated temporary working directory ---
WORK="$(mktemp -d "${TMPDIR:-/tmp}/uninstall-test-XXXXXX")"
cleanup() { [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf "$WORK"; }
trap cleanup EXIT

new_text() { local d; d=$(dirname "$1"); [[ -d "$d" ]] || mkdir -p "$d"; printf '%s' "$2" > "$1"; }

MANIFEST_JSON='{"version":"3.2.0","skills":["sdlc","sdlc-wave-orchestrator","sdlc-lang-dispatcher","sdlc-asvs-auditor"]}'
CLAUDE_MD_TEXT=$'# My personal CLAUDE.md\nPre-existing user content.\n@NESTOR.md\n'

# new_case <name> -> exports CASE_LIVE (complete LIVE fixture: 4 skills (including the
# manifest), commands/sdlc, 3 agents (one RECURSIVE + one nestor-*), NESTOR.md,
# CLAUDE.md WITH the import).
new_case() {
    local name="$1"
    local c="$WORK/$name"
    CASE_LIVE="$c/live"
    mkdir -p "$CASE_LIVE"
    new_text "$CASE_LIVE/skills/sdlc/SKILL.md"                       $'root skill\n'
    new_text "$CASE_LIVE/skills/sdlc/.install-manifest.json"         "$MANIFEST_JSON"
    new_text "$CASE_LIVE/skills/sdlc-wave-orchestrator/SKILL.md"     $'wave skill\n'
    new_text "$CASE_LIVE/skills/sdlc-lang-dispatcher/SKILL.md"       $'lang skill\n'
    new_text "$CASE_LIVE/skills/sdlc-asvs-auditor/SKILL.md"          $'asvs skill\n'
    new_text "$CASE_LIVE/commands/sdlc/brainstorm.md"                $'brainstorm cmd\n'
    new_text "$CASE_LIVE/agents/sdlc-architect.md"                   $'architect agent\n'
    new_text "$CASE_LIVE/agents/nested/sdlc-deep.md"                 $'deep nested agent\n'
    new_text "$CASE_LIVE/agents/nestor-clara.md"                       $'clara agent\n'
    new_text "$CASE_LIVE/NESTOR.md"                                    $'nestor core\n'
    new_text "$CASE_LIVE/CLAUDE.md"                                    "$CLAUDE_MD_TEXT"
}

# run_uninstall <args...> -> RC + OUT (real subprocess, --force implied except in U4)
run_uninstall() { OUT=$(bash "$UNINSTALL" "$@" 2>&1); RC=$?; }
live_has()    { [[ -e "$CASE_LIVE/$1" ]]; }
live_hasnot() { [[ ! -e "$CASE_LIVE/$1" ]]; }
read_text()   { [[ -f "$1" ]] && cat "$1"; }
backup_root() {
    # prints the path of the (single) expected _backups/sdlc-uninstall-* folder
    find "$CASE_LIVE/skills/_backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1
}

printf '\n=== test-uninstall.sh: self-check P025:A023 (bash mirror) ===\n'

# =======================================================================
# (U0) source invariants
# =======================================================================
printf -- '-- (U0) source invariants --\n'
SRC="$(cat "$UNINSTALL")"
at "U0. agents/core scope via get_domain_relpaths (single source)" has "$SRC" 'get_domain_relpaths'
at "U0. import removal via remove_nestor_import (single source)"   has "$SRC" 'remove_nestor_import'
at "U0. logic wrapped in invoke_uninstall (testable)"              has "$SRC" 'invoke_uninstall'
at "U0. auto-run guard (BASH_SOURCE)"                              has "$SRC" 'BASH_SOURCE[0]'
at "U0. --remove-core flag declared"                               has "$SRC" '--remove-core'
at "U0. no hard-coded AGENTS_DEFAULT list"           hasnot "$SRC" 'AGENTS_DEFAULT'
at "U0. no hard-coded literal agent name"            hasnot "$SRC" 'sdlc-architect'
at "U0. no hard-coded literal nestor-* agent name"   hasnot "$SRC" 'nestor-clara'
at "U0. agents scope derived by domain prefix, not by name" has "$SRC" 'agents/*'

# =======================================================================
# (U1) default behavior (WITHOUT --remove-core): strict non-regression
# =======================================================================
printf -- '-- (U1) default behavior: agents/core UNTOUCHED --\n'
new_case 'u1'
claudeMdBefore1="$(read_text "$CASE_LIVE/CLAUDE.md")"
run_uninstall --claude-root "$CASE_LIVE" --force
ae "U1. exit 0" "0" "$RC"
at "U1. sdlc skill removed"                     live_hasnot 'skills/sdlc'
at "U1. wave-orchestrator skill removed"        live_hasnot 'skills/sdlc-wave-orchestrator'
at "U1. commands/sdlc removed"                  live_hasnot 'commands/sdlc'
at "U1. sdlc-architect agent UNTOUCHED (no --remove-core)" live_has 'agents/sdlc-architect.md'
at "U1. nested agent UNTOUCHED"                 live_has 'agents/nested/sdlc-deep.md'
at "U1. nestor-* agent UNTOUCHED"               live_has 'agents/nestor-clara.md'
at "U1. NESTOR.md core UNTOUCHED"               live_has 'NESTOR.md'
at "U1. CLAUDE.md UNTOUCHED"                    live_has 'CLAUDE.md'
claudeMdAfter1="$(read_text "$CASE_LIVE/CLAUDE.md")"
ae "U1. CLAUDE.md byte-identical (import NOT touched without --remove-core)" "$claudeMdBefore1" "$claudeMdAfter1"
bk1="$(backup_root)"
at "U1. timestamped backup folder created" test -n "$bk1"
at "U1. backup contains the skills" bash -c "find '$bk1' -name SKILL.md | grep -q ."
af "U1. backup does NOT contain agents/ (no --remove-core)" bash -c "[[ -d '$bk1/agents' ]]"

# =======================================================================
# (U2) --remove-core: agents + core + import removed, backed up without collision
# =======================================================================
printf -- '-- (U2) --remove-core: agents/core/import removed --\n'
new_case 'u2'
run_uninstall --claude-root "$CASE_LIVE" --force --remove-core
ae "U2. exit 0" "0" "$RC"
at "U2. sdlc skill removed (base behavior preserved)" live_hasnot 'skills/sdlc'
at "U2. sdlc-architect agent removed"          live_hasnot 'agents/sdlc-architect.md'
at "U2. nested agent removed"                  live_hasnot 'agents/nested/sdlc-deep.md'
at "U2. nestor-* agent NOT removed (outside the SDLC domain)"  live_has 'agents/nestor-clara.md'
at "U2. NESTOR.md core NOT removed (outside the SDLC domain)"  live_has 'NESTOR.md'
at "U2. CLAUDE.md itself PRESERVED (only the import line is removed)" live_has 'CLAUDE.md'
claudeMdAfter2="$(read_text "$CASE_LIVE/CLAUDE.md")"
at "U2. '@NESTOR.md' line removed from CLAUDE.md" hasnot "$claudeMdAfter2" '@NESTOR.md'
at "U2. rest of the CLAUDE.md content preserved"  has "$claudeMdAfter2" 'Pre-existing user content.'
bk2="$(backup_root)"
at "U2. timestamped backup folder created" test -n "$bk2"
at "U2. backup: root agent present"            bash -c "[[ -f '$bk2/agents/sdlc-architect.md' ]]"
at "U2. backup: nested agent present (full relative path, no collision)" bash -c "[[ -f '$bk2/agents/nested/sdlc-deep.md' ]]"
af "U2. backup: nestor-* agent absent"         bash -c "[[ -f '$bk2/agents/nestor-clara.md' ]]"
af "U2. backup: NESTOR.md core absent"         bash -c "[[ -f '$bk2/NESTOR.md' ]]"

# =======================================================================
# (U3) --remove-core without agents/core present: graceful no-op
# =======================================================================
printf -- '-- (U3) --remove-core without agents/core present: graceful no-op --\n'
new_case 'u3'
rm -rf "$CASE_LIVE/agents" "$CASE_LIVE/NESTOR.md" "$CASE_LIVE/CLAUDE.md"
run_uninstall --claude-root "$CASE_LIVE" --force --remove-core
ae "U3. exit 0 (no crash without agents/core/CLAUDE.md)" "0" "$RC"
at "U3. skills still removed normally" live_hasnot 'skills/sdlc'

# =======================================================================
# (U4) confirmation refused (without --force): cancelled, live intact
# =======================================================================
printf -- '-- (U4) confirmation refused (without --force): cancelled --\n'
new_case 'u4'
OUT=$(printf 'non\n' | bash "$UNINSTALL" --claude-root "$CASE_LIVE" 2>&1); RC=$?
ae "U4. answer 'non': exit 0 (cancelled, no error)" "0" "$RC"
at "U4. cancelled: live intact (nothing removed)" live_has 'skills/sdlc'

# --- Summary -----------------------------------------------------------
printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$pass" "$fail"
if [[ $fail -gt 0 ]]; then
    printf 'Failures:\n'
    for f in "${failures[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
exit 0
