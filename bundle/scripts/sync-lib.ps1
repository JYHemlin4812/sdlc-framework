#requires -Version 5.1
<#
.SYNOPSIS
  sync-lib — shared dot-sourced library of SP2 (bidirectional sync).

.DESCRIPTION
  Foundation of capture/restore/verify/install (P011:A002). SINGLE source of
  the sync behavior: mapping of the 3 domains, byte-exact SHA256 hashing,
  centralized exclusion set, base-aware state classifier, atomic writes
  (temp+rename), O_EXCL lockfile, atomic fail-closed manifest.

  Contract:
    - Compatible with PowerShell 5.1 (Desktop) AND 7 (Core). No $IsWindows
      assumed, no 7-only operators (?? / ?.).
    - ZERO external dependency (no Pester, no third-party module). git is
      used when present (Show-ConflictDiff), otherwise degrades cleanly.
    - DOT-SOURCES with no side effect: this file ONLY defines functions. No
      code runs on load, no scope variable is created, nothing is written.
      Set-StrictMode is enabled at the entry of EACH function (not at file
      level) so nothing leaks into the caller.

  Exported functions (dot-source):
    Get-SyncExclusion      Test-SyncExcluded
    Get-SyncDomainSkill    Get-DomainRelPaths     Get-RelPath
    Get-FileHashByteExact  Get-SyncState
    Show-ConflictDiff      Resolve-LWW
    Write-FileAtomic       Copy-Tree
    Acquire-SyncLock       Release-SyncLock
    Write-SyncManifest     Read-SyncManifest      Get-FirstRunPlan
    Set-GenericImport      Set-NestorImport       Remove-NestorImport
#>

# ---------------------------------------------------------------------------
# 1. Centralized exclusion set (A004) — single source + predicate
# ---------------------------------------------------------------------------

function Get-SyncExclusion {
    # SINGLE source of truth for exclusions, consumed by every tool.
    Set-StrictMode -Version Latest
    return [pscustomobject]@{
        # directories (a path segment equal to one of these names => excluded)
        Dirs  = @('__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache', '_backups', '_backup')
        # file patterns (leaf name matched with -like)
        Files = @('*.pyc', '*.pyo', '*.bak')
        # exact names to exclude (the manifest and the conflict log)
        Names = @('.sync-manifest.json', 'conflicts.log', '.install-manifest.json')
    }
}

function Test-SyncExcluded {
    # Predicate: $true if the relPath must be ignored by the sync.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RelPath)
    Set-StrictMode -Version Latest
    $ex = Get-SyncExclusion
    $norm = ($RelPath -replace '\\', '/').Trim('/')
    if ($norm -eq '') { return $false }
    $segments = $norm -split '/'
    $leaf = $segments[$segments.Length - 1]
    foreach ($seg in $segments) {
        if ($ex.Dirs -contains $seg) { return $true }
    }
    foreach ($fp in $ex.Files) {
        if ($leaf -like $fp) { return $true }
    }
    if ($ex.Names -contains $leaf) { return $true }
    return $false
}

# ---------------------------------------------------------------------------
# 2. 3-domain mapping (A003) + sdlc domain scope (H7) + H3 exclusion
# ---------------------------------------------------------------------------

function Get-RelPath {
    # '/'-normalized relative path of $FullPath with respect to $Root.
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$FullPath
    )
    Set-StrictMode -Version Latest
    $r = ($Root -replace '\\', '/').TrimEnd('/')
    $f = ($FullPath -replace '\\', '/')
    if ($f.StartsWith($r + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $f.Substring($r.Length + 1)
    }
    return $f.TrimStart('/')
}

