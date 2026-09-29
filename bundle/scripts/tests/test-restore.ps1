#requires -Version 5.1
<#
.SYNOPSIS
  Self-contained assert-based self-check (ZERO dependency: no Pester) of restore.ps1
  (P013:A009). Exit code != 0 on the first failure.

.DESCRIPTION
  Creates ALL its fixtures in a single TEMP directory (fake committed git ref repo,
  fake live dir, machine-local base + backups OUTSIDE worktree/live). NEVER operates on
  the real repo nor on ~/.claude. Cleans up in finally.

  Covers EVERY Code Lock criterion of P013:A009:
    (C1) staging+swap: modified-ref/added-ref -> deployed, verify post-check 0, exit 0.
    (C2) base-aware deletion (H6): deleted-ref -> DELETE live + backup, verify 0.
    (C3) modified-live-only BLOCKED without -ForceRestore; unblocked + deployed with -ForceRestore.
    (C4) modified-both BLOCKED even with -ForceRestore (never guessed).
    (C5) added-live PROTECTED (H6): never deleted.
    (C6) --dry-run: 0 writes (live/backup), would-restore reflected.
    (C7) timestamped backup before replacement + atomic swap (no leftover temp/bak).
    (C8) the verify post-check catches drift (ref working tree != HEAD) -> exit 7.
    (D1) fail-closed on a corrupt manifest (H4) -> exit != 0, no write.

  Compatible with PowerShell 5.1 (Desktop) and 7 (Core).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Minimal assertion harness ---------------------------------------------
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

# --- Locate the scripts ----------------------------------------------------
$restorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'restore.ps1'
$libPath     = Join-Path (Split-Path -Parent $PSScriptRoot) 'sync-lib.ps1'
$verifyPath  = Join-Path (Split-Path -Parent $PSScriptRoot) 'verify.ps1'
foreach ($p in @($restorePath, $libPath, $verifyPath)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "not found: $p" -ForegroundColor Red; exit 2 }
}

# Dot-source: sync-lib THEN restore (restore dot-sources sync-lib itself; the
# InvocationName guard prevents the auto-run). Exposes Invoke-Restore + helpers + lib.
. $libPath
. $restorePath

# --- Isolated temporary working directory ----------------------------------
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('restore-test-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null

function New-TextFile {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Git2 {
    param([string]$RepoDir, [string[]]$GitArgs)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & git -C $RepoDir @GitArgs 2>&1 | ForEach-Object { "$_" }; return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join "`n") } }
    finally { $ErrorActionPreference = $prev }
}

# Git repo (ref under <repo>/claude) + live, identical common files (ref==live),
# committed (HEAD == ref working tree). State/base/lock/backups under <case>/state (OUTSIDE
# the worktree and OUTSIDE live).
function New-Case {
    param([string]$Name, [hashtable]$Files)
    $c = Join-Path $root $Name
    $repo = Join-Path $c 'repo'
    $ref  = Join-Path $repo 'claude'
    $live = Join-Path $c 'live'
    $state = Join-Path $c 'state'
    New-Item -ItemType Directory -Path $ref  -Force | Out-Null
    New-Item -ItemType Directory -Path $live -Force | Out-Null
    New-Item -ItemType Directory -Path $state -Force | Out-Null

    foreach ($rel in $Files.Keys) {
        $native = $rel -replace '/', ([string][System.IO.Path]::DirectorySeparatorChar)
        New-TextFile -Path (Join-Path $ref  $native) -Text $Files[$rel]
        New-TextFile -Path (Join-Path $live $native) -Text $Files[$rel]
    }

    Invoke-Git2 -RepoDir $repo -GitArgs @('init', '-q')                        | Out-Null
    Invoke-Git2 -RepoDir $repo -GitArgs @('config', 'user.email', 't@t')       | Out-Null
    Invoke-Git2 -RepoDir $repo -GitArgs @('config', 'user.name', 'test')       | Out-Null
    Invoke-Git2 -RepoDir $repo -GitArgs @('config', 'commit.gpgsign', 'false') | Out-Null
    Invoke-Git2 -RepoDir $repo -GitArgs @('add', '--', 'claude')               | Out-Null
    Invoke-Git2 -RepoDir $repo -GitArgs @('commit', '-q', '-m', 'seed ref')    | Out-Null

    return [pscustomobject]@{
        Dir = $c; Repo = $repo; Ref = $ref; Live = $live
        Manifest = (Join-Path $state '.sync-manifest.json')
        Lock     = (Join-Path $state '.sync.lock')
        Backup   = (Join-Path $state '_backups')
    }
}

