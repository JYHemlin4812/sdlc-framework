#requires -Version 5.1
<#
.SYNOPSIS
  planchers.assert.ps1 (P017:A013) — CI canary: floor == count(claude/*).

.DESCRIPTION
  The fidelity floors (sdlc* skills / sdlc-* agents / sdlc commands) are DERIVED
  from a count in production code (verify.ps1, M4 hardening) — never hard-coded.
  This isolated test PINS the expected values (documented domain floors) and
  compares them with the count actually present in the real claude/ REF. If the
  domain drifts (skill/agent/command added or removed without an update), this test
  FAILS: it breaks CI (asking a human to revalidate), NOT production.

  SOURCE OF THE relPaths (P027:A025): `git ls-tree -r --name-only HEAD -- claude`
  (Get-RefDomainRelPaths, verify.ps1) — the SAME source of truth as verify.ps1's
  anti-drift guard (REF = HEAD commit, immutable), NOT the working tree file system.
  A file added/changed locally but not committed therefore does not affect this
  canary, exactly as it does not affect verify.ps1.

  READ-ONLY on claude/: reuses Get-RefDomainRelPaths + Test-GitRefUsable
  (verify.ps1) to derive the relPaths from HEAD, and the same cardinality primitive
  as verify (Get-DomainCardinalities, verify.ps1). Writes nothing, touches no
  ~/.claude, takes no lock.

  Compatible with PowerShell 5.1 (Desktop) and 7 (Core). ZERO dependency (no Pester).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Expected floors (PINNED here, in the test — breaks CI on drift) ---------
# ponytail: values pinned on purpose in the TEST (not in production); that is the
# point of the M4 canary. Update them here when the domain changes deliberately.
$EXPECTED_SKILLS   = 10
$EXPECTED_AGENTS   = 12   # sdlc-* only (nestor-* agents live in the separate nestor-agents repo)
$EXPECTED_COMMANDS = 18
$EXPECTED_CORE     = 0    # literal NESTOR.md (core domain, A018 SP3): not shipped in this repo

# --- Minimal assertions -------------------------------------------------------
$script:Passed = 0
$script:Failed = 0
$script:Failures = New-Object System.Collections.Generic.List[string]
function Assert-Eq {
    param($Expected, $Actual, [Parameter(Mandatory)][string]$Name)
    $ok = ($Expected -eq $Actual)
    if ($ok) { $script:Passed++; Write-Host ("  [PASS] " + $Name) -ForegroundColor Green }
    else {
        $script:Failed++; $script:Failures.Add($Name)
        Write-Host ("  [FAIL] " + $Name) -ForegroundColor Red
        Write-Host ("         expected floor=[{0}] actual claude/ count=[{1}]" -f $Expected, $Actual) -ForegroundColor DarkYellow
    }
}

# --- Locations: production scripts (single source of behavior) ---------------
$scriptsDir = Split-Path -Parent $PSScriptRoot            # bundle/scripts
$repoRoot   = Split-Path -Parent (Split-Path -Parent $scriptsDir)  # sdlc-framework root
$libPath    = Join-Path $scriptsDir 'sync-lib.ps1'
$verifyPath = Join-Path $scriptsDir 'verify.ps1'
$claudeRoot = Join-Path $repoRoot 'claude'
foreach ($p in @($libPath, $verifyPath, $claudeRoot)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "not found: $p" -ForegroundColor Red; exit 2 }
}

# Dot-source (InvocationName guards: no auto-run). verify.ps1 exposes
# Get-RefDomainRelPaths, Test-GitRefUsable and Get-DomainCardinalities — the
# SAME primitives as production (no home-made re-derivation that could diverge
# from verify). sync-lib.ps1 provides Test-SyncExcluded, required by verify.ps1.
. $libPath
. $verifyPath

Write-Host ""
Write-Host "=== planchers.assert: floor == count(claude/) [M4] ===" -ForegroundColor Cyan

# Derives the domain cardinalities from the real committed REF (git HEAD),
# NOT the working tree — same source of truth as verify.ps1 (P027:A025).
if (-not (Test-GitRefUsable -RepoRoot $repoRoot)) {
    Write-Host "REF unusable (git missing or no committed HEAD): $repoRoot" -ForegroundColor Red
    exit 2
}
$rels = @(Get-RefDomainRelPaths -RepoRoot $repoRoot)
$card = Get-DomainCardinalities -RelPaths $rels

Write-Host ("  claude/ (git HEAD) : {0} domain files  (skills={1} agents={2} commands={3} core={4})" -f `
    $rels.Count, $card.Skills, $card.Agents, $card.Commands, $card.Core) -ForegroundColor Gray

Assert-Eq $EXPECTED_SKILLS   $card.Skills   "skills floor == count(claude/skills/sdlc*)"
Assert-Eq $EXPECTED_AGENTS   $card.Agents   "agents floor == count(claude/agents/sdlc-*)"
Assert-Eq $EXPECTED_COMMANDS $card.Commands "commands floor == count(claude/commands/sdlc/*)"
Assert-Eq $EXPECTED_CORE     $card.Core     "core floor == count(claude/NESTOR.md)"

Write-Host ""
Write-Host ("=== Summary: {0} PASS / {1} FAIL ===" -f $script:Passed, $script:Failed) -ForegroundColor Cyan
if ($script:Failed -gt 0) {
    foreach ($f in $script:Failures) { Write-Host ("  - " + $f) -ForegroundColor Red }
    Write-Host "FLOORS DRIFTED: the claude/ domain changed. Revalidate and update the pinned values." -ForegroundColor Red
    exit 1
}
Write-Host ("OK: floors match the actual claude/ count ({0}/{1}/{2}/{3})." -f $EXPECTED_SKILLS, $EXPECTED_AGENTS, $EXPECTED_COMMANDS, $EXPECTED_CORE) -ForegroundColor Green
exit 0
