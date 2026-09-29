#requires -Version 5.1
<#
.SYNOPSIS
    Leak scan ("scan-fuites" in French) for PII / private data - read-only (P045:A044,A048).

.DESCRIPTION
    Detects leftover private paths, emails and version markers in the working
    tree AND in 3 key revisions of the git history, before the repository is
    made public. READ-ONLY BY DESIGN: the only file written is the report given
    as output (-ReportPath).

    Two pattern levels (never mixed in the script's source code):
      - Level 1 - EMBEDDED here, FROZEN, not tied to any person (Get-FuitesLevel1Patterns):
          * generic Windows profile path   : [A-Za-z]:\Users\...
          * generic email address          : local@domain.tld
          * version marker 'sdlcv2' (detection only, case-insensitive)
          * version marker 'sdlcv3' (detection only, case-insensitive)
        No person-specific pattern is ever added here (safeguard R-Q1): any
        specific rule (exact email, precise user path, private tool name) goes
        through level 2 only.
      - Level 2 - OPTIONAL, external file SDLC_PM/scan-fuites-motifs.txt
        (path RELATIVE to the repository root, never absolute), one regex per
        line, empty lines and '#' comments ignored. INTERNAL zone (SDLC_PM/):
        this file may legitimately contain private tokens and is never itself
        reported in the public zone (it lives under SDLC_PM/). If it is missing,
        the report says so at the top ("generic mode only") and the script
        carries on normally - never a failure, never silent about it.

    Zoning (fail-safe, A044):
      - Candidate public zone (zero tolerance): EVERY path that is NOT
        explicitly classified as internal - so it includes claude/, bundle/,
        .github/, root files, AND any unlisted folder (anything not recognized
        as internal is treated as public).
      - Internal zone (informational counts ONLY, no zero tolerance):
        SDLC_PM/, nestor/.

    History probe (3 revisions, same patterns, no checkout - git grep on a
    tree-ish):
      (a) root commit          : git rev-list --max-parents=0 HEAD
      (b) last commit before SP4 : parent of the first commit whose message
                                matches 'SP4' (git log --reverse --grep=SP4)
      (c) HEAD
    Any hit on (a) or (b) feeds the history verdict written to the report
    (contamination expected by construction, see F5).

    Reuses the shared sync-lib.ps1 foundation (single source):
      - Get-RelPath        -> relative path normalized to '/' (zoning, report).
      - Test-SyncExcluded  -> ignores known noise (__pycache__, *.bak,
        manifests...) - avoids a second, parallel exclusion list.
      - Write-FileAtomic   -> writes the report (temp+rename, never in place).

.PARAMETER RepoRoot
    Root of the repository to scan. Default: ..\.. relative to the script
    (bundle/scripts -> sdlc-framework repository root).

.PARAMETER MotifsPath
    Path of the level-2 pattern file. Default: <RepoRoot>\SDLC_PM\scan-fuites-motifs.txt.
    Exposed for tests (Code Lock: rename/point elsewhere to simulate its absence).

.PARAMETER ReportPath
    Output report path. Default:
    <RepoRoot>\SDLC_PM\SP6-productisation\rapport-scan-fuites-<YYYY-MM-DD>.md (today's date).

.EXAMPLE
    pwsh ./scripts/scan-fuites.ps1
    pwsh ./scripts/scan-fuites.ps1 -MotifsPath C:\elsewhere\patterns.txt -ReportPath C:\tmp\report.md

.NOTES
    Exit codes: this is a REPORTING TOOL, not a gate - a scan that RUNS to the
    end (report written) is a SUCCESS, even if it finds hits in the public zone
    (finding them is the tool's purpose; deciding to block a public release
    belongs to an upstream gate, P051, which READS the report). A missing
    level-2 pattern file is NEVER a cause of a non-zero exit.
      0 = scan complete, report written (with or without hits).
      2 = precheck: RepoRoot not found or sync-lib.ps1 not found.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = (Join-Path $PSScriptRoot "..\.."),
    [string]$MotifsPath = "",
    [string]$ReportPath = ""
)

# --- Shared foundation (single source, same convention as install.ps1) ------
$syncLib = Join-Path $PSScriptRoot 'sync-lib.ps1'
if (-not (Test-Path -LiteralPath $syncLib)) {
    Write-Error "sync-lib.ps1 not found next to scan-fuites.ps1: $syncLib"
    exit 2
}
. $syncLib

Set-StrictMode -Version Latest

# --- Display helpers (console progress - same style as install.ps1) ---------
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

# --- Level-1 patterns: FROZEN here, not person-specific (see 3_conception.md P045) ---
# SINGLE-QUOTED here-string (@'...'@): no escaping needed (backslashes and quotes
# are literal), equivalent in principle to the bash heredoc <<'EOF' - parity is
# guaranteed by comparing the string VALUE, not the syntax.
function Get-FuitesLevel1Patterns {
    Set-StrictMode -Version Latest
    $raw = @'
windows-profile-path	[A-Za-z]:\\Users\\[^\\ "']+
generic-email	[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}
sdlcv2	sdlcv2
sdlcv3	sdlcv3
'@
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($raw -split "`n")) {
        $t = $line.TrimEnd("`r")
        if ($t -eq '') { continue }
        $parts = $t.Split("`t", 2)
        if ($parts.Count -lt 2) { continue }
        $out.Add([pscustomobject]@{ Label = $parts[0]; Pattern = $parts[1] })
    }
    # .ToArray() rather than @($out): avoids a known PS binder bug (PSToObjectArrayBinder,
    # "Argument types do not match") when @() DIRECTLY wraps a generic List[T].
    return $out.ToArray()
}

# --- Level-2 patterns: optional, one regex per line, '#'/empty lines ignored ---
function Get-FuitesLevel2Patterns {
    param([Parameter(Mandatory)][string]$Path)
    Set-StrictMode -Version Latest
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $out.Add([pscustomobject]@{ Label = 'level2'; Pattern = $t })
    }
    return $out.ToArray()
}