function Get-SyncDomainSkill {
    # Scope helper (H7): names of the sdlc* skills under <root>/skills.
    # THIRD-PARTY skills in live are ignored (never counted nor copied).
    param([Parameter(Mandatory)][string]$Root)
    Set-StrictMode -Version Latest
    $skillsDir = Join-Path $Root 'skills'
    if (-not (Test-Path -LiteralPath $skillsDir)) { return @() }
    $names = @()
    # -clike (case-sensitive): parity with bash `find`/globs + `git ls-tree`
    # (all case-sensitive). Otherwise an SDLCx folder would be in scope on the
    # PS side and not on the bash side => diverging states/exit codes (SP2 invariant).
    Get-ChildItem -LiteralPath $skillsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -clike 'sdlc*' } |
        ForEach-Object { $names += $_.Name }
    return $names
}

function Get-DomainRelPaths {
    # List of relPaths ('/'-normalized) of the domains (skills, commands,
    # agents), exclusions applied. Excludes the skills/sdlc/commands/** subtree
    # (H3). Skills scope derived from Get-ChildItem(<root>/skills) filtered
    # on sdlc* (H7).
    param([Parameter(Mandatory)][string]$Root)
    Set-StrictMode -Version Latest

    $resolved = Resolve-Path -LiteralPath $Root -ErrorAction SilentlyContinue
    if ($null -eq $resolved) { return @() }
    $root = $resolved.Path

    $result = New-Object System.Collections.Generic.List[string]

    # --- skills domain (H7 scope: sdlc* only) ---
    foreach ($name in (Get-SyncDomainSkill -Root $root)) {
        $skillPath = Join-Path (Join-Path $root 'skills') $name
        if (-not (Test-Path -LiteralPath $skillPath)) { continue }
        Get-ChildItem -LiteralPath $skillPath -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = Get-RelPath -Root $root -FullPath $_.FullName
            # H3: the embedded commands subtree of the sdlc skill is excluded
            if ($rel -like 'skills/sdlc/commands/*') { return }
            if (Test-SyncExcluded -RelPath $rel) { return }
            $result.Add($rel)
        }
    }

    # --- commands domain (canonical top-level = single source) ---
    $cmdPath = Join-Path (Join-Path $root 'commands') 'sdlc'
    if (Test-Path -LiteralPath $cmdPath) {
        Get-ChildItem -LiteralPath $cmdPath -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = Get-RelPath -Root $root -FullPath $_.FullName
            if (Test-SyncExcluded -RelPath $rel) { return }
            $result.Add($rel)
        }
    }

    # --- agents domain (sdlc-*) ---
    $agentsPath = Join-Path $root 'agents'
    if (Test-Path -LiteralPath $agentsPath) {
        Get-ChildItem -LiteralPath $agentsPath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -clike 'sdlc-*' } | ForEach-Object {
                $rel = Get-RelPath -Root $root -FullPath $_.FullName
                if (Test-SyncExcluded -RelPath $rel) { return }
                $result.Add($rel)
            }
    }


    return @($result | Sort-Object -Unique)
}

# ---------------------------------------------------------------------------
# 3. Byte-exact SHA256 hashing (A002) — reads raw BYTES, no text/EOL handling
# ---------------------------------------------------------------------------

