#requires -Version 5.1
<#
.SYNOPSIS
  Self-contained assert-based self-check (ZERO dependency: no Pester) of capture.ps1
  (P012:A006). Exit code != 0 on the first failure.

.DESCRIPTION
  Creates ALL its fixtures in a single TEMP directory (fake git ref repo, fake
  live dir, machine-local base outside the worktree). NEVER operates on the real
  sdlc-framework repo nor on ~/.claude. Cleans up in finally.

  Covers EVERY Code Lock criterion of P012:A006:
    (C1) modified-both without -Lww -> exit!=0 + diff + NOTHING written.
    (C2) commit strictly via 'git add -- claude/' (source scan, no -A).
    (C3) manifest + conflicts.log written OUTSIDE the worktree, atomically.
    (C4) empty porcelain post-check; worktree dirty after commit -> exit!=0, base NOT rewritten.
    (C5) 'added-live' captured; 'deleted-live' blocked.
    (C6) --dry-run: 0 commit, 0 ref file modified, 0 manifest written; would-block reflected.
  Hardening: (D1) first-run seed/block/adopt (H5); (D2) fail-closed on a corrupt manifest (H4);
    (D3) nominal modified-live success (post-check pass + base rewritten); (D4) -Lww logged.

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
$capturePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'capture.ps1'
$libPath     = Join-Path (Split-Path -Parent $PSScriptRoot) 'sync-lib.ps1'
foreach ($p in @($capturePath, $libPath)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "not found: $p" -ForegroundColor Red; exit 2 }
}

# Dot-source: loads sync-lib THEN capture (capture dot-sources sync-lib itself;
# the InvocationName guard prevents the auto-run). Exposes Invoke-Capture + helpers + lib.
. $libPath
. $capturePath

# --- Isolated temporary working directory ----------------------------------
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('capture-test-' + [System.Guid]::NewGuid().ToString('N'))
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

function Get-CommitCount {
    param([string]$RepoDir)
    $r = Invoke-Git2 -RepoDir $RepoDir -GitArgs @('rev-list', '--count', 'HEAD')
    if ($r.Code -ne 0) { return 0 }
    return [int]($r.Out.Trim())
}

# Builds a scenario: git repo (ref under <repo>/claude) + live, with identical
# common files (ref==live). State/base/lock/logs under <case>/state (OUTSIDE the worktree).
function New-Case {
    param([string]$Name, [hashtable]$Files)   # Files: relPath (domain) -> common content
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

    Invoke-Git2 -RepoDir $repo -GitArgs @('init', '-q')                       | Out-Null
    Invoke-Git2 -RepoDir $repo -GitArgs @('config', 'user.email', 't@t')      | Out-Null
    Invoke-Git2 -RepoDir $repo -GitArgs @('config', 'user.name', 'test')      | Out-Null
    Invoke-Git2 -RepoDir $repo -GitArgs @('config', 'commit.gpgsign', 'false')| Out-Null
    Invoke-Git2 -RepoDir $repo -GitArgs @('add', '--', 'claude')              | Out-Null
    Invoke-Git2 -RepoDir $repo -GitArgs @('commit', '-q', '-m', 'seed ref')   | Out-Null

    return [pscustomobject]@{
        Dir      = $c
        Repo     = $repo
        Ref      = $ref
        Live     = $live
        Manifest = (Join-Path $state '.sync-manifest.json')
        Conflict = (Join-Path $state 'conflicts.log')
        Lock     = (Join-Path $state '.sync.lock')
    }
}

# Explicit base seed = current hashes of the ref domain (reuses the lib).
function Set-SeedBase {
    param($Case)
    $rels = @(Get-DomainRelPaths -Root $Case.Ref)
    $h = @{}
    foreach ($r in $rels) { $h[$r] = Get-FileHashByteExact -Path (Get-CaptureFullPath -Root $Case.Ref -Rel $r) }
    Write-SyncManifest -Path $Case.Manifest -Entries $h | Out-Null
}