# --- Fail-safe zoning (A044): internal = SDLC_PM/ or nestor/, otherwise public ---
function Get-FuitesZone {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RelPath)
    Set-StrictMode -Version Latest
    if ($RelPath -like 'SDLC_PM/*' -or $RelPath -like 'nestor/*') { return 'internal' }
    return 'public'
}

# --- Text-file heuristic: known binary extension OR NUL byte ----------------
$script:FuitesBinaryExt = @(
    '.png', '.jpg', '.jpeg', '.gif', '.ico', '.bmp', '.pdf', '.zip', '.gz', '.7z',
    '.exe', '.dll', '.pyc', '.pyo', '.bin', '.woff', '.woff2', '.ttf', '.eot',
    '.otf', '.mp3', '.mp4', '.mov', '.class', '.so', '.dylib', '.jar'
)
function Test-FuitesTextFile {
    param([Parameter(Mandatory)][string]$Path)
    Set-StrictMode -Version Latest
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($script:FuitesBinaryExt -contains $ext) { return $false }
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 8000
            $n = $fs.Read($buf, 0, $buf.Length)
            for ($i = 0; $i -lt $n; $i++) { if ($buf[$i] -eq 0) { return $false } }
        }
        finally { $fs.Dispose() }
    }
    catch { return $false }
    return $true
}

# ponytail: the scanner excludes itself. Its own sources EMBED the level-1 pattern
# catalog in clear text (the words 'sdlcv2'/'sdlcv3', the email pattern text) - a
# self-match is therefore guaranteed and is NOT a leak (no person-specific token,
# just the code documenting itself). Without this targeted exclusion the scanner
# would report itself on every run (permanent noise that cannot be fixed without
# hurting its readability). Exclusion LIMITED to these 2 files (no whole folder)
# - Code Lock P045.
$script:FuitesSelfExclude = @('bundle/scripts/scan-fuites.ps1', 'bundle/scripts/scan-fuites.sh')

# --- Exhaustive enumeration of the working tree, excluding .git/ and known noise ---
function Get-FuitesFileList {
    param([Parameter(Mandatory)][string]$Root)
    Set-StrictMode -Version Latest
    $out = New-Object System.Collections.Generic.List[string]
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $rel = Get-RelPath -Root $Root -FullPath $_.FullName
            if ($rel -eq '.git' -or $rel -like '.git/*') { return }
            if (Test-SyncExcluded -RelPath $rel) { return }
            if ($script:FuitesSelfExclude -contains $rel) { return }
            $out.Add($rel)
        }
    # ORDINAL (byte-exact) sort rather than Sort-Object (culture-aware,
    # case-insensitive by default): parity with `LC_ALL=C sort` on the bash side -
    # same report order on both sides (Code Lock: "same report format").
    $arr = $out.ToArray()
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return $arr
}

