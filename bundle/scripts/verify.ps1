#requires -Version 5.1
<#
.SYNOPSIS
  verify — REF-authoritative hash fidelity checker (P014:A010).

.DESCRIPTION
  Replaces the former false-green smoke test. Proves that the LIVE install
  (~/.claude) is byte-identical to the committed canonical REF (repo
  sdlc-framework/claude/ at git HEAD). Strictly READ-ONLY: writes NO file,
  commits nothing, takes no lock. Exit != 0 on the smallest difference.

  Behavior (dot-sources sync-lib as the single source of behavior):
    - sdlc domain scope (H7): LIVE side through Get-DomainRelPaths; THIRD-PARTY
      skills (not sdlc*) are ignored, never counted nor flagged as extra.
    - Compares the COMMITTED HEAD (A4): REF content is read with
      `git cat-file blob HEAD:claude/<relpath>` — NOT the working tree. Changing
      the ref working tree after a commit therefore does not change the verdict.
    - Reuses sync-lib's CENTRALIZED exclusion set (Test-SyncExcluded, M1): real
      .pyc / __pycache__ files in live are NEVER extra.
    - Reports: MISSING (in ref HEAD, absent from live) / HASH DIFF / EXTRA
      (present in live within the scoped domain, absent from ref HEAD) /
      FLOOR (cardinality difference).
    - DERIVED floors (M4): count(sdlc* skills), sdlc-* agents and commands/sdlc
      are computed from the committed ref — NO hard-coded literal — and compared
      with live (drift => difference).

  Exit codes: 0 = identical, 1 = at least one difference, 2 = unavailable
  (live missing, or git missing / no committed HEAD).

  Drivable: the body does NOT run when dot-sourced (InvocationName guard), which
  lets tests dot-source it and call Invoke-Verify on isolated fixtures.

  Compatible with PowerShell 5.1 (Desktop) AND 7 (Core). ZERO external dependency
  (git is required to read the committed ref).
#>

[CmdletBinding()]
param(
    # Root of the REF repo (contains claude/ and .git). Default: two levels
    # above bundle/scripts/ (the sdlc-framework root).
    [string]$RefRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    # LIVE root = the ~/.claude install.
    [string]$LiveRoot = (Join-Path $env:USERPROFILE '.claude'),
    [switch]$Quiet
)

# --- Shared foundation: single source of sync behavior ----------------------
. (Join-Path $PSScriptRoot 'sync-lib.ps1')

# ---------------------------------------------------------------------------
# verify helpers (domain projection on the git tree + byte-exact hashing)
# ---------------------------------------------------------------------------

function Get-Sha256HexBytes {
    # ponytail: same recipe as Get-FileHashByteExact (byte-exact lowercase sha256
    # hex), but on in-memory BYTES — git streams a blob, not a file. LIVE files go
    # through the Get-FileHashByteExact primitive.
    param([Parameter(Mandatory)][byte[]]$Bytes)
    Set-StrictMode -Version Latest
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($h) -replace '-', '').ToLowerInvariant()
}

function Test-InSdlcDomain {
    # Projection of the sync domain (A003 + core A018 SP3) onto a relPath from the
    # git tree, where no filesystem exists for Get-DomainRelPaths. FAITHFUL mirror
    # of the Get-DomainRelPaths rules; reuses Test-SyncExcluded.
    # ponytail: any new domain added to Get-DomainRelPaths must be mirrored here.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RelPath)
    Set-StrictMode -Version Latest
    $norm = ($RelPath -replace '\\', '/').Trim('/')
    if ($norm -eq '') { return $false }
    if (Test-SyncExcluded -RelPath $norm) { return $false }
    # -ceq/-clike (case-SENSITIVE) everywhere: the source of truth is `git ls-tree`
    # (case-sensitive even on Windows) and the bash mirror uses [[ == ]] / globs /
    # find, all case-sensitive. Otherwise a committed blob with the wrong case
    # (e.g. claude/nestor.md, agents/Nestor-rh.md) would be in-domain on the PS side
    # and out-of-domain on the bash side => same inputs, different exit codes (breaks
    # the SP2 parity invariant). Canonical names are all lowercase => 0 regression.
    # core domain (A018 SP3): the LITERAL NESTOR.md only — no root pattern.
    $seg = $norm -split '/'
    $leaf = $seg[$seg.Length - 1]
    # skills domain: skills/<sdlc*dir>/<file...> (H7), except skills/sdlc/commands/** (H3).
    # -ge 3 (not 2): Get-DomainRelPaths only recurses into files INSIDE an sdlc* skill
    # folder; a loose 2-segment file (e.g. skills/sdlc-notes.md) is never scanned on
    # the LIVE side, so it is never in-domain on the REF side either.
    if ($seg[0] -ceq 'skills' -and $seg.Length -ge 3 -and ($seg[1] -clike 'sdlc*')) {
        if ($norm -clike 'skills/sdlc/commands/*') { return $false }
        return $true
    }
    # commands domain: canonical top-level commands/sdlc/**
    if ($norm -clike 'commands/sdlc/*') { return $true }
    # agents domain: agents/**/<sdlc-*> (A018 SP3)
    if ($seg[0] -ceq 'agents' -and $seg.Length -ge 2 -and
        (($leaf -clike 'sdlc-*'))) { return $true }
    return $false
}

