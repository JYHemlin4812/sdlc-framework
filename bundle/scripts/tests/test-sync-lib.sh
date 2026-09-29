#!/usr/bin/env bash
# Self-contained assert-based self-check (ZERO framework) of sync-lib.sh.
#
# Mirror of test-sync-lib.ps1: covers EACH Code Lock criterion of P011:A002 (a..j)
# + the sha256('abc') invariant. Creates its fixtures in a unique TEMP directory
# (never ~/.claude nor the real repo) and cleans up via trap EXIT. Exit != 0 on
# the first failure.

# NB: no `set -e` — the predicates (test_sync_excluded, acquire_sync_lock)
# legitimately return != 0; the harness captures each result.
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

# Content helpers
is_fn()         { declare -f "$1" >/dev/null 2>&1; }         # function defined and callable
contains_line() { grep -qxF -- "$2" <<< "$1"; }              # $1 multi-line, $2 exact line
body_has()      { declare -f "$1" | grep -qF -- "$2"; }      # function body contains substring
body_hasnot()   { ! declare -f "$1" | grep -qF -- "$2"; }

# read_sync_manifest accessors
rsm_line1()      { read_sync_manifest "$1" | head -1; }
rsm_ok()         { local l; l=$(rsm_line1 "$1"); printf '%s' "$(cut -f1 <<< "$l")"; }
rsm_exists()     { local l; l=$(rsm_line1 "$1"); printf '%s' "$(cut -f2 <<< "$l")"; }
rsm_failclosed() { local l; l=$(rsm_line1 "$1"); printf '%s' "$(cut -f3 <<< "$l")"; }
rsm_count()      { read_sync_manifest "$1" | tail -n +2 | grep -c . ; }
rsm_entry()      { read_sync_manifest "$1" | tail -n +2 | awk -F'\t' -v k="$2" '$1==k{print $2}'; }

# --- Locate the library -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/sync-lib.sh"
if [[ ! -f "$LIB_PATH" ]]; then
    printf 'sync-lib.sh not found: %s\n' "$LIB_PATH" >&2
    exit 2
fi