function Get-FileHashByteExact {
    param([Parameter(Mandatory)][string]$Path)
    Set-StrictMode -Version Latest
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

# ---------------------------------------------------------------------------
# 4. Get-SyncState (A005) — base-aware classifier. MODIFIES NOTHING.
# ---------------------------------------------------------------------------

function Get-SyncState {
    # Returns the state (string) + the hashes from (RefHash, LiveHash,
    # BaseHash). Absent = $null or ''. See the TRUTH TABLE of the P011 mandate.
    param(
        [AllowNull()][AllowEmptyString()][string]$RefHash,
        [AllowNull()][AllowEmptyString()][string]$LiveHash,
        [AllowNull()][AllowEmptyString()][string]$BaseHash,
        [string]$RelPath = ''
    )
    Set-StrictMode -Version Latest

    $rPresent = -not [string]::IsNullOrEmpty($RefHash)
    $lPresent = -not [string]::IsNullOrEmpty($LiveHash)
    $bPresent = -not [string]::IsNullOrEmpty($BaseHash)

    $state = $null

    if (-not $rPresent -and -not $lPresent) {
        # O | O | *  -> absent-both
        $state = 'absent-both'
    }
    elseif ($rPresent -and -not $lPresent) {
        # ref present, live absent
        if (-not $bPresent) {
            $state = 'added-ref'                          # R | O | O
        }
        elseif ($RefHash -eq $BaseHash) {
            $state = 'deleted-live'                        # =B | O | present
        }
        else {
            $state = 'conflict-deleted-live-modified-ref'        # !=B | O | present
        }
    }
    elseif (-not $rPresent -and $lPresent) {
        # ref absent, live present
        if (-not $bPresent) {
            $state = 'added-live'                          # O | L | O  (PROTECTED)
        }
        elseif ($LiveHash -eq $BaseHash) {
            $state = 'deleted-ref'                         # O | =B | present (base-aware)
        }
        else {
            $state = 'conflict-deleted-ref-modified-live'        # O | !=B | present
        }
    }
    else {
        # ref AND live present
        if ($RefHash -eq $LiveHash) {
            $state = 'identical'                            # R==L | * | *
        }
        elseif (-not $bPresent) {
            # R!=L without base: added-both-divergent, handled as modified-both
            $state = 'modified-both'
        }
        elseif ($RefHash -eq $BaseHash) {
            $state = 'modified-live'                         # R!=L, R=B, L!=B
        }
        elseif ($LiveHash -eq $BaseHash) {
            $state = 'modified-ref'                          # R!=L, R!=B, L=B
        }
        else {
            $state = 'modified-both'                     # R!=L, R!=B, L!=B (H2)
        }
    }

    return [pscustomobject]@{
        RelPath  = $RelPath
        State    = $state
        RefHash  = $RefHash
        LiveHash = $LiveHash
        BaseHash = $BaseHash
    }
}

# ---------------------------------------------------------------------------
# 5. Show-ConflictDiff — git diff --no-index, degrades if git is missing
# ---------------------------------------------------------------------------

function Show-ConflictDiff {
    param(
        [Parameter(Mandatory)][string]$RefPath,
        [Parameter(Mandatory)][string]$LivePath
    )
    Set-StrictMode -Version Latest
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        Write-Warning "git not found: diff unavailable ($RefPath <-> $LivePath)."
        return ''
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # --no-index exits 1 when the files differ: expected, do not throw.
        $out = & git diff --no-index -- $RefPath $LivePath 2>&1 | ForEach-Object { "$_" }
        return ($out -join "`n")
    } finally {
        $ErrorActionPreference = $prev
    }
}

# ---------------------------------------------------------------------------
# 6. Resolve-LWW (A008) — opt-in, conservative, append-only log.
#    Never based on the live FS mtime alone: the default winner protects the ref.
# ---------------------------------------------------------------------------

function Resolve-LWW {
    param(
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][string]$ConflictLogPath,   # OUTSIDE the worktree (given by the caller)
        [AllowNull()][AllowEmptyString()][string]$RefHash = '',
        [AllowNull()][AllowEmptyString()][string]$LiveHash = '',
        # Reliable provenance of BOTH sides is required to pick 'live'; otherwise
        # the conservative rule keeps the ref (canonical). mtime is never used.
        [ValidateSet('ref', 'live')][string]$Provenance = 'ref',
        [switch]$DryRun
    )
    Set-StrictMode -Version Latest

    $winner = 'ref'
    if ($Provenance -eq 'live') { $winner = 'live' }

    $ts = (Get-Date).ToString('o')
    $line = "$ts | relpath=$RelPath | ref=$RefHash | live=$LiveHash | provenance=$Provenance | winner=$winner"

    $logged = $false
    if (-not $DryRun) {
        $dir = Split-Path -Parent $ConflictLogPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        # append-only: the conflict log is never rewritten in place.
        Add-Content -LiteralPath $ConflictLogPath -Value $line -Encoding utf8
        $logged = $true
    }

    return [pscustomobject]@{
        RelPath = $RelPath
        Winner  = $winner
        Logged  = $logged
        Line    = $line
    }
}