function Test-GitRefUsable {
    param([Parameter(Mandatory)][string]$RepoRoot)
    Set-StrictMode -Version Latest
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { return $false }
    & git -C $RepoRoot rev-parse --verify --quiet HEAD > $null 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Get-RefDomainRelPaths {
    # relPaths (normalized '/', claude/ prefix removed) of the sdlc domain as
    # COMMITTED at HEAD — enumerates the git tree, not the working tree.
    param([Parameter(Mandatory)][string]$RepoRoot)
    Set-StrictMode -Version Latest
    $out = & git -C $RepoRoot -c core.quotepath=false ls-tree -r --name-only HEAD -- claude 2>$null
    if ($LASTEXITCODE -ne 0) { throw "git ls-tree failed on HEAD:claude in $RepoRoot" }
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($out)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $p = ($line -replace '\\', '/').Trim()
        if (-not $p.StartsWith('claude/')) { continue }
        $rel = $p.Substring('claude/'.Length)
        if (Test-InSdlcDomain -RelPath $rel) { $result.Add($rel) }
    }
    return @($result | Sort-Object -Unique)
}

function Get-GitBlobBytes {
    # Raw bytes of the committed blob HEAD:claude/<rel> — through Process to keep
    # byte accuracy (the PowerShell pipeline would alter line endings).
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RelPath
    )
    Set-StrictMode -Version Latest
    $treePath = 'HEAD:claude/' + $RelPath
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    # .Arguments (string): compatible with .NET Framework (5.1) AND Core (7).
    # ArgumentList does not exist on 5.1. Quotes around treePath.
    $psi.Arguments = 'cat-file blob "' + $treePath + '"'
    $psi.WorkingDirectory = $RepoRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $ms = New-Object System.IO.MemoryStream
    try {
        # ponytail: domain blobs are small files; stderr stays empty on success.
        # If blobs grew to several MB, drain stderr on a separate thread to avoid
        # a buffer deadlock.
        $p.StandardOutput.BaseStream.CopyTo($ms)
        $null = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) { throw "git cat-file failed for $treePath" }
        return $ms.ToArray()
    } finally {
        $ms.Dispose()
        $p.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Derived cardinalities (M4) — no magic literal
# ---------------------------------------------------------------------------

function Get-DomainCardinalities {
    # From a set of relPaths (sync domain), computes the cardinalities
    # dynamically (skills = number of first-level sdlc* folders, agents = files,
    # commands = files, core = 0/1 on the literal NESTOR.md — A018 SP3).
    # No hard-coded number.
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RelPaths)
    Set-StrictMode -Version Latest
    $skillDirs = New-Object 'System.Collections.Generic.HashSet[string]'
    $agents = 0
    $commands = 0
    $core = 0
    foreach ($rel in $RelPaths) {
        $seg = $rel -split '/'
        # -ceq/-clike: mirror of the bash awk (case-sensitive: $0=="NESTOR.md",
        # $1=="skills"/"agents", /^commands\/sdlc\//). HashSet[string] = ordinal.
        if ($rel -ceq 'NESTOR.md') { $core++ }
        elseif ($seg[0] -ceq 'skills' -and $seg.Length -ge 2) { [void]$skillDirs.Add($seg[1]) }
        elseif ($seg[0] -ceq 'agents') { $agents++ }
        elseif ($rel -clike 'commands/sdlc/*') { $commands++ }
    }
    return [pscustomobject]@{
        Skills   = $skillDirs.Count
        Agents   = $agents
        Commands = $commands
        Core     = $core
    }
}

# ---------------------------------------------------------------------------
# Core: Invoke-Verify (returns 0 = identical, != 0 = difference / error)
# ---------------------------------------------------------------------------