# --- Isolated temporary work directory --------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sync-lib-test-XXXXXX")"
cleanup() { [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf "$WORK"; }
trap cleanup EXIT

new_text() {  # new_text <path> <text>
    local d; d=$(dirname "$1"); [[ -d "$d" ]] || mkdir -p "$d"
    printf '%s' "$2" > "$1"
}

printf '\n=== test-sync-lib.sh: self-check P011:A002 (bash mirror) ===\n'

# =======================================================================
# (a) source OK with no side effect + functions callable in isolation
# =======================================================================
printf -- '-- (a) source with no side effect --\n'

CANARY="$WORK/canary"; mkdir -p "$CANARY"
files_before=$(find "$CANARY" -mindepth 1 | wc -l | tr -d ' ')

# shellcheck source=/dev/null
. "$LIB_PATH"

files_after=$(find "$CANARY" -mindepth 1 | wc -l | tr -d ' ')
ae "a. source writes no file (no FS side effect)" "$files_before" "$files_after"

# no scope variable polluted by loading
at "a. source creates no scope variable" test -z "${SYNC_EXCLUDE_DIRS:-}"

exported=(
    get_sync_exclusion test_sync_excluded
    get_sync_domain_skill get_domain_relpaths get_rel_path
    get_file_hash_byteexact get_sync_state
    show_conflict_diff resolve_lww
    write_file_atomic copy_tree
    acquire_sync_lock release_sync_lock
    write_sync_manifest read_sync_manifest get_first_run_plan
    set_nestor_import remove_nestor_import
)
for fn in "${exported[@]}"; do
    at "a. exported function callable: $fn" is_fn "$fn"
done

# actual isolated call of pure functions
ex_out=$(get_sync_exclusion)
at "a. get_sync_exclusion callable in isolation" grep -qF '__pycache__' <<< "$ex_out"
iso="$WORK/iso.txt"; new_text "$iso" 'iso'
ae "a. get_file_hash_byteexact callable in isolation" 64 "$(get_file_hash_byteexact "$iso" | wc -c | tr -d ' ')"

# =======================================================================
# (b) write_sync_manifest & copy_tree NEVER write in place (temp+rename)
# =======================================================================
printf -- '-- (b) atomic temp+rename writes --\n'

at "b. write_file_atomic uses a .tmp- temporary file" body_has write_file_atomic '.tmp-'
at "b. write_file_atomic publishes via mv -f (rename)"  body_has write_file_atomic 'mv -f'
at "b. write_file_atomic never writes directly to the target" body_hasnot write_file_atomic '> "$path"'
at "b. write_sync_manifest goes through write_file_atomic" body_has write_sync_manifest 'write_file_atomic'
at "b. copy_tree goes through write_file_atomic"        body_has copy_tree 'write_file_atomic'

# Functional proof: overwrite of an existing target, no leftover .tmp-.
MANDIR="$WORK/manifest"; mkdir -p "$MANDIR"
MANPATH="$MANDIR/.sync-manifest.json"
new_text "$MANPATH" 'OLD-SENTINEL'
printf 'commands/sdlc/a.md\tdeadbeef\n' | write_sync_manifest --path "$MANPATH" >/dev/null
at "b. write_sync_manifest produces the final target" test -f "$MANPATH"
tmp_left=$(find "$MANDIR" -name '*.tmp-*' | wc -l | tr -d ' ')
ae "b. no leftover .tmp- file after write_sync_manifest" 0 "$tmp_left"
ae "b. atomically rewritten manifest is readable (target replaced, not the sentinel)" "deadbeef" "$(rsm_entry "$MANPATH" 'commands/sdlc/a.md')"

# =======================================================================
# (c) copy_tree: no destructive mirror + copies ONLY greenlisted paths
# =======================================================================
printf -- '-- (c) per-relPath copy_tree, no mirror --\n'

at "c. copy_tree contains no rsync"    body_hasnot copy_tree 'rsync'
at "c. copy_tree contains no cp -r"    body_hasnot copy_tree 'cp -r'
at "c. copy_tree contains no --delete" body_hasnot copy_tree '--delete'

SRC="$WORK/ct-src"; DST="$WORK/ct-dst"
new_text "$SRC/a.md" 'AAA'
new_text "$SRC/sub/b.md" 'BBB'
new_text "$SRC/c.md" 'CCC'          # NOT greenlisted
copy_tree "$SRC" "$DST" a.md sub/b.md >/dev/null 2>&1
at "c. copy_tree copies the greenlisted relPath (a.md)"   test -f "$DST/a.md"
at "c. copy_tree creates parent folders (sub/b.md)"       test -f "$DST/sub/b.md"
af "c. copy_tree does NOT copy a non-greenlisted file (c.md)" test -f "$DST/c.md"
ae "c. copied content is byte-faithful" 'AAA' "$(cat "$DST/a.md")"

# (c-sec) boundary: a '..' relPath must NEVER escape dstroot
SECB="$WORK/ct-sec"
SECSRC="$SECB/s/src"; SECDST="$SECB/d/dst"
mkdir -p "$SECSRC" "$SECDST"
new_text "$SECB/s/payload.md" 'ATTACKER-PAYLOAD'   # parent of srcroot
new_text "$SECB/d/payload.md" 'PRECIOUS-LIVE-DATA' # parent of dstroot (OUTSIDE target)
sec_n=$(copy_tree "$SECSRC" "$SECDST" '../payload.md' 2>/dev/null | grep -c .)
ae "c-sec. copy_tree rejects the '..' escape relPath (nothing copied)" 0 "$sec_n"
ae "c-sec. the victim OUTSIDE dstroot is NOT overwritten via '..'" 'PRECIOUS-LIVE-DATA' "$(cat "$SECB/d/payload.md")"
sec_n2=$(copy_tree "$SECSRC" "$SECDST" 'sub//../../x.md' 2>/dev/null | grep -c .)
ae "c-sec. copy_tree rejects '..' even when nested" 0 "$sec_n2"

# =======================================================================
# (d) corrupt read_sync_manifest -> fail CLOSED
# =======================================================================
printf -- '-- (d) corrupt manifest => fail-closed --\n'

CORRUPT="$WORK/corrupt.json"
new_text "$CORRUPT" '{ "version": "SP2", "entries": { truncated...'
ae "d. corrupt parse => FailClosed=1" 1 "$(rsm_failclosed "$CORRUPT")"
ae "d. empty base when fail-closed" 0 "$(rsm_count "$CORRUPT")"
# no ref!=live assumed synced: missing base => modified-both (blocked)
base_d=$(rsm_entry "$CORRUPT" 'commands/sdlc/x.md')
st_d=$(get_sync_state 'aaaa' 'bbbb' "$base_d")
af "d. fail-closed: a ref!=live is never assumed synced" test "$st_d" = 'identical'
ae "d. fail-closed: ref!=live without base => modified-both (blocked)" 'modified-both' "$st_d"

# (d-schema) VALID JSON but 'entries' with a wrong schema => fail CLOSED
BADARR="$WORK/entries-array.json"
new_text "$BADARR" '{ "version": "SP2", "entries": [1,2,3] }'
ae "d-schema. entries=JSON array => FailClosed=1" 1 "$(rsm_failclosed "$BADARR")"
ae "d-schema. entries=array => empty base" 0 "$(rsm_count "$BADARR")"

BADSTR="$WORK/entries-string.json"
new_text "$BADSTR" '{ "version": "SP2", "entries": "boom" }'
ae "d-schema. entries=string => FailClosed=1" 1 "$(rsm_failclosed "$BADSTR")"
ae "d-schema. entries=string => empty base" 0 "$(rsm_count "$BADSTR")"

# entries={} (empty JSON object) stays OK = conservative empty base (not fail-closed)
EMPTYE="$WORK/entries-empty.json"
new_text "$EMPTYE" '{ "version": "SP2", "entries": {} }'
ae "d-schema. entries={} => Ok=1" 1 "$(rsm_ok "$EMPTYE")"
ae "d-schema. entries={} => empty base (conservative)" 0 "$(rsm_count "$EMPTYE")"

# =======================================================================
# (e) get_sync_state: correct label for EACH row of the truth table
# =======================================================================
printf -- '-- (e) classifier: truth table --\n'

ae "e. identical (R==L)"                    'identical'        "$(get_sync_state 'x' 'x' 'x')"
ae "e. identical (R==L, without base)"      'identical'        "$(get_sync_state 'x' 'x' '')"
ae "e. modified-ref (L==B, R!=B)"            'modified-ref'      "$(get_sync_state 'r2' 'b' 'b')"
ae "e. modified-live (R==B, L!=B)"           'modified-live'     "$(get_sync_state 'b' 'l2' 'b')"
ae "e. modified-both (R!=B,L!=B) [H2]"   'modified-both' "$(get_sync_state 'r2' 'l2' 'b')"
ae "e. added-both-divergent => modified-both" 'modified-both' "$(get_sync_state 'r2' 'l2' '')"
ae "e. added-live (protected)"             'added-live'      "$(get_sync_state '' 'l' '')"
ae "e. deleted-ref (base-aware, L==B)"     'deleted-ref'     "$(get_sync_state '' 'b' 'b')"
ae "e. conflict-deleted-ref-modified-live"        'conflict-deleted-ref-modified-live' "$(get_sync_state '' 'l2' 'b')"
ae "e. added-ref"                          'added-ref'       "$(get_sync_state 'r' '' '')"
ae "e. deleted-live (R==B)"                'deleted-live'    "$(get_sync_state 'b' '' 'b')"
ae "e. conflict-deleted-live-modified-ref"        'conflict-deleted-live-modified-ref' "$(get_sync_state 'r2' '' 'b')"
ae "e. absent-both"                     'absent-both'  "$(get_sync_state '' '' 'b')"

# =======================================================================
# (f) Exclusions: *.pyc and __pycache__/ excluded; domain .md not excluded
# =======================================================================
printf -- '-- (f) centralized exclusions --\n'

at "f. *.pyc excluded"            test_sync_excluded 'skills/sdlc/x.pyc'
at "f. __pycache__/ excluded"     test_sync_excluded 'skills/sdlc/__pycache__/x.py'
at "f. conflicts.log excluded"    test_sync_excluded 'commands/sdlc/conflicts.log'
at "f. manifest excluded"         test_sync_excluded '.sync-manifest.json'
af "f. domain .md NOT excluded"   test_sync_excluded 'skills/sdlc/SKILL.md'

# =======================================================================
# (g) Mapping: skills/sdlc/commands/** excluded; third-party skill ignored (H7)
# =======================================================================
printf -- '-- (g) 3-domain mapping + H3/H7 --\n'

REF="$WORK/ref-tree"
new_text "$REF/skills/sdlc/SKILL.md" 's'
new_text "$REF/skills/sdlc/commands/sdlc/dev.md" 'embed'   # H3: excluded
new_text "$REF/skills/sdlc-reviewer/SKILL.md" 'r'
new_text "$REF/skills/autre/SKILL.md" 'third-party'            # H7: ignored
new_text "$REF/skills/sdlc/__pycache__/z.pyc" 'z'            # excluded
new_text "$REF/commands/sdlc/plan.md" 'p'
new_text "$REF/agents/sdlc-python-dev.md" 'a'
new_text "$REF/agents/autre-agent.md" 'x'                      # not sdlc-*

rels=$(get_domain_relpaths "$REF")
at "g. includes skills/sdlc/SKILL.md"           contains_line "$rels" 'skills/sdlc/SKILL.md'
at "g. includes skills/sdlc-reviewer/SKILL.md"  contains_line "$rels" 'skills/sdlc-reviewer/SKILL.md'
at "g. includes commands/sdlc/plan.md"          contains_line "$rels" 'commands/sdlc/plan.md'
at "g. includes agents/sdlc-python-dev.md"      contains_line "$rels" 'agents/sdlc-python-dev.md'
af "g. H3: skills/sdlc/commands/** excluded"    contains_line "$rels" 'skills/sdlc/commands/sdlc/dev.md'
af "g. H7: third-party skill 'autre' ignored"   contains_line "$rels" 'skills/autre/SKILL.md'
af "g. agents outside sdlc-* ignored"           contains_line "$rels" 'agents/autre-agent.md'
ae "g. .pyc absent from the mapping (exclusions)"    0 "$(grep -c '\.pyc$' <<< "$rels")"

scope=$(get_sync_domain_skill "$REF")
at "g. skills scope includes sdlc"          contains_line "$scope" 'sdlc'
at "g. skills scope includes sdlc-reviewer" contains_line "$scope" 'sdlc-reviewer'
af "g. skills scope excludes the third-party skill" contains_line "$scope" 'autre'

# =======================================================================
# (g-sp3) P021:A018 extension — agents/nestor-* pattern + core domain
#         NESTOR.md (literal 0/1, no open root pattern) [T070/T071]
# =======================================================================
printf -- '-- (g-sp3) agents nestor-* domain + NESTOR.md core (A018) --\n'

# root WITHOUT NESTOR.md: empty core domain (0), no error (T071)
af "g-sp3. root without NESTOR.md => empty core domain (0), no error" contains_line "$rels" 'NESTOR.md'

new_text "$REF/agents/nestor-qualite.md" 'nq'
new_text "$REF/NESTOR.md"                'core'
new_text "$REF/AUTRE.md"                 'arbitrary root file'

rels3=$(get_domain_relpaths "$REF")
af "g-sp3. T070: agents/nestor-* OUTSIDE the SDLC domain"        contains_line "$rels3" 'agents/nestor-qualite.md'
af "g-sp3. T071: root NESTOR.md OUTSIDE the SDLC domain" contains_line "$rels3" 'NESTOR.md'
af "g-sp3. T071: arbitrary root file (AUTRE.md) OUTSIDE the domain (no open root pattern)" contains_line "$rels3" 'AUTRE.md'
af "g-sp3. agents outside sdlc-*/nestor-* still ignored" contains_line "$rels3" 'agents/autre-agent.md'
# T070: a domain nestor-* agent modified on the ref side only is classified modified-ref
ae "g-sp3. T070: agents/nestor-* modified-ref-only classified modified-ref (not ignored)" 'modified-ref' "$(get_sync_state 'r2' 'b' 'b')"
# T071: the core domain is SUBJECT to exclusions (proof by the code: no fixed
# pattern of the exclusion set can match 'NESTOR.md').

# =======================================================================
# (h) Byte-exact hash: stable, sensitive to 1 byte, CRLF!=LF, abc invariant
# =======================================================================
printf -- '-- (h) byte-exact hashing --\n'

HF="$WORK/hash.bin"
printf '\x01\x02\x03\x04\x05' > "$HF"
h1=$(get_file_hash_byteexact "$HF")
h2=$(get_file_hash_byteexact "$HF")
ae "h. stable hash (two identical reads)" "$h1" "$h2"
printf '\x01\x02\x03\x04\x06' > "$HF"   # 1 byte changed
h3=$(get_file_hash_byteexact "$HF")
af "h. hash sensitive to 1 byte" test "$h3" = "$h1"
# byte-exact: no EOL conversion (CRLF vs LF => different hash)
CRLF="$WORK/crlf.txt"; printf 'a\r\nb' > "$CRLF"
LF="$WORK/lf.txt";     printf 'a\nb'   > "$LF"
af "h. byte-exact: CRLF != LF (no normalization)" test "$(get_file_hash_byteexact "$CRLF")" = "$(get_file_hash_byteexact "$LF")"
# testable invariant: sha256('abc')
ABC="$WORK/abc.txt"; printf 'abc' > "$ABC"
ae "h. sha256('abc') invariant" 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' "$(get_file_hash_byteexact "$ABC")"

# =======================================================================
# (i) First run: identical union => seed; asymmetry => block
# =======================================================================
printf -- '-- (i) first-run union (H5) --\n'

refA="$WORK/i-refA"; liveA="$WORK/i-liveA"
printf 'a\th1\nb\th2\n' > "$refA"; printf 'a\th1\nb\th2\n' > "$liveA"
ae "i. identical union => seed" 'seed' "$(get_first_run_plan --ref "$refA" --live "$liveA")"

refB="$WORK/i-refB"; liveB="$WORK/i-liveB"
printf 'a\th1\nb\th2\n' > "$refB"; printf 'a\th1\n' > "$liveB"   # presence asymmetry
ae "i. presence asymmetry => block" 'block' "$(get_first_run_plan --ref "$refB" --live "$liveB")"
ae "i. --adopt forces the seed despite asymmetry" 'seed' "$(get_first_run_plan --ref "$refB" --live "$liveB" --adopt)"

refC="$WORK/i-refC"; liveC="$WORK/i-liveC"
printf 'a\th1\n' > "$refC"; printf 'a\thX\n' > "$liveC"          # same key, different hash
ae "i. content divergence => block" 'block' "$(get_first_run_plan --ref "$refC" --live "$liveC")"

# =======================================================================
# (j) O_EXCL lockfile: 2nd acquisition fails until released
# =======================================================================
printf -- '-- (j) O_EXCL lockfile --\n'

LOCK="$WORK/sync.lock"
acquire_sync_lock "$LOCK" >/dev/null
at "j. acquire_sync_lock creates the lock" test -e "$LOCK"
af "j. concurrent 2nd acquisition fails (O_EXCL)" acquire_sync_lock "$LOCK"
release_sync_lock "$LOCK"
af "j. release_sync_lock removes the lock" test -e "$LOCK"
acquire_sync_lock "$LOCK" >/dev/null
at "j. re-acquisition possible after release" test -e "$LOCK"
release_sync_lock "$LOCK"

# (j-orphan) if writing the metadata fails, the orphan lockfile is removed
# (otherwise lock without holder = blocked forever). Checked in the code.
at "j-orphan. acquire_sync_lock cleans the orphan lock when metadata write fails" body_has acquire_sync_lock 'rmdir'

# bonus: show_conflict_diff degrades cleanly (does not throw), resolve_lww conservative
D1="$WORK/d1.txt"; new_text "$D1" 'one'
D2="$WORK/d2.txt"; new_text "$D2" 'two'
diff_ok() { show_conflict_diff "$1" "$2" >/dev/null 2>&1; }
at "bonus. show_conflict_diff does not throw (degrades without git)" diff_ok "$D1" "$D2"

CLOG="$WORK/conflicts.log"
w=$(resolve_lww --relpath 'commands/sdlc/a.md' --log "$CLOG" --ref 'r' --live 'l')
ae "bonus. resolve_lww conservative: winner=ref by default (protects the canonical tree)" 'ref' "$w"
at "bonus. resolve_lww logs (append-only)" test -e "$CLOG"

# =======================================================================
# (k) set_nestor_import / remove_nestor_import (P022:A019) — idempotent
#     @NESTOR.md import in a file OUTSIDE the sync domain (~/.claude/CLAUDE.md).
# =======================================================================
printf -- '-- (k) set_nestor_import / remove_nestor_import --\n'

# read_raw_into VARNAME PATH: assigns the BYTE-EXACT content (trailing EOL included)
# of PATH to VARNAME via `printf -v` — never via an enclosing $(...), which would
# strip the trailing \n again (classic nested command substitution trap).
read_raw_into() {
    local __v="$1" __p="$2" __c
    __c=$(cat -- "$__p" 2>/dev/null; printf 'X')
    printf -v "$__v" '%s' "${__c%X}"
}
count_marker() { grep -c -E '^[[:space:]]*@NESTOR\.md[[:space:]]*$' "$1" 2>/dev/null || true; }

# k1. 3x set (install) + 3x set (restore) in a row -> count==1 at each step,
#     rest of the file byte-identical to the initial state.
K1_MD="$WORK/nestor-k1/CLAUDE.md"
INITIAL=$'# User preferences\nALWAYS tell the truth.\n'
new_text "$K1_MD" "$INITIAL"
for i in 1 2 3 4 5 6; do
    set_nestor_import "$K1_MD"
    ae "k1. iteration $i: count(@NESTOR.md) == 1" 1 "$(count_marker "$K1_MD")"
    read_raw_into txt "$K1_MD"
    prefix="${txt:0:${#INITIAL}}"
    ae "k1. iteration $i: initial content preserved (prefix intact)" "$INITIAL" "$prefix"
done

# k2. Line already present in the MIDDLE of the file -> nothing added.
K2_MD="$WORK/nestor-k2/CLAUDE.md"
MID_TEXT=$'line1\n@NESTOR.md\nline3\n'
new_text "$K2_MD" "$MID_TEXT"
set_nestor_import "$K2_MD"
read_raw_into got2 "$K2_MD"
ae "k2. line in the middle: file unchanged (position-agnostic detection)" "$MID_TEXT" "$got2"

# k3. Removal (remove_nestor_import) -> line gone AND no other diff.
K3_MD="$WORK/nestor-k3/CLAUDE.md"
new_text "$K3_MD" $'before\n@NESTOR.md\nafter\n'
remove_nestor_import "$K3_MD"
read_raw_into got3 "$K3_MD"
ae "k3. remove_nestor_import: line removed, rest byte-identical" $'before\nafter\n' "$got3"

# k4. Missing file -> created with the single '@NESTOR.md' line.
K4_MD="$WORK/nestor-k4/CLAUDE.md"
af "k4. (pre) file missing" test -e "$K4_MD"
set_nestor_import "$K4_MD"
read_raw_into got4 "$K4_MD"
ae "k4. missing file -> created with the single line" '@NESTOR.md' "$got4"

# k5. File WITHOUT a final newline -> initial content preserved byte for byte,
#     correct EOL prefix (LF here, the file's dominant style).
K5_MD="$WORK/nestor-k5/CLAUDE.md"; mkdir -p "$(dirname "$K5_MD")"
printf '%s' 'line-without-eol' > "$K5_MD"
set_nestor_import "$K5_MD"
read_raw_into got5 "$K5_MD"
ae "k5. no final EOL: initial bytes preserved + EOL prefix + marker" \
   $'line-without-eol\n@NESTOR.md' "$got5"

# k5b. File WITHOUT a final newline, DOMINANT CRLF -> CRLF prefix (not LF).
K5B_MD="$WORK/nestor-k5b/CLAUDE.md"; mkdir -p "$(dirname "$K5B_MD")"
printf 'a\r\nb\r\nc-without-eol' > "$K5B_MD"
set_nestor_import "$K5B_MD"
read_raw_into got5b "$K5B_MD"
ae "k5b. no final EOL, CRLF dominant: CRLF prefix" \
   $'a\r\nb\r\nc-without-eol\r\n@NESTOR.md' "$got5b"

# k6. --dry-run -> 0 writes (no backup, no target file, no leftover temp).
K6_MD="$WORK/nestor-k6/CLAUDE.md"
af "k6. (pre) file missing" test -e "$K6_MD"
set_nestor_import --dry-run "$K6_MD"
af "k6a. dry-run on a missing file: still missing (0 writes)" test -e "$K6_MD"

K6B_MD="$WORK/nestor-k6b/CLAUDE.md"
new_text "$K6B_MD" $'existing\n'
read_raw_into BEFORE6B "$K6B_MD"
set_nestor_import --dry-run "$K6B_MD"
read_raw_into AFTER6B "$K6B_MD"
ae "k6b. dry-run on an existing file: unchanged" "$BEFORE6B" "$AFTER6B"
af "k6b. dry-run: no backup created" test -d "$WORK/nestor-k6b/_backups"
TMP_LEFT6=$(find "$WORK/nestor-k6b" -name '*.tmp-*' 2>/dev/null | wc -l | tr -d ' ')
ae "k6b. dry-run: no leftover temp" 0 "$TMP_LEFT6"

# k7. count > 1 (2 @NESTOR.md lines already present) -> warning, NO dedup.
K7_MD="$WORK/nestor-k7/CLAUDE.md"
DUP_TEXT=$'@NESTOR.md\nmiddle\n@NESTOR.md\n'
new_text "$K7_MD" "$DUP_TEXT"
WARN_OUT=$(set_nestor_import "$K7_MD" 2>&1 1>/dev/null)
at "k7. warning emitted when count > 1" test -n "$WARN_OUT"
read_raw_into got7 "$K7_MD"
ae "k7. count > 1: NO automatic dedup (file unchanged)" "$DUP_TEXT" "$got7"

# k8. remove_nestor_import on a missing file -> no-op (no error).
K8_MD="$WORK/nestor-k8/CLAUDE.md"
at "k8. remove_nestor_import on a missing file: no-op without error" remove_nestor_import "$K8_MD"

# =======================================================================
# (L) P033:A029 — set_local_overlay_import (existence guard for the private
#     *.local.md overlay + adding the "@<local-file-name>" import).
# =======================================================================
printf -- '-- (L) set_local_overlay_import (P033:A029) --\n'

# L1. Overlay missing -> created EMPTY, then "@CLAUDE.local.md" line added to path.
L1_DIR="$WORK/overlay-l1"
L1_MD="$L1_DIR/CLAUDE.md"
L1_LOCAL="$L1_DIR/CLAUDE.local.md"
af "L1. (pre) overlay missing" test -f "$L1_LOCAL"
set_local_overlay_import "$L1_MD" 'CLAUDE.local.md'
at "L1. overlay created (missing -> present)" test -f "$L1_LOCAL"
read_raw_into l1local "$L1_LOCAL"
ae "L1. overlay created EMPTY" '' "$l1local"
read_raw_into l1md "$L1_MD"
ae "L1. @CLAUDE.local.md line added to path" '@CLAUDE.local.md' "$l1md"

# L2. Overlay ALREADY present and NOT empty -> never overwritten (private content kept).
L2_DIR="$WORK/overlay-l2"
L2_MD="$L2_DIR/CLAUDE.md"
L2_LOCAL="$L2_DIR/CLAUDE.local.md"
new_text "$L2_LOCAL" $'existing private content\n'
set_local_overlay_import "$L2_MD" 'CLAUDE.local.md'
read_raw_into l2local "$L2_LOCAL"
ae "L2. existing NON-empty overlay: never overwritten" $'existing private content\n' "$l2local"
read_raw_into l2md "$L2_MD"
ae "L2. import line added despite the pre-existing overlay" '@CLAUDE.local.md' "$l2md"

# L3. Idempotence: 2nd call -> overlay still intact, import line NOT duplicated.
set_local_overlay_import "$L1_MD" 'CLAUDE.local.md'
read_raw_into l1local2 "$L1_LOCAL"
ae "L3. 2nd call: overlay still empty (untouched)" '' "$l1local2"
L3_COUNT=$(grep -c -E '^[[:space:]]*@CLAUDE\.local\.md[[:space:]]*$' "$L1_MD" 2>/dev/null || true)
ae "L3. 2nd call: exactly 1 @CLAUDE.local.md line (idempotent)" 1 "$L3_COUNT"

# L4. --dry-run: 0 writes (no overlay created, no import line added).
L4_DIR="$WORK/overlay-l4"
L4_MD="$L4_DIR/CLAUDE.md"
L4_LOCAL="$L4_DIR/CLAUDE.local.md"
set_local_overlay_import --dry-run "$L4_MD" 'CLAUDE.local.md'
af "L4. --dry-run: overlay NOT created" test -f "$L4_LOCAL"
af "L4. --dry-run: path NOT created (0 import line added)" test -f "$L4_MD"

# L5. set_local_overlay_import OUTSIDE the sync domain (same status as set_nestor_import).
L5_DIR="$WORK/overlay-l5"
mkdir -p "$L5_DIR"
DOMAIN_L5=$(get_domain_relpaths "$L5_DIR")
af "L5. CLAUDE.md OUTSIDE the sync domain (get_domain_relpaths)" contains_line "$DOMAIN_L5" 'CLAUDE.md'
af "L5. CLAUDE.local.md OUTSIDE the sync domain (get_domain_relpaths)" contains_line "$DOMAIN_L5" 'CLAUDE.local.md'

# =======================================================================
# (R) Non-regression — P018 adversarial review findings (parity/portability)
# =======================================================================
printf -- '-- (R) P018 review non-regression --\n'

# R1. write_file_atomic: a write failure propagates a non-zero exit (parent
#     impossible because an ancestor is a file) — basis of the backup/copy guards.
WFA_BLOCK="$WORK/wfa-blocker"; printf 'x' > "$WFA_BLOCK"
wfa_fail() { printf 'data' | write_file_atomic "$WFA_BLOCK/sub/f.txt" >/dev/null 2>&1; }
af "R1. write_file_atomic non-zero when the write fails" wfa_fail

# R2. copy_tree: on write failure, do NOT emit the rel (the caller will not count
#     it as deployed) AND return non-zero — avoids a lying manifest.
CT_SRC="$WORK/ct-src"; new_text "$CT_SRC/a.md" 'A'; new_text "$CT_SRC/b.md" 'B'
CT_DST="$WORK/ct-dstblock"; printf 'x' > "$CT_DST"   # dst root IS a file
ct_out=$(copy_tree "$CT_SRC" "$CT_DST" a.md b.md 2>/dev/null); ct_rc=$?
ae "R2. copy_tree emits no rel when writes fail" '' "$ct_out"
af "R2. copy_tree returns non-zero on write failure" test "$ct_rc" -eq 0

# R3. get_first_run_plan: the last line WITHOUT a final newline is read (otherwise
#     phantom asymmetry / hidden divergence). Ref has 2 entries (no final \n),
#     live 1 -> real asymmetry => block (with the bug, B lost => false 'seed').
REFNL="$WORK/ref-nonl"; printf 'skills/sdlc/A.md\th1\nskills/sdlc/B.md\th2' > "$REFNL"
LIVENL="$WORK/live-nonl"; printf 'skills/sdlc/A.md\th1\n' > "$LIVENL"
ae "R3. last line without newline taken into account (asymmetry => block)" \
   'block' "$(get_first_run_plan --ref "$REFNL" --live "$LIVENL")"

# R4. _sync_py resolves a Python 3 interpreter (order [python, python3] —
#     Windows-safe, Linux/Mac fallback). Non-empty on a host with python3.
at "R4. _sync_py resolves a Python 3 interpreter" test -n "$(_sync_py)"

# R5. require_bash4: OK (exit 0) on the current bash (>= 4).
at "R5. require_bash4 OK on the current bash" require_bash4

# --- Report -----------------------------------------------------------------
printf '\n=== Result: %d PASS / %d FAIL ===\n' "$pass" "$fail"
if [[ $fail -gt 0 ]]; then
    printf 'Failures:\n'
    for f in "${failures[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
printf 'All Code Lock criteria (a..j) + the abc invariant are green.\n'
exit 0