# ---------------------------------------------------------------------------
# 11. Write-FileAtomic — temp+rename helper reused by 7 and 9.
#     Always writes to a temporary file, then atomic rename/replace.
#     NEVER writes directly to $Path.
# ---------------------------------------------------------------------------

function Write-FileAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [byte[]]$Bytes,
        [AllowNull()][string]$Content
    )
    Set-StrictMode -Version Latest

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # temporary file in the SAME folder (same volume => atomic rename)
    $tmp = "$Path.tmp-" + ([System.Guid]::NewGuid().ToString('N'))
    try {
        if ($PSBoundParameters.ContainsKey('Bytes') -and $null -ne $Bytes) {
            [System.IO.File]::WriteAllBytes($tmp, $Bytes)
        }
        else {
            $text = ''
            if ($null -ne $Content) { $text = $Content }
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($tmp, $text, $utf8NoBom)
        }

        # atomic publish: the target only appears after this rename/replace.
        if (Test-Path -LiteralPath $Path) {
            # File.Replace is atomic on the same volume; a temporary backup is
            # required (the PowerShell binding rejects a $null backup), then deleted.
            $bak = "$Path.bak-" + ([System.Guid]::NewGuid().ToString('N'))
            try {
                [System.IO.File]::Replace($tmp, $Path, $bak)
            }
            finally {
                if (Test-Path -LiteralPath $bak) {
                    Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
                }
            }
        }
        else {
            [System.IO.File]::Move($tmp, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    return $Path
}

# ---------------------------------------------------------------------------
# 7. Copy-Tree (A009, A1/A3/M2) — per-relPath copy, file by file,
#    ONLY greenlisted relPaths. NO robocopy, NO /MIR, no destructive
#    directory copy. Atomic write per file.
# ---------------------------------------------------------------------------

function Copy-Tree {
    param(
        [Parameter(Mandatory)][string]$SrcRoot,
        [Parameter(Mandatory)][string]$DstRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RelPaths,   # EXCLUSIVE greenlist
        [switch]$DryRun
    )
    Set-StrictMode -Version Latest

    $sep = [System.IO.Path]::DirectorySeparatorChar
    $copied = New-Object System.Collections.Generic.List[string]

    # Canonical roots (with trailing separator) for the boundary check.
    $srcRootFull = [System.IO.Path]::GetFullPath($SrcRoot).TrimEnd($sep) + $sep
    $dstRootFull = [System.IO.Path]::GetFullPath($DstRoot).TrimEnd($sep) + $sep

    foreach ($rel in $RelPaths) {
        $norm = ($rel -replace '\\', '/').TrimStart('/')
        if ($norm -eq '') { continue }

        # Defense in depth: the greenlist is supposed to be sane
        # (Get-DomainRelPaths), but Copy-Tree trusts NOTHING blindly.
        # A '..'/'.'/empty segment or a rooted path would let a relPath escape
        # DstRoot and overwrite a file outside the target tree.
        $segments = $norm -split '/'
        $unsafe = [System.IO.Path]::IsPathRooted($norm)
        if (-not $unsafe) {
            foreach ($seg in $segments) {
                if ($seg -eq '..' -or $seg -eq '.' -or $seg -eq '') { $unsafe = $true; break }
            }
        }
        if ($unsafe) {
            Write-Warning "Copy-Tree: unsafe relPath (escape/rooted), skipped: $rel"
            continue
        }

        $native = $norm.Replace('/', [string]$sep)
        $src = Join-Path $SrcRoot $native
        $dst = Join-Path $DstRoot $native

        # Final check: resolved paths MUST stay under their respective roots,
        # otherwise NOTHING is written (same as a missing source).
        $srcFull = [System.IO.Path]::GetFullPath($src)
        $dstFull = [System.IO.Path]::GetFullPath($dst)
        if ((-not $srcFull.StartsWith($srcRootFull, [System.StringComparison]::Ordinal)) -or
            (-not $dstFull.StartsWith($dstRootFull, [System.StringComparison]::Ordinal))) {
            Write-Warning "Copy-Tree: resolved path outside root, skipped: $rel"
            continue
        }

        if (-not (Test-Path -LiteralPath $src)) {
            Write-Warning "Copy-Tree: missing source, skipped: $rel"
            continue
        }
        if ($DryRun) {
            $copied.Add($rel)
            continue
        }

        $bytes = [System.IO.File]::ReadAllBytes($src)
        Write-FileAtomic -Path $dst -Bytes $bytes | Out-Null
        $copied.Add($rel)
    }

    return @($copied)
}

# ---------------------------------------------------------------------------
# 8. O_EXCL lockfile (A009) — exclusive creation (CreateNew). Fails if another
#    process already holds the lock.
# ---------------------------------------------------------------------------

function Acquire-SyncLock {
    param([Parameter(Mandatory)][string]$Path)
    Set-StrictMode -Version Latest

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    try {
        # CreateNew = O_EXCL: throws an IOException if the file already exists.
        $fs = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        throw "Sync lock already held by another process: $Path"
    }

    try {
        $meta = "pid=$PID`nhost=$([System.Environment]::MachineName)`nat=$((Get-Date).ToString('o'))"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($meta)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
    }
    catch {
        try { $fs.Dispose() } catch { }
        # The lockfile was created (CreateNew) but writing the metadata failed:
        # delete the orphan lock before re-throwing, otherwise every later
        # acquisition would fail forever (lock without holder).
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw
    }

    return [pscustomobject]@{ Path = $Path; Handle = $fs }
}

function Release-SyncLock {
    param([Parameter(Mandatory)][AllowNull()]$Lock)
    Set-StrictMode -Version Latest
    if ($null -eq $Lock) { return }

    if (($Lock.PSObject.Properties.Name -contains 'Handle') -and ($null -ne $Lock.Handle)) {
        try { $Lock.Handle.Close() } catch { }
        try { $Lock.Handle.Dispose() } catch { }
    }
    if ($Lock.PSObject.Properties.Name -contains 'Path') {
        if (Test-Path -LiteralPath $Lock.Path) {
            Remove-Item -LiteralPath $Lock.Path -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# 9. Write-SyncManifest (A006, H4) — writes the manifest atomically (temp+rename),
#    NEVER in place. Schema from the "Data model".
# ---------------------------------------------------------------------------

function Write-SyncManifest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Entries,        # relPath -> sha256 (the BASE)
        [string]$Version = 'SP2',
        [string]$Machine = ([System.Environment]::MachineName),
        [string[]]$Domains = @('skills/sdlc*', 'commands/sdlc', 'agents/sdlc-*')
    )
    Set-StrictMode -Version Latest

    $entriesOrdered = [ordered]@{}
    foreach ($k in ($Entries.Keys | Sort-Object)) {
        $entriesOrdered[$k] = [string]$Entries[$k]
    }

    $obj = [ordered]@{
        version   = $Version
        machine   = $Machine
        synced_at = (Get-Date).ToString('o')   # ISO-8601 round-trip
        domains   = $Domains
        entries   = $entriesOrdered
    }

    $json = $obj | ConvertTo-Json -Depth 10
    # atomic write (temp+rename) — never in place.
    Write-FileAtomic -Path $Path -Content $json | Out-Null
    return $Path
}

# ---------------------------------------------------------------------------
# 10. Read-SyncManifest (H4) — parse; failure/corruption/truncation => fail CLOSED.
#     The sentinel has empty Entries: every base is absent, so no ref!=live
#     relPath is assumed synced (never 'identical' by default).
# ---------------------------------------------------------------------------

function Read-SyncManifest {
    param([Parameter(Mandatory)][string]$Path)
    Set-StrictMode -Version Latest

    $failClosed = [pscustomobject]@{
        Ok         = $false
        Exists     = $true
        FailClosed = $true
        Version    = $null
        Machine    = $null
        SyncedAt   = $null
        Domains    = @()
        Entries    = @{}     # empty base => no ref!=live assumed identical
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        # Missing = first run (distinct from corruption). Not fail-closed:
        # the caller switches to Get-FirstRunPlan (seed/block on the union).
        return [pscustomobject]@{
            Ok         = $false
            Exists     = $false
            FailClosed = $false
            Version    = $null
            Machine    = $null
            SyncedAt   = $null
            Domains    = @()
            Entries    = @{}
        }
    }

    try {
        $raw = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $failClosed }

        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $parsed) { return $failClosed }

        $propNames = @($parsed.PSObject.Properties.Name)
        if ($propNames -notcontains 'entries') { return $failClosed }

        $entries = @{}
        if ($null -ne $parsed.entries) {
            # H4: 'entries' present but NOT a JSON object (array, string,
            # scalar) => invalid schema => fail CLOSED. Otherwise PSObject.Properties
            # would expose the container's .NET properties (Length, Count, Rank...)
            # as fake base entries while returning Ok=true.
            if ($parsed.entries -isnot [pscustomobject]) { return $failClosed }
            foreach ($p in $parsed.entries.PSObject.Properties) {
                $entries[$p.Name] = [string]$p.Value
            }
        }

        $domains = @()
        if (($propNames -contains 'domains') -and ($null -ne $parsed.domains)) {
            $domains = @($parsed.domains)
        }

        $verVal = $null;  if ($propNames -contains 'version')   { $verVal = $parsed.version }
        $macVal = $null;  if ($propNames -contains 'machine')   { $macVal = $parsed.machine }
        $syncVal = $null; if ($propNames -contains 'synced_at') { $syncVal = $parsed.synced_at }

        return [pscustomobject]@{
            Ok         = $true
            Exists     = $true
            FailClosed = $false
            Version    = $verVal
            Machine    = $macVal
            SyncedAt   = $syncVal
            Domains    = $domains
            Entries    = $entries
        }
    }
    catch {
        # parse failed / corrupt / truncated => fail CLOSED
        return $failClosed
    }
}

# ---------------------------------------------------------------------------
# 12. First-run union (A007, H5) — without a base, iterates the UNION {ref ∪ live}.
#     All identical => 'seed'. Any asymmetry/difference => 'block'
#     (resolvable only with -Adopt). Never freezes a divergence into the base.
# ---------------------------------------------------------------------------

function Get-FirstRunPlan {
    param(
        [Parameter(Mandatory)][hashtable]$RefHashes,    # relPath -> sha
        [Parameter(Mandatory)][hashtable]$LiveHashes,   # relPath -> sha
        [switch]$Adopt
    )
    Set-StrictMode -Version Latest

    $union = New-Object System.Collections.Generic.List[string]
    foreach ($k in $RefHashes.Keys)  { if (-not $union.Contains($k)) { $union.Add($k) } }
    foreach ($k in $LiveHashes.Keys) { if (-not $union.Contains($k)) { $union.Add($k) } }

    $mismatches = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $union) {
        $r = $null; if ($RefHashes.ContainsKey($rel))  { $r = $RefHashes[$rel] }
        $l = $null; if ($LiveHashes.ContainsKey($rel)) { $l = $LiveHashes[$rel] }
        if ($r -ne $l) { $mismatches.Add($rel) }
    }

    if ($mismatches.Count -eq 0) {
        return [pscustomobject]@{ Signal = 'seed'; Adopted = $false; Mismatches = @(); Union = @($union) }
    }
    if ($Adopt) {
        # EXPLICIT adoption of the current state despite the asymmetry/divergence.
        return [pscustomobject]@{ Signal = 'seed'; Adopted = $true; Mismatches = @($mismatches); Union = @($union) }
    }
    return [pscustomobject]@{ Signal = 'block'; Adopted = $false; Mismatches = @($mismatches); Union = @($union) }
}