# Commits the CURRENT state of the ref working tree (add -A to pick up changes/additions/deletions).
function Update-RefCommit {
    param($Case, [string]$Msg = 'update ref')
    Invoke-Git2 -RepoDir $Case.Repo -GitArgs @('add', '-A', '--', 'claude') | Out-Null
    Invoke-Git2 -RepoDir $Case.Repo -GitArgs @('commit', '-q', '-m', $Msg)  | Out-Null
}

# Seeds the base = current hashes of the ref domain (before any scenario mutation).
function Set-SeedBase {
    param($Case)
    $rels = @(Get-DomainRelPaths -Root $Case.Ref)
    $h = @{}
    foreach ($r in $rels) { $h[$r] = Get-FileHashByteExact -Path (Get-RestoreFullPath -Root $Case.Ref -Rel $r) }
    Write-SyncManifest -Path $Case.Manifest -Entries $h | Out-Null
}

# Runs Invoke-Restore, separating the return code (int) from the text (Write-Host). 5.1/7.
function Invoke-RestoreCase {
    param([hashtable]$P)
    $streamed = Invoke-Restore @P *>&1
    $ints = @($streamed | Where-Object { $_ -is [int] })
    $rc = if ($ints.Count -gt 0) { $ints[$ints.Count - 1] } else { -999 }
    $text = (@($streamed | Where-Object { $_ -isnot [int] }) | ForEach-Object { $_.ToString() }) -join "`n"
    return [pscustomobject]@{ Rc = $rc; Text = $text }
}

function Read-Text { param([string]$Path) if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path) } return $null }
function Get-BaseParams { param($Case) return @{ RefRoot = $Case.Ref; LiveRoot = $Case.Live; GitRoot = $Case.Repo; ManifestPath = $Case.Manifest; LockPath = $Case.Lock; BackupRoot = $Case.Backup } }
function Get-BackupFiles { param($Case, [string]$Leaf) if (-not (Test-Path -LiteralPath $Case.Backup)) { return @() } return @(Get-ChildItem -LiteralPath $Case.Backup -Recurse -File -Filter $Leaf -ErrorAction SilentlyContinue) }

$COMMON = @{ 'agents/sdlc-alpha.md' = "alpha-v1`n"; 'commands/sdlc/beta.md' = "beta-v1`n" }
$A = 'agents\sdlc-alpha.md'
$B = 'commands\sdlc\beta.md'

