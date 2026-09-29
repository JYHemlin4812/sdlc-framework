#!/usr/bin/env bash
# SDLC uninstaller v3.2 — removes skills + commands (+ agents/core optionally
# with --remove-core) from ~/.claude/.
# Always takes an automatic backup. Refuses without a manifest (unless --discover).
# Usage: ./uninstall.sh [--claude-root DIR] [--force] [--discover] [--remove-core]
#
# P025:A023 — --remove-core (additive flag, OPT-IN): on top of the default behavior
# (skills + commands/sdlc/), also removes the claude/agents/{sdlc-*,nestor-*}
# agents and the NESTOR.md core PRESENT IN LIVE, in the SAME backup/removal pass,
# then removes the '@NESTOR.md' import from the personal CLAUDE.md
# (remove_nestor_import, single source sync-lib.sh). Without the flag: behavior
# STRICTLY identical to before (agents and core untouched) — non-regression.
#
# The agents/core scope is DERIVED from get_domain_relpaths (sync-lib, single
# source of the domain) — never a hard-coded list of agent names (M4).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# --- Shared foundation (single source A002/A004; get_domain_relpaths, remove_nestor_import) ---
# shellcheck source=/dev/null
. "$SCRIPT_DIR/sync-lib.sh"

CLAUDE_ROOT="${HOME}/.claude"
COMMANDS_NS="sdlc"
SKILLS_DEFAULT=("sdlc" "sdlc-wave-orchestrator" "sdlc-lang-dispatcher" "sdlc-asvs-auditor")
FORCE=0
DISCOVER=0
REMOVE_CORE=0