# ---------------------------------------------------------------------------
# 13. Set-NestorImport / Remove-NestorImport (P022:A019) — adds/removes the
#     canonical '@NESTOR.md' line in a GLOBAL USER file (~/.claude/CLAUDE.md),
#     OUTSIDE the sync domain (never added to Get-DomainRelPaths/greenlist; this
#     file is unrelated to the sdlc domain mapping). Detection = count of lines
#     whose TRIMMED content (leading/trailing whitespace removed) is EXACTLY
#     '@NESTOR.md' (literal match, never a broad regex). Atomic write
#     (Write-FileAtomic) + timestamped backup (except -DryRun) BEFORE any
#     mutation; NEVER touches the bytes of other lines.
#     Set-NestorImport wraps Set-GenericImport (P032:A029), which carries the
#     same logic parameterized by an explicit $Marker (reusable for any future
#     marker, e.g. a *.local.md overlay). Optional nestor-agents interop.
# ---------------------------------------------------------------------------

function Backup-NestorImportFile {
    # Timestamped backup (file name UNCHANGED, nested in a unique subfolder)
    # before any mutation of $Path. Mirrors the install.ps1/restore.ps1
    # conventions ($backupRoot/<prefix>-<timestamp>/<original name>) — avoids any
    # clash with the *.tmp-*/*.bak-* patterns reserved for Write-FileAtomic's
    # TRANSIENT artifacts.
    param([Parameter(Mandatory)][string]$Path)
    Set-StrictMode -Version Latest
    $dir  = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    $ts   = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $backupDir  = Join-Path (Join-Path $dir '_backups') ("nestor-import-$ts-$PID")
    $backupPath = Join-Path $backupDir $leaf
    Write-FileAtomic -Path $backupPath -Bytes ([System.IO.File]::ReadAllBytes($Path)) | Out-Null
}

