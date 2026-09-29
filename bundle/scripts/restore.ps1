#requires -Version 5.1
<#
.SYNOPSIS
  restore (P013:A009) — deploys the canonical REF (git) to the LIVE install.

.DESCRIPTION
  Direction (A001, E002): REF = source of truth = repo sdlc-framework/claude/ at
  git HEAD. LIVE = the ~/.claude/ install. restore takes the committed REF and
  makes LIVE match it, with safeguards against data loss. Foundation of the
  install bootstrap (P015).

  Behavior:
    - Requires git (ff-only + dependent verify post-check). Missing -> exit 2.
    - Acquires an O_EXCL lockfile around every mutation (released in finally).
    - UNDER the lock: `git --ff-only` (if an upstream is configured; fast-forward
      ONLY, never a merge commit; non-ff divergence -> abort exit 4; no upstream
      -> skip; NEVER run in -DryRun so that it stays 100% read-only).
    - CANONICAL GUARD: the REF working tree (claude/) must be clean (== HEAD),
      otherwise abort (exit 5) BEFORE any write. restore deploys the worktree; this
      guard makes it equal to the HEAD the verify post-check is authoritative on
      (avoids writing uncommitted / non-canonical content into LIVE).
    - Loads the base (Read-SyncManifest). Corrupt -> FAIL CLOSED (refuses to act).
      Missing -> empty base (first-run / bootstrap): the per-rel classification
      stays safe (see below); restore needs no seed.
    - Classifies each relPath of the UNION of the domains (Get-SyncState, base-aware):
        modified-ref / added-ref / deleted-live   -> RESTORE (copy ref->live)
        deleted-ref (live==base)                  -> DELETE live (base-aware H6)
        modified-live                             -> BLOCKED, unless -ForceRestore
        modified-both / conflict-*                -> BLOCKED (always)
        added-live                                -> PROTECTED (never touched, H6)
        identical / absent-both                   -> skip
    - If there is >=1 block: exit != 0 (3), WRITES NOTHING, shows the diffs.
    - Deployment: (1) temp STAGING (Copy-Tree ref->staging, assembled outside live);
      (2) timestamped BACKUP of each existing live file BEFORE replacement/deletion
      (recoverable, outside the sync domain); (3) atomic SWAP (Copy-Tree staging->live,
      temp+rename per file via Write-FileAtomic); (4) base-aware DELETE. Never a
      destructive in-place copy; never /MIR.
    - POST-CHECK: runs `verify` (P014) as a SUBPROCESS (read-only isolation);
      0 drift required, otherwise exit != 0 (7).
    - -DryRun: 0 writes (staging/backup/live); the exit code reflects the would-block.

  On NOT rewriting the base: restore does not touch the manifest (capture owns
  it, H1). This is safe because after restore every touched rel satisfies R==L
  (or absent-both): Get-SyncState then short-circuits to `identical` /
  `absent-both` REGARDLESS of the base — so a stale base cannot cause a
  misclassification on the next run.

  Compatible with PowerShell 5.1 (Desktop) AND 7 (Core). ZERO external dependency.
  Driven by param(); the logic lives in Invoke-Restore. Dot-sourcing (tests)
  does NOT trigger the auto-run (InvocationName guard).
#>

[CmdletBinding()]
param(
    # REF = canonical repo .../claude; default: ..\..\claude relative to the script.
    [string]$RefRoot = (Join-Path $PSScriptRoot '..\..\claude'),
    # LIVE = the ~/.claude install.
    [string]$LiveRoot = (Join-Path $env:USERPROFILE '.claude'),
    # Root of the git worktree (contains the REF folder). Default: parent of RefRoot.
    [string]$GitRoot = '',
    # Machine-local base OUTSIDE the worktree. Default: under LiveRoot (excluded from sync).
    [string]$ManifestPath = '',
    [string]$LockPath = '',
    # Root of the timestamped backups. Default: LiveRoot/_backups (excluded from sync).
    [string]$BackupRoot = '',
    # Unblocks 'modified-live' (overwrites the local live change with the canonical file).
    [switch]$ForceRestore,
    [switch]$DryRun
)

