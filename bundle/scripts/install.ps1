#requires -Version 5.1
<#
.SYNOPSIS
    SDLC system installer v3.2 — disaster-recovery bootstrap (P015:A011).
    Deploys the sdlc* skills + slash commands + sdlc-* agents of the canonical
    REF (repo sdlc-framework/claude/) to the LIVE install (~/.claude/).

.DESCRIPTION
    Bootstrap = SUBSET of restore (P013): on an empty live install (or on upgrade),
    deploys the canonical greenlist Get-DomainRelPaths(claude/) through STAGING + ATOMIC
    SWAP (Copy-Tree/Write-FileAtomic from sync-lib — never robocopy /MIR, never a
    destructive in-place copy), takes a timestamped backup before replacing, then runs a
    verify POST-CHECK (P014) in a subprocess to assert 0 drift.

    Reuses the shared sync-lib.ps1 foundation (SINGLE source, A002/A004):
      - Get-DomainRelPaths  → greenlist of the 3 domains (skills/sdlc*, commands/sdlc,
        agents/sdlc-*), excludes skills/sdlc/commands/** (H3), centralized exclusions.
      - Get-SyncDomainSkill → DERIVED list of the sdlc* skills (H7; never hard-coded).
      - Copy-Tree / Write-FileAtomic → atomic per-relPath deployment.
      - Get-FileHashByteExact → byte-exact idempotence checksum (CRLF != LF).

    Cardinalities (skills/agents/commands) and checksum are DERIVED from disk
    (M4 hardening), never magic literals.

    Preserved features (non-regression):
    - Idempotence through an aggregate checksum (manifest .install-manifest.json): a 2nd
      install with an unchanged source → "already up to date", exit 0 (unless -Force).
    - Overwrite guard: refuses (exit 3) if a target SKILL.md belongs to a third-party
      skill (name: not sdlc*).
    - Timestamped backup before replacing any live file (unless -NoBackup).
    - -DryRun (0 writes), -Force (reinstall), -NoBackup.

    TESTABLE structure (like restore): the logic lives in Invoke-Install; the final
    auto-run block is skipped when the script is dot-sourced (InvocationName guard),
    which lets test-install.ps1 drive fixtures.

    Compatible with PowerShell 5.1 (Desktop) AND 7 (Core). ZERO external dependency (git
    is required ONLY for the verify post-check, which degrades cleanly without it).

.PARAMETER ClaudeRoot
    Claude Code root (LIVE target). Default: $env:USERPROFILE\.claude.

.PARAMETER SourceRoot
    Root of the canonical REF. Default: ..\..\claude relative to the script (bundle/scripts
    → sdlc-framework/claude). This is the claude/ folder (skills/, commands/, agents/).

.PARAMETER Force
    Reinstall even if the checksum is unchanged (bypasses idempotence).

.PARAMETER DryRun
    Simulate without writing anything. Shows the greenlist that would be deployed.

.PARAMETER NoBackup
    Skip the backup before replacing files (not recommended).

.PARAMETER RemoveImport
    Only remove the '@NESTOR.md' import from ClaudeRoot/CLAUDE.md, then exit.

.EXAMPLE
    pwsh ./scripts/install.ps1
    pwsh ./scripts/install.ps1 -DryRun
    pwsh ./scripts/install.ps1 -Force -NoBackup
#>

[CmdletBinding()]
param(
    [string]$ClaudeRoot = (Join-Path $env:USERPROFILE ".claude"),
    # Canonical REF = ..\..\claude (bundle/scripts → sdlc-framework/claude), NOT bundle/.
    [string]$SourceRoot = (Join-Path $PSScriptRoot "..\..\claude"),
    [switch]$Force,
    [switch]$DryRun,
    [switch]$NoBackup,
    # P022:A019: removes the '@NESTOR.md' import from ClaudeRoot/CLAUDE.md INSTEAD of
    # installing (separate flag, does NOT run the rest of the installation).
    [switch]$RemoveImport
)

# --- Shared foundation (single source A002/A004) ----------------------------
. (Join-Path $PSScriptRoot 'sync-lib.ps1')

$VERSION     = "3.2.0"
$COMMANDS_NS = "sdlc"

# --- Display helpers --------------------------------------------------------
function Write-Header($msg) {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}
function Write-Step($msg) { Write-Host "  - $msg" -ForegroundColor Gray }
function Write-Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "  [ERR] $msg" -ForegroundColor Red }

function Get-CanonicalPath {
    # LONG canonical form of a path (matches Get-ChildItem.FullName). Resolve-Path and
    # [IO.Path]::GetFullPath do not reliably expand 8.3 short names; Get-Item.FullName
    # does for an existing path. Without this normalization, a SourceRoot/ClaudeRoot passed
    # in short form (e.g. C:\Users\JOHN-D~1\...) would make the Get-RelPath prefix (sync-lib)
    # diverge from the real FullName -> ABSOLUTE relPaths -> greenlist rejected by
    # Copy-Tree and FALSE drift in the verify post-check.
    param([Parameter(Mandatory)][string]$Path)
    Set-StrictMode -Version Latest
    if (Test-Path -LiteralPath $Path) { return (Get-Item -LiteralPath $Path).FullName }
    return [System.IO.Path]::GetFullPath($Path)
}

function Get-SkillName {
    # Reads the `name:` frontmatter field of a SKILL.md (third-party skill guard).
    param([string]$SkillMdPath)
    Set-StrictMode -Version Latest
    if (-not (Test-Path -LiteralPath $SkillMdPath)) { return $null }
    $lines = Get-Content -LiteralPath $SkillMdPath -Encoding UTF8 -TotalCount 30
    $inFront = $false
    foreach ($line in $lines) {
        if ($line -match '^---\s*$') {
            if ($inFront) { break }
            $inFront = $true
            continue
        }
        if ($inFront -and $line -match '^name:\s*(\S+)') {
            return $Matches[1].Trim()
        }
    }
    return $null
}

function Get-GreenlistChecksum {
    # BYTE-EXACT aggregate checksum of the greenlist (single source: Get-FileHashByteExact
    # from sync-lib, CRLF != LF). Replaces the former Get-AggregateChecksum and its local
    # exclusion lists: the exclusion set now lives only in sync-lib (the greenlist is
    # already filtered).
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RelPaths
    )
    Set-StrictMode -Version Latest
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $sb = [System.Text.StringBuilder]::new()
    foreach ($rel in ($RelPaths | Sort-Object)) {
        $full = Join-Path $Root ($rel -replace '/', [string]$sep)
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $h = Get-FileHashByteExact -Path $full
        [void]$sb.Append($rel); [void]$sb.Append(':'); [void]$sb.Append($h); [void]$sb.Append("`n")
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Invoke-VerifyPostCheck {
    # A011 POST-CHECK: runs verify (P014) in a SUBPROCESS (read-only isolation, avoids
    # clobbering verify's param() in the current scope). CAPTURES the output (WITHOUT
    # -Quiet) to CLASSIFY the drift through verify's markers — needed to tell EXTRA
    # orphans (additive install: not fatal) from a real MISSING/HASH DIFF, and an internal
    # verify failure (no marker) from real drift.
    # Returns an object: Code (0 = 0 drift; 2 = verify UNAVAILABLE: script/host/git
    # missing, no HEAD) + marker counters + HasMarkers.
    # ponytail: wrapper duplicated from restore.ps1 (locked file P013) rather than
    # editing a shipped script; to be consolidated in sync-lib when unlocked (P018 follow-up).
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$LiveTarget)
    Set-StrictMode -Version Latest
    $unavailable = [pscustomobject]@{ Code = 2; Missing = 0; HashDiff = 0; Surplus = 0; CardDrift = 0; HasMarkers = $false }
    $verifyScript = Join-Path $PSScriptRoot 'verify.ps1'
    if (-not (Test-Path -LiteralPath $verifyScript)) { return $unavailable }
    $psExe = $null
    try { $psExe = (Get-Process -Id $PID).Path } catch { }
    if ([string]::IsNullOrEmpty($psExe)) {
        $cmd = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue
        if ($null -eq $cmd) { $cmd = Get-Command powershell -CommandType Application -ErrorAction SilentlyContinue }
        if ($null -ne $cmd) { $psExe = $cmd.Source }
    }
    if ([string]::IsNullOrEmpty($psExe)) { return $unavailable }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out  = & $psExe -NoProfile -File $verifyScript -RefRoot $RepoRoot -LiveRoot $LiveTarget 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    $text      = ($out -join "`n")
    $missing   = ([regex]::Matches($text, '\[MISSING\]')).Count
    $hashDiff  = ([regex]::Matches($text, '\[HASH DIFF\]')).Count
    $surplus   = ([regex]::Matches($text, '\[EXTRA\]')).Count
    $cardDrift = ([regex]::Matches($text, '\[FLOOR\]')).Count
    return [pscustomobject]@{
        Code = $code; Missing = $missing; HashDiff = $hashDiff; Surplus = $surplus
        CardDrift = $cardDrift; HasMarkers = (($missing + $hashDiff + $surplus + $cardDrift) -gt 0)
    }
}

function Test-RefWorktreeDirty {
    # $true IF git is available AND the claude/ REF tree has uncommitted changes
    # (worktree != HEAD). Used to tell REAL drift in the verify post-check from an
    # expected difference (verify is HEAD-authoritative: it compares the committed HEAD
    # with the live tree deployed from the WORKING TREE — if that is not committed, the
    # difference is explained and not fatal). git missing / outside a repo => $false
    # (unavailable, not 'dirty': that case is already covered by verify code 2).
    param([Parameter(Mandatory)][string]$RepoRoot)
    Set-StrictMode -Version Latest
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { return $false }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $RepoRoot status --porcelain -- claude 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) { return $false }   # not a git repo: unavailable, not dirty
    return (-not [string]::IsNullOrWhiteSpace(($out -join "`n")))
}

# --- Core -------------------------------------------------------------------

function Invoke-Install {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ClaudeRoot,
        [switch]$Force,
        [switch]$DryRun,
        [switch]$NoBackup,
        [switch]$RemoveImport
    )
    Set-StrictMode -Version Latest

    # --- P022:A019: -RemoveImport is a flag SEPARATE from the normal run —
    #     it only removes the '@NESTOR.md' import from ClaudeRoot/CLAUDE.md and does
    #     NOT run the rest of the installation (no SourceRoot/greenlist needed here).
    if ($RemoveImport) {
        $rmClaudeRoot = Get-CanonicalPath -Path $ClaudeRoot
        $rmClaudeMd = Join-Path $rmClaudeRoot 'CLAUDE.md'
        Remove-NestorImport -Path $rmClaudeMd -DryRun:$DryRun
        Write-Ok "Import '@NESTOR.md' removed (if present): $rmClaudeMd"
        return 0
    }

    Write-Header "SDLC v$VERSION — System installer (disaster-recovery bootstrap)"

    # --- 1. Prechecks (read-only) ---
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Err "PowerShell 7+ required. Detected: $($PSVersionTable.PSVersion)"
        Write-Host "  Install: winget install Microsoft.PowerShell" -ForegroundColor Yellow
        return 2
    }

    $srcResolved = Resolve-Path -LiteralPath $SourceRoot -ErrorAction SilentlyContinue
    if ($null -eq $srcResolved) {
        Write-Err "SourceRoot not found: $SourceRoot"
        return 2
    }
    # LONG canonical form: required so that Get-DomainRelPaths (sync-lib) emits RELATIVE
    # relPaths (prefix == FullName). See Get-CanonicalPath.
    $SourceRoot = Get-CanonicalPath -Path $srcResolved.Path

    $sourceSkillsDir = Join-Path $SourceRoot 'skills'
    if (-not (Test-Path -LiteralPath $sourceSkillsDir)) {
        Write-Err "Source folder not found: $sourceSkillsDir"
        return 2
    }

    # Skills DERIVED from disk (H7, reuses sync-lib Get-SyncDomainSkill) — never a
    # hard-coded literal list. The third-party skill guard iterates this list.
    $SKILLS = @(Get-SyncDomainSkill -Root $SourceRoot)
    if ($SKILLS.Count -eq 0) {
        Write-Err "No sdlc* skill found under $sourceSkillsDir"
        return 2
    }
    foreach ($skill in $SKILLS) {
        $skillMd = Join-Path (Join-Path $sourceSkillsDir $skill) 'SKILL.md'
        if (-not (Test-Path -LiteralPath $skillMd)) {
            Write-Err "SKILL.md missing: $skillMd"
            return 2
        }
    }

    # Commands: canonical top-level source commands/sdlc (A003, H3) — never the
    # embedded copy under the sdlc skill (removed in P016 → exit 2 guaranteed).
    $sourceCommandsDir = Join-Path (Join-Path $SourceRoot 'commands') 'sdlc'
    if (-not (Test-Path -LiteralPath $sourceCommandsDir)) {
        Write-Err "Source commands folder not found: $sourceCommandsDir"
        return 2
    }

    # --- Canonical greenlist (single source: Get-DomainRelPaths) ---
    $greenlist = @(Get-DomainRelPaths -Root $SourceRoot)
    if ($greenlist.Count -eq 0) {
        Write-Err "Empty domain greenlist — nothing to install."
        return 2
    }

    # DERIVED cardinalities (M4, from the real ref) — no magic literal.
    $skillCount = $SKILLS.Count
    $cmdCount   = @($greenlist | Where-Object { $_ -like 'commands/sdlc/*' }).Count
    $agentCount = @($greenlist | Where-Object { $_ -like 'agents/*' }).Count
    if ($cmdCount -eq 0) {
        Write-Err "No command under commands/sdlc — incomplete source."
        return 2
    }
    Write-Ok "Source: $skillCount skills + $cmdCount commands + $agentCount agents ($($greenlist.Count) domain files)"

    # --- Target ---
    if (-not (Test-Path -LiteralPath $ClaudeRoot) -and -not $DryRun) {
        New-Item -ItemType Directory -Path $ClaudeRoot -Force | Out-Null
    }
    # LONG canonical form (after possible creation): deployment, manifest, backup AND the
    # verify post-check all use this form, otherwise Get-DomainRelPaths on the live side
    # would emit absolute relPaths -> false drift. See Get-CanonicalPath.
    $ClaudeRoot = Get-CanonicalPath -Path $ClaudeRoot
    $targetSkillsDir = Join-Path $ClaudeRoot 'skills'
    $manifestPath    = Join-Path (Join-Path $targetSkillsDir 'sdlc') '.install-manifest.json'
    $backupRoot      = Join-Path $ClaudeRoot '_backups'
    # P022:A019: GLOBAL USER file, OUTSIDE the sync domain (never in the
    # Get-DomainRelPaths greenlist). The import is added at the end of a nominal run.
    $claudeMdTarget  = Join-Path $ClaudeRoot 'CLAUDE.md'

    # --- 2. Source checksum (byte-exact, single source) ---
    $globalChecksum = Get-GreenlistChecksum -Root $SourceRoot -RelPaths $greenlist
    Write-Ok ("Source checksum: {0}..." -f $globalChecksum.Substring(0, 16))

    # --- 3. Idempotence (manifest) + self-repair (F4) ---
    $isUpgrade = $false
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $existingManifest = Get-Content -LiteralPath $manifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
            if (($existingManifest.checksum_sha256 -eq $globalChecksum) -and (-not $Force)) {
                # SOURCE checksum unchanged: the manifest says "up to date". But a
                # DISASTER-RECOVERY tool cannot rely on the manifest to claim the LIVE tree is
                # INTACT (the manifest proves nothing about the real live state). CONFIRM
                # through verify; if the live tree is damaged, REPAIR (fall through to the
                # redeploy) instead of wrongly reporting "already up to date" (F4).
                $repoRootIdem = Split-Path -Parent $SourceRoot
                $vrIdem = Invoke-VerifyPostCheck -RepoRoot $repoRootIdem -LiveTarget $ClaudeRoot
                # Canonical tree INTACT = 0 missing AND 0 hash-diff (extra/orphan files do not
                # make the live tree "damaged": install is additive, restore cleans up).
                $liveIntact = ($vrIdem.Code -eq 0) -or ($vrIdem.Code -eq 2) -or (-not $vrIdem.HasMarkers) -or
                    (($vrIdem.Missing -eq 0) -and ($vrIdem.HashDiff -eq 0)) -or
                    (Test-RefWorktreeDirty -RepoRoot $repoRootIdem)
                if ($liveIntact) {
                    Write-Header "Already up to date (checksum unchanged)"
                    Write-Ok "Installed version: $($existingManifest.version)"
                    if ($vrIdem.Code -eq 0) { Write-Ok "Live install confirmed intact (verify: 0 drift)." }
                    else { Write-Warn "Live install integrity not confirmed against HEAD (non-blocking)." }
                    Write-Host "  Nothing to do. To force: -Force." -ForegroundColor Gray
                    Set-LocalOverlayImport -Path $claudeMdTarget -LocalFileName 'CLAUDE.local.md' -DryRun:$DryRun
                    return 0
                }
                Write-Warn ("Source checksum unchanged BUT live install damaged (verify: {0} missing, {1} hash-diff, {2} floor) — REPAIR in progress." -f $vrIdem.Missing, $vrIdem.HashDiff, $vrIdem.CardDrift)
                $isUpgrade = $true
            } else {
                $isUpgrade = $true
                Write-Warn "Existing installation detected (v$($existingManifest.version)). Reinstall/upgrade to v$VERSION."
            }
        } catch {
            Write-Warn "Unreadable manifest — it will be overwritten. ($_)"
        }
    }

    # --- 4. Third-party skill overwrite guard (iterates the DERIVED list) ---
    Write-Step "Guard: checking ownership of target skills"
    foreach ($skill in $SKILLS) {
        $targetSkillMd = Join-Path (Join-Path $targetSkillsDir $skill) 'SKILL.md'
        if (Test-Path -LiteralPath $targetSkillMd) {
            $existingName = Get-SkillName -SkillMdPath $targetSkillMd
            # FAIL CLOSED (F2): a target SKILL.md whose `name:` field is missing/unreadable
            # is treated as an unidentifiable THIRD-PARTY skill (refuse to overwrite) rather
            # than failing open — otherwise a squatter without frontmatter would be
            # overwritten (unrecoverable under -NoBackup). Our own skills ALWAYS have a
            # name: sdlc* (never affected).
            if ([string]::IsNullOrWhiteSpace([string]$existingName)) {
                Write-Err "ABORT: $targetSkillMd exists but its 'name:' field is unreadable — unidentifiable skill, refusing to overwrite (fail-closed)."
                Write-Err "Rename, remove or fix the frontmatter of this skill before continuing."
                return 3
            }
            if ($existingName -notlike 'sdlc*') {
                Write-Err "ABORT: $targetSkillMd contains a third-party skill (name: $existingName)."
                Write-Err "Cannot overwrite. Rename or remove this skill before continuing."
                return 3
            }
        }
    }
    Write-Ok "No conflict with a third-party skill"

    # --- 5. DRY-RUN: 0 writes ---
    if ($DryRun) {
        Write-Header "DRY-RUN — no writes"
        Write-Step ("{0} domain file(s) would be deployed source -> live:" -f $greenlist.Count)
        foreach ($rel in $greenlist) { Write-Host "    ~ $rel" -ForegroundColor DarkCyan }
        Write-Warn "DRY-RUN: no actual change made."
        Set-LocalOverlayImport -Path $claudeMdTarget -LocalFileName 'CLAUDE.local.md' -DryRun
        return 0
    }

    # --- 6-8. Deployment + post-check + manifest, UNDER O_EXCL LOCK (F1) ---
    # Every LIVE mutation is serialized by the same lock as capture/restore
    # (sibling invariant: no mutation outside the lock). Not reached under -DryRun (earlier return).
    Write-Header "Deployment (staging + atomic swap via sync-lib)"
    $lock    = $null
    $staging = $null
    try {
        $lock = Acquire-SyncLock -Path (Join-Path $ClaudeRoot '.sync.lock')

        $staging = Join-Path ([System.IO.Path]::GetTempPath()) ('install-stage-' + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $staging -Force | Out-Null

        # (1) STAGING: assemble the canonical content outside live (atomic per file).
        $staged = @(Copy-Tree -SrcRoot $SourceRoot -DstRoot $staging -RelPaths $greenlist)

        # (2) Timestamped BACKUP of every PRESENT live file before replacement (unless -NoBackup).
        #     On an empty live tree (bootstrap) nothing is present → no backup created.
        if (-not $NoBackup) {
            $sep = [System.IO.Path]::DirectorySeparatorChar
            $backupDir = Join-Path $backupRoot ('sdlc-' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff'))
            $backedUp = 0
            foreach ($rel in $staged) {
                $liveFull = Join-Path $ClaudeRoot ($rel -replace '/', [string]$sep)
                if (Test-Path -LiteralPath $liveFull) {
                    $bak = Join-Path $backupDir ($rel -replace '/', [string]$sep)
                    Write-FileAtomic -Path $bak -Bytes ([System.IO.File]::ReadAllBytes($liveFull)) | Out-Null
                    $backedUp++
                }
            }
            if ($backedUp -gt 0) {
                Write-Ok ("Backup: {0} live file(s) saved -> {1}" -f $backedUp, $backupDir)
            }
        }

        # (3) Atomic SWAP: staging -> live (temp+rename per file via Copy-Tree/Write-FileAtomic).
        $deployed = @(Copy-Tree -SrcRoot $staging -DstRoot $ClaudeRoot -RelPaths $staged)
        Write-Ok ("{0} file(s) deployed source -> {1}" -f $deployed.Count, $ClaudeRoot)

        # --- verify POST-CHECK (read-only subprocess) + drift CLASSIFICATION ---
        # COUPLING (handled like restore's canonical guard): verify is HEAD-AUTHORITATIVE
        # (git cat-file). install is a DISASTER-RECOVERY bootstrap that must run EVEN
        # without git (source extracted from a bundle/zip), so it fails (exit 7) ONLY on
        # real fidelity drift (MISSING/HASH DIFF) against a CLEAN REF tree:
        #   - Code 0                          → 0 drift (confirmed).
        #   - Code 2                          → verify unavailable (git missing / outside repo) → not fatal.
        #   - Code !=0 without any marker     → verify internal error (F5, verify untouched)    → not fatal.
        #   - EXTRA only                      → orphans from a previous version; install is
        #                                       ADDITIVE (no delete) → not fatal (run restore).
        #   - MISSING/HASH DIFF + DIRTY ref   → cannot be confirmed against HEAD (deploy = working tree) → not fatal.
        #   - MISSING/HASH DIFF + CLEAN ref   → real DRIFT (incomplete/corrupt deploy)          → fatal (exit 7).
        $repoRoot = Split-Path -Parent $SourceRoot
        $vr = Invoke-VerifyPostCheck -RepoRoot $repoRoot -LiveTarget $ClaudeRoot
        if ($vr.Code -eq 0) {
            Write-Ok "verify post-check: 0 drift (live == committed ref HEAD)."
        }
        elseif ($vr.Code -eq 2) {
            Write-Warn "verify post-check unavailable (git missing / source outside a repo) — atomic deployment NOT confirmed against HEAD (non-blocking)."
        }
        elseif (-not $vr.HasMarkers) {
            Write-Warn ("verify post-check inconclusive (code {0}, no fidelity difference reported: verify error?) — non-blocking." -f $vr.Code)
        }
        elseif (($vr.Missing -eq 0) -and ($vr.HashDiff -eq 0)) {
            # Canonical tree INTACT (0 missing, 0 hash-diff): the only differences are EXTRA
            # live files (orphans from a previous version) + the resulting cardinality
            # difference (verify compares counters with exact equality). install is
            # ADDITIVE (no delete): all canonical files are deployed -> not fatal (F6).
            Write-Warn ("verify post-check: {0} EXTRA file(s) on the live side (orphans from a previous version)." -f $vr.Surplus)
            Write-Warn "Canonical deployment is correct; install is additive — run restore to clean up the orphans."
        }
        elseif (Test-RefWorktreeDirty -RepoRoot $repoRoot) {
            Write-Warn ("verify post-check reports a difference ({0} missing, {1} hash-diff), but the claude/ source is not committed (worktree != HEAD): integrity NOT confirmed against HEAD (non-blocking)." -f $vr.Missing, $vr.HashDiff)
        }
        else {
            Write-Err ("verify post-check: real DRIFT (code {0}: {1} missing, {2} hash-diff, {3} floor) — live != committed ref HEAD. Deployment NOT reliable." -f $vr.Code, $vr.Missing, $vr.HashDiff, $vr.CardDrift)
            Write-Err "The timestamped backups can be recovered. Reconcile, then run again with -Force."
            return 7
        }

        # --- Manifest (F6: written ONLY after an ACCEPTABLE post-check, to avoid the
        #     inconsistency run1=exit7 / run2=already-up-to-date; atomic write via sync-lib). ---
        $manifest = [ordered]@{
            version            = $VERSION
            installed_at       = (Get-Date).ToString('o')
            source             = ($SourceRoot -replace '\\', '/')
            skills             = $SKILLS
            commands_namespace = $COMMANDS_NS
            commands_count     = $cmdCount
            agents_count       = $agentCount
            files_count        = $deployed.Count
            checksum_sha256    = $globalChecksum
            installer          = 'install.ps1'
            pwsh_version       = $PSVersionTable.PSVersion.ToString()
        }
        Write-FileAtomic -Path $manifestPath -Content ($manifest | ConvertTo-Json -Depth 5) | Out-Null
        Write-Ok "Manifest written: $manifestPath"
    }
    finally {
        if ($null -ne $staging -and (Test-Path -LiteralPath $staging)) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $lock) { Release-SyncLock -Lock $lock }
    }

    # --- 9. Final report ---
    Write-Header "Installation complete"
    Write-Host "  Version    : $VERSION" -ForegroundColor White
    Write-Host "  Skills     : $skillCount  ($($SKILLS -join ', '))" -ForegroundColor White
    Write-Host "  Commands   : $cmdCount in commands/$COMMANDS_NS/" -ForegroundColor White
    Write-Host "  Agents     : $agentCount in agents/" -ForegroundColor White
    Write-Host "  Files      : $($deployed.Count) deployed" -ForegroundColor White
    Write-Host "  Checksum   : $($globalChecksum.Substring(0,16))..." -ForegroundColor White
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor Cyan
    Write-Host "    1. Restart Claude Code (so it discovers the skills/commands)" -ForegroundColor Gray
    Write-Host "    2. Try: /sdlc:status" -ForegroundColor Gray
    Write-Host ""
    Set-LocalOverlayImport -Path $claudeMdTarget -LocalFileName 'CLAUDE.local.md'
    return 0
}

# --- Auto-run (script) — skipped when dot-sourced (tests) --------------------
if ($MyInvocation.InvocationName -ne '.') {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $rc = Invoke-Install -SourceRoot $SourceRoot -ClaudeRoot $ClaudeRoot `
        -Force:$Force -DryRun:$DryRun -NoBackup:$NoBackup -RemoveImport:$RemoveImport
    exit $rc
}