function Get-NestorImportLines {
    # Splits $Text into "lines" that KEEP their original terminator (CRLF/LF);
    # the last segment has NO terminator if the text does not end with an EOL.
    # (?<=\n): zero-width split right AFTER each \n (on CRLF, the \r stays
    # attached to the end of the PREVIOUS segment — never separated from its \n).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    Set-StrictMode -Version Latest
    if ($Text.Length -eq 0) { return @() }
    $segs = [System.Text.RegularExpressions.Regex]::Split($Text, '(?<=\n)')
    if ($segs.Length -ge 2 -and $segs[$segs.Length - 1] -eq '') {
        $segs = $segs[0..($segs.Length - 2)]
    }
    return @($segs)
}

function Test-NestorImportLine {
    # $true if $Line (terminator included) is EXACTLY '@NESTOR.md' once its
    # terminator is removed and leading/trailing whitespace trimmed (literal match).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    Set-StrictMode -Version Latest
    $t = $Line.TrimEnd("`n").TrimEnd("`r").Trim()
    return ($t -eq '@NESTOR.md')
}

function Set-GenericImport {
    # Adds the canonical $Marker line to $Path (P032:A029 — body extracted from the
    # former Set-NestorImport, parameterized by an explicit marker instead of the
    # '@NESTOR.md' literal).
    #   count($Marker) >= 1 -> no-op (count > 1: Write-Warning, NO dedup).
    #   count == 0 -> append at end of file, WITHOUT touching existing bytes;
    #     prefixed with an EOL (file's DOMINANT style: CRLF if CRLF is the majority,
    #     else LF) if the file does not already end with an EOL. Missing file ->
    #     created with that single line. -DryRun: 0 writes (no backup, target or temp).
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Marker,
        [switch]$DryRun
    )
    Set-StrictMode -Version Latest

    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $text = ''
    if ($exists) {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    }

    $lines = Get-NestorImportLines -Text $text
    $count = 0
    foreach ($ln in $lines) {
        $t = $ln.TrimEnd("`n").TrimEnd("`r").Trim()
        if ($t -eq $Marker) { $count++ }
    }

    if ($count -ge 1) {
        if ($count -gt 1) {
            Write-Warning "Set-GenericImport: $count '$Marker' lines found in $Path (no automatic dedup)"
        }
        return
    }

    # count == 0: build the content to write (file's dominant EOL style).
    $crlfN = 0; $lfN = 0
    foreach ($ln in $lines) {
        if ($ln.EndsWith("`r`n")) { $crlfN++ }
        elseif ($ln.EndsWith("`n")) { $lfN++ }
    }
    $dominantEol = if ($crlfN -gt $lfN) { "`r`n" } else { "`n" }

    if ($text.Length -eq 0) {
        $newText = $Marker
    }
    elseif ($text.EndsWith("`n")) {
        $newText = $text + $Marker
    }
    else {
        $newText = $text + $dominantEol + $Marker
    }

    if ($DryRun) { return }

    if ($exists) { Backup-NestorImportFile -Path $Path }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    Write-FileAtomic -Path $Path -Bytes ($utf8NoBom.GetBytes($newText)) | Out-Null
}

