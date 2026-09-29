#requires -Version 5.1
<#
.SYNOPSIS
  Self-contained, assert-based self-check (ZERO dependency: no Pester) of verify.ps1
  (P014:A010 — REF-authoritative fidelity checker).

.DESCRIPTION
  Creates ALL its fixtures in a single TEMP directory (fake git REF repo + fake LIVE
  dir) — NEVER operates on the real sdlc-framework repo nor on ~/.claude.
  Cleans up in finally. Exit code != 0 on the first failure.

  Covers each Code Lock criterion of P014:
   - READ-ONLY: verify writes no file (ref+live FS unchanged before/after).
   - Committed HEAD comparison: changing the ref WORKING TREE after a commit does
     NOT change the verdict (proves HEAD, not the working tree).
   - Reuses the single exclusion set: a live .pyc => PASS (not extra).
   - Derived floors: no literal skill/agent/command count in the source; count computed.
   - Fidelity: PASS if byte-identical; FAIL on missing / hash-diff / extra.
   - Third-party live skill (not sdlc*) => ignored, verdict unchanged (H7).

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

# --- Locations of the scripts under test --------------------------------------
$scriptsDir = Split-Path -Parent $PSScriptRoot
$libPath = Join-Path $scriptsDir 'sync-lib.ps1'
$verifyPath = Join-Path $scriptsDir 'verify.ps1'
foreach ($p in @($libPath, $verifyPath)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "Not found: $p" -ForegroundColor Red; exit 2 }
}

# Dot-source: verify.ps1's InvocationName guard prevents the auto-run.
. $libPath
. $verifyPath

