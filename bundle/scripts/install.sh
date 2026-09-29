#!/usr/bin/env bash
# install.sh — SDLC system installer v3.2, disaster-recovery bootstrap (P018:A014).
#
# BASH port with identical behavior of install.ps1 (the shipped/tested reference).
# Deploys the sdlc* skills + commands/sdlc slash commands + sdlc-* agents of the
# canonical REF (repo sdlc-framework/claude/) to the LIVE install (~/.claude/).
#
# Bootstrap = SUBSET of restore: on an empty live install (or on upgrade), deploys the
# canonical greenlist get_domain_relpaths(claude/) through STAGING + ATOMIC SWAP
# (copy_tree/write_file_atomic from sync-lib — NEVER a destructive mirror), takes a
# timestamped backup before replacing, then runs a CLASSIFIED verify.sh POST-CHECK (subprocess).
#
# Reuses sync-lib.sh (single source A002/A004): get_domain_relpaths (greenlist),
# get_sync_domain_skill (DERIVED skills H7), copy_tree/write_file_atomic (atomic),
# get_file_hash_byteexact (byte-exact idempotence checksum), acquire/release_sync_lock.
#
# Cardinalities (skills/agents/commands) and checksum are DERIVED from disk, never literals.
#
# Exit codes (same as install.ps1):
#   0 = ok (deployed, already up to date, dry-run)
#   2 = prechecks: source/skills/commands not found or empty greenlist
#   3 = third-party skill guard (target SKILL.md not sdlc* OR unreadable name: = fail-closed)
#   7 = real DRIFT in the post-check (MISSING/HASH DIFF against a CLEAN REF tree)
#
# Usage:
#   ./install.sh                                   # standard install (~/.claude)
#   ./install.sh --dry-run                         # simulation (0 writes)
#   ./install.sh --force --no-backup               # reinstall without backup
#   ./install.sh --source-root DIR --claude-root DIR
#   ./install.sh --remove-import                   # only remove '@NESTOR.md' from CLAUDE.md

# ponytail: `set -uo pipefail` WITHOUT -e — many commands legitimately exit
# != 0 (verify, grep -c, git status outside a repo, acquire_sync_lock);
# return codes are propagated explicitly with `return N` (mirror of install.ps1).
set -uo pipefail

VERSION="3.2.0"
COMMANDS_NS="sdlc"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# --- Shared foundation (single source A002/A004) ---
# shellcheck source=/dev/null
. "$SCRIPT_DIR/sync-lib.sh"

# --- Display helpers ---
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

# --- get_skill_name: `name:` frontmatter field of a SKILL.md (third-party guard) ---
get_skill_name() {
    local skill_md="$1"
    [[ -f "$skill_md" ]] || { printf ''; return 0; }
    head -n 30 "$skill_md" | awk '
        /^---[[:space:]]*$/ { if (in_front) exit; in_front=1; next }
        in_front && /^name:[[:space:]]*[^[:space:]]/ {
            sub(/^name:[[:space:]]*/, ""); sub(/[[:space:]].*$/, ""); print; exit
        }'
}

# --- get_greenlist_checksum: BYTE-EXACT aggregate checksum of the greenlist ---
# (single source get_file_hash_byteexact, CRLF != LF). Takes root + relPaths (args).
get_greenlist_checksum() {
    local root="$1"; shift
    local rel full h out
    out=$(
        printf '%s\n' "$@" | LC_ALL=C sort | while IFS= read -r rel; do
            [[ -n "$rel" ]] || continue
            full="$root/$rel"
            [[ -f "$full" ]] || continue
            h=$(get_file_hash_byteexact "$full")
            printf '%s:%s\n' "$rel" "$h"
        done | sha256sum
    )
    printf '%s' "${out%% *}"
}