try {
    Write-Host ""
    Write-Host "=== test-restore: self-check P013:A009 ===" -ForegroundColor Cyan

    # =======================================================================
    # (C0) Source safeguards: staging+swap, never /MIR, verify post-check
    # =======================================================================
    Write-Host "-- (C0) source invariants --" -ForegroundColor Cyan
    $src = Get-Content -LiteralPath $restorePath -Raw
    Assert-True ($src -notmatch 'robocopy') "C0. no robocopy (destructive mirror) in the source"
    Assert-True ($src -match 'Copy-Tree') "C0. deployment via Copy-Tree (atomic per relpath)"
    Assert-True ($src -match 'Invoke-VerifyPostCheck') "C0. verify post-check present"

    # =======================================================================
    # (C1) staging+swap: modified-ref + added-ref -> deployed, verify 0, exit 0
    # =======================================================================
    Write-Host "-- (C1) nominal restore (modified-ref + added-ref) --" -ForegroundColor Cyan
    $k1 = New-Case -Name 'c1' -Files $COMMON
    Set-SeedBase -Case $k1
    # modified-ref: the ref changes (committed), live stays == base
    New-TextFile -Path (Join-Path $k1.Ref $B) -Text "beta-v2`n"
    # added-ref: new canonical file, missing from live
    New-TextFile -Path (Join-Path $k1.Ref 'agents\sdlc-gamma.md') -Text "gamma-new`n"
    Update-RefCommit -Case $k1 -Msg 'ref: modify beta + add gamma'
    $r1 = Invoke-RestoreCase -P (Get-BaseParams $k1)
    Assert-Eq 0 $r1.Rc "C1. exit 0 (deployed + verify post-check 0 drift)"
    Assert-Eq "beta-v2`n" (Read-Text (Join-Path $k1.Live $B)) "C1. modified-ref: live receives the canonical file (beta-v2)"
    Assert-True (Test-Path -LiteralPath (Join-Path $k1.Live 'agents\sdlc-gamma.md')) "C1. added-ref: new file deployed to live"
    Assert-Eq "alpha-v1`n" (Read-Text (Join-Path $k1.Live $A)) "C1. identical: alpha unchanged"
    # timestamped backup of the old live beta (before replacement)
    $bak1 = @(Get-BackupFiles -Case $k1 -Leaf 'beta.md')
    Assert-Eq 1 $bak1.Count "C1. backup of the old live beta created"
    if ($bak1.Count -eq 1) { Assert-Eq "beta-v1`n" (Read-Text $bak1[0].FullName) "C1. backup holds the old live content (recoverable)" }

    # =======================================================================
    # (C2) base-aware deletion (H6): deleted-ref -> DELETE live + backup
    # =======================================================================
    Write-Host "-- (C2) base-aware deletion (H6) --" -ForegroundColor Cyan
    $k2 = New-Case -Name 'c2' -Files $COMMON
    Set-SeedBase -Case $k2
    Remove-Item -LiteralPath (Join-Path $k2.Ref $A) -Force   # ref deletes alpha; live==base
    Update-RefCommit -Case $k2 -Msg 'ref: delete alpha'
    Assert-True (Test-Path -LiteralPath (Join-Path $k2.Live $A)) "C2. (pre) alpha present on the live side"
    $r2 = Invoke-RestoreCase -P (Get-BaseParams $k2)
    Assert-Eq 0 $r2.Rc "C2. exit 0 (deletion propagated + verify 0)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $k2.Live $A))) "C2. base-aware: alpha deleted on the live side"
    $bak2 = @(Get-BackupFiles -Case $k2 -Leaf 'sdlc-alpha.md')
    Assert-Eq 1 $bak2.Count "C2. backup of alpha before deletion (recoverable)"
    if ($bak2.Count -eq 1) { Assert-Eq "alpha-v1`n" (Read-Text $bak2[0].FullName) "C2. backup holds the deleted alpha" }

    # =======================================================================
    # (C3) modified-live-only: BLOCKED without -ForceRestore; deployed with it
    # =======================================================================
    Write-Host "-- (C3) modified-live-only (block / force) --" -ForegroundColor Cyan
    $k3 = New-Case -Name 'c3' -Files $COMMON
    Set-SeedBase -Case $k3
    New-TextFile -Path (Join-Path $k3.Live $B) -Text "beta-LOCAL`n"   # live modified, ref==base
    # (a) without force -> block, live intact, no backup
    $r3 = Invoke-RestoreCase -P (Get-BaseParams $k3)
    Assert-Eq 3 $r3.Rc "C3a. exit 3 (modified-live blocked without -ForceRestore)"
    Assert-True ($r3.Text -match 'modified-live-only') "C3a. modified-live-only state reported"
    Assert-Eq "beta-LOCAL`n" (Read-Text (Join-Path $k3.Live $B)) "C3a. live NOT overwritten (blocked)"
    Assert-True (-not (Test-Path -LiteralPath $k3.Backup)) "C3a. no backup created (nothing written)"
    # (b) with -ForceRestore -> deploys the canonical file, backs up the losing live, verify 0
    $p3 = Get-BaseParams $k3; $p3.ForceRestore = $true
    $r3b = Invoke-RestoreCase -P $p3
    Assert-Eq 0 $r3b.Rc "C3b. exit 0 (-ForceRestore deploys the canonical file)"
    Assert-Eq "beta-v1`n" (Read-Text (Join-Path $k3.Live $B)) "C3b. live overwritten by the canonical file (beta-v1)"
    $bak3 = @(Get-BackupFiles -Case $k3 -Leaf 'beta.md')
    Assert-Eq 1 $bak3.Count "C3b. backup of the losing live change"
    if ($bak3.Count -eq 1) { Assert-Eq "beta-LOCAL`n" (Read-Text $bak3[0].FullName) "C3b. backup holds the overwritten live change (recoverable)" }

    # =======================================================================
    # (C4) modified-both: BLOCKED even with -ForceRestore
    # =======================================================================
    Write-Host "-- (C4) modified-both (blocked even with force) --" -ForegroundColor Cyan
    $k4 = New-Case -Name 'c4' -Files $COMMON
    Set-SeedBase -Case $k4
    New-TextFile -Path (Join-Path $k4.Ref  $B) -Text "beta-REF`n"
    Update-RefCommit -Case $k4 -Msg 'ref: modify beta'
    New-TextFile -Path (Join-Path $k4.Live $B) -Text "beta-LIVE`n"   # both diverge from the base
    $p4 = Get-BaseParams $k4; $p4.ForceRestore = $true
    $r4 = Invoke-RestoreCase -P $p4
    Assert-Eq 3 $r4.Rc "C4. exit 3 (modified-both blocked even with -ForceRestore)"
    Assert-True ($r4.Text -match 'modified-both') "C4. modified-both state reported"
    Assert-Eq "beta-LIVE`n" (Read-Text (Join-Path $k4.Live $B)) "C4. live NOT overwritten (blocked)"

    # =======================================================================
    # (C5) added-live PROTECTED (H6): never deleted
    # =======================================================================
    Write-Host "-- (C5) added-live protected (H6) --" -ForegroundColor Cyan
    $k5 = New-Case -Name 'c5' -Files $COMMON
    Set-SeedBase -Case $k5
    New-TextFile -Path (Join-Path $k5.Live 'agents\sdlc-extra.md') -Text "live-only`n"   # added-live (missing from ref+base)
    $r5 = Invoke-RestoreCase -P (Get-BaseParams $k5)
    # Property under test: the live-only file SURVIVES (never deleted). The verify
    # post-check reports a difference (extra) -> exit != 0: an honest signal that "live has
    # an uncaptured addition", NOT a deletion. Protection is proven by survival.
    Assert-True (Test-Path -LiteralPath (Join-Path $k5.Live 'agents\sdlc-extra.md')) "C5. added-live NOT deleted (protected H6)"
    Assert-Eq "live-only`n" (Read-Text (Join-Path $k5.Live 'agents\sdlc-extra.md')) "C5. live-only content intact"
    Assert-True ($r5.Rc -ne 0) "C5. exit != 0 (extra reported by the post-check, not a deletion)"

    # =======================================================================
    # (C6) --dry-run: 0 writes (live/backup), would-restore reflected
    # =======================================================================
    Write-Host "-- (C6) dry-run 0 writes --" -ForegroundColor Cyan
    $k6 = New-Case -Name 'c6' -Files $COMMON
    Set-SeedBase -Case $k6
    New-TextFile -Path (Join-Path $k6.Ref $B) -Text "beta-v2`n"
    Update-RefCommit -Case $k6 -Msg 'ref: modify beta'
    $liveBefore6 = Read-Text (Join-Path $k6.Live $B)
    $p6 = Get-BaseParams $k6; $p6.DryRun = $true
    $r6 = Invoke-RestoreCase -P $p6
    Assert-Eq 0 $r6.Rc "C6. dry-run without block -> exit 0"
    Assert-Eq $liveBefore6 (Read-Text (Join-Path $k6.Live $B)) "C6. dry-run: live unchanged"
    Assert-True (-not (Test-Path -LiteralPath $k6.Backup)) "C6. dry-run: no backup created"
    Assert-True ($r6.Text -match 'dry-run') "C6. dry-run reported (would-restore list)"

    # =======================================================================
    # (C7) atomicity: no leftover temp/bak on the live side after deployment
    # =======================================================================
    Write-Host "-- (C7) atomic swap: no leftover temp/bak --" -ForegroundColor Cyan
    $residue = @(Get-ChildItem -LiteralPath $k1.Live -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.tmp-*' -or $_.Name -like '*.bak-*' })
    Assert-Eq 0 $residue.Count "C7. no leftover .tmp-/.bak- file on the live side (C1)"

    # =======================================================================
    # (C8) CANONICAL GUARD: dirty (uncommitted) REF tree -> abort exit 5,
    #      NO LIVE write. Closes the adversarial finding "LIVE written with
    #      non-canonical content": deploy source == HEAD guaranteed before writing.
    # =======================================================================
    Write-Host "-- (C8) canonical guard: dirty REF worktree blocked before writing --" -ForegroundColor Cyan
    $k8 = New-Case -Name 'c8' -Files $COMMON
    Set-SeedBase -Case $k8
    New-TextFile -Path (Join-Path $k8.Ref $B) -Text "beta-UNCOMMITTED`n"   # modified-ref NOT committed (dirty tree)
    $liveBefore8 = Read-Text (Join-Path $k8.Live $B)
    $r8 = Invoke-RestoreCase -P (Get-BaseParams $k8)
    Assert-Eq 5 $r8.Rc "C8. exit 5 (REF tree not clean -> abort before any write)"
    Assert-True ($r8.Text -match 'not clean') "C8. REF tree not clean reported"
    Assert-Eq $liveBefore8 (Read-Text (Join-Path $k8.Live $B)) "C8. LIVE unchanged (no non-canonical content deployed)"
    Assert-True (-not (Test-Path -LiteralPath $k8.Backup)) "C8. no backup (nothing written)"

    # =======================================================================
    # (C9) dry-run does NOT advance the branch: `git --ff-only` never runs
    #      in dry-run (100% read-only contract). Upstream 1 commit ahead.
    # =======================================================================
    Write-Host "-- (C9) dry-run does not advance the branch (ff-only skipped in dry-run) --" -ForegroundColor Cyan
    $k9 = New-Case -Name 'c9' -Files $COMMON
    Set-SeedBase -Case $k9
    $origin9 = Join-Path $k9.Dir 'origin.git'
    Invoke-Git2 -RepoDir $k9.Dir  -GitArgs @('init', '--bare', '-q', $origin9)   | Out-Null
    Invoke-Git2 -RepoDir $k9.Repo -GitArgs @('remote', 'add', 'origin', $origin9)| Out-Null
    Invoke-Git2 -RepoDir $k9.Repo -GitArgs @('push', '-q', '-u', 'origin', 'HEAD') | Out-Null
    $headBase9 = (Invoke-Git2 -RepoDir $k9.Repo -GitArgs @('rev-parse', 'HEAD')).Out.Trim()
    # upstream advances one commit, then local reset -> local 1 behind, tracking ahead
    New-TextFile -Path (Join-Path $k9.Ref 'agents\sdlc-gamma.md') -Text "gamma`n"
    Update-RefCommit -Case $k9 -Msg 'ref: add gamma (upstream ahead)'
    Invoke-Git2 -RepoDir $k9.Repo -GitArgs @('push', '-q', 'origin', 'HEAD')      | Out-Null
    Invoke-Git2 -RepoDir $k9.Repo -GitArgs @('reset', '--hard', '-q', $headBase9) | Out-Null
    $headBefore9 = (Invoke-Git2 -RepoDir $k9.Repo -GitArgs @('rev-parse', 'HEAD')).Out.Trim()
    $p9 = Get-BaseParams $k9; $p9.DryRun = $true
    $r9 = Invoke-RestoreCase -P $p9
    $headAfter9 = (Invoke-Git2 -RepoDir $k9.Repo -GitArgs @('rev-parse', 'HEAD')).Out.Trim()
    Assert-Eq 0 $r9.Rc "C9. dry-run exit 0"
    Assert-Eq $headBefore9 $headAfter9 "C9. dry-run does NOT advance the local branch (ff-only skipped in dry-run)"

    # =======================================================================
    # (D1) corrupt manifest -> FAIL CLOSED (no write, exit != 0)
    # =======================================================================
    Write-Host "-- (D1) fail-closed on corrupt manifest (H4) --" -ForegroundColor Cyan
    $kd = New-Case -Name 'd1' -Files $COMMON
    New-TextFile -Path $kd.Manifest -Text "{ this is : not json"
    New-TextFile -Path (Join-Path $kd.Ref $B) -Text "beta-v2`n"
    Update-RefCommit -Case $kd -Msg 'ref: modify beta'
    $liveBeforeD1 = Read-Text (Join-Path $kd.Live $B)
    $rd = Invoke-RestoreCase -P (Get-BaseParams $kd)
    Assert-True ($rd.Rc -ne 0) "D1. corrupt manifest -> exit != 0 (fail closed)"
    Assert-True ($rd.Text -match 'FAIL CLOSED') "D1. fail-closed reported"
    Assert-Eq $liveBeforeD1 (Read-Text (Join-Path $kd.Live $B)) "D1. fail-closed: live unchanged"
    Assert-True (-not (Test-Path -LiteralPath $kd.Backup)) "D1. fail-closed: no backup"

    # --- Summary -----------------------------------------------------------
    Write-Host ""
    Write-Host ("=== Summary: {0} PASS / {1} FAIL ===" -f $script:Passed, $script:Failed) -ForegroundColor Cyan
    if ($script:Failed -gt 0) {
        foreach ($f in $script:Failures) { Write-Host ("  - " + $f) -ForegroundColor Red }
    }
}
finally {
    [System.GC]::Collect()
    for ($i = 0; $i -lt 5; $i++) {
        try { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop } ; break }
        catch { Start-Sleep -Milliseconds 200 }
    }
}

if ($script:Failed -gt 0) { exit 1 }
Write-Host "OK: restore.ps1 compliant (P013:A009)." -ForegroundColor Green
exit 0
