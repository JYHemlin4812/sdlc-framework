#!/usr/bin/env bash
# Self-contained, assert-based self-check (ZERO framework) of verify.sh (P018:A014).
#
# Mirror of test-verify.ps1: creates ALL its fixtures in a single TEMP dir (fake git
# REF repo + fake LIVE dir) — NEVER operates on the real repo nor on ~/.claude.
# Cleans up via trap EXIT. Exit != 0 on the first failure.
#
# NB: no `set -e` — invoke_verify legitimately exits != 0 (T6*); the harness
# captures each result.
set -uo pipefail

pass=0
fail=0
declare -a failures=()
_pass() { pass=$((pass+1)); printf '  [PASS] %s\n' "$1"; }
_fail() { fail=$((fail+1)); failures+=("$1"); printf '  [FAIL] %s\n' "$1"; }
# aeq <name> <expected> <actual>
aeq() {
    local n="$1" exp="$2" act="$3"
    if [[ "$exp" == "$act" ]]; then _pass "$n"
    else printf '         expected=[%s] got=[%s]\n' "$exp" "$act"; _fail "$n"; fi
}
# ane <name> <a> <b>: PASS if a != b
ane() {
    local n="$1" a="$2" b="$3"
    if [[ "$a" != "$b" ]]; then _pass "$n"
    else printf '         expected != [%s]\n' "$b"; _fail "$n"; fi
}
at() { local n="$1"; shift; if "$@"; then _pass "$n"; else _fail "$n"; fi; }
af() { local n="$1"; shift; if "$@"; then _fail "$n"; else _pass "$n"; fi; }

# --- Location + source (the BASH_SOURCE guard prevents the auto-run) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFY_PATH="$SCRIPTS/verify.sh"
for p in "$SCRIPTS/sync-lib.sh" "$VERIFY_PATH"; do
    [[ -f "$p" ]] || { printf 'Not found: %s\n' "$p" >&2; exit 2; }
done
# shellcheck disable=SC1090
. "$VERIFY_PATH"

# --- Fixtures ---------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-test-XXXXXX")"
cleanup() { [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf "$WORK"; }
trap cleanup EXIT
REF="$WORK/ref"
LIVE="$WORK/live"

new_text() {  # new_text <path> <text>
    local d; d=$(dirname "$1"); [[ -d "$d" ]] || mkdir -p "$d"
    printf '%s' "$2" > "$1"
}

# DOMAIN files (present in the committed ref AND in live for a faithful install).
domain_rels=(
    'skills/sdlc/SKILL.md'
    'skills/sdlc-wave-orchestrator/SKILL.md'
    'skills/sdlc-lang-dispatcher/SKILL.md'
    'commands/sdlc/brainstorm.md'
    'commands/sdlc/plan.md'
    'agents/sdlc-python.md'
    'agents/sdlc-js.md'
)
domain_text() {
    case "$1" in
        'skills/sdlc/SKILL.md')                   printf 'main skill\n' ;;
        'skills/sdlc-wave-orchestrator/SKILL.md') printf 'wave orchestrator\n' ;;
        'skills/sdlc-lang-dispatcher/SKILL.md')   printf 'lang dispatcher\n' ;;
        'commands/sdlc/brainstorm.md')            printf 'brainstorm cmd\n' ;;
        'commands/sdlc/plan.md')                  printf 'plan cmd\n' ;;
        'agents/sdlc-python.md')                  printf 'python agent\n' ;;
        'agents/sdlc-js.md')                      printf 'js agent\n' ;;
    esac
}
# REF-only files outside the domain: never expected on the live side (H3 + H7 + loose).
declare -A refonly=(
    ['skills/sdlc/commands/embedded.md']='stale embedded command'
    ['skills/other-thirdparty/SKILL.md']='third-party skill'
    ['skills/sdlc-standalone.md']='loose 2-segment sdlc file'
    ['README.md']='outside the domain'
    ['OTHER.md']='arbitrary root file'   # A018: no open root pattern
)

reset_live() {
    [[ -d "$LIVE" ]] && rm -rf "$LIVE"
    local rel
    for rel in "${domain_rels[@]}"; do
        new_text "$LIVE/$rel" "$(domain_text "$rel")"
    done
}