# --- Load the shared foundation (single source A002/A004) -------------------
. (Join-Path $PSScriptRoot 'sync-lib.ps1')

# --- Path/hash helpers (mirror of capture, in restore.ps1) ------------------

function Get-RestoreFullPath {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Rel)
    Set-StrictMode -Version Latest
    $native = $Rel -replace '/', ([string][System.IO.Path]::DirectorySeparatorChar)
    return (Join-Path $Root $native)
}

function Get-RestoreHashOrNull {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Rel)
    Set-StrictMode -Version Latest
    $full = Get-RestoreFullPath -Root $Root -Rel $Rel
    if (Test-Path -LiteralPath $full) { return (Get-FileHashByteExact -Path $full) }
    return $null
}

function Invoke-RestoreGit {
    # Wrapper for 'git -C <GitRoot> <args>': returns code + output. Compatible with 5.1/7.
    param([Parameter(Mandatory)][string]$GitRoot, [Parameter(Mandatory)][string[]]$GitArgs)
    Set-StrictMode -Version Latest
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $GitRoot @GitArgs 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Update-RefFastForward {
    # `git --ff-only first`. Returns 'skip' (no upstream), 'ok' (up to date /
    # fast-forward applied) or 'diverged' (non-ff -> the caller aborts). Does NOT
    # fetch (no network surprise): fast-forwards the already-fetched tracking branch.
    param([Parameter(Mandatory)][string]$GitRoot)
    Set-StrictMode -Version Latest
    # '@{u}' is passed LITERALLY to git (in PS, @{...} would be a hashtable: quoted).
    $up = Invoke-RestoreGit -GitRoot $GitRoot -GitArgs @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
    if ($up.Code -ne 0) { return 'skip' }   # no upstream configured
    $ff = Invoke-RestoreGit -GitRoot $GitRoot -GitArgs @('merge', '--ff-only', '@{u}')
    if ($ff.Code -ne 0) { return 'diverged' }
    return 'ok'
}

function Invoke-VerifyPostCheck {
    # POST-CHECK A009: runs verify (P014) as a SUBPROCESS to guarantee its
    # read-only isolation (and to avoid verify.ps1's param() clobbering the
    # restore scope). Returns verify's exit code (0 = 0 drift).
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$LiveTarget)
    Set-StrictMode -Version Latest
    $verifyScript = Join-Path $PSScriptRoot 'verify.ps1'
    if (-not (Test-Path -LiteralPath $verifyScript)) { return 2 }
    # Re-invoke the SAME PowerShell host (pwsh or powershell) as the current process.
    $psExe = $null
    try { $psExe = (Get-Process -Id $PID).Path } catch { }
    if ([string]::IsNullOrEmpty($psExe)) {
        $cmd = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue
        if ($null -eq $cmd) { $cmd = Get-Command powershell -CommandType Application -ErrorAction SilentlyContinue }
        if ($null -ne $cmd) { $psExe = $cmd.Source }
    }
    if ([string]::IsNullOrEmpty($psExe)) { return 2 }
    & $psExe -NoProfile -File $verifyScript -RefRoot $RepoRoot -LiveRoot $LiveTarget -Quiet *> $null
    return $LASTEXITCODE
}

# --- Core --------------------------------------------------------------------