# Runs Invoke-Capture capturing ALL streams: separates the return code (int)
# from the text (Write-Host = Information stream). Robust on 5.1/7.
function Invoke-CaptureCase {
    param([hashtable]$P)
    $streamed = Invoke-Capture @P *>&1
    $ints = @($streamed | Where-Object { $_ -is [int] })
    $rc = if ($ints.Count -gt 0) { $ints[$ints.Count - 1] } else { -999 }
    $text = (@($streamed | Where-Object { $_ -isnot [int] }) | ForEach-Object { $_.ToString() }) -join "`n"
    return [pscustomobject]@{ Rc = $rc; Text = $text }
}

function Get-FileHashSafe { param([string]$Path) if (Test-Path -LiteralPath $Path) { return (Get-FileHashByteExact -Path $Path) } return $null }

$COMMON = @{ 'agents/sdlc-alpha.md' = "alpha-v1`n"; 'commands/sdlc/beta.md' = "beta-v1`n" }

try {
    Write-Host ""
    Write-Host "=== test-capture: self-check P012:A006 ===" -ForegroundColor Cyan

    # =======================================================================
    # (C2) Source scan: 'git add -- claude/' only, no 'git add -A'
    # =======================================================================
    Write-Host "-- (C2) commit scoped to claude/ (no -A) --" -ForegroundColor Cyan
    $src = Get-Content -LiteralPath $capturePath -Raw
    Assert-True (($src -notmatch 'add[''"\s,]+-A') -and ($src -notmatch "'-A'") -and ($src -notmatch '"-A"') -and ($src -notmatch 'git add -A')) `
        "C2. no 'git add -A' in the source"
    Assert-True ($src -match "'add',\s*'--'") "C2. 'git add' uses a pathspec ('--')"
    # The commit MUST carry an explicit pathspec (otherwise it commits the whole index).
    Assert-True ($src -match "'commit',\s*'-m',\s*\`$msg,\s*'--'") "C2. 'git commit' carries an explicit pathspec ('--')"

    # =======================================================================
    # (C2b) REAL commit scope: only greenlisted rels are committed.
    #   Pre-dirties claude/ with (S1) an out-of-domain file + an uncommitted
    #   third-party skill, (S2) a pre-staged file outside claude/, (S3) a
    #   'deleted-ref' deletion (skip). A modified-live triggers the commit. HEAD must
    #   contain ONLY the greenlisted rel; the tip keeps the deleted file.
    # =======================================================================
    Write-Host "-- (C2b) real commit scope (S1/S2/S3) --" -ForegroundColor Cyan
    $ks = New-Case -Name 'c2scope' -Files $COMMON
    Set-SeedBase -Case $ks
    # S1: files OUTSIDE the sdlc domain in claude/ (WIP secret + third-party skill), uncommitted
    New-TextFile -Path (Join-Path $ks.Ref 'settings.local.json')       -Text '{"secret":"WIP"}'
    New-TextFile -Path (Join-Path $ks.Ref 'skills\other-tool\SKILL.md') -Text "tiers`n"
    # S3: ref-side deletion of a domain file -> 'deleted-ref' -> skip
    Remove-Item -LiteralPath (Join-Path $ks.Ref 'agents\sdlc-alpha.md') -Force
    # S2: file OUTSIDE claude/ pre-staged before capture
    New-TextFile -Path (Join-Path $ks.Repo 'README.md') -Text "readme`n"
    Invoke-Git2 -RepoDir $ks.Repo -GitArgs @('add', '--', 'README.md') | Out-Null
    # modified-live on beta -> greenlisted, triggers the commit
    New-TextFile -Path (Join-Path $ks.Live 'commands\sdlc\beta.md') -Text "beta-scope`n"
    $rs = Invoke-CaptureCase -P @{ RefRoot = $ks.Ref; LiveRoot = $ks.Live; GitRoot = $ks.Repo; ManifestPath = $ks.Manifest; ConflictLogPath = $ks.Conflict; LockPath = $ks.Lock }
    Assert-Eq 0 $rs.Rc "C2b. capture OK (post-check scoped to the copied rels)"
    # Files of the HEAD commit (name-only, without the subject)
    $head = Invoke-Git2 -RepoDir $ks.Repo -GitArgs @('show', '--pretty=format:', '--name-only', 'HEAD')
    Assert-True ($head.Out -match 'commands/sdlc/beta\.md') "C2b. HEAD commits the greenlisted rel (beta)"
    Assert-True ($head.Out -notmatch 'settings\.local\.json') "C2b. S1: out-of-domain secret NOT committed"
    Assert-True ($head.Out -notmatch 'other-tool') "C2b. S1: third-party skill NOT committed"
    Assert-True ($head.Out -notmatch 'README\.md') "C2b. S2: pre-staged file outside claude/ NOT committed"
    Assert-True ($head.Out -notmatch 'sdlc-alpha\.md') "C2b. S3: skipped deletion NOT committed"
    # The canonical tip keeps the domain file the classifier decided not to touch
    $tree = Invoke-Git2 -RepoDir $ks.Repo -GitArgs @('ls-tree', '-r', '--name-only', 'HEAD')
    Assert-True ($tree.Out -match 'claude/agents/sdlc-alpha\.md') "C2b. S3: the tip keeps sdlc-alpha.md (not deleted)"
    Assert-True ($tree.Out -notmatch 'README\.md') "C2b. S2: README.md absent from the tip (never committed)"

    # =======================================================================
    # (C1) modified-both without -Lww -> exit!=0 + diff + NOTHING written
    # =======================================================================
    Write-Host "-- (C1) modified-both blocked --" -ForegroundColor Cyan
    $k = New-Case -Name 'c1' -Files $COMMON
    Set-SeedBase -Case $k
    # ref and live both diverge from the base (and from each other)
    New-TextFile -Path (Join-Path $k.Ref  'agents\sdlc-alpha.md') -Text "alpha-REF`n"
    New-TextFile -Path (Join-Path $k.Live 'agents\sdlc-alpha.md') -Text "alpha-LIVE`n"
    $refBytesBefore = Get-FileHashByteExact -Path (Join-Path $k.Ref 'agents\sdlc-alpha.md')
    $manBefore = Get-FileHashSafe $k.Manifest
    $commitsBefore = Get-CommitCount -RepoDir $k.Repo

    $r = Invoke-CaptureCase -P @{ RefRoot = $k.Ref; LiveRoot = $k.Live; GitRoot = $k.Repo; ManifestPath = $k.Manifest; ConflictLogPath = $k.Conflict; LockPath = $k.Lock }
    Assert-True ($r.Rc -ne 0) "C1. exit != 0 on modified-both"
    Assert-True ($r.Text -match 'modified-both') "C1. diff/state shown (modified-both visible)"
    Assert-Eq $refBytesBefore (Get-FileHashByteExact -Path (Join-Path $k.Ref 'agents\sdlc-alpha.md')) "C1. ref file NOT overwritten by live"
    Assert-Eq $manBefore (Get-FileHashSafe $k.Manifest) "C1. manifest NOT rewritten"
    Assert-Eq $commitsBefore (Get-CommitCount -RepoDir $k.Repo) "C1. no new commit"
    Assert-True (-not (Test-Path -LiteralPath $k.Conflict)) "C1. conflicts.log NOT created (no -Lww)"

    # =======================================================================
    # (C3) manifest + conflicts.log OUTSIDE the worktree, atomically
    # =======================================================================
    Write-Host "-- (C3) state outside the worktree --" -ForegroundColor Cyan
    $k3 = New-Case -Name 'c3' -Files $COMMON
    # state paths not contained in the worktree
    $repoFull = [System.IO.Path]::GetFullPath($k3.Repo)
    Assert-True (-not ([System.IO.Path]::GetFullPath($k3.Manifest)).StartsWith($repoFull, [System.StringComparison]::OrdinalIgnoreCase)) "C3. ManifestPath outside the git worktree"
    Assert-True (-not ([System.IO.Path]::GetFullPath($k3.Conflict)).StartsWith($repoFull, [System.StringComparison]::OrdinalIgnoreCase)) "C3. ConflictLogPath outside the git worktree"
    Set-SeedBase -Case $k3
    New-TextFile -Path (Join-Path $k3.Live 'commands\sdlc\beta.md') -Text "beta-v2`n"   # modified-live
    $r3 = Invoke-CaptureCase -P @{ RefRoot = $k3.Ref; LiveRoot = $k3.Live; GitRoot = $k3.Repo; ManifestPath = $k3.Manifest; ConflictLogPath = $k3.Conflict; LockPath = $k3.Lock }
    Assert-Eq 0 $r3.Rc "C3. nominal capture OK (modified-live)"
    Assert-True (Test-Path -LiteralPath $k3.Manifest) "C3. manifest written at the out-of-worktree location"
    $inRepoManifest = @(Get-ChildItem -LiteralPath $k3.Repo -Recurse -Force -Filter '.sync-manifest.json' -ErrorAction SilentlyContinue)
    Assert-Eq 0 $inRepoManifest.Count "C3. no manifest in the git worktree"
    $tmpLeft = @(Get-ChildItem -LiteralPath (Split-Path -Parent $k3.Manifest) -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.tmp-*' -or $_.Name -like '*.bak-*' })
    Assert-Eq 0 $tmpLeft.Count "C3. atomic write: no leftover temp/bak file"

    # =======================================================================
    # (D3) nominal modified-live success: base rewritten, worktree clean
    # =======================================================================
    Write-Host "-- (D3) modified-live success --" -ForegroundColor Cyan
    Assert-Eq (Get-FileHashByteExact -Path (Join-Path $k3.Live 'commands\sdlc\beta.md')) (Get-FileHashByteExact -Path (Join-Path $k3.Ref 'commands\sdlc\beta.md')) "D3. ref == live after capture"
    $porc3 = Invoke-Git2 -RepoDir $k3.Repo -GitArgs @('status', '--porcelain', '--', 'claude')
    Assert-True ([string]::IsNullOrWhiteSpace($porc3.Out)) "D3. post-check: claude/ worktree clean"
    $man3 = Read-SyncManifest -Path $k3.Manifest
    Assert-True ($man3.Ok) "D3. manifest readable again (Ok)"
    Assert-Eq (Get-FileHashByteExact -Path (Join-Path $k3.Ref 'commands\sdlc\beta.md')) $man3.Entries['commands/sdlc/beta.md'] "D3. base rewritten with the new hash"

    # =======================================================================
    # (C4) porcelain post-check: worktree dirty after commit -> exit!=0, base NOT rewritten
    # =======================================================================
    Write-Host "-- (C4) post-check partial failure --" -ForegroundColor Cyan
    $k4 = New-Case -Name 'c4' -Files $COMMON
    Set-SeedBase -Case $k4
    $man4Before = Get-FileHashSafe $k4.Manifest
    # post-commit hook: dirties the COMMITTED file (beta) AFTER a successful commit.
    # The post-check is scoped to the copied rels: the partial failure must affect
    # a greenlisted rel (otherwise a legitimate out-of-scope change must not block).
    $hook = Join-Path $k4.Repo '.git/hooks/post-commit'
    New-TextFile -Path $hook -Text "#!/bin/sh`necho dirty >> claude/commands/sdlc/beta.md`n"
    New-TextFile -Path (Join-Path $k4.Live 'commands\sdlc\beta.md') -Text "beta-capture`n"   # modified-live -> triggers the commit
    $r4 = Invoke-CaptureCase -P @{ RefRoot = $k4.Ref; LiveRoot = $k4.Live; GitRoot = $k4.Repo; ManifestPath = $k4.Manifest; ConflictLogPath = $k4.Conflict; LockPath = $k4.Lock }
    Assert-True ($r4.Rc -ne 0) "C4. exit != 0 when the worktree is dirty after commit"
    Assert-True ($r4.Text -match 'POST-CHECK') "C4. post-check failure reported"
    Assert-Eq $man4Before (Get-FileHashSafe $k4.Manifest) "C4. base NOT rewritten on partial failure"

    # =======================================================================
    # (C5a) added-live -> captured (present in ref + committed)
    # =======================================================================
    Write-Host "-- (C5a) added-live captured --" -ForegroundColor Cyan
    $k5 = New-Case -Name 'c5a' -Files $COMMON
    Set-SeedBase -Case $k5
    New-TextFile -Path (Join-Path $k5.Live 'agents\sdlc-new.md') -Text "brand-new`n"   # live-only, missing from the base
    $commitsBefore5 = Get-CommitCount -RepoDir $k5.Repo
    $r5 = Invoke-CaptureCase -P @{ RefRoot = $k5.Ref; LiveRoot = $k5.Live; GitRoot = $k5.Repo; ManifestPath = $k5.Manifest; ConflictLogPath = $k5.Conflict; LockPath = $k5.Lock }
    Assert-Eq 0 $r5.Rc "C5a. exit 0 (added-live captured)"
    Assert-True (Test-Path -LiteralPath (Join-Path $k5.Ref 'agents\sdlc-new.md')) "C5a. new file present in ref"
    Assert-Eq ($commitsBefore5 + 1) (Get-CommitCount -RepoDir $k5.Repo) "C5a. one new commit created"
    $show5 = Invoke-Git2 -RepoDir $k5.Repo -GitArgs @('show', '--stat', '--name-only', 'HEAD')
    Assert-True ($show5.Out -match 'sdlc-new\.md') "C5a. added file present in the HEAD commit"
    $man5 = Read-SyncManifest -Path $k5.Manifest
    Assert-True ($man5.Entries.ContainsKey('agents/sdlc-new.md')) "C5a. base includes the new relPath"

    # =======================================================================
    # (C5b) deleted-live -> blocked (canonical deletion never propagated)
    # =======================================================================
    Write-Host "-- (C5b) deleted-live blocked --" -ForegroundColor Cyan
    $k5b = New-Case -Name 'c5b' -Files $COMMON
    Set-SeedBase -Case $k5b
    Remove-Item -LiteralPath (Join-Path $k5b.Live 'agents\sdlc-alpha.md') -Force   # live missing, ref==base
    $commitsBefore5b = Get-CommitCount -RepoDir $k5b.Repo
    $man5bBefore = Get-FileHashSafe $k5b.Manifest
    $r5b = Invoke-CaptureCase -P @{ RefRoot = $k5b.Ref; LiveRoot = $k5b.Live; GitRoot = $k5b.Repo; ManifestPath = $k5b.Manifest; ConflictLogPath = $k5b.Conflict; LockPath = $k5b.Lock }
    Assert-True ($r5b.Rc -ne 0) "C5b. exit != 0 (deleted-live blocked)"
    Assert-True (Test-Path -LiteralPath (Join-Path $k5b.Ref 'agents\sdlc-alpha.md')) "C5b. ref file NOT deleted"
    Assert-Eq $commitsBefore5b (Get-CommitCount -RepoDir $k5b.Repo) "C5b. no commit"
    Assert-Eq $man5bBefore (Get-FileHashSafe $k5b.Manifest) "C5b. base NOT rewritten"

    # =======================================================================
    # (C6a) --dry-run: 0 commit, 0 ref file modified, 0 manifest written
    # =======================================================================
    Write-Host "-- (C6a) dry-run 0 writes --" -ForegroundColor Cyan
    $k6 = New-Case -Name 'c6' -Files $COMMON
    Set-SeedBase -Case $k6
    New-TextFile -Path (Join-Path $k6.Live 'agents\sdlc-new.md') -Text "would-add`n"       # added-live pending
    New-TextFile -Path (Join-Path $k6.Live 'commands\sdlc\beta.md') -Text "would-modify`n" # modified-live pending
    $man6Before = Get-FileHashSafe $k6.Manifest
    $commits6Before = Get-CommitCount -RepoDir $k6.Repo
    $r6 = Invoke-CaptureCase -P @{ RefRoot = $k6.Ref; LiveRoot = $k6.Live; GitRoot = $k6.Repo; ManifestPath = $k6.Manifest; ConflictLogPath = $k6.Conflict; LockPath = $k6.Lock; DryRun = $true }
    Assert-Eq 0 $r6.Rc "C6a. dry-run without block -> exit 0"
    Assert-Eq $commits6Before (Get-CommitCount -RepoDir $k6.Repo) "C6a. dry-run: 0 commit created"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $k6.Ref 'agents\sdlc-new.md'))) "C6a. dry-run: 0 ref file created"
    Assert-Eq (Get-FileHashByteExact -Path (Join-Path $k6.Ref 'commands\sdlc\beta.md')) (Get-FileHashByteExact -Path (Join-Path $k6.Ref 'commands\sdlc\beta.md')) "C6a. (sanity) ref beta readable"
    Assert-Eq $man6Before (Get-FileHashSafe $k6.Manifest) "C6a. dry-run: manifest unchanged"

    # =======================================================================
    # (C6b) --dry-run reflects the would-block (modified-both) -> exit!=0
    # =======================================================================
    Write-Host "-- (C6b) dry-run would-block --" -ForegroundColor Cyan
    $k6b = New-Case -Name 'c6b' -Files $COMMON
    Set-SeedBase -Case $k6b
    New-TextFile -Path (Join-Path $k6b.Ref  'agents\sdlc-alpha.md') -Text "alpha-REF`n"
    New-TextFile -Path (Join-Path $k6b.Live 'agents\sdlc-alpha.md') -Text "alpha-LIVE`n"
    $man6bBefore = Get-FileHashSafe $k6b.Manifest
    $r6b = Invoke-CaptureCase -P @{ RefRoot = $k6b.Ref; LiveRoot = $k6b.Live; GitRoot = $k6b.Repo; ManifestPath = $k6b.Manifest; ConflictLogPath = $k6b.Conflict; LockPath = $k6b.Lock; DryRun = $true }
    Assert-True ($r6b.Rc -ne 0) "C6b. dry-run reflects the would-block (exit != 0)"
    Assert-Eq $man6bBefore (Get-FileHashSafe $k6b.Manifest) "C6b. dry-run would-block: nothing written"
    Assert-True (-not (Test-Path -LiteralPath $k6b.Conflict)) "C6b. dry-run: conflicts.log not created"

    # =======================================================================
    # (D1) first-run: seed (equal), block (asymmetry), adopt
    # =======================================================================
    Write-Host "-- (D1) first-run H5 --" -ForegroundColor Cyan
    # seed: ref==live, no base
    $kd1 = New-Case -Name 'd1seed' -Files $COMMON
    $rd1 = Invoke-CaptureCase -P @{ RefRoot = $kd1.Ref; LiveRoot = $kd1.Live; GitRoot = $kd1.Repo; ManifestPath = $kd1.Manifest; ConflictLogPath = $kd1.Conflict; LockPath = $kd1.Lock }
    Assert-Eq 0 $rd1.Rc "D1. first-run seed (ref==live) -> exit 0"
    Assert-True (Test-Path -LiteralPath $kd1.Manifest) "D1. first-run seed writes the base"
    # block: asymmetry (live-only), no base
    $kd2 = New-Case -Name 'd1block' -Files $COMMON
    New-TextFile -Path (Join-Path $kd2.Live 'agents\sdlc-extra.md') -Text "extra`n"
    $rd2 = Invoke-CaptureCase -P @{ RefRoot = $kd2.Ref; LiveRoot = $kd2.Live; GitRoot = $kd2.Repo; ManifestPath = $kd2.Manifest; ConflictLogPath = $kd2.Conflict; LockPath = $kd2.Lock }
    Assert-True ($rd2.Rc -ne 0) "D1. first-run asymmetry -> BLOCKED (exit != 0)"
    Assert-True (-not (Test-Path -LiteralPath $kd2.Manifest)) "D1. first-run block: base NOT written"
    # adopt: same asymmetry, -Adopt -> forced seed
    $rd3 = Invoke-CaptureCase -P @{ RefRoot = $kd2.Ref; LiveRoot = $kd2.Live; GitRoot = $kd2.Repo; ManifestPath = $kd2.Manifest; ConflictLogPath = $kd2.Conflict; LockPath = $kd2.Lock; Adopt = $true }
    Assert-Eq 0 $rd3.Rc "D1. first-run -Adopt -> forced seed (exit 0)"
    Assert-True (Test-Path -LiteralPath $kd2.Manifest) "D1. -Adopt writes the base"

    # =======================================================================
    # (D2) corrupt manifest -> FAIL CLOSED (no action, exit != 0)
    # =======================================================================
    Write-Host "-- (D2) fail-closed on corrupt manifest --" -ForegroundColor Cyan
    $kd = New-Case -Name 'd2' -Files $COMMON
    New-TextFile -Path $kd.Manifest -Text "{ this is : not json"   # corrupt
    New-TextFile -Path (Join-Path $kd.Live 'commands\sdlc\beta.md') -Text "beta-v2`n"  # modified-live
    $commitsBeforeD2 = Get-CommitCount -RepoDir $kd.Repo
    $rd = Invoke-CaptureCase -P @{ RefRoot = $kd.Ref; LiveRoot = $kd.Live; GitRoot = $kd.Repo; ManifestPath = $kd.Manifest; ConflictLogPath = $kd.Conflict; LockPath = $kd.Lock }
    Assert-True ($rd.Rc -ne 0) "D2. corrupt manifest -> exit != 0 (fail closed)"
    Assert-True ($rd.Text -match 'FAIL CLOSED') "D2. fail-closed reported"
    Assert-Eq $commitsBeforeD2 (Get-CommitCount -RepoDir $kd.Repo) "D2. fail-closed: no commit"

    # =======================================================================
    # (D4) -Lww: logged (conflicts.log outside the worktree) and resolved
    # =======================================================================
    Write-Host "-- (D4) -Lww logged --" -ForegroundColor Cyan
    $kl = New-Case -Name 'd4' -Files $COMMON
    Set-SeedBase -Case $kl
    New-TextFile -Path (Join-Path $kl.Ref  'agents\sdlc-alpha.md') -Text "alpha-REF`n"
    New-TextFile -Path (Join-Path $kl.Live 'agents\sdlc-alpha.md') -Text "alpha-LIVE`n"
    $commitsBeforeD4 = Get-CommitCount -RepoDir $kl.Repo
    # Provenance 'live': winner=live -> captures live over the ref, commits
    $rl = Invoke-CaptureCase -P @{ RefRoot = $kl.Ref; LiveRoot = $kl.Live; GitRoot = $kl.Repo; ManifestPath = $kl.Manifest; ConflictLogPath = $kl.Conflict; LockPath = $kl.Lock; Lww = $true; Provenance = 'live' }
    Assert-Eq 0 $rl.Rc "D4. -Lww resolves the conflict (exit 0, no block)"
    Assert-True (Test-Path -LiteralPath $kl.Conflict) "D4. conflicts.log written (logged)"
    $inRepoLog = @(Get-ChildItem -LiteralPath $kl.Repo -Recurse -Force -Filter 'conflicts.log' -ErrorAction SilentlyContinue)
    Assert-Eq 0 $inRepoLog.Count "D4. conflicts.log OUTSIDE the git worktree"
    Assert-Eq "alpha-LIVE`n" ([System.IO.File]::ReadAllText((Join-Path $kl.Ref 'agents\sdlc-alpha.md'))) "D4. winner=live: ref adopts the live content"
    Assert-Eq ($commitsBeforeD4 + 1) (Get-CommitCount -RepoDir $kl.Repo) "D4. -Lww winner=live: commit created"
    # The losing REF change (alpha-REF, uncommitted) must stay recoverable through a timestamped backup OUTSIDE the worktree.
    $backupsRoot = Join-Path (Split-Path -Parent $kl.Conflict) '_backups'
    $baks = @(Get-ChildItem -LiteralPath $backupsRoot -Recurse -File -Filter 'sdlc-alpha.md' -ErrorAction SilentlyContinue)
    Assert-Eq 1 $baks.Count "D4. timestamped backup of the losing ref created"
    if ($baks.Count -eq 1) {
        Assert-Eq "alpha-REF`n" ([System.IO.File]::ReadAllText($baks[0].FullName)) "D4. backup holds the overwritten ref change (recoverable)"
        $repoFullD4 = [System.IO.Path]::GetFullPath($kl.Repo)
        Assert-True (-not ([System.IO.Path]::GetFullPath($baks[0].FullName)).StartsWith($repoFullD4, [System.StringComparison]::OrdinalIgnoreCase)) "D4. backup OUTSIDE the git worktree"
    }

    # --- Summary -----------------------------------------------------------
    Write-Host ""
    Write-Host ("=== Summary: {0} PASS / {1} FAIL ===" -f $script:Passed, $script:Failed) -ForegroundColor Cyan
    if ($script:Failed -gt 0) {
        foreach ($f in $script:Failures) { Write-Host ("  - " + $f) -ForegroundColor Red }
    }
}
finally {
    # Cleanup: release any handles, then delete the temporary tree.
    [System.GC]::Collect()
    for ($i = 0; $i -lt 5; $i++) {
        try { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop } ; break }
        catch { Start-Sleep -Milliseconds 200 }
    }
}

if ($script:Failed -gt 0) { exit 1 }
Write-Host "OK: capture.ps1 compliant (P012:A006)." -ForegroundColor Green
exit 0