function Set-NestorImport {
    # Adds the canonical '@NESTOR.md' line to $Path. Wrapper of Set-GenericImport
    # (P032:A029) — byte-identical behavior to the original implementation.
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$DryRun
    )
    Set-GenericImport -Path $Path -Marker '@NESTOR.md' -DryRun:$DryRun
}

function Set-LocalOverlayImport {
    # P033:A029 — ensures the private overlay <LocalFileName> exists (next to
    # $Path), then adds the "@$LocalFileName" import line to $Path (via
    # Set-GenericImport). If the overlay is missing AND this is NOT -DryRun, it is
    # created EMPTY (Write-FileAtomic) before the import is added — never the other
    # way round. An existing overlay (empty or not) is never overwritten. -DryRun:
    # 0 writes (no overlay, no import line).
    param(
        [Parameter(Mandatory)][string]$Path,          # e.g. ~/.claude/CLAUDE.md
        [Parameter(Mandatory)][string]$LocalFileName,  # e.g. CLAUDE.local.md
        [switch]$DryRun
    )
    Set-StrictMode -Version Latest

    $localPath = Join-Path (Split-Path -Parent $Path) $LocalFileName
    if (-not (Test-Path -LiteralPath $localPath -PathType Leaf) -and -not $DryRun) {
        Write-FileAtomic -Path $localPath -Content '' | Out-Null
    }
    Set-GenericImport -Path $Path -Marker "@$LocalFileName" -DryRun:$DryRun
}


function Remove-NestorImport {
    # Removes ALL lines whose trimmed content is EXACTLY '@NESTOR.md', and ONLY
    # those: the rest of the file stays byte-identical (same other lines, same EOL
    # style, no trim on kept lines). Missing file -> no-op. -DryRun: 0 writes.
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$DryRun
    )
    Set-StrictMode -Version Latest

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $lines = Get-NestorImportLines -Text $text

    $sb = [System.Text.StringBuilder]::new()
    $removedAny = $false
    foreach ($ln in $lines) {
        if (Test-NestorImportLine -Line $ln) { $removedAny = $true; continue }
        [void]$sb.Append($ln)
    }

    if (-not $removedAny) { return }
    if ($DryRun) { return }

    Backup-NestorImportFile -Path $Path
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    Write-FileAtomic -Path $Path -Bytes ($utf8NoBom.GetBytes($sb.ToString())) | Out-Null
}