# --- Working-tree scan: public hits (detailed) + internal counts (aggregated) ---
function Invoke-FuitesTreeScan {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RelPaths,
        [Parameter(Mandatory)][object[]]$Patterns
    )
    Set-StrictMode -Version Latest
    $publicHits = New-Object System.Collections.Generic.List[object]
    $internalCounts = [ordered]@{}
    $reOpts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    foreach ($rel in $RelPaths) {
        $full = Join-Path $Root ($rel -replace '/', [string][System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-FuitesTextFile -Path $full)) { continue }
        $zone = Get-FuitesZone -RelPath $rel
        $lines = $null
        try { $lines = Get-Content -LiteralPath $full -ErrorAction Stop }
        catch { continue }
        if ($null -eq $lines) { continue }
        if ($lines -isnot [System.Array]) { $lines = @($lines) }
        $lineNum = 0
        foreach ($line in $lines) {
            $lineNum++
            # Internal zone: count of matching LINES (a line matching 2 patterns
            # counts ONCE) - parity with bash (grep -c counts lines, not
            # line x pattern pairs). Public zone: detail kept per pattern
            # (each pattern matching a line produces its own file:line:pattern entry).
            $lineAlreadyCountedInternal = $false
            foreach ($p in $Patterns) {
                if ([System.Text.RegularExpressions.Regex]::IsMatch($line, $p.Pattern, $reOpts)) {
                    if ($zone -eq 'public') {
                        $publicHits.Add([pscustomobject]@{ File = $rel; Line = $lineNum; Motif = $p.Label })
                    }
                    elseif (-not $lineAlreadyCountedInternal) {
                        if (-not $internalCounts.Contains($rel)) { $internalCounts[$rel] = 0 }
                        $internalCounts[$rel] = $internalCounts[$rel] + 1
                        $lineAlreadyCountedInternal = $true
                    }
                }
            }
        }
    }
    return [pscustomobject]@{ PublicHits = $publicHits.ToArray(); InternalCounts = $internalCounts }
}

# --- History probe: git grep on a tree-ish, no checkout ---------------------
function Invoke-FuitesRevisionGrep {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Revision,
        [Parameter(Mandatory)][object[]]$Patterns
    )
    Set-StrictMode -Version Latest
    # One -e per pattern (never a single concatenated alternation): avoids any
    # shell escaping issue for patterns that contain quotes.
    $gitArgs = @('-C', $Root, 'grep', '-n', '-I', '-i', '-E')
    foreach ($p in $Patterns) { $gitArgs += @('-e', $p.Pattern) }
    $gitArgs += @($Revision)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & git @gitArgs 2>$null }
    finally { $ErrorActionPreference = $prev }
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        $lines = @($out)
        return [pscustomobject]@{ Available = $true; Count = $lines.Count; Sample = @($lines | Select-Object -First 5) }
    }
    if ($code -eq 1) {
        return [pscustomobject]@{ Available = $true; Count = 0; Sample = @() }
    }
    return [pscustomobject]@{ Available = $false; Count = 0; Sample = @() }
}

function Get-FuitesHistoryRevisions {
    # Resolves the 3 key revisions (a)/(b)/(c). Each entry: Id, Label, Hash (or $null).
    param([Parameter(Mandatory)][string]$Root)
    Set-StrictMode -Version Latest
    $revisions = New-Object System.Collections.Generic.List[object]
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        return $revisions.ToArray()
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $rootHash = (& git -C $Root rev-list --max-parents=0 HEAD 2>$null | Select-Object -First 1)
        $sp4Hash = (& git -C $Root log --reverse --grep=SP4 --format=%H 2>$null | Select-Object -First 1)
        $sp4Parent = $null
        if (-not [string]::IsNullOrWhiteSpace($sp4Hash)) {
            $parents = (& git -C $Root log -1 --format=%P $sp4Hash 2>$null)
            if (-not [string]::IsNullOrWhiteSpace($parents)) {
                $sp4Parent = ($parents.Trim() -split '\s+')[0]
            }
        }
        $headHash = (& git -C $Root rev-parse HEAD 2>$null)
    }
    finally { $ErrorActionPreference = $prev }
    $revisions.Add([pscustomobject]@{ Id = 'a'; Label = 'repository root commit'; Hash = $rootHash })
    $revisions.Add([pscustomobject]@{ Id = 'b'; Label = 'last commit before SP4'; Hash = $sp4Parent })
    $revisions.Add([pscustomobject]@{ Id = 'c'; Label = 'HEAD'; Hash = $headHash })
    return $revisions.ToArray()
}

