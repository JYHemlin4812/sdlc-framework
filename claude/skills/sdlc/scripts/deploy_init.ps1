<#
.SYNOPSIS
    Bootstrap a new SDLC project (v4.0).

.DESCRIPTION
    Creates the SDLC_PM/ structure with:
    - HANDOFF.md + RESUME.md at the root (cross-cutting, from tier `minimal`)
    - v1.0.0/0_context.md (tier >= standard) + 5 phase files
      (1_elicitation, 2_architecture, 2_5_discussion, 3_conception, 4_tests)
    - sdlc-config.json at the root
    Prepares the project for /sdlc:brainstorm (or /sdlc:exit in minimal mode).

    Note: this script creates ALL files (full skeleton). The orchestrator
    (SKILL.md) reads `documentation_tier` and decides which files are
    required or optional for the tier.

.PARAMETER ProjectRoot
    Directory in which to create SDLC_PM/. Default: current directory.

.PARAMETER Force
    Overwrites an existing structure (data loss possible).

.EXAMPLE
    pwsh deploy_init.ps1
    pwsh deploy_init.ps1 -ProjectRoot "C:\dev\myproject"
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$assetsDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..\assets"
$assetsDir = (Resolve-Path $assetsDir).Path

$pmDir = Join-Path $ProjectRoot "SDLC_PM"
$versionDir = Join-Path $pmDir "v1.0.0"

if ((Test-Path $pmDir) -and (-not $Force)) {
    Write-Error "SDLC_PM/ already exists in $ProjectRoot. Use -Force to overwrite."
    exit 1
}

New-Item -ItemType Directory -Path $versionDir -Force | Out-Null

$mappings = @(
    # v3.2 — cross-cutting deliverables (SDLC_PM/ root), from tier minimal
    @{ Src = "HANDOFF.template.md";         Dst = (Join-Path $pmDir "HANDOFF.md") }
    @{ Src = "RESUME.template.md";          Dst = (Join-Path $pmDir "RESUME.md") }
    # v3.2 — context (versioned), from tier standard
    @{ Src = "0_context.template.md";       Dst = (Join-Path $versionDir "0_context.md") }
    # E→A→P→T phases (tiers standard/full/exhaustive)
    @{ Src = "1_elicitation.template.md";   Dst = (Join-Path $versionDir "1_elicitation.md") }
    @{ Src = "2_architecture.template.md";  Dst = (Join-Path $versionDir "2_architecture.md") }
    @{ Src = "2_5_discussion.template.md";  Dst = (Join-Path $versionDir "2_5_discussion.md") }
    @{ Src = "3_conception.template.md";    Dst = (Join-Path $versionDir "3_conception.md") }
    @{ Src = "4_tests.template.md";         Dst = (Join-Path $versionDir "4_tests.md") }
    @{ Src = "sdlc-config.example.json";    Dst = (Join-Path $pmDir "sdlc-config.json") }
)

foreach ($m in $mappings) {
    $src = Join-Path $assetsDir $m.Src
    if (-not (Test-Path $src)) {
        Write-Warning "Missing asset: $src"
        continue
    }
    if ((Test-Path $m.Dst) -and (-not $Force)) {
        Write-Output "Skipped (exists): $($m.Dst)"
        continue
    }
    Copy-Item -Path $src -Destination $m.Dst -Force
    Write-Output "Created: $($m.Dst)"
}

# v3.2 friction F1 — pre-fill project_name in sdlc-config.json
# (otherwise it stays "example-project" until edited by hand)
$configPath = Join-Path $pmDir "sdlc-config.json"
if (Test-Path $configPath) {
    $projectSlug = $ProjectRoot | Split-Path -Leaf
    # Slugify : keep [a-zA-Z0-9_-] only, replace anything else with '-'
    $projectSlug = ($projectSlug -replace '[^a-zA-Z0-9_-]', '-').Trim('-')
    if ($projectSlug) {
        $cfg = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $cfg.project_name = $projectSlug
        $cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $configPath -Encoding UTF8
        Write-Output "Patched: sdlc-config.json project_name = '$projectSlug'"
    }
}

@"
# SDLC — $($ProjectRoot | Split-Path -Leaf)

Phase index. Updated automatically by /sdlc:plan, /sdlc:dev, /sdlc:gate.

## Versions

- v1.0.0 — ⬜ To do

## Configuration

See ``sdlc-config.json`` at the root of SDLC_PM/.
"@ | Set-Content -Path (Join-Path $pmDir "SDLC_PLAN.md") -Encoding UTF8

Write-Output ""
Write-Output "✅ SDLC structure (v4.0) initialized in $pmDir"
Write-Output "   - HANDOFF.md + RESUME.md       (cross-cutting, tier >= minimal)"
Write-Output "   - v1.0.0/0_context.md          (tier >= standard)"
Write-Output "   - v1.0.0/1..4_*.md             (E->A->P->T phases)"
Write-Output ""
Write-Output "   Next steps:"
Write-Output "   1. Choose the documentation tier and output_language in sdlc-config.json (defaults: standard, en)"
Write-Output "   2. /sdlc:brainstorm <description>   (tier >= standard)"
Write-Output "      OR fill in HANDOFF.md + RESUME.md directly (tier minimal)"
