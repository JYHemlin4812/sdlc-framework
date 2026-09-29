#requires -Version 5.1
<#
.SYNOPSIS
  Self-contained, assert-based self-check (ZERO dependency: no Pester) of uninstall.ps1
  (P025:A023). Exit code != 0 on the first failure.

.DESCRIPTION
  Creates ALL its fixtures in a single TEMP directory (fake LIVE ClaudeRoot with
  skills + commands/sdlc + agents + NESTOR.md + CLAUDE.md). NEVER operates on the
  real ~/.claude. Cleans up in finally.

  Covers:
    (U0) source invariants: Get-DomainRelPaths (never a hard-coded agent list),
         testable Invoke-Uninstall (dot-source + auto-run guard), Remove-NestorImport.
    (U1) default behavior (without -RemoveCore) STRICTLY identical to before:
         skills + commands/sdlc removed and backed up; agents, NESTOR.md and CLAUDE.md
         UNTOUCHED (byte-identical).
    (U2) -RemoveCore: sdlc-* agents removed from live and backed up (full relPath, no
         basename collision between nested agents), '@NESTOR.md' import removed from
         CLAUDE.md (otherwise byte-identical).
    (U3) -RemoveCore on a live tree WITHOUT agents/core: graceful no-op (no crash).
    (U4) interactive confirmation: without -Force, answer 'non' -> cancelled, live intact.

  Compatible with PowerShell 5.1 (Desktop) and 7 (Core).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Minimal assertion harness ----------------------------------------------
$script:Passed = 0
$script:Failed = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Name)
    if ($Condition) {
        $script:Passed++
        Write-Host ("  [PASS] " + $Name) -ForegroundColor Green
    } else {
        $script:Failed++
        $script:Failures.Add($Name)
        Write-Host ("  [FAIL] " + $Name) -ForegroundColor Red
    }
}
function Assert-Eq {
    param($Expected, $Actual, [Parameter(Mandatory)][string]$Name)
    $ok = ($Expected -eq $Actual)
    if (-not $ok) { Write-Host ("         expected=[{0}] got=[{1}]" -f $Expected, $Actual) -ForegroundColor DarkYellow }
    Assert-True -Condition $ok -Name $Name
}

# --- Script locations ---------------------------------------------------------
$scriptsDir    = Split-Path -Parent $PSScriptRoot
$uninstallPath = Join-Path $scriptsDir 'uninstall.ps1'
$libPath       = Join-Path $scriptsDir 'sync-lib.ps1'
foreach ($p in @($uninstallPath, $libPath)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "not found: $p" -ForegroundColor Red; exit 2 }
}

# Dot-source: sync-lib THEN uninstall (uninstall dot-sources sync-lib itself; the
# InvocationName guard prevents the auto-run). Exposes Invoke-Uninstall + helpers + lib.
. $libPath
. $uninstallPath

# --- Isolated temporary working directory -------------------------------------
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('uninstall-test-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null

function New-TextFile {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

$MANIFEST_JSON = '{"version":"3.2.0","skills":["sdlc","sdlc-wave-orchestrator","sdlc-lang-dispatcher","sdlc-asvs-auditor"]}'
$CLAUDE_MD_TEXT = "# My personal CLAUDE.md`nPre-existing user content.`n@NESTOR.md`n"

# Complete LIVE fixture: 4 skills (including the manifest), commands/sdlc, 3 agents (one
# of them RECURSIVE under agents/nested/ + one nestor-*), NESTOR.md, CLAUDE.md WITH the import.
function New-UninstallCase {
    param([string]$Name)
    $c    = Join-Path $root $Name
    $live = Join-Path $c 'live'
    New-Item -ItemType Directory -Path $live -Force | Out-Null

    New-TextFile (Join-Path $live 'skills\sdlc\SKILL.md') "root skill`n"
    New-TextFile (Join-Path $live 'skills\sdlc\.install-manifest.json') $MANIFEST_JSON
    New-TextFile (Join-Path $live 'skills\sdlc-wave-orchestrator\SKILL.md') "wave skill`n"
    New-TextFile (Join-Path $live 'skills\sdlc-lang-dispatcher\SKILL.md') "lang skill`n"
    New-TextFile (Join-Path $live 'skills\sdlc-asvs-auditor\SKILL.md') "asvs skill`n"
    New-TextFile (Join-Path $live 'commands\sdlc\brainstorm.md') "brainstorm cmd`n"
    New-TextFile (Join-Path $live 'agents\sdlc-architect.md') "architect agent`n"
    New-TextFile (Join-Path $live 'agents\nested\sdlc-deep.md') "deep nested agent`n"
    New-TextFile (Join-Path $live 'agents\nestor-clara.md') "clara agent`n"
    New-TextFile (Join-Path $live 'NESTOR.md') "nestor core`n"
    New-TextFile (Join-Path $live 'CLAUDE.md') $CLAUDE_MD_TEXT

    return [pscustomobject]@{ Dir = $c; Live = $live }
}

# Runs Invoke-Uninstall, separating the return code (int) from the text (Write-Host). 5.1/7.
function Invoke-UninstallCase {
    param([hashtable]$P)
    $streamed = Invoke-Uninstall @P *>&1
    $ints = @($streamed | Where-Object { $_ -is [int] })
    $rc = if ($ints.Count -gt 0) { $ints[$ints.Count - 1] } else { -999 }
    $text = (@($streamed | Where-Object { $_ -isnot [int] }) | ForEach-Object { $_.ToString() }) -join "`n"
    return [pscustomobject]@{ Rc = $rc; Text = $text }
}

function Test-Live { param($Case, [string]$Rel) Test-Path -LiteralPath (Join-Path $Case.Live ($Rel -replace '/', ([string][System.IO.Path]::DirectorySeparatorChar))) }
function Read-Text { param([string]$Path) if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path) } return $null }
function Get-BackupDirs { param($Case) if (Test-Path -LiteralPath (Join-Path $Case.Live 'skills\_backups')) { return @(Get-ChildItem -LiteralPath (Join-Path $Case.Live 'skills\_backups') -Directory) } return @() }