function Invoke-Verify {
    param(
        [Parameter(Mandatory)][string]$RefRoot,
        [Parameter(Mandatory)][string]$LiveRoot,
        [switch]$Quiet
    )
    Set-StrictMode -Version Latest

    function Say {
        param([string]$Msg, [string]$Color = 'Gray')
        if (-not $Quiet) { Write-Host $Msg -ForegroundColor $Color }
    }

    Say ""
    Say ("=" * 70) 'Cyan'
    Say "  verify — REF-authoritative fidelity (committed HEAD vs live)" 'Cyan'
    Say ("=" * 70) 'Cyan'

    if (-not (Test-Path -LiteralPath $LiveRoot)) {
        Say "LIVE not found: $LiveRoot" 'Red'
        return 2
    }
    if (-not (Test-GitRefUsable -RepoRoot $RefRoot)) {
        Say "REF unusable (git missing or no committed HEAD): $RefRoot" 'Red'
        return 2
    }

    # --- REF (committed HEAD) ---------------------------------------------------
    $refRel = Get-RefDomainRelPaths -RepoRoot $RefRoot
    $refHash = @{}
    foreach ($rel in $refRel) {
        $bytes = Get-GitBlobBytes -RepoRoot $RefRoot -RelPath $rel
        $refHash[$rel] = Get-Sha256HexBytes -Bytes $bytes
    }

    # --- LIVE (domain scope via sync-lib, H7 + M1 exclusions) ------------------
    $liveRel = Get-DomainRelPaths -Root $LiveRoot
    $liveHash = @{}
    $sep = [System.IO.Path]::DirectorySeparatorChar
    foreach ($rel in @($liveRel)) {
        $full = Join-Path $LiveRoot ($rel -replace '/', [string]$sep)
        if (Test-Path -LiteralPath $full) {
            $liveHash[$rel] = Get-FileHashByteExact -Path $full
        }
    }

    # --- Fidelity comparison ---------------------------------------------------
    $missing = New-Object System.Collections.Generic.List[string]   # in ref HEAD, absent from live
    $hashDiff = New-Object System.Collections.Generic.List[string]  # present on both sides, hash !=
    $surplus = New-Object System.Collections.Generic.List[string]   # in live scope, absent from ref HEAD

    foreach ($rel in ($refHash.Keys | Sort-Object)) {
        if (-not $liveHash.ContainsKey($rel)) { $missing.Add($rel) }
        elseif ($liveHash[$rel] -ne $refHash[$rel]) { $hashDiff.Add($rel) }
    }
    foreach ($rel in ($liveHash.Keys | Sort-Object)) {
        if (-not $refHash.ContainsKey($rel)) { $surplus.Add($rel) }
    }

    # --- Derived floors (M4): committed ref == live -----------------------------
    $refCard = Get-DomainCardinalities -RelPaths @($refHash.Keys)
    $liveCard = Get-DomainCardinalities -RelPaths @($liveHash.Keys)
    $cardDrift = New-Object System.Collections.Generic.List[string]
    if ($liveCard.Skills   -ne $refCard.Skills)   { $cardDrift.Add(("skills: floor={0} live={1}"   -f $refCard.Skills,   $liveCard.Skills)) }
    if ($liveCard.Agents   -ne $refCard.Agents)   { $cardDrift.Add(("agents: floor={0} live={1}"   -f $refCard.Agents,   $liveCard.Agents)) }
    if ($liveCard.Commands -ne $refCard.Commands) { $cardDrift.Add(("commands: floor={0} live={1}" -f $refCard.Commands, $liveCard.Commands)) }
    if ($liveCard.Core     -ne $refCard.Core)     { $cardDrift.Add(("core: floor={0} live={1}"     -f $refCard.Core,     $liveCard.Core)) }

    # --- Report ----------------------------------------------------------------
    Say ""
    Say ("  ref (committed HEAD) : {0} domain files" -f $refHash.Count)
    Say ("  live (sdlc scope)    : {0} domain files" -f $liveHash.Count)
    Say ("  derived floors       : skills={0} agents={1} commands={2} core={3}" -f $refCard.Skills, $refCard.Agents, $refCard.Commands, $refCard.Core)

    foreach ($m in $missing)  { Say ("  [MISSING]      $m") 'Red' }
    foreach ($h in $hashDiff) { Say ("  [HASH DIFF]    $h") 'Red' }
    foreach ($s in $surplus)  { Say ("  [EXTRA]        $s") 'Red' }
    foreach ($c in $cardDrift){ Say ("  [FLOOR]        $c") 'Red' }

    $ecarts = $missing.Count + $hashDiff.Count + $surplus.Count + $cardDrift.Count

    Say ""
    if ($ecarts -eq 0) {
        Say "  PERFECT fidelity: live == committed ref HEAD (0 differences)." 'Green'
        return 0
    }
    Say ("  FAIL: {0} difference(s) found. Live != canonical ref." -f $ecarts) 'Red'
    return 1
}

# ---------------------------------------------------------------------------
# Execution guard: run nothing when dot-sourced (drivable by tests).
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $rc = Invoke-Verify -RefRoot $RefRoot -LiveRoot $LiveRoot -Quiet:$Quiet
    exit $rc
}
