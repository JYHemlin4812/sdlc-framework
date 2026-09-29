#requires -Version 5.1
<#
.SYNOPSIS
  capture (P012:A006) — proposes LIVE changes to the canonical REF, then commits.

.DESCRIPTION
  Canonical direction (A001): REF = source of truth = repo sdlc-framework/claude/
  (tracked by git). LIVE = the ~/.claude/ install. The BASE (3rd state) is a
  machine-local manifest stored OUTSIDE the git worktree (under ~/.claude/, H1).

  Behavior:
    - Acquires an O_EXCL lockfile around every mutation (released in finally).
    - Loads the base (Read-SyncManifest). Missing -> Get-FirstRunPlan (union
      ref+live): seed if equal, otherwise BLOCKED (requires -Adopt). Corrupt -> fail
      CLOSED (refuses to act on an untrusted base).
    - Classifies each relPath of the UNION of the domains (Get-SyncState):
        modified-live / added-live      -> CAPTURE (copy live->ref)
        modified-both                   -> BLOCKED (diff), unless -Lww (logged)
        deleted-live / conflict-*       -> BLOCKED (never propagated without a direction)
        identical / modified-ref / ...  -> skip
    - If there is >=1 unresolved block: exit != 0, WRITES NOTHING
      (no files, no manifest, no git).
    - Copies the greenlisted relPaths with Copy-Tree (per-relpath, never /MIR).
    - Commit: stage AND commit LIMITED to the rels actually copied
      (explicit pathspec 'claude/<rel>' on both 'git add' AND 'git commit') — never
      'git add -- claude/' (would index the whole worktree) nor 'git commit' without
      a pathspec (would commit the whole index). Closes S1/S2/S3: no out-of-domain
      file, no pre-staged file outside claude/, no skipped deletion
      is pulled into the canonical commit.
    - BEFORE any LWW winner=live overwrite of an existing ref file: timestamped
      backup of the losing ref OUTSIDE the worktree (recoverable; capture has no
      staging/swap like restore).
    - POST-CHECK (A4): after the commit, asserts 'git status --porcelain' is empty
      for the committed rels ONLY; otherwise exit != 0 and the base is NOT rewritten
      (partial failure on our files).
    - On success only: rewrites the base (atomic Write-SyncManifest).
    - -DryRun: 0 writes (files/manifest/git); the exit code reflects the
      would-block (!=0 if it would have blocked).

  Compatible with PowerShell 5.1 (Desktop) AND 7 (Core). ZERO external dependency.
  Driven by param(); the logic lives in Invoke-Capture. Dot-sourcing
  (tests) does NOT trigger the auto-run (InvocationName guard).
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
    [string]$ConflictLogPath = '',
    [string]$LockPath = '',
    [switch]$Lww,
    [ValidateSet('ref', 'live')][string]$Provenance = 'ref',
    [switch]$Adopt,
    [switch]$DryRun
)

# --- Load the shared foundation (single source A002/A004) -------------------
. (Join-Path $PSScriptRoot 'sync-lib.ps1')

# --- Path/hash helpers (reuse sync-lib) --------------------------------------

function Get-CaptureFullPath {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Rel)
    Set-StrictMode -Version Latest
    $native = $Rel -replace '/', ([string][System.IO.Path]::DirectorySeparatorChar)
    return (Join-Path $Root $native)
}

function Get-CaptureHashOrNull {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Rel)
    Set-StrictMode -Version Latest
    $full = Get-CaptureFullPath -Root $Root -Rel $Rel
    if (Test-Path -LiteralPath $full) { return (Get-FileHashByteExact -Path $full) }
    return $null
}

function Get-CaptureHashMap {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Rels)
    Set-StrictMode -Version Latest
    $m = @{}
    foreach ($r in $Rels) {
        $h = Get-CaptureHashOrNull -Root $Root -Rel $r
        if ($null -ne $h) { $m[$r] = $h }
    }
    return $m
}