# --- Markdown report assembly -----------------------------------------------
function Format-FuitesReport {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$MotifsPath,
        [Parameter(Mandatory)][bool]$Level2Present,
        [Parameter(Mandatory)][int]$Level2Count,
        [Parameter(Mandatory)][object]$TreeScan,
        [Parameter(Mandatory)][object[]]$HistoryRows,
        [Parameter(Mandatory)][bool]$HistoryContaminated,
        [Parameter(Mandatory)][bool]$GitAvailable
    )
    Set-StrictMode -Version Latest
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Leak scan report - sdlc-framework')
    [void]$sb.AppendLine('')
    if ($Level2Present) {
        [void]$sb.AppendLine("**Level-2 patterns**: loaded from ``$MotifsPath`` ($Level2Count pattern(s)).")
    }
    else {
        [void]$sb.AppendLine("**Generic mode only** - ``$MotifsPath`` missing: only the 4 embedded level-1 patterns are applied. Not a failure: normal run.")
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("**Date**: $(Get-Date -Format 'yyyy-MM-dd')")
    [void]$sb.AppendLine("**Scanned root**: ``$RepoRoot``")
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('## Candidate public zone (zero tolerance)')
    [void]$sb.AppendLine('')
    $publicHits = @($TreeScan.PublicHits)
    if ($publicHits.Count -eq 0) {
        [void]$sb.AppendLine('No hits.')
    }
    else {
        [void]$sb.AppendLine("$($publicHits.Count) hit(s) found:")
        [void]$sb.AppendLine('')
        foreach ($h in $publicHits) {
            [void]$sb.AppendLine("- ``$($h.File):$($h.Line):$($h.Motif)``")
        }
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('## Internal zone (informational counts - no zero tolerance)')
    [void]$sb.AppendLine('')
    $internalKeys = @($TreeScan.InternalCounts.Keys)
    if ($internalKeys.Count -eq 0) {
        [void]$sb.AppendLine('No hits.')
    }
    else {
        foreach ($k in $internalKeys) {
            [void]$sb.AppendLine("- ``$k``: $($TreeScan.InternalCounts[$k]) hit(s)")
        }
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('## History probe (3 key revisions)')
    [void]$sb.AppendLine('')
    if (-not $GitAvailable) {
        [void]$sb.AppendLine('git unavailable or repository inaccessible - probe not run.')
    }
    else {
        [void]$sb.AppendLine('| Revision | Hash | Hits |')
        [void]$sb.AppendLine('|---|---|---|')
        foreach ($row in $HistoryRows) {
            $hashDisp = if ([string]::IsNullOrWhiteSpace($row.Hash)) { '(unavailable)' } else { $row.Hash }
            $countDisp = if (-not $row.Grep.Available) { 'unavailable' } else { "$($row.Grep.Count)" }
            [void]$sb.AppendLine("| ($($row.Id)) $($row.Label) | ``$hashDisp`` | $countDisp |")
        }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**History verdict**: ' + $(if ($HistoryContaminated) {
        'history contaminated: any public release requires a squash/new repository or a filter-repo.'
    } else {
        'no hits on the probed revisions (a)/(b) - history clean on this sample (no guarantee for the unprobed intermediate revisions, nor when the git probe is unavailable).'
    }))
    [void]$sb.AppendLine('')
    return $sb.ToString()
}