tree_fingerprint() {
    # Stable fingerprint (relpath|sha, .git excluded) — proves verify is READ-ONLY.
    local root="$1" f rel
    while IFS= read -r f; do
        rel="${f#"$root"/}"
        printf '%s|%s\n' "$rel" "$(get_file_hash_byteexact "$f")"
    done < <(find "$root" -type f -not -path '*/.git/*' 2>/dev/null | LC_ALL=C sort)
}

printf '\n=== test-verify.sh: self-check P018:A014 (bash mirror) ===\n'

# --- Build the fake REF repo and commit ---------------------------------------
for rel in "${domain_rels[@]}"; do
    new_text "$REF/claude/$rel" "$(domain_text "$rel")"
done
for rel in "${!refonly[@]}"; do
    new_text "$REF/claude/$rel" "${refonly[$rel]}"$'\n'
done
git -C "$REF" init -q
git -C "$REF" config user.email 'test@example.com'
git -C "$REF" config user.name 'verify test'
git -C "$REF" config commit.gpgsign false
git -C "$REF" config core.autocrlf false
git -C "$REF" add -A
git -C "$REF" commit -q -m 'seed ref' || { printf 'ref fixture commit failed\n' >&2; exit 2; }

reset_live

# === T1: PERFECT fidelity => exit 0 ==========================================
invoke_verify --ref-root "$REF" --live-root "$LIVE" -q; rc=$?
aeq "T1 byte-identical => exit 0" "0" "$rc"

# === T2: READ-ONLY (ref+live FS unchanged before/after) =======================
fp_ref_before="$(tree_fingerprint "$REF")"
fp_live_before="$(tree_fingerprint "$LIVE")"
invoke_verify --ref-root "$REF" --live-root "$LIVE" -q >/dev/null; rc=$?
fp_ref_after="$(tree_fingerprint "$REF")"
fp_live_after="$(tree_fingerprint "$LIVE")"
aeq "T2 READ-ONLY: REF tree unchanged"  "$fp_ref_before"  "$fp_ref_after"
aeq "T2 READ-ONLY: LIVE tree unchanged" "$fp_live_before" "$fp_live_after"

# === T3: compares the committed HEAD, not the working tree ====================
reset_live
printf 'WORKING TREE MODIFIED - NOT COMMITTED\n' > "$REF/claude/skills/sdlc/SKILL.md"
invoke_verify --ref-root "$REF" --live-root "$LIVE" -q; rc=$?
aeq "T3 committed HEAD (dirty ref working tree ignored) => exit 0" "0" "$rc"
git -C "$REF" checkout -q -- claude   # restore the working tree

# === T4: live .pyc => NOT extra (centralized exclusions) ======================
reset_live
new_text "$LIVE/skills/sdlc/__pycache__/mod.pyc" "bytecode"
new_text "$LIVE/skills/sdlc/leftover.pyc" "bytecode2"
invoke_verify --ref-root "$REF" --live-root "$LIVE" -q; rc=$?
aeq "T4 live .pyc ignored => exit 0" "0" "$rc"

# === T5: derived floors — no literal 10/12/18, count computed =================
src="$(cat "$VERIFY_PATH")"
af "T5 no literal 10/12/18 in verify.sh" grep -Eq '\b1[028]\b' <<< "$src"
at "T5 floors computed (get_domain_cardinalities present)" grep -q 'get_domain_cardinalities' <<< "$src"

# === T6a: missing live file => FAIL (exit != 0) ===============================
reset_live
rm -f "$LIVE/agents/sdlc-python.md"
invoke_verify --ref-root "$REF" --live-root "$LIVE" -q; rc=$?
ane "T6a MISSING => exit != 0" "$rc" "0"

# === T6b: different hash => FAIL ===============================================
reset_live
printf 'DIVERGENT CONTENT\n' > "$LIVE/commands/sdlc/plan.md"
invoke_verify --ref-root "$REF" --live-root "$LIVE" -q; rc=$?
ane "T6b HASH DIFF => exit != 0" "$rc" "0"

