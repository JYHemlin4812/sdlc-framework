#requires -Version 5.1
<#
.SYNOPSIS
  Self-contained assert-based self-check (ZERO dependency: no Pester) of sync-lib.ps1.

.DESCRIPTION
  Covers EACH Code Lock criterion of P011:A002 (a..j). Creates its fixtures in a
  unique TEMP directory (never ~/.claude nor the real repo) and cleans up at the
  end (try/finally). Exit code != 0 on the first failure.

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

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Script, [Parameter(Mandatory)][string]$Name)
    $threw = $false
    try { & $Script | Out-Null } catch { $threw = $true }
    Assert-True -Condition $threw -Name $Name
}

# --- Locate the library -----------------------------------------------------
$libPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'sync-lib.ps1'
if (-not (Test-Path -LiteralPath $libPath)) {
    Write-Host "sync-lib.ps1 not found: $libPath" -ForegroundColor Red
    exit 2
}

# --- Isolated temporary work directory --------------------------------------
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('sync-lib-test-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

function New-FileWithBytes {
    param([string]$Path, [byte[]]$Bytes)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
}
function New-TextFile {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

try {
    Write-Host ""
    Write-Host "=== test-sync-lib: self-check P011:A002 ===" -ForegroundColor Cyan

    # =======================================================================
    # (a) dot-source OK with no side effect + functions callable in isolation
    # =======================================================================
    Write-Host "-- (a) dot-source with no side effect --" -ForegroundColor Cyan

    $canary = Join-Path $work 'canary'
    New-Item -ItemType Directory -Path $canary -Force | Out-Null
    $filesBefore = (Get-ChildItem -LiteralPath $canary -Recurse -Force | Measure-Object).Count

    # dot-source into the current scope
    . $libPath

    $filesAfter = (Get-ChildItem -LiteralPath $canary -Recurse -Force | Measure-Object).Count
    Assert-Eq $filesBefore $filesAfter "a. dot-source writes no file (no FS side effect)"

    # no scope variable polluted by loading
    Assert-True (-not (Test-Path variable:script:SyncExcludeDirs)) "a. dot-source creates no scope variable"

    $exported = @(
        'Get-SyncExclusion', 'Test-SyncExcluded',
        'Get-SyncDomainSkill', 'Get-DomainRelPaths', 'Get-RelPath',
        'Get-FileHashByteExact', 'Get-SyncState',
        'Show-ConflictDiff', 'Resolve-LWW',
        'Write-FileAtomic', 'Copy-Tree',
        'Acquire-SyncLock', 'Release-SyncLock',
        'Write-SyncManifest', 'Read-SyncManifest', 'Get-FirstRunPlan',
        'Set-NestorImport', 'Remove-NestorImport'
    )
    foreach ($fn in $exported) {
        Assert-True ($null -ne (Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue)) "a. exported function callable: $fn"
    }

    # actual isolated call of pure functions
    $ex = Get-SyncExclusion
    Assert-True ($ex.Dirs -contains '__pycache__') "a. Get-SyncExclusion callable in isolation"
    $isoFile = Join-Path $work 'iso.txt'
    New-TextFile -Path $isoFile -Text 'iso'
    Assert-True ((Get-FileHashByteExact -Path $isoFile).Length -eq 64) "a. Get-FileHashByteExact callable in isolation"

    # =======================================================================
    # (b) Write-SyncManifest & Copy-Tree NEVER write in place (temp+rename)
    # =======================================================================
    Write-Host "-- (b) atomic temp+rename writes --" -ForegroundColor Cyan

    # Proof by the code: Write-FileAtomic writes to a .tmp then Replace/Move,
    # and never writes directly to $Path.
    $wfaDef = (Get-Command Write-FileAtomic).Definition
    Assert-True ($wfaDef -match '\.tmp-') "b. Write-FileAtomic uses a .tmp- temporary file"
    Assert-True (($wfaDef -match '::Replace\(') -and ($wfaDef -match '::Move\(')) "b. Write-FileAtomic publishes via Replace/Move (rename)"
    Assert-True ($wfaDef -notmatch 'WriteAll\w+\(\s*\$Path') 'b. Write-FileAtomic never writes directly to the $Path target'
    Assert-True ((Get-Command Write-SyncManifest).Definition -match 'Write-FileAtomic') "b. Write-SyncManifest goes through Write-FileAtomic"
    Assert-True ((Get-Command Copy-Tree).Definition -match 'Write-FileAtomic') "b. Copy-Tree goes through Write-FileAtomic"

    # Functional proof: overwrite of an existing target, no leftover .tmp.
    $manifestDir = Join-Path $work 'manifest'
    New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
    $manifestPath = Join-Path $manifestDir '.sync-manifest.json'
    New-TextFile -Path $manifestPath -Text 'OLD-SENTINEL'   # pre-existing target
    Write-SyncManifest -Path $manifestPath -Entries @{ 'commands/sdlc/a.md' = 'deadbeef' } | Out-Null
    Assert-True (Test-Path -LiteralPath $manifestPath) "b. Write-SyncManifest produces the final target"
    $tmpLeft = @(Get-ChildItem -LiteralPath $manifestDir -Filter '*.tmp-*' -Force -ErrorAction SilentlyContinue)
    Assert-Eq 0 $tmpLeft.Count "b. no leftover .tmp- file after Write-SyncManifest (rename done)"
    $reread = Read-SyncManifest -Path $manifestPath
    Assert-True ($reread.Ok -and $reread.Entries['commands/sdlc/a.md'] -eq 'deadbeef') "b. atomically rewritten manifest is readable (target replaced, not the sentinel)"

    # =======================================================================
    # (c) Copy-Tree: no robocopy / /MIR + copies ONLY greenlisted paths
    # =======================================================================
    Write-Host "-- (c) per-relPath Copy-Tree, no /MIR --" -ForegroundColor Cyan

    $ctDef = (Get-Command Copy-Tree).Definition
    Assert-True ($ctDef -notmatch 'robocopy') "c. Copy-Tree contains no robocopy"
    Assert-True ($ctDef -notmatch '/MIR') "c. Copy-Tree contains no /MIR"

    $srcRoot = Join-Path $work 'ct-src'
    $dstRoot = Join-Path $work 'ct-dst'
    New-TextFile -Path (Join-Path $srcRoot 'a.md') -Text 'AAA'
    New-TextFile -Path (Join-Path $srcRoot 'sub\b.md') -Text 'BBB'
    New-TextFile -Path (Join-Path $srcRoot 'c.md') -Text 'CCC'   # NOT greenlisted
    $copied = Copy-Tree -SrcRoot $srcRoot -DstRoot $dstRoot -RelPaths @('a.md', 'sub/b.md')
    Assert-True (Test-Path -LiteralPath (Join-Path $dstRoot 'a.md')) "c. Copy-Tree copies the greenlisted relPath (a.md)"
    Assert-True (Test-Path -LiteralPath (Join-Path $dstRoot 'sub\b.md')) "c. Copy-Tree creates parent folders (sub/b.md)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $dstRoot 'c.md'))) "c. Copy-Tree does NOT copy a non-greenlisted file (c.md)"
    Assert-Eq 'AAA' ([System.IO.File]::ReadAllText((Join-Path $dstRoot 'a.md'))) "c. copied content is byte-faithful"

    # (c-sec) boundary: a '..' relPath must NEVER escape DstRoot
    #         nor overwrite a file outside the target tree.
    $secBase = Join-Path $work 'ct-sec'
    $secSrc  = Join-Path $secBase 's\src'
    $secDst  = Join-Path $secBase 'd\dst'
    New-Item -ItemType Directory -Path $secSrc -Force | Out-Null
    New-Item -ItemType Directory -Path $secDst -Force | Out-Null
    $attacker = Join-Path $secBase 's\payload.md'   # parent of SrcRoot
    $victim   = Join-Path $secBase 'd\payload.md'   # parent of DstRoot (OUTSIDE target)
    New-TextFile -Path $attacker -Text 'ATTACKER-PAYLOAD'
    New-TextFile -Path $victim   -Text 'PRECIOUS-LIVE-DATA'
    $secCopied = @(Copy-Tree -SrcRoot $secSrc -DstRoot $secDst -RelPaths @('../payload.md') 3>$null)
    Assert-Eq 0 $secCopied.Count "c-sec. Copy-Tree rejects the '..' escape relPath (nothing copied)"
    Assert-Eq 'PRECIOUS-LIVE-DATA' ([System.IO.File]::ReadAllText($victim)) "c-sec. the victim OUTSIDE DstRoot is NOT overwritten via '..'"
    # variants: rooted path and empty segment are rejected too
    $secCopied2 = @(Copy-Tree -SrcRoot $secSrc -DstRoot $secDst -RelPaths @('sub//../../x.md') 3>$null)
    Assert-Eq 0 $secCopied2.Count "c-sec. Copy-Tree rejects '..' even when nested"

    # =======================================================================
    # (d) corrupt Read-SyncManifest -> fail CLOSED
    # =======================================================================
    Write-Host "-- (d) corrupt manifest => fail-closed --" -ForegroundColor Cyan

    $corrupt = Join-Path $work 'corrupt.json'
    New-TextFile -Path $corrupt -Text '{ "version": "SP2", "entries": { truncated...'   # invalid JSON
    $rc = Read-SyncManifest -Path $corrupt
    Assert-True ($rc.FailClosed -eq $true) "d. corrupt parse => FailClosed=true"
    Assert-Eq 0 $rc.Entries.Count "d. empty base when fail-closed"
    # no ref!=live assumed synced: two different present sides => modified-both (blocked), never 'identical'
    $baseD = $null
    if ($rc.Entries.ContainsKey('commands/sdlc/x.md')) { $baseD = $rc.Entries['commands/sdlc/x.md'] }
    $stD = (Get-SyncState -RefHash 'aaaa' -LiveHash 'bbbb' -BaseHash $baseD).State
    Assert-True ($stD -ne 'identical') "d. fail-closed: a ref!=live is never assumed synced"
    Assert-Eq 'modified-both' $stD "d. fail-closed: ref!=live without base => modified-both (blocked)"

    # (d-schema) VALID JSON but 'entries' with a wrong schema (array/scalar/string)
    #            => fail CLOSED. Otherwise PSObject.Properties injects Length/Count/Rank...
    #            as fake base entries while returning Ok=true (violates H4).
    $badArr = Join-Path $work 'entries-array.json'
    New-TextFile -Path $badArr -Text '{ "version": "SP2", "entries": [1,2,3] }'
    $rcArr = Read-SyncManifest -Path $badArr
    Assert-True ($rcArr.FailClosed -eq $true) "d-schema. entries=JSON array => FailClosed=true"
    Assert-Eq 0 $rcArr.Entries.Count "d-schema. entries=array => empty base (no fake .NET entry)"

    $badStr = Join-Path $work 'entries-string.json'
    New-TextFile -Path $badStr -Text '{ "version": "SP2", "entries": "boom" }'
    $rcStr = Read-SyncManifest -Path $badStr
    Assert-True ($rcStr.FailClosed -eq $true) "d-schema. entries=string => FailClosed=true"
    Assert-Eq 0 $rcStr.Entries.Count "d-schema. entries=string => empty base"

    # entries={} (empty JSON object) stays OK = conservative empty base (not fail-closed)
    $emptyEntries = Join-Path $work 'entries-empty.json'
    New-TextFile -Path $emptyEntries -Text '{ "version": "SP2", "entries": {} }'
    $rcEmpty = Read-SyncManifest -Path $emptyEntries
    Assert-True (($rcEmpty.Ok -eq $true) -and ($rcEmpty.Entries.Count -eq 0)) "d-schema. entries={} => Ok, empty base (conservative)"

    # =======================================================================
    # (e) Get-SyncState: correct label for EACH row of the truth table
    # =======================================================================
    Write-Host "-- (e) classifier: truth table --" -ForegroundColor Cyan

    Assert-Eq 'identical'        (Get-SyncState -RefHash 'x' -LiveHash 'x' -BaseHash 'x').State     "e. identical (R==L)"
    Assert-Eq 'identical'        (Get-SyncState -RefHash 'x' -LiveHash 'x' -BaseHash $null).State   "e. identical (R==L, without base)"
    Assert-Eq 'modified-ref'      (Get-SyncState -RefHash 'r2' -LiveHash 'b' -BaseHash 'b').State    "e. modified-ref (L==B, R!=B)"
    Assert-Eq 'modified-live'     (Get-SyncState -RefHash 'b' -LiveHash 'l2' -BaseHash 'b').State    "e. modified-live (R==B, L!=B)"
    Assert-Eq 'modified-both' (Get-SyncState -RefHash 'r2' -LiveHash 'l2' -BaseHash 'b').State   "e. modified-both (R!=B,L!=B) [H2]"
    Assert-Eq 'modified-both' (Get-SyncState -RefHash 'r2' -LiveHash 'l2' -BaseHash $null).State "e. added-both-divergent => modified-both"
    Assert-Eq 'added-live'      (Get-SyncState -RefHash $null -LiveHash 'l' -BaseHash $null).State "e. added-live (protected)"
    Assert-Eq 'deleted-ref'     (Get-SyncState -RefHash $null -LiveHash 'b' -BaseHash 'b').State   "e. deleted-ref (base-aware, L==B)"
    Assert-Eq 'conflict-deleted-ref-modified-live' (Get-SyncState -RefHash $null -LiveHash 'l2' -BaseHash 'b').State "e. conflict-deleted-ref-modified-live"
    Assert-Eq 'added-ref'       (Get-SyncState -RefHash 'r' -LiveHash $null -BaseHash $null).State "e. added-ref"
    Assert-Eq 'deleted-live'    (Get-SyncState -RefHash 'b' -LiveHash $null -BaseHash 'b').State   "e. deleted-live (R==B)"
    Assert-Eq 'conflict-deleted-live-modified-ref' (Get-SyncState -RefHash 'r2' -LiveHash $null -BaseHash 'b').State "e. conflict-deleted-live-modified-ref"
    Assert-Eq 'absent-both'  (Get-SyncState -RefHash $null -LiveHash $null -BaseHash 'b').State "e. absent-both"

    # =======================================================================
    # (f) Exclusions: *.pyc and __pycache__/ excluded; domain .md not excluded
    # =======================================================================
    Write-Host "-- (f) centralized exclusions --" -ForegroundColor Cyan

    Assert-True (Test-SyncExcluded -RelPath 'skills/sdlc/x.pyc') "f. *.pyc excluded"
    Assert-True (Test-SyncExcluded -RelPath 'skills/sdlc/__pycache__/x.py') "f. __pycache__/ excluded"
    Assert-True (Test-SyncExcluded -RelPath 'commands/sdlc/conflicts.log') "f. conflicts.log excluded"
    Assert-True (Test-SyncExcluded -RelPath '.sync-manifest.json') "f. manifest excluded"
    Assert-True (-not (Test-SyncExcluded -RelPath 'skills/sdlc/SKILL.md')) "f. domain .md NOT excluded"

    # =======================================================================
    # (g) Mapping: skills/sdlc/commands/** excluded; third-party skill ignored (H7)
    # =======================================================================
    Write-Host "-- (g) 3-domain mapping + H3/H7 --" -ForegroundColor Cyan

    $ref = Join-Path $work 'ref-tree'
    New-TextFile -Path (Join-Path $ref 'skills\sdlc\SKILL.md')                       -Text 's'
    New-TextFile -Path (Join-Path $ref 'skills\sdlc\commands\sdlc\dev.md')          -Text 'embed'   # H3: excluded
    New-TextFile -Path (Join-Path $ref 'skills\sdlc-reviewer\SKILL.md')               -Text 'r'
    New-TextFile -Path (Join-Path $ref 'skills\autre\SKILL.md')                         -Text 'third-party'   # H7: ignored
    New-TextFile -Path (Join-Path $ref 'skills\sdlc\__pycache__\z.pyc')               -Text 'z'       # excluded
    New-TextFile -Path (Join-Path $ref 'commands\sdlc\plan.md')                       -Text 'p'
    New-TextFile -Path (Join-Path $ref 'agents\sdlc-python-dev.md')                   -Text 'a'
    New-TextFile -Path (Join-Path $ref 'agents\autre-agent.md')                         -Text 'x'       # not sdlc-*

    $rels = @(Get-DomainRelPaths -Root $ref)
    Assert-True ($rels -contains 'skills/sdlc/SKILL.md') "g. includes skills/sdlc/SKILL.md"
    Assert-True ($rels -contains 'skills/sdlc-reviewer/SKILL.md') "g. includes skills/sdlc-reviewer/SKILL.md"
    Assert-True ($rels -contains 'commands/sdlc/plan.md') "g. includes commands/sdlc/plan.md"
    Assert-True ($rels -contains 'agents/sdlc-python-dev.md') "g. includes agents/sdlc-python-dev.md"
    Assert-True (-not ($rels -contains 'skills/sdlc/commands/sdlc/dev.md')) "g. H3: skills/sdlc/commands/** excluded"
    Assert-True (-not ($rels -contains 'skills/autre/SKILL.md')) "g. H7: third-party skill 'autre' ignored"
    Assert-True (-not ($rels -contains 'agents/autre-agent.md')) "g. agents outside sdlc-* ignored"
    Assert-True (@($rels | Where-Object { $_ -like '*.pyc' }).Count -eq 0) "g. .pyc absent from the mapping (exclusions)"

    $skillScope = @(Get-SyncDomainSkill -Root $ref)
    Assert-True (($skillScope -contains 'sdlc') -and ($skillScope -contains 'sdlc-reviewer')) "g. skills scope derived from sdlc*"
    Assert-True (-not ($skillScope -contains 'autre')) "g. skills scope excludes the third-party skill"

    # =======================================================================
    # (g-sp3) P021:A018 extension — agents/nestor-* pattern + core domain
    #         NESTOR.md (literal 0/1, no open root pattern) [T070/T071]
    # =======================================================================
    Write-Host "-- (g-sp3) agents nestor-* domain + NESTOR.md core (A018) --" -ForegroundColor Cyan

    # root WITHOUT NESTOR.md: empty core domain (0), no error (T071)
    Assert-True (-not ($rels -contains 'NESTOR.md')) "g-sp3. root without NESTOR.md => empty core domain (0), no error"

    New-TextFile -Path (Join-Path $ref 'agents\nestor-qualite.md') -Text 'nq'
    New-TextFile -Path (Join-Path $ref 'NESTOR.md')                -Text 'core'
    New-TextFile -Path (Join-Path $ref 'AUTRE.md')                 -Text 'arbitrary root file'

    $rels3 = @(Get-DomainRelPaths -Root $ref)
    Assert-True (-not ($rels3 -contains 'agents/nestor-qualite.md')) "g-sp3. T070: agents/nestor-* OUTSIDE the SDLC domain"
    Assert-True (-not ($rels3 -contains 'NESTOR.md')) "g-sp3. T071: root NESTOR.md OUTSIDE the SDLC domain"
    Assert-True (-not ($rels3 -contains 'AUTRE.md')) "g-sp3. T071: arbitrary root file (AUTRE.md) OUTSIDE the domain (no open root pattern)"
    Assert-True (-not ($rels3 -contains 'agents/autre-agent.md')) "g-sp3. agents outside sdlc-*/nestor-* still ignored"
    # T070: a domain nestor-* agent modified on the ref side only is classified modified-ref
    Assert-Eq 'modified-ref' (Get-SyncState -RefHash 'r2' -LiveHash 'b' -BaseHash 'b' -RelPath 'agents/nestor-qualite.md').State "g-sp3. T070: agents/nestor-* modified-ref-only classified modified-ref (not ignored)"
    # T071: the core domain is SUBJECT to exclusions (proof by the code:
    # no fixed pattern of the exclusion set can match 'NESTOR.md', so the
    # guard can only be exercised structurally).

    # =======================================================================
    # (h) Byte-exact hash: stable and sensitive to 1 byte
    # =======================================================================
    Write-Host "-- (h) byte-exact hashing --" -ForegroundColor Cyan

    $hf = Join-Path $work 'hash.bin'
    New-FileWithBytes -Path $hf -Bytes ([byte[]](1, 2, 3, 4, 5))
    $h1 = Get-FileHashByteExact -Path $hf
    $h2 = Get-FileHashByteExact -Path $hf
    Assert-Eq $h1 $h2 "h. stable hash (two identical reads)"
    New-FileWithBytes -Path $hf -Bytes ([byte[]](1, 2, 3, 4, 6))   # 1 byte changed
    $h3 = Get-FileHashByteExact -Path $hf
    Assert-True ($h3 -ne $h1) "h. hash sensitive to 1 byte"
    # byte-exact: no EOL conversion (CRLF vs LF => different hash)
    $crlf = Join-Path $work 'crlf.txt'; New-FileWithBytes -Path $crlf -Bytes ([System.Text.Encoding]::ASCII.GetBytes("a`r`nb"))
    $lf = Join-Path $work 'lf.txt';     New-FileWithBytes -Path $lf   -Bytes ([System.Text.Encoding]::ASCII.GetBytes("a`nb"))
    Assert-True ((Get-FileHashByteExact -Path $crlf) -ne (Get-FileHashByteExact -Path $lf)) "h. byte-exact: CRLF != LF (no normalization)"

    # =======================================================================
    # (i) First run: identical union => seed; asymmetry => block
    # =======================================================================
    Write-Host "-- (i) first-run union (H5) --" -ForegroundColor Cyan

    $refH  = @{ 'a' = 'h1'; 'b' = 'h2' }
    $liveH = @{ 'a' = 'h1'; 'b' = 'h2' }
    Assert-Eq 'seed'  (Get-FirstRunPlan -RefHashes $refH -LiveHashes $liveH).Signal "i. identical union => seed"

    $refH2  = @{ 'a' = 'h1'; 'b' = 'h2' }
    $liveH2 = @{ 'a' = 'h1' }                      # presence asymmetry: 'b' missing on the right
    Assert-Eq 'block' (Get-FirstRunPlan -RefHashes $refH2 -LiveHashes $liveH2).Signal "i. presence asymmetry => block"
    Assert-Eq 'seed'  (Get-FirstRunPlan -RefHashes $refH2 -LiveHashes $liveH2 -Adopt).Signal "i. -Adopt forces the seed despite asymmetry"

    $refH3  = @{ 'a' = 'h1' }
    $liveH3 = @{ 'a' = 'hX' }                      # same key, different hash => block
    Assert-Eq 'block' (Get-FirstRunPlan -RefHashes $refH3 -LiveHashes $liveH3).Signal "i. content divergence => block"

    # =======================================================================
    # (j) O_EXCL lockfile: 2nd acquisition fails until released
    # =======================================================================
    Write-Host "-- (j) O_EXCL lockfile --" -ForegroundColor Cyan

    $lockPath = Join-Path $work 'sync.lock'
    $lock = Acquire-SyncLock -Path $lockPath
    Assert-True (Test-Path -LiteralPath $lockPath) "j. Acquire-SyncLock creates the lock"
    Assert-Throws { Acquire-SyncLock -Path $lockPath } "j. concurrent 2nd acquisition fails (O_EXCL)"
    Release-SyncLock -Lock $lock
    Assert-True (-not (Test-Path -LiteralPath $lockPath)) "j. Release-SyncLock removes the lock"
    $lock2 = Acquire-SyncLock -Path $lockPath
    Assert-True ($null -ne $lock2) "j. re-acquisition possible after release"
    Release-SyncLock -Lock $lock2

    # (j-orphan) if writing the metadata fails after CreateNew, the orphan lockfile
    # is removed (otherwise lock without holder = blocked forever).
    # Not reproducible without fault injection: checked in the code.
    $aslDef = (Get-Command Acquire-SyncLock).Definition
    Assert-True ($aslDef -match 'Remove-Item[^\r\n]*\$Path') "j-orphan. Acquire-SyncLock cleans the orphan lockfile when the metadata write fails"

    # bonus: Show-ConflictDiff degrades cleanly (does not throw), Resolve-LWW conservative
    $d1 = Join-Path $work 'd1.txt'; New-TextFile -Path $d1 -Text 'one'
    $d2 = Join-Path $work 'd2.txt'; New-TextFile -Path $d2 -Text 'two'
    $diffOk = $true
    try { Show-ConflictDiff -RefPath $d1 -LivePath $d2 | Out-Null } catch { $diffOk = $false }
    Assert-True $diffOk "bonus. Show-ConflictDiff does not throw (degrades without git)"

    $clog = Join-Path $work 'conflicts.log'
    $res = Resolve-LWW -RelPath 'commands/sdlc/a.md' -ConflictLogPath $clog -RefHash 'r' -LiveHash 'l'
    Assert-Eq 'ref' $res.Winner "bonus. Resolve-LWW conservative: winner=ref by default (protects the canonical tree)"
    Assert-True (Test-Path -LiteralPath $clog) "bonus. Resolve-LWW logs (append-only)"

    # =======================================================================
    # (k) Set-NestorImport / Remove-NestorImport (P022:A019) — idempotent
    #     @NESTOR.md import in a file OUTSIDE the sync domain (~/.claude/CLAUDE.md).
    # =======================================================================
    Write-Host "-- (k) Set-NestorImport / Remove-NestorImport --" -ForegroundColor Cyan

    # k1. 3x Set (install) + 3x Set (restore) in a row -> count==1 at each step,
    #     rest of the file byte-identical to the initial state.
    $nestorDir = Join-Path $work 'nestor-k1'
    $claudeMd  = Join-Path $nestorDir 'CLAUDE.md'
    $initial   = "# User preferences`nALWAYS tell the truth.`n"
    New-TextFile -Path $claudeMd -Text $initial
    for ($i = 1; $i -le 6; $i++) {
        Set-NestorImport -Path $claudeMd
        $txt = [System.IO.File]::ReadAllText($claudeMd)
        $cnt = @([regex]::Matches($txt, '(?m)^\s*@NESTOR\.md\s*$')).Count
        Assert-Eq 1 $cnt "k1. iteration $i : count(@NESTOR.md) == 1"
        Assert-True ($txt.StartsWith($initial)) "k1. iteration $i : initial content preserved (prefix intact)"
    }

    # k2. Line already present in the MIDDLE of the file -> nothing added.
    $midDir = Join-Path $work 'nestor-k2'
    $midMd  = Join-Path $midDir 'CLAUDE.md'
    $midText = "line1`n@NESTOR.md`nline3`n"
    New-TextFile -Path $midMd -Text $midText
    Set-NestorImport -Path $midMd
    $midAfter = [System.IO.File]::ReadAllText($midMd)
    Assert-Eq $midText $midAfter "k2. line in the middle: file unchanged (position-agnostic detection)"

    # k3. Removal (Remove-NestorImport) -> line gone AND no other diff.
    $rmDir = Join-Path $work 'nestor-k3'
    $rmMd  = Join-Path $rmDir 'CLAUDE.md'
    $rmInitial = "before`n@NESTOR.md`nafter`n"
    New-TextFile -Path $rmMd -Text $rmInitial
    Remove-NestorImport -Path $rmMd
    $rmAfter = [System.IO.File]::ReadAllText($rmMd)
    Assert-Eq "before`nafter`n" $rmAfter "k3. Remove-NestorImport: line removed, rest byte-identical"

    # k4. Missing file -> created with the single '@NESTOR.md' line.
    $absDir = Join-Path $work 'nestor-k4'
    $absMd  = Join-Path $absDir 'CLAUDE.md'
    Assert-True (-not (Test-Path -LiteralPath $absMd)) "k4. (pre) file missing"
    Set-NestorImport -Path $absMd
    Assert-Eq '@NESTOR.md' ([System.IO.File]::ReadAllText($absMd)) "k4. missing file -> created with the single line"

    # k5. File WITHOUT a final newline -> initial content preserved byte for byte,
    #     correct EOL prefix (LF here, the file's dominant style).
    $noeolDir = Join-Path $work 'nestor-k5'
    $noeolMd  = Join-Path $noeolDir 'CLAUDE.md'
    New-Item -ItemType Directory -Path $noeolDir -Force | Out-Null
    [System.IO.File]::WriteAllText($noeolMd, "line-without-eol", (New-Object System.Text.UTF8Encoding($false)))
    Set-NestorImport -Path $noeolMd
    Assert-Eq "line-without-eol`n@NESTOR.md" ([System.IO.File]::ReadAllText($noeolMd)) "k5. no final EOL: initial bytes preserved + EOL prefix + marker"

    # k5b. File WITHOUT a final newline, DOMINANT CRLF -> CRLF prefix (not LF).
    $noeolCrlfMd = Join-Path (Join-Path $work 'nestor-k5b') 'CLAUDE.md'
    New-Item -ItemType Directory -Path (Split-Path -Parent $noeolCrlfMd) -Force | Out-Null
    [System.IO.File]::WriteAllText($noeolCrlfMd, "a`r`nb`r`nc-without-eol", (New-Object System.Text.UTF8Encoding($false)))
    Set-NestorImport -Path $noeolCrlfMd
    Assert-Eq "a`r`nb`r`nc-without-eol`r`n@NESTOR.md" ([System.IO.File]::ReadAllText($noeolCrlfMd)) "k5b. no final EOL, CRLF dominant: CRLF prefix"

    # k6. --dry-run (DryRun) -> 0 writes (no backup, no target file, no leftover temp).
    $dryDir = Join-Path $work 'nestor-k6'
    $dryMd  = Join-Path $dryDir 'CLAUDE.md'
    Assert-True (-not (Test-Path -LiteralPath $dryMd)) "k6. (pre) file missing"
    Set-NestorImport -Path $dryMd -DryRun
    Assert-True (-not (Test-Path -LiteralPath $dryMd)) "k6a. dry-run on a missing file: still missing (0 writes)"
    $dryDir2 = Join-Path $work 'nestor-k6b'
    $dryMd2  = Join-Path $dryDir2 'CLAUDE.md'
    New-TextFile -Path $dryMd2 -Text "existing`n"
    $before6b = [System.IO.File]::ReadAllText($dryMd2)
    Set-NestorImport -Path $dryMd2 -DryRun
    Assert-Eq $before6b ([System.IO.File]::ReadAllText($dryMd2)) "k6b. dry-run on an existing file: unchanged"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $dryDir2 '_backups'))) "k6b. dry-run: no backup created"
    Assert-Eq 0 (@(Get-ChildItem -LiteralPath $dryDir2 -Filter '*.tmp-*' -Force -ErrorAction SilentlyContinue).Count) "k6b. dry-run: no leftover temp"

    # k7. count > 1 (2 @NESTOR.md lines already present) -> warning, NO dedup.
    $dupDir = Join-Path $work 'nestor-k7'
    $dupMd  = Join-Path $dupDir 'CLAUDE.md'
    $dupText = "@NESTOR.md`nmiddle`n@NESTOR.md`n"
    New-TextFile -Path $dupMd -Text $dupText
    $warnOut = (Set-NestorImport -Path $dupMd -WarningAction Continue) 3>&1 | Out-String
    Assert-True ($warnOut -match 'NESTOR\.md') "k7. warning emitted when count > 1"
    Assert-Eq $dupText ([System.IO.File]::ReadAllText($dupMd)) "k7. count > 1: NO automatic dedup (file unchanged)"

    # k8. Remove-NestorImport on a missing file -> no-op (no error).
    $noneMd = Join-Path (Join-Path $work 'nestor-k8') 'CLAUDE.md'
    $removeOk = $true
    try { Remove-NestorImport -Path $noneMd } catch { $removeOk = $false }
    Assert-True $removeOk "k8. Remove-NestorImport on a missing file: no-op without error"

    # =======================================================================
    # (L) P033:A029 — Set-LocalOverlayImport (existence guard for the private
    #     *.local.md overlay + adding the "@<LocalFileName>" import).
    # =======================================================================
    Write-Host "-- (L) Set-LocalOverlayImport (P033:A029) --" -ForegroundColor Cyan

    # L1. Overlay missing -> created EMPTY, then "@CLAUDE.local.md" line added to $Path.
    $l1Dir   = Join-Path $work 'overlay-l1'
    $l1Md    = Join-Path $l1Dir 'CLAUDE.md'
    $l1Local = Join-Path $l1Dir 'CLAUDE.local.md'
    Assert-True (-not (Test-Path -LiteralPath $l1Local)) "L1. (pre) overlay missing"
    Set-LocalOverlayImport -Path $l1Md -LocalFileName 'CLAUDE.local.md'
    Assert-True (Test-Path -LiteralPath $l1Local -PathType Leaf) "L1. overlay created (missing -> present)"
    Assert-Eq '' ([System.IO.File]::ReadAllText($l1Local)) "L1. overlay created EMPTY"
    Assert-Eq '@CLAUDE.local.md' ([System.IO.File]::ReadAllText($l1Md)) "L1. @CLAUDE.local.md line added to Path"

    # L2. Overlay ALREADY present and NOT empty -> never overwritten (private content kept).
    $l2Dir   = Join-Path $work 'overlay-l2'
    $l2Md    = Join-Path $l2Dir 'CLAUDE.md'
    $l2Local = Join-Path $l2Dir 'CLAUDE.local.md'
    New-TextFile -Path $l2Local -Text "existing private content`n"
    Set-LocalOverlayImport -Path $l2Md -LocalFileName 'CLAUDE.local.md'
    Assert-Eq "existing private content`n" ([System.IO.File]::ReadAllText($l2Local)) "L2. existing NON-empty overlay: never overwritten"
    Assert-Eq '@CLAUDE.local.md' ([System.IO.File]::ReadAllText($l2Md)) "L2. import line added despite the pre-existing overlay"

    # L3. Idempotence: 2nd call -> overlay still intact, import line NOT duplicated.
    Set-LocalOverlayImport -Path $l1Md -LocalFileName 'CLAUDE.local.md'
    Assert-Eq '' ([System.IO.File]::ReadAllText($l1Local)) "L3. 2nd call: overlay still empty (untouched)"
    Assert-Eq 1 (@([regex]::Matches([System.IO.File]::ReadAllText($l1Md), '(?m)^\s*@CLAUDE\.local\.md\s*$')).Count) "L3. 2nd call: exactly 1 @CLAUDE.local.md line (idempotent)"

    # L4. -DryRun: 0 writes (no overlay created, no import line added).
    $l4Dir   = Join-Path $work 'overlay-l4'
    $l4Md    = Join-Path $l4Dir 'CLAUDE.md'
    $l4Local = Join-Path $l4Dir 'CLAUDE.local.md'
    Set-LocalOverlayImport -Path $l4Md -LocalFileName 'CLAUDE.local.md' -DryRun
    Assert-True (-not (Test-Path -LiteralPath $l4Local)) "L4. -DryRun: overlay NOT created"
    Assert-True (-not (Test-Path -LiteralPath $l4Md)) "L4. -DryRun: Path NOT created (0 import line added)"

    # L5. Set-LocalOverlayImport OUTSIDE the sync domain (same status as Set-NestorImport).
    $l5Dir = Join-Path $work 'overlay-l5'
    New-Item -ItemType Directory -Path $l5Dir -Force | Out-Null
    $domainL5 = @(Get-DomainRelPaths -Root $l5Dir)
    Assert-True (-not ($domainL5 -contains 'CLAUDE.md') -and -not ($domainL5 -contains 'CLAUDE.local.md')) "L5. CLAUDE.md/CLAUDE.local.md OUTSIDE the sync domain (Get-DomainRelPaths)"
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Report -----------------------------------------------------------------
Write-Host ""
Write-Host ("=== Result: {0} PASS / {1} FAIL ===" -f $script:Passed, $script:Failed) -ForegroundColor Cyan
if ($script:Failed -gt 0) {
    Write-Host "Failures:" -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host ("  - " + $f) -ForegroundColor Red }
    exit 1
}
Write-Host "All Code Lock criteria (a..j) are green." -ForegroundColor Green
exit 0