# --- invoke_verify_post_check: runs verify.sh (read-only subprocess) and CLASSIFIES ---
# Sets the globals VR_CODE / VR_MISSING / VR_HASHDIFF / VR_SURPLUS / VR_CARDDRIFT /
# VR_HASMARKERS. Missing verify.sh => unavailable (code 2, no marker), like the .ps1.
invoke_verify_post_check() {
    local repo_root="$1" live_target="$2"
    VR_CODE=2; VR_MISSING=0; VR_HASHDIFF=0; VR_SURPLUS=0; VR_CARDDRIFT=0; VR_HASMARKERS=0
    local verify_script="$SCRIPT_DIR/verify.sh"
    [[ -f "$verify_script" ]] || return 0
    local out code
    out=$(bash "$verify_script" --ref-root "$repo_root" --live-root "$live_target" 2>&1)
    code=$?
    VR_CODE=$code
    VR_MISSING=$(printf '%s\n' "$out" | grep -c '\[MISSING\]'); VR_MISSING=${VR_MISSING//[^0-9]/}
    VR_HASHDIFF=$(printf '%s\n' "$out" | grep -c '\[HASH DIFF\]'); VR_HASHDIFF=${VR_HASHDIFF//[^0-9]/}
    VR_SURPLUS=$(printf '%s\n' "$out" | grep -c '\[EXTRA\]'); VR_SURPLUS=${VR_SURPLUS//[^0-9]/}
    VR_CARDDRIFT=$(printf '%s\n' "$out" | grep -c '\[FLOOR\]'); VR_CARDDRIFT=${VR_CARDDRIFT//[^0-9]/}
    if (( VR_MISSING + VR_HASHDIFF + VR_SURPLUS + VR_CARDDRIFT > 0 )); then VR_HASMARKERS=1; fi
    return 0
}

# --- test_ref_worktree_dirty: true if git is available AND the claude/ REF tree has ---
# uncommitted changes (worktree != HEAD). git missing / outside a repo => false (unavailable).
test_ref_worktree_dirty() {
    local repo_root="$1"
    command -v git >/dev/null 2>&1 || return 1
    local out code
    out=$(git -C "$repo_root" status --porcelain -- claude 2>/dev/null)
    code=$?
    [[ $code -eq 0 ]] || return 1
    [[ -n "${out//[[:space:]]/}" ]]
}

# --- cleanup (staging + lock) via trap EXIT ---
_INSTALL_LOCK=""
_INSTALL_STAGING=""
_install_cleanup() {
    [[ -n "$_INSTALL_STAGING" && -d "$_INSTALL_STAGING" ]] && rm -rf "$_INSTALL_STAGING"
    [[ -n "$_INSTALL_LOCK" ]] && release_sync_lock "$_INSTALL_LOCK"
    return 0
}

# ===========================================================================
# Core: invoke_install <source_root> <claude_root> <force> <dry_run> <no_backup> <remove_import>
# ===========================================================================
invoke_install() {
    local SourceRoot="$1" ClaudeRoot="$2" Force="$3" DryRun="$4" NoBackup="$5" RemoveImport="${6:-0}"

    # --- P022:A019: --remove-import is a flag SEPARATE from the normal run —
    #     it only removes the '@NESTOR.md' import from ClaudeRoot/CLAUDE.md and does
    #     NOT run the rest of the installation (no SourceRoot/greenlist needed here).
    if [[ "$RemoveImport" == "1" ]]; then
        local rmCanon
        rmCanon=$(realpath -m "$ClaudeRoot" 2>/dev/null) || rmCanon="$ClaudeRoot"
        local rmClaudeMd="$rmCanon/CLAUDE.md"
        if [[ "$DryRun" == "1" ]]; then
            remove_nestor_import --dry-run "$rmClaudeMd"
        else
            remove_nestor_import "$rmClaudeMd"
        fi
        write_ok "Import '@NESTOR.md' removed (if present): $rmClaudeMd"
        return 0
    fi

    write_header "SDLC v$VERSION — System installer (disaster-recovery bootstrap)"

    # --- 1. Prechecks (read-only) ---
    local srcResolved
    srcResolved=$(realpath "$SourceRoot" 2>/dev/null) || srcResolved=""
    if [[ -z "$srcResolved" || ! -e "$srcResolved" ]]; then
        write_err "SourceRoot not found: $SourceRoot"
        return 2
    fi
    SourceRoot="$srcResolved"

    local sourceSkillsDir="$SourceRoot/skills"
    if [[ ! -d "$sourceSkillsDir" ]]; then
        write_err "Source folder not found: $sourceSkillsDir"
        return 2
    fi

    # Skills DERIVED from disk (H7, get_sync_domain_skill) — never a hard-coded list.
    local -a SKILLS=()
    mapfile -t SKILLS < <(get_sync_domain_skill "$SourceRoot")
    if [[ ${#SKILLS[@]} -eq 0 ]]; then
        write_err "No sdlc* skill found under $sourceSkillsDir"
        return 2
    fi
    local skill
    for skill in "${SKILLS[@]}"; do
        if [[ ! -f "$sourceSkillsDir/$skill/SKILL.md" ]]; then
            write_err "SKILL.md missing: $sourceSkillsDir/$skill/SKILL.md"
            return 2
        fi
    done

    # Commands: canonical top-level source commands/sdlc (A003, H3) — never the
    # embedded copy of the sdlc skill (excluded by sync-lib under H3).
    local sourceCommandsDir="$SourceRoot/commands/sdlc"
    if [[ ! -d "$sourceCommandsDir" ]]; then
        write_err "Source commands folder not found: $sourceCommandsDir"
        return 2
    fi

    # --- Canonical greenlist (single source: get_domain_relpaths) ---
    local -a greenlist=()
    mapfile -t greenlist < <(get_domain_relpaths "$SourceRoot")
    if [[ ${#greenlist[@]} -eq 0 ]]; then
        write_err "Empty domain greenlist — nothing to install."
        return 2
    fi

    # DERIVED cardinalities (from the real ref) — no literal.
    local skillCount=${#SKILLS[@]}
    local cmdCount agentCount
    cmdCount=$(printf '%s\n' "${greenlist[@]}" | grep -c '^commands/sdlc/'); cmdCount=${cmdCount//[^0-9]/}
    agentCount=$(printf '%s\n' "${greenlist[@]}" | grep -c '^agents/'); agentCount=${agentCount//[^0-9]/}
    if [[ "$cmdCount" -eq 0 ]]; then
        write_err "No command under commands/sdlc — incomplete source."
        return 2
    fi
    write_ok "Source: $skillCount skills + $cmdCount commands + $agentCount agents (${#greenlist[@]} domain files)"

    # --- Target ---
    if [[ ! -d "$ClaudeRoot" && "$DryRun" != "1" ]]; then
        mkdir -p "$ClaudeRoot"
    fi
    # Canonical form (after possible creation): deployment/manifest/backup/post-check
    # all use this form (otherwise get_domain_relpaths on the live side emits absolute paths).
    local canon
    canon=$(realpath -m "$ClaudeRoot" 2>/dev/null) || canon=""
    [[ -n "$canon" ]] && ClaudeRoot="$canon"
    local targetSkillsDir="$ClaudeRoot/skills"
    local manifestPath="$targetSkillsDir/sdlc/.install-manifest.json"
    local backupRoot="$ClaudeRoot/_backups"
    # P022:A019: GLOBAL USER file, OUTSIDE the sync domain (never in the
    # get_domain_relpaths greenlist). The import is added at the end of a nominal run.
    local claudeMdTarget="$ClaudeRoot/CLAUDE.md"

    # --- 2. Source checksum (byte-exact, single source) ---
    local globalChecksum
    globalChecksum=$(get_greenlist_checksum "$SourceRoot" "${greenlist[@]}")
    write_ok "Source checksum: ${globalChecksum:0:16}..."

    # --- 3. Idempotence (manifest) + self-repair (F4) ---
    if [[ -f "$manifestPath" ]]; then
        local existingChecksum existingVersion
        existingChecksum=$(grep -oE '"checksum_sha256"[[:space:]]*:[[:space:]]*"[a-f0-9]+"' "$manifestPath" 2>/dev/null | grep -oE '[a-f0-9]{64}' | head -n1)
        existingVersion=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$manifestPath" 2>/dev/null | head -n1 | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
        if [[ -n "$existingChecksum" && "$existingChecksum" == "$globalChecksum" && "$Force" != "1" ]]; then
            # SOURCE checksum unchanged: the manifest says "up to date". But a
            # DISASTER-RECOVERY tool cannot rely on it to claim the LIVE tree is INTACT.
            # CONFIRM through verify; if the live tree is damaged, REPAIR (fall through) (F4).
            local repoRootIdem
            repoRootIdem=$(dirname "$SourceRoot")
            invoke_verify_post_check "$repoRootIdem" "$ClaudeRoot"
            # Canonical tree INTACT = 0 missing AND 0 hash-diff (extra files do not damage it).
            local liveIntact=0
            if [[ "$VR_CODE" -eq 0 ]] || [[ "$VR_CODE" -eq 2 ]] || [[ "$VR_HASMARKERS" -eq 0 ]] || \
               { [[ "$VR_MISSING" -eq 0 ]] && [[ "$VR_HASHDIFF" -eq 0 ]]; } || \
               test_ref_worktree_dirty "$repoRootIdem"; then
                liveIntact=1
            fi
            if [[ "$liveIntact" -eq 1 ]]; then
                write_header "Already up to date (checksum unchanged)"
                write_ok "Installed version: ${existingVersion:-?}"
                if [[ "$VR_CODE" -eq 0 ]]; then write_ok "Live install confirmed intact (verify: 0 drift)."
                else write_warn "Live install integrity not confirmed against HEAD (non-blocking)."; fi
                printf '  %sNothing to do. To force: --force.%s\n' "$C_GRAY" "$C_RESET"
                if [[ "$DryRun" == "1" ]]; then
                    set_local_overlay_import --dry-run "$claudeMdTarget" 'CLAUDE.local.md'
                else
                    set_local_overlay_import "$claudeMdTarget" 'CLAUDE.local.md'
                fi
                return 0
            fi
            write_warn "Source checksum unchanged BUT live install damaged (verify: $VR_MISSING missing, $VR_HASHDIFF hash-diff, $VR_CARDDRIFT floor) — REPAIR in progress."
        elif [[ -n "$existingChecksum" ]]; then
            write_warn "Existing installation detected (v${existingVersion:-?}). Reinstall/upgrade to v$VERSION."
        else
            write_warn "Unreadable manifest — it will be overwritten."
        fi
    fi

    # --- 4. Third-party skill overwrite guard (iterates the DERIVED list) ---
    write_step "Guard: checking ownership of target skills"
    for skill in "${SKILLS[@]}"; do
        local targetSkillMd="$targetSkillsDir/$skill/SKILL.md"
        if [[ -f "$targetSkillMd" ]]; then
            local existingName
            existingName=$(get_skill_name "$targetSkillMd")
            # FAIL CLOSED (F2): missing/unreadable name: => unidentifiable THIRD-PARTY skill, refuse.
            if [[ -z "${existingName//[[:space:]]/}" ]]; then
                write_err "ABORT: $targetSkillMd exists but its 'name:' field is unreadable — unidentifiable skill, refusing to overwrite (fail-closed)."
                write_err "Rename, remove or fix the frontmatter of this skill before continuing."
                return 3
            fi
            case "$existingName" in
                sdlc*) : ;;
                *)
                    write_err "ABORT: $targetSkillMd contains a third-party skill (name: $existingName)."
                    write_err "Cannot overwrite. Rename or remove this skill before continuing."
                    return 3 ;;
            esac
        fi
    done
    write_ok "No conflict with a third-party skill"

    # --- 5. DRY-RUN: 0 writes ---
    if [[ "$DryRun" == "1" ]]; then
        write_header "DRY-RUN — no writes"
        write_step "${#greenlist[@]} domain file(s) would be deployed source -> live:"
        local rel
        for rel in "${greenlist[@]}"; do printf '    ~ %s\n' "$rel"; done
        write_warn "DRY-RUN: no actual change made."
        set_local_overlay_import --dry-run "$claudeMdTarget" 'CLAUDE.local.md'
        return 0
    fi

    # --- 6-8. Deployment + post-check + manifest, UNDER O_EXCL LOCK (F1) ---
    write_header "Deployment (staging + atomic swap via sync-lib)"
    trap _install_cleanup EXIT

    _INSTALL_LOCK=$(acquire_sync_lock "$ClaudeRoot/.sync.lock") || {
        write_err "Sync lock already held — installation aborted."
        return 1
    }

    _INSTALL_STAGING=$(mktemp -d "${TMPDIR:-/tmp}/install-stage-XXXXXXXX")

    # (1) STAGING: assemble the canonical content outside live (atomic per file).
    local -a staged=()
    mapfile -t staged < <(copy_tree "$SourceRoot" "$_INSTALL_STAGING" "${greenlist[@]}")

    # (2) Timestamped BACKUP of every PRESENT live file before replacement (unless --no-backup).
    if [[ "$NoBackup" != "1" ]]; then
        local backupDir="$backupRoot/sdlc-$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
        local backedUp=0 rel liveFull
        for rel in "${staged[@]}"; do
            liveFull="$ClaudeRoot/$rel"
            if [[ -f "$liveFull" ]]; then
                # CHECKED backup: a write failure aborts BEFORE the SWAP, so the existing
                # live tree stays intact/recoverable. Parity with install.ps1's abort.
                if ! write_file_atomic "$backupDir/$rel" < "$liveFull" >/dev/null; then
                    write_err "Backup failed for $rel — aborting before replacement (live preserved)."
                    return 1
                fi
                backedUp=$((backedUp+1))
            fi
        done
        if [[ "$backedUp" -gt 0 ]]; then
            write_ok "Backup: $backedUp live file(s) saved -> $backupDir"
        fi
    fi

    # (3) Atomic SWAP: staging -> live (temp+rename per file via copy_tree).
    local -a deployed=()
    mapfile -t deployed < <(copy_tree "$_INSTALL_STAGING" "$ClaudeRoot" "${staged[@]}")
    # Incomplete SWAP (copy_tree skipped >=1 file on a write failure): do NOT write a
    # misleading 'complete' manifest. Abort; the backup stays available.
    if [[ ${#deployed[@]} -lt ${#staged[@]} ]]; then
        write_err "Incomplete SWAP: ${#deployed[@]}/${#staged[@]} file(s) deployed. Manifest NOT written. Backup available."
        return 1
    fi
    write_ok "${#deployed[@]} file(s) deployed source -> $ClaudeRoot"

    # --- verify POST-CHECK (read-only subprocess) + drift CLASSIFICATION ---
    #   Code 0                          -> 0 drift (confirmed).
    #   Code 2                          -> verify unavailable (git missing / outside repo) -> not fatal.
    #   Code !=0 without any marker     -> verify internal error                           -> not fatal.
    #   EXTRA only                      -> orphans; install is ADDITIVE (no delete)        -> not fatal.
    #   MISSING/HASH DIFF + DIRTY ref   -> cannot be confirmed against HEAD (deploy=worktree) -> not fatal.
    #   MISSING/HASH DIFF + CLEAN ref   -> real DRIFT (incomplete/corrupt deploy)          -> fatal (exit 7).
    local repoRoot
    repoRoot=$(dirname "$SourceRoot")
    invoke_verify_post_check "$repoRoot" "$ClaudeRoot"
    if [[ "$VR_CODE" -eq 0 ]]; then
        write_ok "verify post-check: 0 drift (live == committed ref HEAD)."
    elif [[ "$VR_CODE" -eq 2 ]]; then
        write_warn "verify post-check unavailable (git missing / source outside a repo) — atomic deployment NOT confirmed against HEAD (non-blocking)."
    elif [[ "$VR_HASMARKERS" -eq 0 ]]; then
        write_warn "verify post-check inconclusive (code $VR_CODE, no fidelity difference reported: verify error?) — non-blocking."
    elif [[ "$VR_MISSING" -eq 0 && "$VR_HASHDIFF" -eq 0 ]]; then
        write_warn "verify post-check: $VR_SURPLUS EXTRA file(s) on the live side (orphans from a previous version)."
        write_warn "Canonical deployment is correct; install is additive — run restore to clean up the orphans."
    elif test_ref_worktree_dirty "$repoRoot"; then
        write_warn "verify post-check reports a difference ($VR_MISSING missing, $VR_HASHDIFF hash-diff), but the claude/ source is not committed (worktree != HEAD): integrity NOT confirmed against HEAD (non-blocking)."
    else
        write_err "verify post-check: real DRIFT (code $VR_CODE: $VR_MISSING missing, $VR_HASHDIFF hash-diff, $VR_CARDDRIFT floor) — live != committed ref HEAD. Deployment NOT reliable."
        write_err "The timestamped backups can be recovered. Reconcile, then run again with --force."
        return 7
    fi

    # --- Manifest (F6: written ONLY after an ACCEPTABLE post-check; atomic) ---
    local installedAt sourceNorm skillsJson
    installedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sourceNorm="${SourceRoot//\\//}"
    skillsJson=$(printf '"%s",' "${SKILLS[@]}"); skillsJson="[${skillsJson%,}]"
    write_file_atomic "$manifestPath" >/dev/null <<EOF
{
  "version": "$VERSION",
  "installed_at": "$installedAt",
  "source": "$sourceNorm",
  "skills": $skillsJson,
  "commands_namespace": "$COMMANDS_NS",
  "commands_count": $cmdCount,
  "agents_count": $agentCount,
  "files_count": ${#deployed[@]},
  "checksum_sha256": "$globalChecksum",
  "installer": "install.sh",
  "bash_version": "${BASH_VERSION:-unknown}"
}
EOF
    write_ok "Manifest written: $manifestPath"

    # --- 9. Final report ---
    write_header "Installation complete"
    printf '  Version    : %s\n' "$VERSION"
    printf '  Skills     : %s  (%s)\n' "$skillCount" "$(IFS=', '; printf '%s' "${SKILLS[*]}")"
    printf '  Commands   : %s in commands/%s/\n' "$cmdCount" "$COMMANDS_NS"
    printf '  Agents     : %s in agents/\n' "$agentCount"
    printf '  Files      : %s deployed\n' "${#deployed[@]}"
    printf '  Checksum   : %s...\n' "${globalChecksum:0:16}"
    printf '\n  %sNext steps:%s\n' "$C_CYAN" "$C_RESET"
    printf '    1. Restart Claude Code (so it discovers the skills/commands)\n'
    printf '    2. Try: /sdlc:status\n\n'
    set_local_overlay_import "$claudeMdTarget" 'CLAUDE.local.md'
    return 0
}

# --- Auto-run (script) — skipped when sourced (tests) ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # bash 4+ prerequisite (mapfile / declare -A) — exit 2, mirror of the
    # PSVersion < 7 guard of install.ps1. macOS /bin/bash 3.2: brew install bash.
    require_bash4 || exit $?
    CLAUDE_ROOT="${HOME}/.claude"
    # Canonical REF = ../../claude (bundle/scripts -> sdlc-framework/claude), NOT bundle/.
    SOURCE_ROOT="$SCRIPT_DIR/../../claude"
    FORCE=0; DRY_RUN=0; NO_BACKUP=0; REMOVE_IMPORT=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --claude-root)   CLAUDE_ROOT="$2"; shift 2 ;;
            --source-root)   SOURCE_ROOT="$2"; shift 2 ;;
            --remove-import) REMOVE_IMPORT=1; shift ;;
            --force)       FORCE=1; shift ;;
            --dry-run)     DRY_RUN=1; shift ;;
            --no-backup)   NO_BACKUP=1; shift ;;
            -h|--help)     grep -E '^# ' "$0" | sed 's/^# \?//'; exit 0 ;;
            *)             write_err "Unknown option: $1"; exit 2 ;;
        esac
    done
    invoke_install "$SOURCE_ROOT" "$CLAUDE_ROOT" "$FORCE" "$DRY_RUN" "$NO_BACKUP" "$REMOVE_IMPORT"
    exit $?
fi