# === T6c: real extra file (non-excluded domain file) => FAIL ===================
reset_live
new_text "$LIVE/skills/sdlc/EXTRA.md" "real extra file"$'\n'
invoke_verify --ref-root "$REF" --live-root "$LIVE" -q; rc=$?
ane "T6c real EXTRA => exit != 0" "$rc" "0"

# === T7: third-party live skill/agent (not sdlc*) => ignored (H7) => exit 0 ====
reset_live
new_text "$LIVE/skills/my-personal-skill/SKILL.md" "third-party live skill"$'\n'
new_text "$LIVE/agents/other-agent.md" "third-party live agent"$'\n'
invoke_verify --ref-root "$REF" --live-root "$LIVE" -q; rc=$?
aeq "T7 third-party live skill/agent ignored (H7) => exit 0" "0" "$rc"

# === T8: committed loose 2-segment sdlc* file => outside the domain => exit 0 ==
reset_live   # byte-identical live, WITHOUT the loose file (never installed)
invoke_verify --ref-root "$REF" --live-root "$LIVE" -q; rc=$?
aeq "T8 committed loose 2-segment sdlc* file => outside the domain => exit 0" "0" "$rc"
af "T8 test_in_sdlc_domain('skills/sdlc-standalone.md') = False" \
    test_in_sdlc_domain 'skills/sdlc-standalone.md'
at "T8 test_in_sdlc_domain('skills/sdlc/SKILL.md') = True" \
    test_in_sdlc_domain 'skills/sdlc/SKILL.md'

# === T9: P021:A018 extension — core domain + nestor-* pattern =================
# (T1 already proves: byte-identical NESTOR.md + agents/nestor-* => exit 0,
#  and a committed root OTHER.md is never flagged missing.)
reset_live
# T9a: the core domain cardinality appears in the report (derived 0/1).
out9="$(invoke_verify --ref-root "$REF" --live-root "$LIVE")"
at "T9a verify report: core domain cardinality shown (core=0)" \
    grep -q 'core=0' <<< "$out9"
at "T9a core cardinality next to skills/agents/commands" \
    grep -Eq 'skills=[0-9]+ agents=[0-9]+ commands=[0-9]+ core=[0-9]+' <<< "$out9"
# T9d: git-tree projection == FS classifier on the new domains
af "T9d test_in_sdlc_domain('NESTOR.md') = False (Nestor core outside the SDLC domain)" \
    test_in_sdlc_domain 'NESTOR.md'
af "T9d test_in_sdlc_domain('OTHER.md') = False (no open root pattern)" \
    test_in_sdlc_domain 'OTHER.md'
af "T9d test_in_sdlc_domain('agents/nestor-analyste.md') = False (nestor-* agents outside the SDLC domain)" \
    test_in_sdlc_domain 'agents/nestor-analyste.md'
af "T9d test_in_sdlc_domain('agents/other-agent.md') = False (no matching pattern)" \
    test_in_sdlc_domain 'agents/other-agent.md'

# === T9e: CASE parity (SP3 adversarial review) — case-SENSITIVE classification
#     aligned on git ls-tree + PS (-ceq/-clike). A wrong spelling is outside the
#     domain on BOTH sides (otherwise PS/bash exit codes diverge on the same repo). ==
af "T9e 'nestor.md' (wrong case) = False (case-sensitive NESTOR.md literal)" \
    test_in_sdlc_domain 'nestor.md'
af "T9e 'agents/Nestor-rh.md' (wrong case) = False (case-sensitive nestor-* pattern)" \
    test_in_sdlc_domain 'agents/Nestor-rh.md'
af "T9e 'agents/SDLC-py.md' (wrong case) = False (case-sensitive sdlc-* pattern)" \
    test_in_sdlc_domain 'agents/SDLC-py.md'
af "T9e 'skills/SDLC-x/SKILL.md' (wrong case) = False (case-sensitive skill folder)" \
    test_in_sdlc_domain 'skills/SDLC-x/SKILL.md'

# --- Final report -------------------------------------------------------------
printf '\nResult: %d PASS / %d FAIL\n' "$pass" "$fail"
if [[ $fail -gt 0 ]]; then
    for f in "${failures[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
exit 0