# --- Fixtures ---------------------------------------------------------------
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('verify-test-' + [System.Guid]::NewGuid().ToString('N'))
$refRoot = Join-Path $work 'ref'
$liveRoot = Join-Path $work 'live'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Text {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

# DOMAIN files (present in the committed ref AND in live for a faithful install).
$domainFiles = [ordered]@{
    'skills/sdlc/SKILL.md'                    = "main skill`n"
    'skills/sdlc-wave-orchestrator/SKILL.md'  = "wave orchestrator`n"
    'skills/sdlc-lang-dispatcher/SKILL.md'    = "lang dispatcher`n"
    'commands/sdlc/brainstorm.md'             = "brainstorm cmd`n"
    'commands/sdlc/plan.md'                   = "plan cmd`n"
    'agents/sdlc-python.md'                   = "python agent`n"
    'agents/sdlc-js.md'                       = "js agent`n"
}
# REF-only files outside the domain: never expected on the live side (must not be
# flagged missing). Checks H3 (embedded command) and H7 (third-party skill).
$refOnlyFiles = [ordered]@{
    'skills/sdlc/commands/embedded.md'        = "stale embedded command`n"   # H3
    'skills/other-thirdparty/SKILL.md'          = "third-party skill`n"        # H7
    'skills/sdlc-standalone.md'               = "loose 2-segment sdlc file`n" # S1: loose, outside the domain
    'README.md'                                 = "outside the domain`n"
    'OTHER.md'                                  = "arbitrary root file`n"      # A018: no open root pattern
}

function Reset-Live {
    if (Test-Path -LiteralPath $liveRoot) { Remove-Item -LiteralPath $liveRoot -Recurse -Force }
    foreach ($rel in $domainFiles.Keys) {
        Write-Text -Path (Join-Path $liveRoot ($rel -replace '/', [string][System.IO.Path]::DirectorySeparatorChar)) -Text $domainFiles[$rel]
    }
}

function Get-TreeFingerprint {
    # Stable fingerprint of the whole tree (relpath|sha), .git excluded — to prove
    # that verify is READ-ONLY (nothing created/modified/deleted).
    param([string]$Root)
    $items = Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
    $parts = @()
    foreach ($f in ($items | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/')
        $parts += ($rel + '|' + (Get-FileHashByteExact -Path $f.FullName))
    }
    return ($parts -join "`n")
}

try {
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    # --- Build the fake REF repo and commit ---------------------------------
    foreach ($rel in $domainFiles.Keys) {
        Write-Text -Path (Join-Path $refRoot ('claude/' + $rel)) -Text $domainFiles[$rel]
    }
    foreach ($rel in $refOnlyFiles.Keys) {
        Write-Text -Path (Join-Path $refRoot ('claude/' + $rel)) -Text $refOnlyFiles[$rel]
    }
    & git -C $refRoot init -q
    & git -C $refRoot config user.email 'test@example.com'
    & git -C $refRoot config user.name 'verify test'
    & git -C $refRoot config commit.gpgsign false
    & git -C $refRoot config core.autocrlf false
    & git -C $refRoot add -A
    & git -C $refRoot commit -q -m 'seed ref'
    if ($LASTEXITCODE -ne 0) { throw "ref fixture commit failed" }

    Reset-Live

    # === T1: PERFECT fidelity => exit 0 =====================================
    $rc = Invoke-Verify -RefRoot $refRoot -LiveRoot $liveRoot -Quiet
    Assert-True -Condition ($rc -eq 0) -Name "T1 byte-identical => exit 0 (PASS)"

    # === T2: READ-ONLY (ref+live FS unchanged before/after) ==================
    $fpRefBefore = Get-TreeFingerprint -Root $refRoot
    $fpLiveBefore = Get-TreeFingerprint -Root $liveRoot
    $null = Invoke-Verify -RefRoot $refRoot -LiveRoot $liveRoot -Quiet
    $fpRefAfter = Get-TreeFingerprint -Root $refRoot
    $fpLiveAfter = Get-TreeFingerprint -Root $liveRoot
    Assert-True -Condition ($fpRefBefore -eq $fpRefAfter)  -Name "T2 READ-ONLY: REF tree unchanged"
    Assert-True -Condition ($fpLiveBefore -eq $fpLiveAfter) -Name "T2 READ-ONLY: LIVE tree unchanged"

    # === T3: compares the committed HEAD, not the working tree ================
    # Dirty the ref WORKING TREE (no commit): the verdict must stay 0.
    Reset-Live
    $wtFile = Join-Path $refRoot 'claude/skills/sdlc/SKILL.md'
    [System.IO.File]::WriteAllText($wtFile, "WORKING TREE MODIFIED - NOT COMMITTED`n", $utf8)
    $rc = Invoke-Verify -RefRoot $refRoot -LiveRoot $liveRoot -Quiet
    Assert-True -Condition ($rc -eq 0) -Name "T3 committed HEAD (dirty ref working tree ignored) => exit 0"
    & git -C $refRoot checkout -q -- claude  # restore the working tree

    # === T4: live .pyc => NOT extra (centralized exclusion set) ==============
    Reset-Live
    Write-Text -Path (Join-Path $liveRoot 'skills/sdlc/__pycache__/mod.pyc') -Text "bytecode"
    Write-Text -Path (Join-Path $liveRoot 'skills/sdlc/leftover.pyc') -Text "bytecode2"
    $rc = Invoke-Verify -RefRoot $refRoot -LiveRoot $liveRoot -Quiet
    Assert-True -Condition ($rc -eq 0) -Name "T4 live .pyc ignored (M1) => exit 0"

    # === T5: derived floors — no literal 10/12/18, count computed =============
    $src = Get-Content -LiteralPath $verifyPath -Raw
    Assert-True -Condition ($src -notmatch '\b1[028]\b') -Name "T5 no literal 10/12/18 in verify.ps1"
    Assert-True -Condition ($src -match 'Get-DomainCardinalities') -Name "T5 floors computed (Get-DomainCardinalities present)"

    # === T6a: missing live file => FAIL (exit != 0) ==========================
    Reset-Live
    Remove-Item -LiteralPath (Join-Path $liveRoot 'agents/sdlc-python.md') -Force
    $rc = Invoke-Verify -RefRoot $refRoot -LiveRoot $liveRoot -Quiet
    Assert-True -Condition ($rc -ne 0) -Name "T6a MISSING => exit != 0 (FAIL)"

    # === T6b: different hash => FAIL ==========================================
    Reset-Live
    [System.IO.File]::WriteAllText((Join-Path $liveRoot 'commands/sdlc/plan.md'), "DIVERGENT CONTENT`n", $utf8)
    $rc = Invoke-Verify -RefRoot $refRoot -LiveRoot $liveRoot -Quiet
    Assert-True -Condition ($rc -ne 0) -Name "T6b HASH DIFF => exit != 0 (FAIL)"

    # === T6c: real extra file (non-excluded domain file) => FAIL ==============
    Reset-Live
    Write-Text -Path (Join-Path $liveRoot 'skills/sdlc/EXTRA.md') -Text "real extra file`n"
    $rc = Invoke-Verify -RefRoot $refRoot -LiveRoot $liveRoot -Quiet
    Assert-True -Condition ($rc -ne 0) -Name "T6c real EXTRA => exit != 0 (FAIL)"

    # === T7: third-party live skill (not sdlc*) => ignored (H7) => exit 0 =====
    Reset-Live
    Write-Text -Path (Join-Path $liveRoot 'skills/my-personal-skill/SKILL.md') -Text "third-party live skill`n"
    Write-Text -Path (Join-Path $liveRoot 'agents/other-agent.md') -Text "third-party live agent`n"
    $rc = Invoke-Verify -RefRoot $refRoot -LiveRoot $liveRoot -Quiet
    Assert-True -Condition ($rc -eq 0) -Name "T7 third-party live skill/agent ignored (H7) => exit 0"

    # === T8: committed loose 2-segment sdlc* file (skills/sdlc-standalone.md) ==
    # Fidelity oracle: the REF classifier (Test-InSdlcDomain) must mirror
    # Get-DomainRelPaths (LIVE) EXACTLY, which only recurses into files INSIDE a
    # skill folder (>=3 segments). A loose 2-segment file must be in-domain on
    # NEITHER side, otherwise a phantom MISSING appears.
    Reset-Live  # byte-identical live, WITHOUT the loose file (never installed)
    $rc = Invoke-Verify -RefRoot $refRoot -LiveRoot $liveRoot -Quiet
    Assert-True -Condition ($rc -eq 0) -Name "T8 committed loose 2-segment sdlc* file => outside the domain => exit 0"
    # Direct assertion on the oracle: both sides agree on this relPath.
    Assert-True -Condition (-not (Test-InSdlcDomain -RelPath 'skills/sdlc-standalone.md')) `
        -Name "T8 Test-InSdlcDomain('skills/sdlc-standalone.md') = False (mirror of Get-DomainRelPaths)"
    # Non-regression: a real skill file (>=3 segments) stays in-domain.
    Assert-True -Condition (Test-InSdlcDomain -RelPath 'skills/sdlc/SKILL.md') `
        -Name "T8 Test-InSdlcDomain('skills/sdlc/SKILL.md') = True (legitimate skill kept)"

    # === T9: P021:A018 extension — core domain + nestor-* pattern =============
    # (T1 already proves: byte-identical NESTOR.md + agents/nestor-* => exit 0,
    #  and a committed root OTHER.md is never flagged missing.)
    Reset-Live
    # T9a: the core domain cardinality appears in the report
    #      (next to skills/agents/commands), derived value 0/1.
    $streamed9 = Invoke-Verify -RefRoot $refRoot -LiveRoot $liveRoot *>&1
    $text9 = (@($streamed9 | Where-Object { $_ -isnot [int] }) | ForEach-Object { $_.ToString() }) -join "`n"
    Assert-True -Condition ($text9 -match 'core=0') -Name "T9a verify report: core domain cardinality shown (core=0)"
    Assert-True -Condition ($text9 -match 'skills=\d+ agents=\d+ commands=\d+ core=\d+') -Name "T9a core cardinality next to skills/agents/commands"
    # T9d: git-tree projection == FS classifier on the new domains
    Assert-True -Condition (-not (Test-InSdlcDomain -RelPath 'NESTOR.md')) `
        -Name "T9d Test-InSdlcDomain('NESTOR.md') = False (outside the SDLC domain)"
    Assert-True -Condition (-not (Test-InSdlcDomain -RelPath 'OTHER.md')) `
        -Name "T9d Test-InSdlcDomain('OTHER.md') = False (no open root pattern)"
    Assert-True -Condition (-not (Test-InSdlcDomain -RelPath 'agents/nestor-analyste.md')) `
        -Name "T9d Test-InSdlcDomain('agents/nestor-analyste.md') = False (outside the SDLC domain)"
    Assert-True -Condition (-not (Test-InSdlcDomain -RelPath 'agents/other-agent.md')) `
        -Name "T9d Test-InSdlcDomain('agents/other-agent.md') = False (no matching pattern)"

    # === T9e: CASE parity (SP3 adversarial review) — case-SENSITIVE classification
    #     aligned on git ls-tree + bash. A wrong spelling is outside the domain on
    #     BOTH sides (otherwise PS/bash exit codes diverge on the same repo). ======
    Assert-True -Condition (-not (Test-InSdlcDomain -RelPath 'nestor.md')) `
        -Name "T9e 'nestor.md' (wrong case) = False (case-sensitive NESTOR.md literal)"
    Assert-True -Condition (-not (Test-InSdlcDomain -RelPath 'agents/Nestor-rh.md')) `
        -Name "T9e 'agents/Nestor-rh.md' (wrong case) = False (case-sensitive nestor-* pattern)"
    Assert-True -Condition (-not (Test-InSdlcDomain -RelPath 'agents/SDLC-py.md')) `
        -Name "T9e 'agents/SDLC-py.md' (wrong case) = False (case-sensitive sdlc-* pattern)"
    Assert-True -Condition (-not (Test-InSdlcDomain -RelPath 'skills/SDLC-x/SKILL.md')) `
        -Name "T9e 'skills/SDLC-x/SKILL.md' (wrong case) = False (case-sensitive skill folder)"

} finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Final report -------------------------------------------------------------
Write-Host ""
Write-Host ("Result: {0} PASS / {1} FAIL" -f $script:Passed, $script:Failed) -ForegroundColor Cyan
if ($script:Failed -gt 0) {
    foreach ($f in $script:Failures) { Write-Host ("  - " + $f) -ForegroundColor Red }
    exit 1
}
exit 0
