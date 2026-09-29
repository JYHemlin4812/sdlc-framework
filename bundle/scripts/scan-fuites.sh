#!/usr/bin/env bash
# scan-fuites.sh - Leak scan ("scan-fuites" in French) for PII / private data, read-only (P045:A044,A048).
#
# BASH port with behavior identical to scan-fuites.ps1 (the shipped/tested reference).
# Detects leftover private paths, emails and version markers in the working tree
# AND in 3 key revisions of the git history, before the repository is made public.
# READ-ONLY BY DESIGN: the only file written is the report given as output
# (--report-path).
#
# Two pattern levels (never mixed):
#   - Level 1 - EMBEDDED here, FROZEN, not person-specific (get_fuites_level1_patterns):
#       * generic Windows profile path   : [A-Za-z]:\Users\...
#       * generic email address          : local@domain.tld
#       * version marker 'sdlcv2' (detection only, case-insensitive)
#       * version marker 'sdlcv3' (detection only, case-insensitive)
#     No person-specific pattern is ever added here (safeguard R-Q1): any specific
#     rule goes through level 2 only.
#   - Level 2 - OPTIONAL, external file SDLC_PM/scan-fuites-motifs.txt (path
#     RELATIVE to the repository root, never absolute), one regex per line, empty
#     lines and '#' comments ignored. INTERNAL zone (SDLC_PM/): this file may
#     legitimately contain private tokens and is never itself reported in the
#     public zone. If missing, the report says so at the top ("generic mode only")
#     and the script carries on normally - never a failure, never silent about it.
#
# Zoning (fail-safe, A044):
#   - Candidate public zone (zero tolerance): EVERY path that is NOT explicitly
#     classified as internal (includes claude/, bundle/, .github/, root files, and
#     any unlisted folder).
#   - Internal zone (informational counts ONLY): SDLC_PM/, nestor/.
#
# History probe (3 revisions, same patterns, no checkout - git grep on a
# tree-ish):
#   (a) root commit            : git rev-list --max-parents=0 HEAD
#   (b) last commit before SP4 : parent of the first commit whose message matches 'SP4'
#   (c) HEAD
# Any hit on (a) or (b) feeds the history verdict (contamination expected by
# construction, see F5).
#
# Reuses sync-lib.sh (single source): get_sync_exclusion, write_file_atomic -
# same helpers as install.sh/capture.sh/restore.sh. (sync-lib's get_rel_path /
# test_sync_excluded fork `tr`/`cat` on every call: too costly here on hundreds of
# files under Git-Bash/MSYS - see the perf note on invoke_fuites_tree_scan - so
# they are replaced by a local pure-bash equivalent, patterns loaded once.)
#
# Exit codes: REPORTING TOOL, not a gate - a scan that RUNS to the end (report
# written) is a SUCCESS, even if it finds hits in the public zone (finding them
# is the tool's purpose; blocking a public release is the job of an upstream
# gate, P051, which READS the report). A missing level-2 pattern file is NEVER a
# cause of a non-zero exit.
#   0 = scan complete, report written (with or without hits).
#   2 = precheck: repo-root not found or sync-lib.sh not found.
#
# Usage:
#   ./scan-fuites.sh
#   ./scan-fuites.sh --repo-root DIR --motifs-path FILE --report-path FILE

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# --- Shared foundation (single source) ---
SYNC_LIB="$SCRIPT_DIR/sync-lib.sh"
if [[ ! -f "$SYNC_LIB" ]]; then
    printf '  [ERR] sync-lib.sh not found next to scan-fuites.sh: %s\n' "$SYNC_LIB" >&2
    exit 2
fi
# shellcheck source=/dev/null
. "$SYNC_LIB"

