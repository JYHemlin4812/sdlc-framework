#requires -Version 5.1
<#
.SYNOPSIS
  sync-bdd.tests.ps1 (P017:A013) — assert-based BDD harness, ZERO dependency
  (no Pester, no third-party module), turning EVERY key acceptance criterion
  of the bidirectional sync (SP2) into temporary-repository fixtures.

.DESCRIPTION
  Each scenario creates its fixtures in an isolated TEMP directory: fake git repo
  (committed claude/ ref, HEAD == worktree), fake live, base/lock/backups/logs OUTSIDE
  the worktree AND outside live. NEVER operates on the real sdlc-framework repo nor on
  ~/.claude. Cleans everything up in finally (even on failure).

  Scenarios (>= 1 runnable assertion each):
    S1  modified-both conflict (capture without -Lww) -> exit 3 + diff + NOTHING written
        (ref file, manifest, git all intact).
    S1b modified-both conflict WITH -Lww -Provenance live -> capture proceeds (exit 0),
        conflicts.log logged and not empty, ref ADOPTS the live version (effective LWW).
    S2  restore protects modified-live-only (without -ForceRestore -> exit 3, live intact).
    S3  first-run: seed (ref==live); block (H5 asymmetry); -Adopt forces the seed.
    S4  --dry-run = 0 writes (capture AND restore).
    S5  partial failure / consistent tree: atomic restore swap (0 leftover tmp/bak);
        interrupted capture (worktree dirtied post-commit) detected -> exit!=0, base NOT rewritten.
    S6  verify PASS despite .pyc files on the live side (M1, centralized exclusions).
    S7  base-aware (H6): deleted-ref propagated (if live==base); added-live protected.
    S8  EOL: a CRLF .ps1 -> STABLE SHA256 over the capture->(commit)->restore cycle.
    S9  NEGATIVE verify (drift detection, the checker's reason to exist): live
        byte-identical to HEAD, then (a) bytes of a live domain file rewritten ->
        exit 1 + [HASH DIFF]; (b) live domain file deleted -> exit 1 + [MISSING].
  Adversarial review hardening:
    G1  DISCRIMINATING atomicity: Write-FileAtomic (temp+rename) is instrumented with a
        counter; a successful restore GOES THROUGH it >=1 time (proof that no write
        happens in place — the absence of leftovers (N4) alone would not prove it).
    G4  HARD exit-code oracles: each asserted exit code is EXACT (never -ne 0)
        and requires an int that was actually captured (Assert-Rc/HasRc), not a -999 sentinel.
  Absorbed nits (4_tests.md follow-ups):
    N1  Copy-Tree non-deletion: a destination file OUTSIDE the greenlist SURVIVES.
    N2  verify vacuous PASS on an empty ref (documented XFAIL — P014 defect, out of scope).
    N3  restore TOCTOU (external writer between backup and swap) — documented + best-effort.
    N4  runtime atomicity: no leftover *.tmp-/*.bak- after a successful write
        (capture on the ref side, restore on the live side).

  The floor==count test lives in planchers.assert.ps1 (sibling file): it READS the
  real claude/ ref (read-only) and does not belong among these temp fixtures.

  Compatible with PowerShell 5.1 (Desktop) and 7 (Core).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Assertion harness --------------------------------------------------------
$script:Passed = 0
$script:Failed = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Name)
    if ($Condition) { $script:Passed++; Write-Host ("  [PASS] " + $Name) -ForegroundColor Green }
    else { $script:Failed++; $script:Failures.Add($Name); Write-Host ("  [FAIL] " + $Name) -ForegroundColor Red }
}
function Assert-Eq {
    param($Expected, $Actual, [Parameter(Mandatory)][string]$Name)
    $ok = ($Expected -eq $Actual)
    if (-not $ok) { Write-Host ("         expected=[{0}] got=[{1}]" -f $Expected, $Actual) -ForegroundColor DarkYellow }
    Assert-True -Condition $ok -Name $Name
}
function Assert-Rc {
    # HARD exit-code oracle (G4). Requires a code that was ACTUALLY captured (HasRc):
    # a void/missing return (sentinel Rc=-999) is an explicit FAILURE —
    # never a vacuous `-ne 0` — then compares to the script's EXACT documented code.
    param([Parameter(Mandatory)]$R, [Parameter(Mandatory)][int]$Expected, [Parameter(Mandatory)][string]$Name)
    if (-not $R.HasRc) {
        $script:Failed++; $script:Failures.Add($Name)
        Write-Host ("  [FAIL] " + $Name + " (no exit code captured — void/missing return)") -ForegroundColor Red
        return
    }
    Assert-Eq $Expected $R.Rc $Name
}

# --- Locate + dot-source the scripts under test ------------------------------
$scriptsDir  = Split-Path -Parent $PSScriptRoot
$libPath     = Join-Path $scriptsDir 'sync-lib.ps1'
$capturePath = Join-Path $scriptsDir 'capture.ps1'
$restorePath = Join-Path $scriptsDir 'restore.ps1'
$verifyPath  = Join-Path $scriptsDir 'verify.ps1'
foreach ($p in @($libPath, $capturePath, $restorePath, $verifyPath)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "not found: $p" -ForegroundColor Red; exit 2 }
}
# InvocationName guards: dot-sourcing runs nothing. Exposes Invoke-Capture,
# Invoke-Restore, Invoke-Verify + helpers + the whole lib.
. $libPath
. $capturePath
. $restorePath
. $verifyPath

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Host "git is required by the BDD harness (capture/restore commit). Not found." -ForegroundColor Red
    exit 2
}

# --- Isolated temp root -------------------------------------------------------
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('sync-bdd-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null

# --- Fixture utilities (merge of the test-capture/test-restore patterns) ------
$utf8 = New-Object System.Text.UTF8Encoding($false)
function New-TextFile {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Get-Native { param([string]$Root, [string]$Rel) return (Join-Path $Root ($Rel -replace '/', ([string][System.IO.Path]::DirectorySeparatorChar))) }
function Read-Text  { param([string]$Path) if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path) } return $null }
function Hash-Safe  { param([string]$Path) if (Test-Path -LiteralPath $Path) { return (Get-FileHashByteExact -Path $Path) } return $null }

function Invoke-Git2 {
    param([string]$RepoDir, [string[]]$GitArgs)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & git -C $RepoDir @GitArgs 2>&1 | ForEach-Object { "$_" }; return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join "`n") } }
    finally { $ErrorActionPreference = $prev }
}
function Get-CommitCount {
    param([string]$RepoDir)
    $r = Invoke-Git2 -RepoDir $RepoDir -GitArgs @('rev-list', '--count', 'HEAD')
    if ($r.Code -ne 0) { return 0 } ; return [int]($r.Out.Trim())
}

# Git repo (ref under <repo>/claude) + live, identical common files, committed
# (HEAD == worktree). autocrlf false: git does not normalize EOLs (S8 byte-exact).
# State/base/lock/backups under <case>/state (OUTSIDE the worktree AND outside live).
function New-Case {
    param([string]$Name, [hashtable]$Files)
    $c = Join-Path $root $Name
    $repo = Join-Path $c 'repo'; $ref = Join-Path $repo 'claude'
    $live = Join-Path $c 'live'; $state = Join-Path $c 'state'
    New-Item -ItemType Directory -Path $ref  -Force | Out-Null
    New-Item -ItemType Directory -Path $live -Force | Out-Null
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    foreach ($rel in $Files.Keys) {
        New-TextFile -Path (Get-Native $ref  $rel) -Text $Files[$rel]
        New-TextFile -Path (Get-Native $live $rel) -Text $Files[$rel]
    }
    Invoke-Git2 -RepoDir $repo -GitArgs @('init', '-q')                        | Out-Null
    Invoke-Git2 -RepoDir $repo -GitArgs @('config', 'user.email', 't@t')       | Out-Null
    Invoke-Git2 -RepoDir $repo -GitArgs @('config', 'user.name', 'test')       | Out-Null
    Invoke-Git2 -RepoDir $repo -GitArgs @('config', 'commit.gpgsign', 'false') | Out-Null
    Invoke-Git2 -RepoDir $repo -GitArgs @('config', 'core.autocrlf', 'false')  | Out-Null
    Invoke-Git2 -RepoDir $repo -GitArgs @('add', '--', 'claude')               | Out-Null
    Invoke-Git2 -RepoDir $repo -GitArgs @('commit', '-q', '-m', 'seed ref')    | Out-Null
    return [pscustomobject]@{
        Dir = $c; Repo = $repo; Ref = $ref; Live = $live
        Manifest = (Join-Path $state '.sync-manifest.json')
        Conflict = (Join-Path $state 'conflicts.log')
        Lock     = (Join-Path $state '.sync.lock')
        Backup   = (Join-Path $state '_backups')
    }
}
function Update-RefCommit {
    param($Case, [string]$Msg = 'update ref')
    Invoke-Git2 -RepoDir $Case.Repo -GitArgs @('add', '-A', '--', 'claude') | Out-Null
    Invoke-Git2 -RepoDir $Case.Repo -GitArgs @('commit', '-q', '-m', $Msg)  | Out-Null
}
function Set-SeedBase {
    # base = current hashes of the ref domain (before the scenario mutation).
    param($Case)
    $h = @{}
    foreach ($r in @(Get-DomainRelPaths -Root $Case.Ref)) { $h[$r] = Get-FileHashByteExact -Path (Get-Native $Case.Ref $r) }
    Write-SyncManifest -Path $Case.Manifest -Entries $h | Out-Null
}
# Separates the return code (int) from the text (Write-Host) — robust on 5.1/7.
function Split-Rc {
    param($Streamed)
    $ints = @($Streamed | Where-Object { $_ -is [int] })
    $hasRc = ($ints.Count -gt 0)                     # G4: tracks the ABSENCE of an int (void return)
    $rc = if ($hasRc) { $ints[$ints.Count - 1] } else { -999 }
    $text = (@($Streamed | Where-Object { $_ -isnot [int] }) | ForEach-Object { $_.ToString() }) -join "`n"
    return [pscustomobject]@{ Rc = $rc; Text = $text; HasRc = $hasRc }
}
function Invoke-CaptureCase { param([hashtable]$P) return (Split-Rc (Invoke-Capture @P *>&1)) }
function Invoke-RestoreCase { param([hashtable]$P) return (Split-Rc (Invoke-Restore @P *>&1)) }
# Verify WITHOUT -Quiet: captures the code (int) AND the Say output (drift markers).
function Invoke-VerifyCase  { param($Case) return (Split-Rc (Invoke-Verify -RefRoot $Case.Repo -LiveRoot $Case.Live *>&1)) }
function Get-CaptureParams  { param($Case) return @{ RefRoot = $Case.Ref; LiveRoot = $Case.Live; GitRoot = $Case.Repo; ManifestPath = $Case.Manifest; ConflictLogPath = $Case.Conflict; LockPath = $Case.Lock } }
function Get-RestoreParams  { param($Case) return @{ RefRoot = $Case.Ref; LiveRoot = $Case.Live; GitRoot = $Case.Repo; ManifestPath = $Case.Manifest; LockPath = $Case.Lock; BackupRoot = $Case.Backup } }
function Get-Residue {
    # Leftover *.tmp-/*.bak- files under $Root (proof of atomicity: 0 after success).
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*.tmp-*' -or $_.Name -like '*.bak-*' })
}
function Get-BackupFiles {
    param($Case, [string]$Leaf)
    if (-not (Test-Path -LiteralPath $Case.Backup)) { return @() }
    return @(Get-ChildItem -LiteralPath $Case.Backup -Recurse -File -Filter $Leaf -ErrorAction SilentlyContinue)
}

$COMMON = @{ 'agents/sdlc-alpha.md' = "alpha-v1`n"; 'commands/sdlc/beta.md' = "beta-v1`n" }
$A = 'agents/sdlc-alpha.md'
$B = 'commands/sdlc/beta.md'

try {
    Write-Host ""
    Write-Host "=== sync-bdd.tests: SP2 BDD harness (P017:A013) ===" -ForegroundColor Cyan

    # =======================================================================
    # S1 — modified-both conflict (capture without -Lww) -> exit!=0 + diff + NOTHING written
    # =======================================================================
    Write-Host "-- S1 modified-both blocked (capture) --" -ForegroundColor Cyan
    $s1 = New-Case -Name 's1' -Files $COMMON
    Set-SeedBase -Case $s1
    New-TextFile -Path (Get-Native $s1.Ref  $A) -Text "alpha-REF`n"
    New-TextFile -Path (Get-Native $s1.Live $A) -Text "alpha-LIVE`n"   # ref AND live diverge from the base
    $refHashBefore = Hash-Safe (Get-Native $s1.Ref $A)
    $manBefore = Hash-Safe $s1.Manifest
    $commitsBefore = Get-CommitCount -RepoDir $s1.Repo
    $r1 = Invoke-CaptureCase -P (Get-CaptureParams $s1)
    Assert-Rc $r1 3 "S1. exit 3 (modified-both block, without -Lww)"
    Assert-True ($r1.Text -match 'modified-both') "S1. modified-both state/diff shown"
    Assert-Eq $refHashBefore (Hash-Safe (Get-Native $s1.Ref $A)) "S1. ref file NOT overwritten (nothing written)"
    Assert-Eq $manBefore (Hash-Safe $s1.Manifest) "S1. manifest NOT rewritten"
    Assert-Eq $commitsBefore (Get-CommitCount -RepoDir $s1.Repo) "S1. no new git commit"
    Assert-True (-not (Test-Path -LiteralPath $s1.Conflict)) "S1. conflicts.log NOT created (no -Lww)"

    # =======================================================================
    # S1b — modified-both WITH -Lww -Provenance live: capture PROCEEDS (G2)
    #   Resolve-LWW is conservative: winner=ref by default (protects the canonical file);
    #   winner=live REQUIRES -Provenance live. Without it, -Lww logs but adopts
    #   NOTHING (empty rels -> exit 0, ref unchanged). So we test the REAL adoption.
    # =======================================================================
    Write-Host "-- S1b modified-both -Lww -Provenance live (adoption) --" -ForegroundColor Cyan
    $s1b = New-Case -Name 's1b' -Files $COMMON
    Set-SeedBase -Case $s1b
    New-TextFile -Path (Get-Native $s1b.Ref  $A) -Text "alpha-REF`n"
    New-TextFile -Path (Get-Native $s1b.Live $A) -Text "alpha-LIVE`n"   # ref AND live diverge from the base
    $liveHash1b = Hash-Safe (Get-Native $s1b.Live $A)
    $p1b = Get-CaptureParams $s1b; $p1b.Lww = $true; $p1b.Provenance = 'live'
    $r1b = Invoke-CaptureCase -P $p1b
    Assert-Rc $r1b 0 "S1b. -Lww -Provenance live: capture proceeds -> exit 0"
    Assert-True (Test-Path -LiteralPath $s1b.Conflict) "S1b. conflicts.log created (-Lww logging)"
    $log1b = Read-Text $s1b.Conflict
    Assert-True (-not [string]::IsNullOrWhiteSpace($log1b)) "S1b. conflicts.log: logged content NOT empty"
    Assert-True ($log1b -match 'winner=live') "S1b. LWW log: winner=live (Last-Write-Wins adoption)"
    Assert-Eq $liveHash1b (Hash-Safe (Get-Native $s1b.Ref $A)) "S1b. ref ADOPTS the live version (ref hash == live hash)"

    # =======================================================================
    # S2 — restore protects modified-live-only (without -ForceRestore -> exit 3)
    # =======================================================================
    Write-Host "-- S2 restore protects modified-live-only --" -ForegroundColor Cyan
    $s2 = New-Case -Name 's2' -Files $COMMON
    Set-SeedBase -Case $s2
    New-TextFile -Path (Get-Native $s2.Live $B) -Text "beta-LOCAL`n"   # live modified, ref==base
    $r2 = Invoke-RestoreCase -P (Get-RestoreParams $s2)
    Assert-Rc $r2 3 "S2. exit 3 (modified-live blocked without -ForceRestore)"
    Assert-True ($r2.Text -match 'modified-live-only') "S2. modified-live-only state reported"
    Assert-Eq "beta-LOCAL`n" (Read-Text (Get-Native $s2.Live $B)) "S2. live NOT overwritten (protected)"
    Assert-True (-not (Test-Path -LiteralPath $s2.Backup)) "S2. no backup (nothing written)"

    # =======================================================================
    # S3 — first-run: seed (ref==live); block (H5 asymmetry); -Adopt forces the seed
    # =======================================================================
    Write-Host "-- S3 first-run seed / block / adopt (H5) --" -ForegroundColor Cyan
    $s3seed = New-Case -Name 's3seed' -Files $COMMON   # no base
    $r3a = Invoke-CaptureCase -P (Get-CaptureParams $s3seed)
    Assert-Rc $r3a 0 "S3. first-run seed (ref==live, no base) -> exit 0"
    Assert-True (Test-Path -LiteralPath $s3seed.Manifest) "S3. seed writes the base"
    $s3blk = New-Case -Name 's3blk' -Files $COMMON
    New-TextFile -Path (Get-Native $s3blk.Live 'agents/sdlc-extra.md') -Text "extra`n"   # presence asymmetry
    $r3b = Invoke-CaptureCase -P (Get-CaptureParams $s3blk)
    Assert-Rc $r3b 5 "S3. first-run asymmetry -> BLOCKED (exit 5)"
    Assert-True (-not (Test-Path -LiteralPath $s3blk.Manifest)) "S3. block: base NOT written"
    $p3c = Get-CaptureParams $s3blk; $p3c.Adopt = $true
    $r3c = Invoke-CaptureCase -P $p3c
    Assert-Rc $r3c 0 "S3. -Adopt forces the seed despite the asymmetry -> exit 0"
    Assert-True (Test-Path -LiteralPath $s3blk.Manifest) "S3. -Adopt writes the base"

    # =======================================================================
    # S4 — --dry-run = 0 writes (capture AND restore)
    # =======================================================================
    Write-Host "-- S4 dry-run 0 writes (capture + restore) --" -ForegroundColor Cyan
    # capture dry-run: modified-live + added-live pending -> 0 commit, 0 ref file, base unchanged
    $s4c = New-Case -Name 's4c' -Files $COMMON
    Set-SeedBase -Case $s4c
    New-TextFile -Path (Get-Native $s4c.Live 'agents/sdlc-new.md') -Text "would-add`n"
    New-TextFile -Path (Get-Native $s4c.Live $B) -Text "would-modify`n"
    $man4Before = Hash-Safe $s4c.Manifest
    $commits4Before = Get-CommitCount -RepoDir $s4c.Repo
    $p4c = Get-CaptureParams $s4c; $p4c.DryRun = $true
    $r4c = Invoke-CaptureCase -P $p4c
    Assert-Rc $r4c 0 "S4. capture dry-run without block -> exit 0"
    Assert-Eq $commits4Before (Get-CommitCount -RepoDir $s4c.Repo) "S4. capture dry-run: 0 commit"
    Assert-True (-not (Test-Path -LiteralPath (Get-Native $s4c.Ref 'agents/sdlc-new.md'))) "S4. capture dry-run: 0 ref file created"
    Assert-Eq $man4Before (Hash-Safe $s4c.Manifest) "S4. capture dry-run: manifest unchanged"
    # restore dry-run: modified-ref pending -> live unchanged, no backup
    $s4r = New-Case -Name 's4r' -Files $COMMON
    Set-SeedBase -Case $s4r
    New-TextFile -Path (Get-Native $s4r.Ref $B) -Text "beta-v2`n"
    Update-RefCommit -Case $s4r -Msg 'ref: modify beta'
    $liveBefore4 = Read-Text (Get-Native $s4r.Live $B)
    $p4r = Get-RestoreParams $s4r; $p4r.DryRun = $true
    $r4r = Invoke-RestoreCase -P $p4r
    Assert-Rc $r4r 0 "S4. restore dry-run without block -> exit 0"
    Assert-Eq $liveBefore4 (Read-Text (Get-Native $s4r.Live $B)) "S4. restore dry-run: live unchanged"
    Assert-True (-not (Test-Path -LiteralPath $s4r.Backup)) "S4. restore dry-run: no backup"

    # =======================================================================
    # S5 — partial failure / consistent tree
    #   (a) atomic restore swap -> 0 leftover tmp/bak on the live side (+ N4 ref side on capture)
    #   (b) interrupted capture (worktree dirtied post-commit) -> exit!=0, base NOT rewritten
    # =======================================================================
    Write-Host "-- S5 partial failure / consistent tree --" -ForegroundColor Cyan
    # (a) successful nominal restore (modified-ref) -> no leftover tmp/bak on the live side
    $s5a = New-Case -Name 's5a' -Files $COMMON
    Set-SeedBase -Case $s5a
    New-TextFile -Path (Get-Native $s5a.Ref $B) -Text "beta-v2`n"
    Update-RefCommit -Case $s5a -Msg 'ref: modify beta'
    $r5a = Invoke-RestoreCase -P (Get-RestoreParams $s5a)
    Assert-Rc $r5a 0 "S5a. nominal restore -> exit 0 (deployed + verify 0)"
    Assert-Eq 0 @(Get-Residue -Root $s5a.Live).Count "S5a. atomic swap: 0 leftover *.tmp-/*.bak- on the live side"
    # (b) interrupted capture: post-commit hook dirties the committed file again (greenlisted rel)
    $s5b = New-Case -Name 's5b' -Files $COMMON
    Set-SeedBase -Case $s5b
    $manB5 = Hash-Safe $s5b.Manifest
    $hook = Join-Path $s5b.Repo '.git/hooks/post-commit'
    New-TextFile -Path $hook -Text "#!/bin/sh`necho dirty >> claude/commands/sdlc/beta.md`n"
    New-TextFile -Path (Get-Native $s5b.Live $B) -Text "beta-capture`n"   # modified-live -> triggers the commit
    $r5b = Invoke-CaptureCase -P (Get-CaptureParams $s5b)
    Assert-Rc $r5b 7 "S5b. interrupted capture (dirty worktree) -> exit 7 POST-CHECK (no false green)"
    Assert-True ($r5b.Text -match 'POST-CHECK') "S5b. post-check failure reported"
    Assert-Eq $manB5 (Hash-Safe $s5b.Manifest) "S5b. base NOT rewritten on partial failure"

    # =======================================================================
    # S6 — verify PASS despite .pyc files on the live side (M1, centralized exclusions)
    # =======================================================================
    Write-Host "-- S6 verify PASS despite live .pyc (M1) --" -ForegroundColor Cyan
    $s6 = New-Case -Name 's6' -Files @{ 'skills/sdlc/SKILL.md' = "skill`n"; 'agents/sdlc-py.md' = "py`n"; 'commands/sdlc/x.md' = "x`n" }
    # byte-identical live + .pyc / __pycache__ noise (never extra)
    New-TextFile -Path (Get-Native $s6.Live 'skills/sdlc/__pycache__/mod.pyc') -Text "bytecode"
    New-TextFile -Path (Get-Native $s6.Live 'skills/sdlc/leftover.pyc') -Text "bytecode2"
    $rc6 = Invoke-Verify -RefRoot $s6.Repo -LiveRoot $s6.Live -Quiet
    Assert-Eq 0 $rc6 "S6. verify: live .pyc/__pycache__ ignored (M1) -> exit 0 (PERFECT fidelity)"

    # =======================================================================
    # S7 — base-aware (H6): deleted-ref propagated; added-live protected
    # =======================================================================
    Write-Host "-- S7 base-aware (H6): deletion / protection --" -ForegroundColor Cyan
    # (a) deleted-ref (live == base) -> DELETE live + backup, verify 0
    $s7a = New-Case -Name 's7a' -Files $COMMON
    Set-SeedBase -Case $s7a
    Remove-Item -LiteralPath (Get-Native $s7a.Ref $A) -Force   # ref deletes alpha; live==base
    Update-RefCommit -Case $s7a -Msg 'ref: delete alpha'
    $r7a = Invoke-RestoreCase -P (Get-RestoreParams $s7a)
    Assert-Rc $r7a 0 "S7a. exit 0 (base-aware deletion propagated + verify 0)"
    Assert-True (-not (Test-Path -LiteralPath (Get-Native $s7a.Live $A))) "S7a. base-aware: alpha deleted on the live side"
    $bak7 = @(Get-BackupFiles -Case $s7a -Leaf 'sdlc-alpha.md')
    Assert-Eq 1 $bak7.Count "S7a. backup of alpha before deletion (recoverable)"
    # (b) added-live protected: the live-only file SURVIVES (never deleted)
    $s7b = New-Case -Name 's7b' -Files $COMMON
    Set-SeedBase -Case $s7b
    New-TextFile -Path (Get-Native $s7b.Live 'agents/sdlc-extra.md') -Text "live-only`n"   # missing from ref+base
    $r7b = Invoke-RestoreCase -P (Get-RestoreParams $s7b)
    Assert-True (Test-Path -LiteralPath (Get-Native $s7b.Live 'agents/sdlc-extra.md')) "S7b. added-live NOT deleted (protected H6)"
    Assert-Eq "live-only`n" (Read-Text (Get-Native $s7b.Live 'agents/sdlc-extra.md')) "S7b. live-only content intact"
    Assert-Rc $r7b 7 "S7b. exit 7 (verify POST-CHECK: extra reported, NOT a deletion)"

    # =======================================================================
    # S8 — EOL: a CRLF .ps1 -> STABLE SHA256 over the capture->(commit)->restore cycle
    # =======================================================================
    Write-Host "-- S8 EOL CRLF: stable SHA256 capture->restore --" -ForegroundColor Cyan
    $CR = "hook-v1`r`nline2`r`n"   # explicit CRLF content
    $s8 = New-Case -Name 's8' -Files @{ 'agents/sdlc-alpha.md' = "alpha`n"; 'skills/sdlc/hook.ps1' = "base`n" }
    Set-SeedBase -Case $s8
    $s8rel = 'skills/sdlc/hook.ps1'
    New-TextFile -Path (Get-Native $s8.Live $s8rel) -Text $CR   # modified-live with CRLFs
    $shaCRLF = Get-FileHashByteExact -Path (Get-Native $s8.Live $s8rel)
    # capture: live -> ref + commit (simulated canonical "push")
    $r8c = Invoke-CaptureCase -P (Get-CaptureParams $s8)
    Assert-Rc $r8c 0 "S8. capture of the CRLF .ps1 -> exit 0"
    Assert-Eq $shaCRLF (Hash-Safe (Get-Native $s8.Ref $s8rel)) "S8. capture: ref byte-exact (CRLF kept, no EOL normalization)"
    # successful capture (HEAD-authoritative verify post-check already passed): runtime atomicity on the ref side.
    Assert-Eq 0 @(Get-Residue -Root $s8.Ref).Count "S8/N4. successful capture: 0 leftover *.tmp-/*.bak- on the ref side (runtime atomicity)"
    # restore the file after deleting it on the live side (deleted-live -> redeploys the canonical file)
    Remove-Item -LiteralPath (Get-Native $s8.Live $s8rel) -Force
    $r8r = Invoke-RestoreCase -P (Get-RestoreParams $s8)
    Assert-Rc $r8r 0 "S8. restore redeploys the CRLF .ps1 -> exit 0 (verify 0)"
    Assert-Eq $shaCRLF (Hash-Safe (Get-Native $s8.Live $s8rel)) "S8. capture->commit->restore cycle: STABLE SHA256 (CRLF byte-exact)"

    # =======================================================================
    # S9 — NEGATIVE verify: drift detection (the checker's reason to exist) (G3)
    #   Every other verify call is POSITIVE (expects 0). Here we
    #   ASSERT that verify returns != 0 (exit 1) AND names the right marker. If verify
    #   were mutated into an unconditional `return 0`, S9 would turn RED (non-vacuity).
    # =======================================================================
    Write-Host "-- S9 verify detects drift (HASH DIFF / MISSING) --" -ForegroundColor Cyan
    $s9files = @{ 'skills/sdlc/SKILL.md' = "skill`n"; 'agents/sdlc-py.md' = "py`n"; 'commands/sdlc/x.md' = "x`n" }
    # (a) bytes of a live domain file rewritten -> [HASH DIFF]
    $s9a = New-Case -Name 's9a' -Files $s9files   # live byte-identical to the committed HEAD
    $v9pre = Invoke-VerifyCase $s9a
    Assert-Rc $v9pre 0 "S9a. byte-identical baseline -> verify 0 (pre-corruption, proves non-vacuity)"
    New-TextFile -Path (Get-Native $s9a.Live 'skills/sdlc/SKILL.md') -Text "skill-CORRUPTED`n"
    $v9a = Invoke-VerifyCase $s9a
    Assert-Rc $v9a 1 "S9a. verify DETECTS the drift (rewritten bytes) -> exit 1"
    Assert-True ($v9a.Text -match '\[HASH DIFF\]') "S9a. verify reports [HASH DIFF] for the corrupted file"
    # (b) live domain file DELETED -> [MISSING]
    $s9b = New-Case -Name 's9b' -Files $s9files
    Remove-Item -LiteralPath (Get-Native $s9b.Live 'agents/sdlc-py.md') -Force
    $v9b = Invoke-VerifyCase $s9b
    Assert-Rc $v9b 1 "S9b. verify DETECTS the deleted file -> exit 1"
    Assert-True ($v9b.Text -match '\[MISSING\]') "S9b. verify reports [MISSING] for the deleted file"

    # =======================================================================
    # G1 — DISCRIMINATING atomicity: Write-FileAtomic ACTUALLY used
    #   The absence of *.tmp-/*.bak- leftovers (N4) does NOT PROVE atomicity: an
    #   in-place write would leave none either. We instrument the temp+rename
    #   primitive with a counter (shadow function that increments then delegates to
    #   the original), run a successful restore, and assert counter > 0:
    #   proof that the copy really goes through temp+rename, not a raw write.
    # =======================================================================
    Write-Host "-- G1 discriminating atomicity (Write-FileAtomic counter) --" -ForegroundColor Cyan
    $g1 = New-Case -Name 'g1' -Files $COMMON
    Set-SeedBase -Case $g1
    New-TextFile -Path (Get-Native $g1.Ref $B) -Text "beta-v2`n"   # modified-ref -> restore deploys
    Update-RefCommit -Case $g1 -Msg 'ref: modify beta'
    $script:WFACalls = 0
    $script:OrigWFA = ${function:Write-FileAtomic}
    function Write-FileAtomic { $script:WFACalls++; & $script:OrigWFA @args }   # shadow: count then delegate
    try {
        $rg1 = Invoke-RestoreCase -P (Get-RestoreParams $g1)
    }
    finally {
        ${function:Write-FileAtomic} = $script:OrigWFA   # restore the original primitive
    }
    Assert-Rc $rg1 0 "G1. nominal restore through the atomic primitive -> exit 0"
    Assert-True ($script:WFACalls -gt 0) "G1. Write-FileAtomic (temp+rename) USED >=1 time (proof of atomicity, no in-place write)"

    # =======================================================================
    # N1 — Copy-Tree non-deletion: a destination file OUTSIDE the greenlist SURVIVES
    # =======================================================================
    Write-Host "-- N1 Copy-Tree non-deletion (anti-/MIR) --" -ForegroundColor Cyan
    $ctSrc = Join-Path $root 'n1-src'; $ctDst = Join-Path $root 'n1-dst'
    New-TextFile -Path (Join-Path $ctSrc 'a.md') -Text 'AAA'
    New-TextFile -Path (Join-Path $ctDst 'preexisting.md') -Text 'PRECIOUS'   # OUTSIDE the greenlist, already in dst
    $copiedN1 = @(Copy-Tree -SrcRoot $ctSrc -DstRoot $ctDst -RelPaths @('a.md'))
    Assert-True (Test-Path -LiteralPath (Join-Path $ctDst 'a.md')) "N1. Copy-Tree copies the greenlisted rel (a.md)"
    Assert-True (Test-Path -LiteralPath (Join-Path $ctDst 'preexisting.md')) "N1. dst file OUTSIDE the greenlist SURVIVES (no deletion, anti-/MIR)"
    Assert-Eq 'PRECIOUS' (Read-Text (Join-Path $ctDst 'preexisting.md')) "N1. out-of-greenlist content intact"

    # =======================================================================
    # N2 — verify vacuous PASS on an empty ref (documented XFAIL — P014 defect)
    #   Committed ref WITHOUT any domain file + empty live: verify should report
    #   (expected exit 2, misconfigured oracle) but returns 0 (vacuous "PERFECT"
    #   fidelity, 0 differences). We ASSERT the REAL behavior (0) and mark it XFAIL:
    #   verify.ps1 is NOT modified (outside P017's scope); raised in openIssues.
    # =======================================================================
    Write-Host "-- N2 verify vacuous PASS on an empty ref (XFAIL) --" -ForegroundColor Cyan
    $n2 = Join-Path $root 'n2'
    $n2repo = Join-Path $n2 'repo'; $n2ref = Join-Path $n2repo 'claude'; $n2live = Join-Path $n2 'live'
    New-Item -ItemType Directory -Path $n2ref -Force  | Out-Null
    New-Item -ItemType Directory -Path $n2live -Force | Out-Null
    New-TextFile -Path (Join-Path $n2ref 'README.md') -Text "out of domain`n"   # 0 DOMAIN file
    Invoke-Git2 -RepoDir $n2repo -GitArgs @('init', '-q')                        | Out-Null
    Invoke-Git2 -RepoDir $n2repo -GitArgs @('config', 'user.email', 't@t')       | Out-Null
    Invoke-Git2 -RepoDir $n2repo -GitArgs @('config', 'user.name', 'test')       | Out-Null
    Invoke-Git2 -RepoDir $n2repo -GitArgs @('config', 'commit.gpgsign', 'false') | Out-Null
    Invoke-Git2 -RepoDir $n2repo -GitArgs @('add', '-A')                         | Out-Null
    Invoke-Git2 -RepoDir $n2repo -GitArgs @('commit', '-q', '-m', 'seed')        | Out-Null
    $rcN2 = Invoke-Verify -RefRoot $n2repo -LiveRoot $n2live -Quiet
    # XFAIL: the DESIRED behavior is exit 2 (guard 'if refHash.Count -eq 0'), not
    # implemented yet. We lock the OBSERVED behavior to detect a future fix
    # (the day verify returns 2, this assertion turns red -> revisit).
    Assert-Eq 0 $rcN2 "N2. [XFAIL] verify on empty ref -> exit 0 OBSERVED (expected 2; P014 defect out of scope, see openIssues)"

    # =======================================================================
    # N3 — restore TOCTOU (external writer between backup and swap): best-effort
    #   Window not reproducible deterministically without an injection point
    #   between the BACKUP phase and the SWAP (the O_EXCL lock assumes no external
    #   writer on ~/.claude). Best-effort: lock in that the SOURCE explicitly
    #   documents the window (anti-regression guard for the threat documentation).
    #   The nit stays raised in openIssues.
    # =======================================================================
    Write-Host "-- N3 restore TOCTOU: documented window (best-effort) --" -ForegroundColor Cyan
    $restoreSrc = Get-Content -LiteralPath $restorePath -Raw
    Assert-True (($restoreSrc -match 'between this backup and the swap') -and ($restoreSrc -match 'external writer')) `
        "N3. restore.ps1 documents the backup->swap TOCTOU window (threat outside the model, see openIssues)"

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
Write-Host "OK: SP2 BDD harness green (P017:A013)." -ForegroundColor Green
exit 0