function Invoke-CaptureGit {
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

# --- Core --------------------------------------------------------------------

function Invoke-Capture {
    param(
        [Parameter(Mandatory)][string]$RefRoot,
        [Parameter(Mandatory)][string]$LiveRoot,
        [string]$GitRoot = '',
        [string]$ManifestPath = '',
        [string]$ConflictLogPath = '',
        [string]$LockPath = '',
        [switch]$Lww,
        [ValidateSet('ref', 'live')][string]$Provenance = 'ref',
        [switch]$Adopt,
        [switch]$DryRun
    )
    Set-StrictMode -Version Latest

    # --- Path resolution ---
    $refResolved = Resolve-Path -LiteralPath $RefRoot -ErrorAction SilentlyContinue
    if ($null -eq $refResolved) {
        Write-Host "capture: RefRoot not found: $RefRoot" -ForegroundColor Red
        return 2
    }
    $RefRoot = $refResolved.Path
    $liveResolved = Resolve-Path -LiteralPath $LiveRoot -ErrorAction SilentlyContinue
    if ($null -eq $liveResolved) {
        Write-Host "capture: LiveRoot not found: $LiveRoot" -ForegroundColor Red
        return 2
    }
    $LiveRoot = $liveResolved.Path

    if ([string]::IsNullOrEmpty($GitRoot)) { $GitRoot = Split-Path -Parent $RefRoot }
    $refLeaf = Split-Path -Leaf $RefRoot
    # Base + logs: OUTSIDE the worktree (under LiveRoot, not tracked by git). Names
    # excluded from sync by sync-lib (Get-SyncExclusion.Names).
    if ([string]::IsNullOrEmpty($ManifestPath))    { $ManifestPath    = Join-Path $LiveRoot '.sync-manifest.json' }
    if ([string]::IsNullOrEmpty($ConflictLogPath)) { $ConflictLogPath = Join-Path $LiveRoot 'conflicts.log' }
    if ([string]::IsNullOrEmpty($LockPath))        { $LockPath        = Join-Path $LiveRoot '.sync.lock' }

    $mode = if ($DryRun) { '[dry-run] ' } else { '' }
    Write-Host ("capture ${mode}: ref=$RefRoot  live=$LiveRoot") -ForegroundColor Cyan

    $lock = $null
    try {
        # Exclusive lock around every mutation (and around the analysis, to avoid
        # racing another capture/restore). Released in finally.
        $lock = Acquire-SyncLock -Path $LockPath

        # --- UNION of the domain relPaths (ref + live) ---
        $refRels  = @(Get-DomainRelPaths -Root $RefRoot)
        $liveRels = @(Get-DomainRelPaths -Root $LiveRoot)
        $union = @(@($refRels + $liveRels) | Sort-Object -Unique)

        # --- Load the base (3rd state) ---
        $manifest = Read-SyncManifest -Path $ManifestPath

        if (-not $manifest.Exists) {
            # ---- FIRST-RUN (H5): seed if the union is equal, otherwise block ----
            $refHashes  = Get-CaptureHashMap -Root $RefRoot  -Rels $union
            $liveHashes = Get-CaptureHashMap -Root $LiveRoot -Rels $union
            $plan = Get-FirstRunPlan -RefHashes $refHashes -LiveHashes $liveHashes -Adopt:$Adopt

            if ($plan.Signal -eq 'block') {
                Write-Host "capture: first-run BLOCKED (asymmetry/divergence without a base)." -ForegroundColor Red
                Write-Host ("        {0} divergent relPath(s). Run again with -Adopt to adopt the current state." -f $plan.Mismatches.Count) -ForegroundColor Yellow
                return 5
            }

            # seed (equal) or adopt: set base = ref-if-present-else-live.
            # ponytail: adopt freezes the current state as the baseline; the real
            # capture happens on the next run against that base.
            $seed = @{}
            foreach ($rel in $plan.Union) {
                if ($refHashes.ContainsKey($rel)) { $seed[$rel] = $refHashes[$rel] }
                elseif ($liveHashes.ContainsKey($rel)) { $seed[$rel] = $liveHashes[$rel] }
            }
            $adoptedTag = if ($plan.Adopted) { ' (adopted)' } else { '' }
            if ($DryRun) {
                Write-Host ("capture: first-run seed{0} — {1} entry(ies) [dry-run, base not written]." -f $adoptedTag, $seed.Count) -ForegroundColor Green
                return 0
            }
            Write-SyncManifest -Path $ManifestPath -Entries $seed | Out-Null
            Write-Host ("capture: first-run seed{0} — base written ({1} entry(ies))." -f $adoptedTag, $seed.Count) -ForegroundColor Green
            return 0
        }

        if ($manifest.FailClosed) {
            # ---- FAIL CLOSED (H4): corrupt base -> refuse to act ----
            Write-Host "capture: unreadable/corrupt manifest -> FAIL CLOSED (no action)." -ForegroundColor Red
            Write-Host "        No capture is attempted on an untrusted base." -ForegroundColor Yellow
            return 6
        }

        # ---- NORMAL PASS (trusted base) ----
        $base = $manifest.Entries

        $captureRels = New-Object System.Collections.Generic.List[string]   # definite copy
        $captureHash = @{}                                                  # rel -> new sha (== liveHash)
        $lwwPending  = New-Object System.Collections.Generic.List[object]   # modified-both states + -Lww
        $blocks      = New-Object System.Collections.Generic.List[object]   # hard blocks

        foreach ($rel in $union) {
            $refH  = Get-CaptureHashOrNull -Root $RefRoot  -Rel $rel
            $liveH = Get-CaptureHashOrNull -Root $LiveRoot -Rel $rel
            $baseH = $null
            if ($base.ContainsKey($rel)) { $baseH = $base[$rel] }

            $st = Get-SyncState -RefHash $refH -LiveHash $liveH -BaseHash $baseH -RelPath $rel

            switch ($st.State) {
                'modified-live' { $captureRels.Add($rel); $captureHash[$rel] = $liveH }
                'added-live'  { $captureRels.Add($rel); $captureHash[$rel] = $liveH }
                'modified-both' {
                    if ($Lww) { $lwwPending.Add($st) }
                    else      { $blocks.Add([pscustomobject]@{ Rel = $rel; State = $st.State; RefH = $refH; LiveH = $liveH }) }
                }
                'identical'   { }
                'modified-ref' { }
                'added-ref'  { }
                'deleted-ref' { }
                'absent-both' { }
                default {
                    # deleted-live and every conflict-*: never propagated without an explicit direction.
                    $blocks.Add([pscustomobject]@{ Rel = $rel; State = $st.State; RefH = $refH; LiveH = $liveH })
                }
            }
        }

        # ---- HARD BLOCKS: exit != 0, NOTHING written ----
        if ($blocks.Count -gt 0) {
            Write-Host ("capture: BLOCKED — {0} unresolved conflict(s). Nothing written." -f $blocks.Count) -ForegroundColor Red
            foreach ($b in $blocks) {
                Write-Host ("  [BLOCK] {0}  ({1})" -f $b.Rel, $b.State) -ForegroundColor Red
                # Readable diff when both sides exist (e.g. modified-both).
                if (($null -ne $b.RefH) -and ($null -ne $b.LiveH)) {
                    $rp = Get-CaptureFullPath -Root $RefRoot  -Rel $b.Rel
                    $lp = Get-CaptureFullPath -Root $LiveRoot -Rel $b.Rel
                    $diff = Show-ConflictDiff -RefPath $rp -LivePath $lp
                    if ($diff) { Write-Host $diff -ForegroundColor DarkGray }
                }
            }
            Write-Host "        Resolve manually, or use -Lww (opt-in, logged) for modified-both." -ForegroundColor Yellow
            return 3
        }

        # At this point: no hard block. Writing is allowed.

        # ---- Opt-in LWW resolution (logged) ----
        # modified-both implies an uncommitted REF change (refH != baseH):
        # winner=live will overwrite it. Remember these rels so they are backed up
        # BEFORE the copy (recoverability; otherwise the losing ref change is destroyed).
        $lwwLiveWinners = New-Object System.Collections.Generic.List[string]
        foreach ($st in $lwwPending) {
            $res = Resolve-LWW -RelPath $st.RelPath -ConflictLogPath $ConflictLogPath `
                        -RefHash $st.RefHash -LiveHash $st.LiveHash -Provenance $Provenance -DryRun:$DryRun
            Write-Host ("  [LWW] {0} -> winner={1}" -f $st.RelPath, $res.Winner) -ForegroundColor Yellow
            if ($res.Winner -eq 'live') {
                if (-not $captureRels.Contains($st.RelPath)) { $captureRels.Add($st.RelPath) }
                $captureHash[$st.RelPath] = $st.LiveHash
                $lwwLiveWinners.Add($st.RelPath)
            }
            # winner=ref: keep the canonical file, nothing to capture.
        }

        $rels = @($captureRels)

        if ($rels.Count -eq 0) {
            Write-Host "capture: nothing to capture (no greenlisted live change)." -ForegroundColor Green
            return 0
        }

        if ($DryRun) {
            Write-Host ("capture [dry-run]: {0} file(s) WOULD be captured — nothing written." -f $rels.Count) -ForegroundColor Cyan
            foreach ($r in $rels) { Write-Host ("  + {0}" -f $r) -ForegroundColor DarkCyan }
            return 0
        }

        # ---- git available (required to commit) ----
        $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue
        if ($null -eq $git) {
            Write-Host "capture: git not found — cannot commit. Nothing written." -ForegroundColor Red
            return 2
        }

        # ---- Timestamped backup of losing refs BEFORE the LWW overwrite ----
        # winner=live overwrites an uncommitted REF change: backing it up OUTSIDE
        # the worktree makes it recoverable (capture has no staging/swap).
        if ($lwwLiveWinners.Count -gt 0) {
            $backupRoot = Join-Path (Split-Path -Parent $ConflictLogPath) `
                ('_backups/' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff'))
            foreach ($rel in $lwwLiveWinners) {
                $refFull = Get-CaptureFullPath -Root $RefRoot -Rel $rel
                if (Test-Path -LiteralPath $refFull) {
                    $bak = Get-CaptureFullPath -Root $backupRoot -Rel $rel
                    Write-FileAtomic -Path $bak -Bytes ([System.IO.File]::ReadAllBytes($refFull)) | Out-Null
                    Write-Host ("  [BACKUP] ref '{0}' backed up -> {1}" -f $rel, $bak) -ForegroundColor DarkYellow
                }
            }
        }

        # ---- Copy live -> ref (per-relpath, never /MIR) ----
        $copied = @(Copy-Tree -SrcRoot $LiveRoot -DstRoot $RefRoot -RelPaths $rels)
        Write-Host ("capture: {0} file(s) copied live->ref." -f $copied.Count) -ForegroundColor Green

        if ($copied.Count -eq 0) {
            # No source actually copied (vanished between scan and copy): commit
            # NOTHING. A commit without a pathspec would pull in the whole index.
            Write-Host "capture: no file actually copied — nothing to commit, base unchanged." -ForegroundColor Yellow
            return 0
        }

        # ---- Commit: EXPLICIT pathspec limited to the copied rels ONLY ----
        # 'git add -- claude/' would index the whole worktree; 'git commit' without
        # a pathspec would commit the whole index (out-of-domain files, pre-staged
        # files outside claude/, skipped deletions). So add + commit +
        # post-check are restricted to the native 'claude/<rel>' paths actually copied.
        $pathspecs = @($copied | ForEach-Object { "$refLeaf/$_" })

        $addRes = Invoke-CaptureGit -GitRoot $GitRoot -GitArgs (@('add', '--') + $pathspecs)
        if ($addRes.Code -ne 0) {
            Write-Host ("capture: 'git add' (copied rels) failed (code {0}). Base not rewritten." -f $addRes.Code) -ForegroundColor Red
            if ($addRes.Out) { Write-Host $addRes.Out -ForegroundColor DarkGray }
            return 4
        }
        $msg = "capture: sync live -> ref (P012:A006) — $($copied.Count) file(s)"
        $commitRes = Invoke-CaptureGit -GitRoot $GitRoot -GitArgs (@('commit', '-m', $msg, '--') + $pathspecs)
        if ($commitRes.Code -ne 0) {
            Write-Host ("capture: 'git commit' failed (code {0}). Base not rewritten." -f $commitRes.Code) -ForegroundColor Red
            if ($commitRes.Out) { Write-Host $commitRes.Out -ForegroundColor DarkGray }
            return 4
        }

        # ---- POST-CHECK (A4): the committed rels ONLY must be clean ----
        # (checks that OUR files landed, not that the whole worktree is clean:
        # legitimate out-of-scope changes must not block.)
        $porc = Invoke-CaptureGit -GitRoot $GitRoot -GitArgs (@('status', '--porcelain', '--') + $pathspecs)
        if (($porc.Code -ne 0) -or (-not [string]::IsNullOrWhiteSpace($porc.Out))) {
            Write-Host "capture: POST-CHECK FAILED — committed rels still dirty (partial failure)." -ForegroundColor Red
            if ($porc.Out) { Write-Host $porc.Out -ForegroundColor DarkGray }
            Write-Host "        Base NOT rewritten (untrusted state)." -ForegroundColor Yellow
            return 7
        }

        # ---- Success: atomic rewrite of the base ----
        # base += hashes of the files actually copied ONLY (not of rels whose
        # source vanished before the copy).
        $newBase = @{}
        foreach ($k in $base.Keys) { $newBase[$k] = $base[$k] }
        foreach ($k in $copied) { if ($captureHash.ContainsKey($k)) { $newBase[$k] = $captureHash[$k] } }
        Write-SyncManifest -Path $ManifestPath -Entries $newBase | Out-Null

        Write-Host ("capture: OK — {0} file(s) captured and committed; base rewritten." -f $copied.Count) -ForegroundColor Green
        return 0
    }
    finally {
        if ($null -ne $lock) { Release-SyncLock -Lock $lock }
    }
}

# --- Auto-run (script) — suppressed when dot-sourced (tests) -----------------
if ($MyInvocation.InvocationName -ne '.') {
    $rc = Invoke-Capture -RefRoot $RefRoot -LiveRoot $LiveRoot -GitRoot $GitRoot `
        -ManifestPath $ManifestPath -ConflictLogPath $ConflictLogPath -LockPath $LockPath `
        -Lww:$Lww -Provenance $Provenance -Adopt:$Adopt -DryRun:$DryRun
    exit $rc
}