# ===========================================================================
# Core: Invoke-ScanFuites - returns the exit code (testable, dot-source)
# ===========================================================================
function Invoke-ScanFuites {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$MotifsPath = "",
        [string]$ReportPath = ""
    )
    Set-StrictMode -Version Latest

    Write-Header "Leak scan - read-only (P045)"

    $resolved = Resolve-Path -LiteralPath $RepoRoot -ErrorAction SilentlyContinue
    if ($null -eq $resolved) {
        Write-Err "RepoRoot not found: $RepoRoot"
        return 2
    }
    $RepoRoot = (Get-Item -LiteralPath $resolved.Path).FullName

    if ([string]::IsNullOrWhiteSpace($MotifsPath)) {
        $MotifsPath = Join-Path $RepoRoot 'SDLC_PM/scan-fuites-motifs.txt'
    }
    if ([string]::IsNullOrWhiteSpace($ReportPath)) {
        $ReportPath = Join-Path $RepoRoot ("SDLC_PM/SP6-productisation/rapport-scan-fuites-{0}.md" -f (Get-Date -Format 'yyyy-MM-dd'))
    }

    # --- Patterns ---
    $level1 = @(Get-FuitesLevel1Patterns)
    $level2Present = Test-Path -LiteralPath $MotifsPath -PathType Leaf
    $level2 = @(Get-FuitesLevel2Patterns -Path $MotifsPath)
    if ($level2Present) { Write-Ok "Level-2 patterns: $($level2.Count) loaded from $MotifsPath" }
    else { Write-Warn "Level-2 patterns missing ($MotifsPath) - generic mode only." }
    $allPatterns = @($level1) + @($level2)

    # --- Working-tree scan ---
    Write-Step "Enumerating the working tree (excluding .git/)"
    $files = @(Get-FuitesFileList -Root $RepoRoot)
    Write-Step "$($files.Count) candidate file(s)"
    $treeScan = Invoke-FuitesTreeScan -Root $RepoRoot -RelPaths $files -Patterns $allPatterns
    Write-Ok "Public zone   : $($treeScan.PublicHits.Count) hit(s)"
    Write-Ok "Internal zone : $($treeScan.InternalCounts.Keys.Count) file(s) with hits"

    # --- History probe ---
    Write-Step "History probe (3 revisions)"
    $gitAvailable = $null -ne (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
    $historyRevs = @(Get-FuitesHistoryRevisions -Root $RepoRoot)
    $historyRows = New-Object System.Collections.Generic.List[object]
    $historyContaminated = $false
    foreach ($rev in $historyRevs) {
        if ([string]::IsNullOrWhiteSpace($rev.Hash)) {
            $historyRows.Add([pscustomobject]@{ Id = $rev.Id; Label = $rev.Label; Hash = $null; Grep = [pscustomobject]@{ Available = $false; Count = 0 } })
            continue
        }
        $grepResult = Invoke-FuitesRevisionGrep -Root $RepoRoot -Revision $rev.Hash -Patterns $allPatterns
        $historyRows.Add([pscustomobject]@{ Id = $rev.Id; Label = $rev.Label; Hash = $rev.Hash; Grep = $grepResult })
        if ($rev.Id -in @('a', 'b') -and $grepResult.Available -and $grepResult.Count -gt 0) {
            $historyContaminated = $true
        }
    }
    Write-Ok "History: $(if ($historyContaminated) { 'contaminated (expected, see F5)' } else { 'clean on the probed sample' })"

    # --- Report ---
    $report = Format-FuitesReport -RepoRoot $RepoRoot -MotifsPath $MotifsPath `
        -Level2Present $level2Present -Level2Count $level2.Count `
        -TreeScan $treeScan -HistoryRows $historyRows.ToArray() -HistoryContaminated $historyContaminated `
        -GitAvailable $gitAvailable
    Write-FileAtomic -Path $ReportPath -Content $report | Out-Null
    Write-Ok "Report written: $ReportPath"

    Write-Header "Scan complete"
    if ($treeScan.PublicHits.Count -gt 0) {
        Write-Warn "$($treeScan.PublicHits.Count) hit(s) in the public zone - see the report."
    }
    else {
        Write-Ok "0 hits in the public zone."
    }
    # Reporting tool (not a gate): the scan SUCCEEDED as soon as the report is
    # written, whether or not hits were found (see .NOTES).
    return 0
}

# --- Auto-run (script) - skipped when dot-sourced (tests) -------------------
if ($MyInvocation.InvocationName -ne '.') {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $rc = Invoke-ScanFuites -RepoRoot $RepoRoot -MotifsPath $MotifsPath -ReportPath $ReportPath
    exit $rc
}
