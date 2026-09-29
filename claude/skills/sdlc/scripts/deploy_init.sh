#!/usr/bin/env bash
# deploy_init.sh — Bootstrap a new SDLC project (Linux/macOS).
#
# Usage:
#   ./deploy_init.sh [project_root] [--force]
#
# Creates SDLC_PM/v1.0.0/ with the 5 phase templates and the example config.

set -euo pipefail

PROJECT_ROOT="${1:-$(pwd)}"
FORCE=0
for arg in "$@"; do
    if [[ "$arg" == "--force" ]]; then FORCE=1; fi
done

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ASSETS_DIR="${SCRIPT_DIR}/../assets"

PM_DIR="${PROJECT_ROOT}/SDLC_PM"
VERSION_DIR="${PM_DIR}/v1.0.0"

if [[ -d "$PM_DIR" && $FORCE -ne 1 ]]; then
    echo "SDLC_PM/ already exists in $PROJECT_ROOT. Use --force to overwrite." >&2
    exit 1
fi

mkdir -p "$VERSION_DIR"

declare -A MAPPINGS=(
    ["1_elicitation.template.md"]="${VERSION_DIR}/1_elicitation.md"
    ["2_architecture.template.md"]="${VERSION_DIR}/2_architecture.md"
    ["2_5_discussion.template.md"]="${VERSION_DIR}/2_5_discussion.md"
    ["3_conception.template.md"]="${VERSION_DIR}/3_conception.md"
    ["4_tests.template.md"]="${VERSION_DIR}/4_tests.md"
    ["sdlc-config.example.json"]="${PM_DIR}/sdlc-config.json"
)

for src in "${!MAPPINGS[@]}"; do
    dst="${MAPPINGS[$src]}"
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