try {
    Write-Host ""
    Write-Host "=== test-uninstall: self-check P025:A023 ===" -ForegroundColor Cyan

    # =======================================================================
    # (U0) source invariants
    # =======================================================================
    Write-Host "-- (U0) source invariants --" -ForegroundColor Cyan
    $src = Get-Content -LiteralPath $uninstallPath -Raw
    Assert-True ($src -match 'Get-DomainRelPaths')          "U0. agents/core scope via Get-DomainRelPaths (single source)"
    Assert-True ($src -match 'Remove-NestorImport')         "U0. import removal via Remove-NestorImport (single source)"
    Assert-True ($src -match 'function Invoke-Uninstall')  "U0. logic wrapped in Invoke-Uninstall (testable)"
    Assert-True ($src -match "InvocationName -ne '\.'")     "U0. auto-run guard (skipped when dot-sourced)"
    Assert-True ($src -match '\[switch\]\$RemoveCore')      "U0. -RemoveCore flag declared"
    # Criterion (5c): ZERO hard-coded list of agent names — only SKILLS_DEFAULT
    # (skills, pre-existing, allowed) may appear; no literal list of agents
    # (sdlc-architect, nestor-clara, etc.) hard-coded in the script.
    Assert-True ($src -notmatch 'AGENTS_DEFAULT')                    "U0. no hard-coded AGENTS_DEFAULT list"
    Assert-True ($src -notmatch 'sdlc-architect')          "U0. no hard-coded literal agent name"
    Assert-True ($src -notmatch 'nestor-clara')               "U0. no hard-coded literal nestor-* agent name"
    Assert-True ($src -match "'agents/\*'")                   "U0. agents scope derived by domain prefix, not by name"

    # =======================================================================
    # (U1) default behavior (WITHOUT -RemoveCore): strict non-regression
    # =======================================================================
    Write-Host "-- (U1) default behavior: agents/core UNTOUCHED --" -ForegroundColor Cyan
    $u1 = New-UninstallCase -Name 'u1'
    $claudeMdBefore = Read-Text (Join-Path $u1.Live 'CLAUDE.md')
    $r1 = Invoke-UninstallCase -P @{ ClaudeRoot = $u1.Live; Force = $true }
    Assert-Eq 0 $r1.Rc "U1. exit 0"
    Assert-True (-not (Test-Live $u1 'skills/sdlc'))                    "U1. sdlc skill removed"
    Assert-True (-not (Test-Live $u1 'skills/sdlc-wave-orchestrator'))  "U1. wave-orchestrator skill removed"
    Assert-True (-not (Test-Live $u1 'commands/sdlc'))                  "U1. commands/sdlc removed"
    Assert-True (Test-Live $u1 'agents/sdlc-architect.md')              "U1. sdlc-architect agent UNTOUCHED (no -RemoveCore)"
    Assert-True (Test-Live $u1 'agents/nested/sdlc-deep.md')            "U1. nested agent UNTOUCHED"
    Assert-True (Test-Live $u1 'agents/nestor-clara.md')                  "U1. nestor-* agent UNTOUCHED"
    Assert-True (Test-Live $u1 'NESTOR.md')                               "U1. NESTOR.md core UNTOUCHED"
    Assert-True (Test-Live $u1 'CLAUDE.md')                               "U1. CLAUDE.md UNTOUCHED"
    $claudeMdAfter1 = Read-Text (Join-Path $u1.Live 'CLAUDE.md')
    Assert-Eq $claudeMdBefore $claudeMdAfter1 "U1. CLAUDE.md byte-identical (import NOT touched without -RemoveCore)"
    # backup: skills + commands only, NEVER agents/core
    $bkDirs1 = @(Get-BackupDirs -Case $u1)
    Assert-Eq 1 $bkDirs1.Count "U1. exactly 1 timestamped backup folder"
    $bk1Names = @(Get-ChildItem -LiteralPath $bkDirs1[0].FullName -Recurse -File | ForEach-Object { $_.Name })
    Assert-True (($bk1Names | Where-Object { $_ -eq 'SKILL.md' }).Count -ge 1) "U1. backup contains the skills"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $bkDirs1[0].FullName 'agents'))) "U1. backup does NOT contain agents/ (no -RemoveCore)"

    # =======================================================================
    # (U2) -RemoveCore: agents + core + import removed, backed up without collision
    # =======================================================================
    Write-Host "-- (U2) -RemoveCore: agents/core/import removed --" -ForegroundColor Cyan
    $u2 = New-UninstallCase -Name 'u2'
    $r2 = Invoke-UninstallCase -P @{ ClaudeRoot = $u2.Live; Force = $true; RemoveCore = $true }
    Assert-Eq 0 $r2.Rc "U2. exit 0"
    Assert-True (-not (Test-Live $u2 'skills/sdlc'))                     "U2. sdlc skill removed (base behavior preserved)"
    Assert-True (-not (Test-Live $u2 'agents/sdlc-architect.md'))        "U2. sdlc-architect agent removed"
    Assert-True (-not (Test-Live $u2 'agents/nested/sdlc-deep.md'))      "U2. nested agent removed"
    Assert-True (Test-Live $u2 'agents/nestor-clara.md')            "U2. nestor-* agent NOT removed (outside the SDLC domain)"
    Assert-True (Test-Live $u2 'NESTOR.md')                         "U2. NESTOR.md core NOT removed (outside the SDLC domain)"
    Assert-True (Test-Live $u2 'CLAUDE.md')                                "U2. CLAUDE.md itself PRESERVED (only the import line is removed)"
    $claudeMdAfter2 = Read-Text (Join-Path $u2.Live 'CLAUDE.md')
    Assert-True ($claudeMdAfter2 -notmatch '(?m)^\s*@NESTOR\.md\s*$') "U2. '@NESTOR.md' line removed from CLAUDE.md"
    Assert-True ($claudeMdAfter2 -match 'Pre-existing user content\.') "U2. rest of the CLAUDE.md content preserved"
    # backup: agents present, WITHOUT basename collision (nested vs root)
    $bkDirs2 = @(Get-BackupDirs -Case $u2)
    Assert-Eq 1 $bkDirs2.Count "U2. exactly 1 timestamped backup folder"
    $bkRoot2 = $bkDirs2[0].FullName
    Assert-True (Test-Path -LiteralPath (Join-Path $bkRoot2 'agents\sdlc-architect.md')) "U2. backup: root agent present"
    Assert-True (Test-Path -LiteralPath (Join-Path $bkRoot2 'agents\nested\sdlc-deep.md')) "U2. backup: nested agent present (full relative path, no collision)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $bkRoot2 'agents\nestor-clara.md'))) "U2. backup: nestor-* agent absent"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $bkRoot2 'NESTOR.md'))) "U2. backup: NESTOR.md core absent"

    # =======================================================================
    # (U3) -RemoveCore on a live tree WITHOUT agents/core: graceful no-op
    # =======================================================================
    Write-Host "-- (U3) -RemoveCore without agents/core present: graceful no-op --" -ForegroundColor Cyan
    $u3 = New-UninstallCase -Name 'u3'
    Remove-Item -LiteralPath (Join-Path $u3.Live 'agents') -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $u3.Live 'NESTOR.md') -Force
    Remove-Item -LiteralPath (Join-Path $u3.Live 'CLAUDE.md') -Force
    $r3 = Invoke-UninstallCase -P @{ ClaudeRoot = $u3.Live; Force = $true; RemoveCore = $true }
    Assert-Eq 0 $r3.Rc "U3. exit 0 (no crash without agents/core/CLAUDE.md)"
    Assert-True (-not (Test-Live $u3 'skills/sdlc')) "U3. skills still removed normally"

    # =======================================================================
    # (U4) interactive confirmation refused (without -Force): cancelled, live intact
    # =======================================================================
    Write-Host "-- (U4) confirmation refused (without -Force): cancelled --" -ForegroundColor Cyan
    $u4 = New-UninstallCase -Name 'u4'
    # Mock Read-Host (scope of the Invoke-Uninstall function imported in this script):
    # a local function in the same scope shadows the native cmdlet.
    function Read-Host { param($Prompt) return 'non' }
    $r4 = Invoke-UninstallCase -P @{ ClaudeRoot = $u4.Live }
    Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
    Assert-Eq 0 $r4.Rc "U4. answer 'non': exit 0 (cancelled, no error)"
    Assert-True (Test-Live $u4 'skills/sdlc') "U4. cancelled: live intact (nothing removed)"

    # --- Summary -----------------------------------------------------------
    Write-Host ""
    $bilanColor = 'Green'
    if ($script:Failed -gt 0) { $bilanColor = 'Red' }
    Write-Host ("=== Summary: {0} PASS / {1} FAIL ===" -f $script:Passed, $script:Failed) -ForegroundColor $bilanColor
    if ($script:Failed -gt 0) {
        Write-Host "Failures:" -ForegroundColor Red
        foreach ($f in $script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
        exit 1
    }
    exit 0
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
