#!/usr/bin/env bash
# deploy_init.sh — Bootstrap a new SDLC project (Linux/macOS).
#
# Usage:
#   ./deploy_init.sh [project_root] [--force] [--tier minimal|standard|full|exhaustive|none]
#
# Creates SDLC_PM/ with HANDOFF.md, RESUME.md and the config, and SDLC_PM/v1.0.0/ with the
# phase templates the tier uses. Without --tier, every skeleton file is created (as before).
# Same file selection as deploy_init.ps1.

set -euo pipefail

PROJECT_ROOT=""
FORCE=0
TIER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=1 ;;
        --tier) TIER="${2:-}"; shift ;;
        *) PROJECT_ROOT="$1" ;;
    esac
    shift
done
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"

case "$TIER" in
    "") TIER_RANK=4 ;;
    none) echo "Tier none: no SDLC_PM/ is created (nothing is tracked at this tier)."; exit 1 ;;
    minimal) TIER_RANK=1 ;;
    standard) TIER_RANK=2 ;;
    full) TIER_RANK=3 ;;
    exhaustive) TIER_RANK=4 ;;
    *) echo "Unknown tier: $TIER (expected minimal, standard, full, exhaustive or none)." >&2; exit 2 ;;
esac

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ASSETS_DIR="${SCRIPT_DIR}/../assets"

PM_DIR="${PROJECT_ROOT}/SDLC_PM"
VERSION_DIR="${PM_DIR}/v1.0.0"

if [[ -d "$PM_DIR" && $FORCE -ne 1 ]]; then
    echo "SDLC_PM/ already exists in $PROJECT_ROOT. Use --force to overwrite." >&2
    exit 1
fi

mkdir -p "$PM_DIR"
if [[ $TIER_RANK -ge 2 ]]; then mkdir -p "$VERSION_DIR"; fi

# "source|destination|minimal rank": a file is copied when the tier's rank reaches its rank.
MAPPINGS=(
    # Cross-cutting deliverables (SDLC_PM/ root), from tier minimal
    "HANDOFF.template.md|${PM_DIR}/HANDOFF.md|1"
    "RESUME.template.md|${PM_DIR}/RESUME.md|1"
    "sdlc-config.example.json|${PM_DIR}/sdlc-config.json|1"
    # Context and the light E→P chain, from tier standard
    "0_context.template.md|${VERSION_DIR}/0_context.md|2"
    "1_elicitation.template.md|${VERSION_DIR}/1_elicitation.md|2"
    "3_conception.template.md|${VERSION_DIR}/3_conception.md|2"
    # Architecture, discussion and tests, from tier full (optional at standard: created on demand)
    "2_architecture.template.md|${VERSION_DIR}/2_architecture.md|3"
    "2_5_discussion.template.md|${VERSION_DIR}/2_5_discussion.md|3"
    "4_tests.template.md|${VERSION_DIR}/4_tests.md|3"
)

for entry in "${MAPPINGS[@]}"; do
    IFS='|' read -r src dst rank <<< "$entry"
    if [[ $rank -gt $TIER_RANK ]]; then continue; fi
    src_path="${ASSETS_DIR}/${src}"
    if [[ ! -f "$src_path" ]]; then
        echo "Missing asset: $src_path" >&2
        continue
    fi
    if [[ -f "$dst" && $FORCE -ne 1 ]]; then
        echo "Skipped (exists): $dst"
        continue
    fi
    cp "$src_path" "$dst"
    echo "Created: $dst"
done

# Pre-fill project_name (and the tier when given), like deploy_init.ps1. The example config is
# the shipped file, so its two lines are known; no JSON tool is needed.
CONFIG="${PM_DIR}/sdlc-config.json"
if [[ -f "$CONFIG" ]]; then
    slug="$(basename "$PROJECT_ROOT" | sed 's/[^a-zA-Z0-9_-]/-/g; s/^-*//; s/-*$//')"
    if [[ -n "$slug" ]]; then
        sed -i.bak "s/\"project_name\": \"example-project\"/\"project_name\": \"${slug}\"/" "$CONFIG"
        echo "Patched: sdlc-config.json project_name = '${slug}'"
    fi
    if [[ -n "$TIER" ]]; then
        sed -i.bak "s/\"documentation_tier\": \"[a-z]*\"/\"documentation_tier\": \"${TIER}\"/" "$CONFIG"
        echo "Patched: sdlc-config.json documentation_tier = '${TIER}'"
    fi
    rm -f "${CONFIG}.bak"
fi

cat > "${PM_DIR}/SDLC_PLAN.md" <<EOF
# SDLC — $(basename "$PROJECT_ROOT")

Phase index. Updated automatically by /sdlc:plan, /sdlc:dev, /sdlc:gate.

## Versions

- v1.0.0 — ⬜ To do

## Configuration

See \`sdlc-config.json\` at the root of SDLC_PM/.
EOF

echo
echo "✅ SDLC structure initialized in $PM_DIR"
echo "   Next: /sdlc:brainstorm <project description>"