function Invoke-Restore {
    param(
        [Parameter(Mandatory)][string]$RefRoot,
        [Parameter(Mandatory)][string]$LiveRoot,
        [string]$GitRoot = '',
        [string]$ManifestPath = '',
        [string]$LockPath = '',
        [string]$BackupRoot = '',
        [switch]$ForceRestore,
        [switch]$DryRun
    )
    Set-StrictMode -Version Latest

    # --- Path resolution ---
    $refResolved = Resolve-Path -LiteralPath $RefRoot -ErrorAction SilentlyContinue
    if ($null -eq $refResolved) {
        Write-Host "restore: RefRoot not found: $RefRoot" -ForegroundColor Red
        return 2
    }
    $RefRoot = $refResolved.Path
    $liveResolved = Resolve-Path -LiteralPath $LiveRoot -ErrorAction SilentlyContinue
    if ($null -eq $liveResolved) {
        Write-Host "restore: LiveRoot not found: $LiveRoot" -ForegroundColor Red
        return 2
    }
    $LiveRoot = $liveResolved.Path

    if ([string]::IsNullOrEmpty($GitRoot)) { $GitRoot = Split-Path -Parent $RefRoot }
    if ([string]::IsNullOrEmpty($ManifestPath)) { $ManifestPath = Join-Path $LiveRoot '.sync-manifest.json' }
    if ([string]::IsNullOrEmpty($LockPath))     { $LockPath     = Join-Path $LiveRoot '.sync.lock' }
    if ([string]::IsNullOrEmpty($BackupRoot))   { $BackupRoot   = Join-Path $LiveRoot '_backups' }
    # P022:A019: GLOBAL USER file, OUTSIDE the sync domain (never in the
    # Get-DomainRelPaths greenlist). The import is added at the end of a nominal run.
    $claudeMdTarget = Join-Path $LiveRoot 'CLAUDE.md'

    $mode = if ($DryRun) { '[dry-run] ' } else { '' }
    Write-Host ("restore ${mode}: ref=$RefRoot  live=$LiveRoot") -ForegroundColor Cyan

    # git is required: ff-only + dependent verify post-check.
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        Write-Host "restore: git not found — required (ff-only + verify post-check). Nothing written." -ForegroundColor Red
        return 2
    }

    $staging = $null
    $lock = $null
    try {
        # Exclusive lock around the analysis AND the mutation (capture/restore race).
        # Acquired BEFORE ff-only: the fast-forward rewrites the REF worktree (a mutation)
        # and must therefore be serialized by the same lock as capture (sibling invariant:
        # no mutation outside the lock).
        $lock = Acquire-SyncLock -Path $LockPath

        # --- `git --ff-only` (under the lock; NEVER in dry-run, which must stay 100% read-only) ---
        if (-not $DryRun) {
            $ff = Update-RefFastForward -GitRoot $GitRoot
            if ($ff -eq 'diverged') {
                Write-Host "restore: ref diverged from upstream (not fast-forward) — abort. Nothing written." -ForegroundColor Red
                Write-Host "        Reconcile the ref (rebase/merge) before restoring." -ForegroundColor Yellow
                return 4
            }
        }

        # --- CANONICAL GUARD: the REF working tree (claude/) must be clean (== HEAD) ---
        # restore deploys the WORKING TREE (like capture) whereas the verify post-check is
        # HEAD-authoritative. On a dirty REF worktree, restore would write UNCOMMITTED
        # (non-canonical) content into LIVE before failing the post-check. So any dirty REF
        # worktree is refused BEFORE the first write: deploy source == HEAD guaranteed (adversarial review).
        # ponytail: guard at the claude/ level (simple, conservative); scope it to the sdlc
        # domain pathspecs if legitimate out-of-domain changes ever need to coexist.
        $porc = Invoke-RestoreGit -GitRoot $GitRoot -GitArgs @('status', '--porcelain', '--', 'claude')
        if (($porc.Code -ne 0) -or (-not [string]::IsNullOrWhiteSpace($porc.Out))) {
            Write-Host "restore: REF tree (claude/) not clean — commit/reconcile the ref before restoring. Nothing written." -ForegroundColor Red
            if ($porc.Out) { Write-Host $porc.Out -ForegroundColor DarkGray }
            return 5
        }

        # --- UNION of the domain relPaths (ref + live) ---
        $refRels  = @(Get-DomainRelPaths -Root $RefRoot)
        $liveRels = @(Get-DomainRelPaths -Root $LiveRoot)
        $union = @(@($refRels + $liveRels) | Sort-Object -Unique)

        # --- Load the base (3rd state) ---
        $manifest = Read-SyncManifest -Path $ManifestPath
        if ($manifest.FailClosed) {
            # FAIL CLOSED (H4): corrupt base -> refuse to act.
            Write-Host "restore: unreadable/corrupt manifest -> FAIL CLOSED (no action)." -ForegroundColor Red
            Write-Host "        No restore is attempted on an untrusted base." -ForegroundColor Yellow
            return 6
        }
        # Base = Entries (empty {} if missing: first-run/bootstrap, safe by construction).
        $base = $manifest.Entries

        # --- Base-aware classification ---
        $restoreRels = New-Object System.Collections.Generic.List[string]   # copy ref->live
        $deleteRels  = New-Object System.Collections.Generic.List[string]   # base-aware deletion
        $blocks      = New-Object System.Collections.Generic.List[object]

        foreach ($rel in $union) {
            $refH  = Get-RestoreHashOrNull -Root $RefRoot  -Rel $rel
            $liveH = Get-RestoreHashOrNull -Root $LiveRoot -Rel $rel
            $baseH = $null
            if ($base.ContainsKey($rel)) { $baseH = $base[$rel] }

            $st = Get-SyncState -RefHash $refH -LiveHash $liveH -BaseHash $baseH -RelPath $rel

            switch ($st.State) {
                'modified-ref'   { $restoreRels.Add($rel) }
                'added-ref'    { $restoreRels.Add($rel) }
                'deleted-live' { $restoreRels.Add($rel) }   # redeploys the canonical file (live had deleted it)
                'modified-live'  {
                    if ($ForceRestore) { $restoreRels.Add($rel) }
                    else { $blocks.Add([pscustomobject]@{ Rel = $rel; State = 'modified-live-only'; RefH = $refH; LiveH = $liveH }) }
                }
                'deleted-ref'    { $deleteRels.Add($rel) }  # base-aware (H6): live==base -> propagate the deletion
                'identical'       { }
                'added-live'     { }                        # PROTECTED (H6): never deleted
                'absent-both' { }
                'modified-both' { $blocks.Add([pscustomobject]@{ Rel = $rel; State = $st.State; RefH = $refH; LiveH = $liveH }) }
                default {
                    # conflict-deleted-live-modified-ref / conflict-deleted-ref-modified-live: never guessed.
                    $blocks.Add([pscustomobject]@{ Rel = $rel; State = $st.State; RefH = $refH; LiveH = $liveH })
                }
            }
        }

        # --- HARD BLOCKS: exit != 0, NOTHING written (even in dry-run) ---
        if ($blocks.Count -gt 0) {
            Write-Host ("restore: BLOCKED — {0} unresolved conflict(s). Nothing written." -f $blocks.Count) -ForegroundColor Red
            foreach ($b in $blocks) {
                Write-Host ("  [BLOCK] {0}  ({1})" -f $b.Rel, $b.State) -ForegroundColor Red
                if (($null -ne $b.RefH) -and ($null -ne $b.LiveH)) {
                    $rp = Get-RestoreFullPath -Root $RefRoot  -Rel $b.Rel
                    $lp = Get-RestoreFullPath -Root $LiveRoot -Rel $b.Rel
                    $diff = Show-ConflictDiff -RefPath $rp -LivePath $lp
                    if ($diff) { Write-Host $diff -ForegroundColor DarkGray }
                }
            }
            Write-Host "        'modified-live': -ForceRestore overwrites the live change with the canonical file." -ForegroundColor Yellow
            return 3
        }

        # --- DRY-RUN: no write, list what WOULD be done ---
        if ($DryRun) {
            Write-Host ("restore [dry-run]: {0} restore(s), {1} deletion(s) — nothing written." -f $restoreRels.Count, $deleteRels.Count) -ForegroundColor Cyan
            foreach ($r in $restoreRels) { Write-Host ("  ~ {0}" -f $r) -ForegroundColor DarkCyan }
            foreach ($r in $deleteRels)  { Write-Host ("  - {0}" -f $r) -ForegroundColor DarkCyan }
            return 0
        }

        # --- Deployment: STAGING -> BACKUP -> SWAP -> DELETE ---
        if ($restoreRels.Count -gt 0) {
            $staging = Join-Path ([System.IO.Path]::GetTempPath()) ('restore-stage-' + [System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $staging -Force | Out-Null
            # (1) STAGING: assemble the ref content outside live (atomic per file).
            $staged = @(Copy-Tree -SrcRoot $RefRoot -DstRoot $staging -RelPaths @($restoreRels))
        }
        else {
            $staged = @()
        }

        # (2) Timestamped BACKUP BEFORE any replacement/deletion of a live file.
        # ponytail: snapshot taken here for every PRESENT live file. An external writer
        # creating a live file between this backup and the swap would have it overwritten
        # without a backup — outside the threat model (the O_EXCL lock assumes no external
        # writer on ~/.claude during the operation). Follow up in P017 if an operational need arises.
        $backupDir = Join-Path $BackupRoot ('restore-' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff'))
        $backedUp = 0
        foreach ($rel in (@($staged) + @($deleteRels))) {
            $liveFull = Get-RestoreFullPath -Root $LiveRoot -Rel $rel
            if (Test-Path -LiteralPath $liveFull) {
                $bak = Get-RestoreFullPath -Root $backupDir -Rel $rel
                Write-FileAtomic -Path $bak -Bytes ([System.IO.File]::ReadAllBytes($liveFull)) | Out-Null
                $backedUp++
            }
        }
        if ($backedUp -gt 0) {
            Write-Host ("  [BACKUP] {0} live file(s) backed up -> {1}" -f $backedUp, $backupDir) -ForegroundColor DarkYellow
        }

        # (3) Atomic SWAP: staging -> live (temp+rename per file).
        $deployed = @()
        if ($staged.Count -gt 0) {
            $deployed = @(Copy-Tree -SrcRoot $staging -DstRoot $LiveRoot -RelPaths @($staged))
            Write-Host ("restore: {0} file(s) deployed ref->live." -f $deployed.Count) -ForegroundColor Green
        }

        # (4) Base-aware DELETE: propagated canonical deletion (backup already taken).
        $deleted = 0
        foreach ($rel in $deleteRels) {
            $liveFull = Get-RestoreFullPath -Root $LiveRoot -Rel $rel
            if (Test-Path -LiteralPath $liveFull) {
                Remove-Item -LiteralPath $liveFull -Force
                $deleted++
            }
        }
        if ($deleted -gt 0) {
            Write-Host ("restore: {0} file(s) deleted (base-aware H6)." -f $deleted) -ForegroundColor Green
        }

        if (($deployed.Count -eq 0) -and ($deleted -eq 0)) {
            Write-Host "restore: nothing to restore (live already matches the greenlisted canonical tree)." -ForegroundColor Green
        }

        # --- verify POST-CHECK (0 drift required) ---
        $verifyRc = Invoke-VerifyPostCheck -RepoRoot $GitRoot -LiveTarget $LiveRoot
        if ($verifyRc -ne 0) {
            if ($verifyRc -eq 2) {
                # 2 = verify UNAVAILABLE (script missing / PS host not found): a failure of
                # the verification infrastructure, not a content drift. Still fail-closed (exit != 0).
                Write-Host "restore: POST-CHECK not run — verify unavailable (code 2). Deployed but NOT verified." -ForegroundColor Red
            } else {
                Write-Host ("restore: POST-CHECK verify found a difference (code {0}) — live != ref HEAD." -f $verifyRc) -ForegroundColor Red
            }
            Write-Host "        Run 'verify' again for details. The timestamped backups are recoverable." -ForegroundColor Yellow
            return 7
        }

        Write-Host "restore: OK — live matches the canonical REF (verify post-check 0 drift)." -ForegroundColor Green
        return 0
    }
    finally {
        if ($null -ne $staging -and (Test-Path -LiteralPath $staging)) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $lock) { Release-SyncLock -Lock $lock }
    }
}

# --- Auto-run (script) — suppressed when dot-sourced (tests) -----------------
if ($MyInvocation.InvocationName -ne '.') {
    $rc = Invoke-Restore -RefRoot $RefRoot -LiveRoot $LiveRoot -GitRoot $GitRoot `
        -ManifestPath $ManifestPath -LockPath $LockPath -BackupRoot $BackupRoot `
        -ForceRestore:$ForceRestore -DryRun:$DryRun
    exit $rc
}