if [[ -t 1 ]]; then
    C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'; C_GRAY=$'\033[90m'; C_RESET=$'\033[0m'
else
    C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GRAY=""; C_RESET=""
fi

write_header() { printf "\n%s\n  %s\n%s\n" "${C_CYAN}$(printf '=%.0s' {1..70})" "$1" "$(printf '=%.0s' {1..70})${C_RESET}"; }
write_step()   { printf "  ${C_GRAY}- %s${C_RESET}\n" "$1"; }
write_ok()     { printf "  ${C_GREEN}[OK] %s${C_RESET}\n" "$1"; }
write_warn()   { printf "  ${C_YELLOW}[WARN] %s${C_RESET}\n" "$1"; }
write_err()    { printf "  ${C_RED}[ERR] %s${C_RESET}\n" "$1" >&2; }

# ===========================================================================
# Core: invoke_uninstall <claude_root> <force> <discover> <remove_core>
# ===========================================================================
invoke_uninstall() {
    local ClaudeRoot="$1" Force="$2" Discover="$3" RemoveCore="${4:-0}"

    write_header "SDLC — Uninstaller (bash)"

    local TARGET_SKILLS_DIR="$ClaudeRoot/skills"
    local TARGET_COMMANDS_DIR="$ClaudeRoot/commands/$COMMANDS_NS"
    local MANIFEST_PATH="$TARGET_SKILLS_DIR/sdlc/.install-manifest.json"

    # --- Read the manifest ---
    local SKILLS=()
    local MANIFEST_VERSION="(unknown)"

    if [[ -f "$MANIFEST_PATH" ]]; then
        MANIFEST_VERSION=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$MANIFEST_PATH" | head -n1 | cut -d'"' -f4)
        while IFS= read -r s; do SKILLS+=("$s"); done < <(
            grep -oE '"skills"[[:space:]]*:[[:space:]]*\[[^]]+\]' "$MANIFEST_PATH" | \
            grep -oE '"sdlc[a-z0-9-]*"' | tr -d '"'
        )
        write_ok "Manifest found: v$MANIFEST_VERSION (${#SKILLS[@]} skills)"
    else
        if [[ "$Discover" != "1" ]]; then
            write_err "Manifest missing: $MANIFEST_PATH"
            write_err "Refusing to uninstall without a manifest. To force: --discover --force"
            return 2
        fi
        write_warn "--discover mode: heuristic search"
        SKILLS=("${SKILLS_DEFAULT[@]}")
    fi

    # --- What will be removed ---
    # TO_REMOVE / TO_REMOVE_NAME: parallel arrays (same index), NAME = relative
    # name/path used for the timestamped backup.
    local TO_REMOVE=() TO_REMOVE_NAME=()
    local skill p
    for skill in "${SKILLS[@]}"; do
        p="$TARGET_SKILLS_DIR/$skill"
        if [[ -d "$p" ]]; then TO_REMOVE+=("$p"); TO_REMOVE_NAME+=("$skill"); fi
    done
    if [[ -d "$TARGET_COMMANDS_DIR" ]]; then
        TO_REMOVE+=("$TARGET_COMMANDS_DIR"); TO_REMOVE_NAME+=("$(basename -- "$TARGET_COMMANDS_DIR")")
    fi

    # --- P025:A023: --remove-core — sdlc-*/nestor-* agents + NESTOR.md core IN LIVE.
    #     Scope DERIVED from get_domain_relpaths (never a hard-coded list of names, M4).
    #     Backup name = full relPath (avoids any basename collision between agents
    #     in different subfolders, see the recursive get_domain_relpaths).
    if [[ "$RemoveCore" == "1" && -d "$ClaudeRoot" ]]; then
        local rel full already dup
        while IFS= read -r rel; do
            [[ -n "$rel" ]] || continue
            case "$rel" in
                'NESTOR.md'|agents/*) ;;
                *) continue ;;
            esac
            full="$ClaudeRoot/$rel"
            [[ -e "$full" ]] || continue
            already=0
            for dup in "${TO_REMOVE[@]}"; do [[ "$dup" == "$full" ]] && { already=1; break; }; done
            [[ $already -eq 1 ]] && continue
            TO_REMOVE+=("$full"); TO_REMOVE_NAME+=("$rel")
        done < <(get_domain_relpaths "$ClaudeRoot")
    fi

    if [[ ${#TO_REMOVE[@]} -eq 0 ]]; then
        write_warn "No SDLC artifact found. Nothing to remove."
        return 0
    fi

    printf "\n  Will be removed:\n"
    for p in "${TO_REMOVE[@]}"; do
        printf "    - %s\n" "$p"
    done
    printf "\n"

    # --- Confirmation ---
    if [[ "$Force" != "1" ]]; then
        local resp
        read -r -p "  Confirm uninstall? (yes/N) " resp
        if [[ ! "$resp" =~ ^(oui|o|yes|y)$ ]]; then
            write_warn "Cancelled."
            return 0
        fi
    fi

    # --- Automatic backup ---
    local TS BACKUP_ROOT
    TS=$(date +"%Y%m%d-%H%M%S")
    BACKUP_ROOT="$TARGET_SKILLS_DIR/_backups/sdlc-uninstall-$TS"
    write_step "Backup to $BACKUP_ROOT"
    mkdir -p "$BACKUP_ROOT"
    local i name dst dstdir
    for i in "${!TO_REMOVE[@]}"; do
        p="${TO_REMOVE[$i]}"; name="${TO_REMOVE_NAME[$i]}"
        dst="$BACKUP_ROOT/$name"
        dstdir=$(dirname -- "$dst")
        [[ -d "$dstdir" ]] || mkdir -p "$dstdir"
        cp -r "$p" "$dst"
    done
    write_ok "Backup created"

    # --- Removal ---
    write_header "Removal"
    for p in "${TO_REMOVE[@]}"; do
        write_step "rm -rf $p"
        rm -rf "$p"
    done

    # Remove commands/ if empty
    local COMMANDS_PARENT="$ClaudeRoot/commands"
    if [[ -d "$COMMANDS_PARENT" ]] && [[ -z "$(ls -A "$COMMANDS_PARENT")" ]]; then
        write_step "Removing empty commands/"
        rmdir "$COMMANDS_PARENT"
    fi

    # --- --remove-core: remove the '@NESTOR.md' import from the personal CLAUDE.md ---
    #     Same EXACT resolution as install.sh --remove-import (realpath -m +
    #     "$canon/CLAUDE.md") so the same file is targeted.
    if [[ "$RemoveCore" == "1" ]]; then
        local rmCanon rmClaudeMd
        rmCanon=$(realpath -m "$ClaudeRoot" 2>/dev/null) || rmCanon="$ClaudeRoot"
        rmClaudeMd="$rmCanon/CLAUDE.md"
        remove_nestor_import "$rmClaudeMd"
        write_ok "Import '@NESTOR.md' removed (if present): $rmClaudeMd"
    fi

    write_header "Uninstall complete"
    printf "  Removed version   : %s\n" "$MANIFEST_VERSION"
    printf "  Removed artifacts : %s\n" "${#TO_REMOVE[@]}"
    printf "  Backup            : %s\n\n" "$BACKUP_ROOT"
    printf "  ${C_CYAN}To reinstall${C_RESET}: ./install.sh\n\n"
    return 0
}

# --- Auto-run (script) — skipped when sourced (tests) ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --claude-root)  CLAUDE_ROOT="$2"; shift 2 ;;
            --force)        FORCE=1; shift ;;
            --discover)     DISCOVER=1; shift ;;
            --remove-core)  REMOVE_CORE=1; shift ;;
            -h|--help)
                sed -n '2,5p' "$0" | sed 's/^# \?//'
                exit 0
                ;;
            *) write_err "Unknown option: $1"; exit 2 ;;
        esac
    done
    invoke_uninstall "$CLAUDE_ROOT" "$FORCE" "$DISCOVER" "$REMOVE_CORE"
    exit $?
fi