# --- Display helpers (console progress - same style as install.sh) ---
if [[ -t 1 ]]; then
    C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'; C_GRAY=$'\033[90m'; C_RESET=$'\033[0m'
else
    C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GRAY=""; C_RESET=""
fi
_bar="======================================================================"
write_header() { printf '\n%s%s\n  %s\n%s%s\n' "$C_CYAN" "$_bar" "$1" "$_bar" "$C_RESET"; }
write_step()   { printf '  %s- %s%s\n' "$C_GRAY" "$1" "$C_RESET"; }
write_ok()     { printf '  %s[OK] %s%s\n' "$C_GREEN" "$1" "$C_RESET"; }
write_warn()   { printf '  %s[WARN] %s%s\n' "$C_YELLOW" "$1" "$C_RESET"; }
write_err()    { printf '  %s[ERR] %s%s\n' "$C_RED" "$1" "$C_RESET" >&2; }

# --- Level-1 patterns: FROZEN here, not person-specific (see 3_conception.md P045) ---
# Heredoc with a QUOTED delimiter ('EOF'): no escaping needed, backslashes and
# quotes are literal. Emits "label<TAB>pattern" per line.
get_fuites_level1_patterns() {
    cat <<'EOF'
windows-profile-path	[A-Za-z]:\\Users\\[^\\ "']+
generic-email	[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}
sdlcv2	sdlcv2
sdlcv3	sdlcv3
EOF
}

# --- Level-2 patterns: optional, one regex per line, '#'/empty lines ignored ---
get_fuites_level2_patterns() {
    local path="$1"
    [[ -f "$path" ]] || return 0
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        local t="${line#"${line%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
        [[ -z "$t" ]] && continue
        [[ "$t" == \#* ]] && continue
        printf 'level2\t%s\n' "$t"
    done < "$path"
}

# --- Fail-safe zoning (A044): internal = SDLC_PM/ or nestor/, otherwise public ---
# Canonical definition (documentation/tests). The hot loop of
# invoke_fuites_tree_scan REPRODUCES this same `case` INLINE (no call to this
# function through $(...) per file) to avoid a needless fork - see its perf note.
get_fuites_zone() {
    local rel="$1"
    case "$rel" in
        SDLC_PM/*|nestor/*) printf 'internal' ;;
        *) printf 'public' ;;
    esac
}

# ponytail: the scanner excludes itself. Its own sources EMBED the level-1
# pattern catalog in clear text (the words 'sdlcv2'/'sdlcv3', the email pattern
# text) - a self-match is therefore guaranteed and is NOT a leak (no
# person-specific token, just the code documenting itself). Exclusion LIMITED to
# these 2 files (no whole folder) - Code Lock P045.
get_fuites_is_self() {
    case "$1" in
        bundle/scripts/scan-fuites.ps1|bundle/scripts/scan-fuites.sh) return 0 ;;
        *) return 1 ;;
    esac
}

# ponytail: exclusions LOADED once (a single `cat` fork, via get_sync_exclusion)
# then tested in PURE bash (no subprocess per file). sync-lib's
# get_rel_path/test_sync_excluded fork `tr` (x2) and `cat` ON EVERY CALL: on
# ~250-650 files under Git-Bash/MSYS (Windows forks are very costly) this
# measurably stalled the scan indefinitely (300 get_rel_path calls alone: > 30s,
# never finished). The replacement below gives the SAME result (same exclusion
# set, same predicate) without ever forking per file.
declare -a _FUITES_EXCL_DIRS=() _FUITES_EXCL_FILES=() _FUITES_EXCL_NAMES=()
_fuites_load_exclusions() {
    _FUITES_EXCL_DIRS=(); _FUITES_EXCL_FILES=(); _FUITES_EXCL_NAMES=()
    local kind pat
    while IFS=$'\t' read -r kind pat; do
        case "$kind" in
            dir)  _FUITES_EXCL_DIRS+=("$pat") ;;
            file) _FUITES_EXCL_FILES+=("$pat") ;;
            name) _FUITES_EXCL_NAMES+=("$pat") ;;
        esac
    done < <(get_sync_exclusion)
}

_fuites_is_excluded() {
    # Pure bash: mirror of test_sync_excluded (sync-lib), patterns preloaded.
    local rel="$1"
    [[ -z "$rel" ]] && return 1
    local leaf="${rel##*/}"
    local -a segs; IFS='/' read -ra segs <<< "$rel"
    local seg pat
    for seg in "${segs[@]}"; do
        for pat in "${_FUITES_EXCL_DIRS[@]}"; do
            [[ "$seg" == "$pat" ]] && return 0
        done
    done
    for pat in "${_FUITES_EXCL_FILES[@]}"; do
        case "$leaf" in $pat) return 0 ;; esac
    done
    for pat in "${_FUITES_EXCL_NAMES[@]}"; do
        [[ "$leaf" == "$pat" ]] && return 0
    done
    return 1
}

# --- Exhaustive enumeration of the working tree, excluding .git/ and known noise ---
get_fuites_file_list() {
    local root="$1"
    _fuites_load_exclusions
    local f rel
    while IFS= read -r f; do
        # Parameter expansion (pure bash) instead of get_rel_path: $f ALWAYS
        # shares the same literal $root prefix (produced by `find "$root"`), so
        # sync-lib's case-insensitive normalization is not needed here.
        rel="${f#"$root"/}"
        case "$rel" in .git|.git/*) continue ;; esac
        _fuites_is_excluded "$rel" && continue
        get_fuites_is_self "$rel" && continue
        printf '%s\n' "$rel"
    done < <(find "$root" -type f 2>/dev/null) | LC_ALL=C sort
}

# --- Working-tree scan: public hits (detailed) + internal counts (aggregated) ---
# Output globals: FUITES_PUBLIC_HITS (array of "file:line:pattern"),
# FUITES_INTERNAL_FILES (array of files with hits),
# FUITES_INTERNAL_COUNTS (associative file -> count).
#
# ponytail: ONE `grep` per file (all patterns combined with repeated -e), the
# pattern label is assigned AFTERWARDS in memory with bash's builtin regex (`=~`,
# no subprocess). One `grep` PER (file x pattern) - the initial version -
# spawned ~250 files x ~6 patterns x 2 passes ~= 3000 processes: under
# Git-Bash/MSYS (costly forks on Windows) this went far past the budget of an
# interactive scan (measured: 90s timeout, never finished). `grep -I` also acts
# as the binary detector (a binary file never matches -> skipped silently, no
# separate detection step).
invoke_fuites_tree_scan() {
    local root="$1"; shift
    local -a rel_paths=("$@")
    FUITES_PUBLIC_HITS=()
    FUITES_INTERNAL_FILES=()
    declare -gA FUITES_INTERNAL_COUNTS=()

    local -a pat_labels=() pat_patterns=() grep_args=(-n -I -i -E)
    local label pattern
    while IFS=$'\t' read -r label pattern; do
        [[ -n "$pattern" ]] || continue
        pat_labels+=("$label"); pat_patterns+=("$pattern")
        grep_args+=(-e "$pattern")
    done < <(_fuites_all_patterns)

    # nocasematch: `=~` is case-sensitive by default; aligned with the grep -i
    # above (and with -like, case-insensitive by default in PowerShell).
    # The previous state is saved and restored (function scope).
    local restore_nocasematch=0
    shopt -q nocasematch || restore_nocasematch=1
    shopt -s nocasematch

    local rel full zone out lineno content i n
    for rel in "${rel_paths[@]}"; do
        full="$root/$rel"
        out=$(grep "${grep_args[@]}" -- "$full" 2>/dev/null)
        [[ -z "$out" ]] && continue
        # Inline zoning (no call to get_fuites_zone through $(...) here): avoids
        # one more fork per file in this hot loop.
        case "$rel" in
            SDLC_PM/*|nestor/*) zone=internal ;;
            *) zone=public ;;
        esac
        if [[ "$zone" == "public" ]]; then
            while IFS=: read -r lineno content; do
                [[ -n "$lineno" ]] || continue
                for i in "${!pat_patterns[@]}"; do
                    if [[ "$content" =~ ${pat_patterns[$i]} ]]; then
                        FUITES_PUBLIC_HITS+=("$rel:$lineno:${pat_labels[$i]}")
                    fi
                done
            done <<< "$out"
        else
            n=$(printf '%s\n' "$out" | grep -c . || true)
            if [[ "$n" -gt 0 ]]; then
                FUITES_INTERNAL_FILES+=("$rel")
                FUITES_INTERNAL_COUNTS["$rel"]=$n
            fi
        fi
    done

    [[ "$restore_nocasematch" -eq 1 ]] && shopt -u nocasematch
    return 0
}

# --- History probe: git grep on a tree-ish, no checkout ---------------------
# invoke_fuites_revision_grep <root> <revision> -> sets the count of matching
# lines; VR_GREP_AVAILABLE=1/0 (globals). One -e per pattern (never a
# concatenated alternation): avoids any shell escaping issue.
invoke_fuites_revision_grep() {
    local root="$1" revision="$2"
    local -a git_args=(-C "$root" grep -n -I -i -E)
    local label pattern
    while IFS=$'\t' read -r label pattern; do
        [[ -n "$pattern" ]] || continue
        git_args+=(-e "$pattern")
    done < <(_fuites_all_patterns)
    git_args+=("$revision")
    local out code
    out=$(git "${git_args[@]}" 2>/dev/null)
    code=$?
    if [[ "$code" -eq 0 ]]; then
        VR_GREP_AVAILABLE=1
        VR_GREP_COUNT=$(printf '%s\n' "$out" | grep -c . || true)
    elif [[ "$code" -eq 1 ]]; then
        VR_GREP_AVAILABLE=1
        VR_GREP_COUNT=0
    else
        VR_GREP_AVAILABLE=0
        VR_GREP_COUNT=0
    fi
}

# --- Resolve the 3 key revisions (a)/(b)/(c) --------------------------------
# Emits 3 lines "id\tlabel\thash" (empty hash if unavailable).
get_fuites_history_revisions() {
    local root="$1"
    command -v git >/dev/null 2>&1 || return 0
    local root_hash sp4_hash sp4_parent head_hash
    root_hash=$(git -C "$root" rev-list --max-parents=0 HEAD 2>/dev/null | head -n1)
    sp4_hash=$(git -C "$root" log --reverse --grep=SP4 --format=%H 2>/dev/null | head -n1)
    sp4_parent=""
    if [[ -n "$sp4_hash" ]]; then
        sp4_parent=$(git -C "$root" log -1 --format=%P "$sp4_hash" 2>/dev/null | awk '{print $1}')
    fi
    head_hash=$(git -C "$root" rev-parse HEAD 2>/dev/null)
    printf 'a\trepository root commit\t%s\n' "$root_hash"
    printf 'b\tlast commit before SP4\t%s\n' "$sp4_parent"
    printf 'c\tHEAD\t%s\n' "$head_hash"
}

# --- helper: emits all patterns (level 1 + current level 2) -----------------
_fuites_all_patterns() {
    get_fuites_level1_patterns
    [[ -n "${FUITES_MOTIFS_PATH:-}" ]] && get_fuites_level2_patterns "$FUITES_MOTIFS_PATH"
}

# ===========================================================================
# Core: invoke_scan_fuites <repo_root> <motifs_path> <report_path>
# ===========================================================================
invoke_scan_fuites() {
    local RepoRoot="$1" MotifsPath="$2" ReportPath="$3"

    write_header "Leak scan - read-only (P045)"

    local resolved
    resolved=$(realpath "$RepoRoot" 2>/dev/null) || resolved=""
    if [[ -z "$resolved" || ! -d "$resolved" ]]; then
        write_err "RepoRoot not found: $RepoRoot"
        return 2
    fi
    RepoRoot="$resolved"

    [[ -n "$MotifsPath" ]] || MotifsPath="$RepoRoot/SDLC_PM/scan-fuites-motifs.txt"
    [[ -n "$ReportPath" ]] || ReportPath="$RepoRoot/SDLC_PM/SP6-productisation/rapport-scan-fuites-$(date +%Y-%m-%d).md"
    FUITES_MOTIFS_PATH="$MotifsPath"

    local level2_present=0 level2_count=0
    if [[ -f "$MotifsPath" ]]; then
        level2_present=1
        level2_count=$(get_fuites_level2_patterns "$MotifsPath" | grep -c . || true)
        write_ok "Level-2 patterns: $level2_count loaded from $MotifsPath"
    else
        write_warn "Level-2 patterns missing ($MotifsPath) - generic mode only."
    fi

    write_step "Enumerating the working tree (excluding .git/)"
    local -a files=()
    mapfile -t files < <(get_fuites_file_list "$RepoRoot")
    write_step "${#files[@]} candidate file(s)"

    invoke_fuites_tree_scan "$RepoRoot" "${files[@]}"
    write_ok "Public zone   : ${#FUITES_PUBLIC_HITS[@]} hit(s)"
    write_ok "Internal zone : ${#FUITES_INTERNAL_FILES[@]} file(s) with hits"

    write_step "History probe (3 revisions)"
    local git_available=0
    command -v git >/dev/null 2>&1 && git_available=1
    local -a hist_ids=() hist_labels=() hist_hashes=() hist_avail=() hist_counts=()
    local history_contaminated=0
    if [[ "$git_available" -eq 1 ]]; then
        local id label hash
        while IFS=$'\t' read -r id label hash; do
            hist_ids+=("$id"); hist_labels+=("$label"); hist_hashes+=("$hash")
            if [[ -z "$hash" ]]; then
                hist_avail+=(0); hist_counts+=(0)
                continue
            fi
            invoke_fuites_revision_grep "$RepoRoot" "$hash"
            hist_avail+=("$VR_GREP_AVAILABLE"); hist_counts+=("$VR_GREP_COUNT")
            if [[ ( "$id" == "a" || "$id" == "b" ) && "$VR_GREP_AVAILABLE" -eq 1 && "$VR_GREP_COUNT" -gt 0 ]]; then
                history_contaminated=1
            fi
        done < <(get_fuites_history_revisions "$RepoRoot")
    fi
    if [[ "$history_contaminated" -eq 1 ]]; then
        write_ok "History: contaminated (expected, see F5)"
    else
        write_ok "History: clean on the probed sample"
    fi

    # --- Report ---
    {
        printf '# Leak scan report - sdlc-framework\n\n'
        if [[ "$level2_present" -eq 1 ]]; then
            printf '**Level-2 patterns**: loaded from `%s` (%s pattern(s)).\n\n' "$MotifsPath" "$level2_count"
        else
            printf '**Generic mode only** - `%s` missing: only the 4 embedded level-1 patterns are applied. Not a failure: normal run.\n\n' "$MotifsPath"
        fi
        printf '**Date**: %s\n' "$(date +%Y-%m-%d)"
        printf '**Scanned root**: `%s`\n\n' "$RepoRoot"

        printf '## Candidate public zone (zero tolerance)\n\n'
        if [[ ${#FUITES_PUBLIC_HITS[@]} -eq 0 ]]; then
            printf 'No hits.\n\n'
        else
            printf '%s hit(s) found:\n\n' "${#FUITES_PUBLIC_HITS[@]}"
            local h
            for h in "${FUITES_PUBLIC_HITS[@]}"; do printf -- '- `%s`\n' "$h"; done
            printf '\n'
        fi

        printf '## Internal zone (informational counts - no zero tolerance)\n\n'
        if [[ ${#FUITES_INTERNAL_FILES[@]} -eq 0 ]]; then
            printf 'No hits.\n\n'
        else
            local k
            for k in "${FUITES_INTERNAL_FILES[@]}"; do
                printf -- '- `%s`: %s hit(s)\n' "$k" "${FUITES_INTERNAL_COUNTS[$k]}"
            done
            printf '\n'
        fi

        printf '## History probe (3 key revisions)\n\n'
        if [[ "$git_available" -ne 1 ]]; then
            printf 'git unavailable or repository inaccessible - probe not run.\n\n'
        else
            printf '| Revision | Hash | Hits |\n|---|---|---|\n'
            local i hashdisp countdisp
            for i in "${!hist_ids[@]}"; do
                hashdisp="${hist_hashes[$i]:-(unavailable)}"
                if [[ "${hist_avail[$i]}" -eq 1 ]]; then countdisp="${hist_counts[$i]}"; else countdisp="unavailable"; fi
                printf '| (%s) %s | `%s` | %s |\n' "${hist_ids[$i]}" "${hist_labels[$i]}" "$hashdisp" "$countdisp"
            done
            printf '\n'
        fi
        if [[ "$history_contaminated" -eq 1 ]]; then
            printf '**History verdict**: history contaminated: any public release requires a squash/new repository or a filter-repo.\n\n'
        else
            printf '**History verdict**: no hits on the probed revisions (a)/(b) - history clean on this sample (no guarantee for the unprobed intermediate revisions, nor when the git probe is unavailable).\n\n'
        fi
    } | write_file_atomic "$ReportPath" >/dev/null
    write_ok "Report written: $ReportPath"

    write_header "Scan complete"
    if [[ ${#FUITES_PUBLIC_HITS[@]} -gt 0 ]]; then
        write_warn "${#FUITES_PUBLIC_HITS[@]} hit(s) in the public zone - see the report."
    else
        write_ok "0 hits in the public zone."
    fi
    # Reporting tool (not a gate): the scan SUCCEEDED as soon as the report is
    # written, whether or not hits were found (see exit codes at the top).
    return 0
}

# --- Auto-run (script) - skipped when sourced (tests) ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    REPO_ROOT="$SCRIPT_DIR/../.."
    MOTIFS_PATH=""
    REPORT_PATH=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo-root)    REPO_ROOT="$2"; shift 2 ;;
            --motifs-path)  MOTIFS_PATH="$2"; shift 2 ;;
            --report-path)  REPORT_PATH="$2"; shift 2 ;;
            -h|--help)      grep -E '^# ' "$0" | sed 's/^# \?//'; exit 0 ;;
            *)              write_err "Unknown option: $1"; exit 2 ;;
        esac
    done
    invoke_scan_fuites "$REPO_ROOT" "$MOTIFS_PATH" "$REPORT_PATH"
    exit $?
fi
