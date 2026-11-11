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

    With -Tier, only the files of that tier are created (minimal: HANDOFF,
    RESUME, config; standard: + 0_context, 1_elicitation, 3_conception;
    full/exhaustive: every file). Without -Tier, every file is created, as
    before. deploy_init.sh selects the same files.

.PARAMETER ProjectRoot
    Directory in which to create SDLC_PM/. Default: current directory.

.PARAMETER Force
    Overwrites an existing structure (data loss possible).

.PARAMETER Tier
    Documentation tier (minimal, standard, full, exhaustive). Creates only the files that tier
    uses and writes it to sdlc-config.json; "none" creates nothing. Omitted: every file.

.EXAMPLE
    pwsh deploy_init.ps1
    pwsh deploy_init.ps1 -ProjectRoot "C:\dev\myproject"
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [switch]$Force,
    # Documentation tier: creates only the files that tier uses and writes it to the config.
    # Empty (default): every skeleton file, as before.
    [ValidateSet("", "none", "minimal", "standard", "full", "exhaustive")]
    [string]$Tier = ""
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

# ValidateSet is case-insensitive; the gate only accepts lowercase tier names (REV-004).
$Tier = $Tier.ToLowerInvariant()
if ($Tier -eq "none") {
    Write-Output "Tier none: no SDLC_PM/ is created (nothing is tracked at this tier)."
    exit 1
}
# Rank of each tier; a file is copied when the tier's rank reaches the file's minimal rank.
$tierRank = @{ "" = 4; "minimal" = 1; "standard" = 2; "full" = 3; "exhaustive" = 4 }[$Tier]

if ($tierRank -ge 2) { New-Item -ItemType Directory -Path $versionDir -Force | Out-Null }
else { New-Item -ItemType Directory -Path $pmDir -Force | Out-Null }

$mappings = @(
    # Cross-cutting deliverables (SDLC_PM/ root), from tier minimal
    @{ Src = "HANDOFF.template.md";         Dst = (Join-Path $pmDir "HANDOFF.md");               Rank = 1 }
    @{ Src = "RESUME.template.md";          Dst = (Join-Path $pmDir "RESUME.md");                Rank = 1 }
    @{ Src = "sdlc-config.example.json";    Dst = (Join-Path $pmDir "sdlc-config.json");         Rank = 1 }
    # Context and the light E→P chain, from tier standard
    @{ Src = "0_context.template.md";       Dst = (Join-Path $versionDir "0_context.md");        Rank = 2 }
    @{ Src = "1_elicitation.template.md";   Dst = (Join-Path $versionDir "1_elicitation.md");    Rank = 2 }
    @{ Src = "3_conception.template.md";    Dst = (Join-Path $versionDir "3_conception.md");     Rank = 2 }
    # Architecture, discussion and tests, from tier full (optional at standard: created on demand)
    @{ Src = "2_architecture.template.md";  Dst = (Join-Path $versionDir "2_architecture.md");   Rank = 3 }
    @{ Src = "2_5_discussion.template.md";  Dst = (Join-Path $versionDir "2_5_discussion.md");   Rank = 3 }
    @{ Src = "4_tests.template.md";         Dst = (Join-Path $versionDir "4_tests.md");          Rank = 3 }
)

foreach ($m in $mappings) {
    if ($m.Rank -gt $tierRank) { continue }
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
    $cfg = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($projectSlug) {
        $cfg.project_name = $projectSlug
        Write-Output "Patched: sdlc-config.json project_name = '$projectSlug'"
    }
    if ($Tier) {
        $cfg.documentation_tier = $Tier
        Write-Output "Patched: sdlc-config.json documentation_tier = '$Tier'"
    }
    # No BOM: Windows PowerShell 5.1 `Set-Content -Encoding UTF8` writes one, and strict JSON
    # readers reject it. .NET resolves relative paths against the process directory, so pass
    # the provider path.
    $json = $cfg | ConvertTo-Json -Depth 6
    $fullPath = (Resolve-Path -LiteralPath $configPath).ProviderPath
    [System.IO.File]::WriteAllText($fullPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
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
