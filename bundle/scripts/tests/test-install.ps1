#requires -Version 5.1
<#
.SYNOPSIS
  Self-contained, assert-based self-check (ZERO dependency: no Pester) of install.ps1
  (P015:A011). Exit code != 0 on the first failure.

.DESCRIPTION
  Creates ALL its fixtures in a single TEMP directory (fake REF = mini claude/ tree
  with skills+commands+agents, in a committed git repo OR non-git; fake empty LIVE
  target). NEVER operates on the real repo nor on ~/.claude. Cleans up in finally.

  Covers EVERY Code Lock criterion of P015:A011:
    (C0) source invariants: no robocopy/MIR; dot-sources sync-lib;
         deployment via Get-DomainRelPaths + Copy-Tree; DERIVED skills
         (Get-SyncDomainSkill); default SourceRoot ..\..\claude; commands sourced from
         the top level (never the embedded copy); Invoke-Install + post-check + auto-run guard.
    (C1) real ref: DERIVED floors for skills / agents / commands (read-only).
    (C2) empty live bootstrap (GIT fixture): greenlist deployed, recursive agent deployed,
         embedded copy (H3) NOT deployed, verify post-check 0 drift → exit 0.
    (C3) verify unavailable (NON-git fixture): deployment done, not fatal → exit 0.
    (C4) idempotence: 2nd install (unchanged source) → "already up to date" exit 0, no redeploy.
    (C5) -Force: reinstalls despite an unchanged checksum → timestamped backup created (before replacement).
    (C6) third-party skill guard: target SKILL.md name not sdlc* → ABORT exit 3, live intact.
    (C7) -DryRun: 0 writes (no file/manifest/backup on the live side).

  Compatible with PowerShell 5.1 (Desktop) and 7 (Core).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Minimal assertion harness ----------------------------------------------
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

# --- Script locations -------------------------------------------------------
$scriptsDir  = Split-Path -Parent $PSScriptRoot
$installPath = Join-Path $scriptsDir 'install.ps1'
$libPath     = Join-Path $scriptsDir 'sync-lib.ps1'
$verifyPath  = Join-Path $scriptsDir 'verify.ps1'
foreach ($p in @($installPath, $libPath, $verifyPath)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "not found: $p" -ForegroundColor Red; exit 2 }
}

# Dot-source: sync-lib THEN install (install dot-sources sync-lib itself; the
# InvocationName guard prevents the auto-run). Exposes Invoke-Install + helpers + lib.
. $libPath
. $installPath

# --- Isolated temporary working directory -----------------------------------
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('install-test-' + [System.Guid]::NewGuid().ToString('N'))
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

# Canonical mini claude/ tree: 2 skills (sdlc, sdlc-verify), 2 commands, 2 agents
# (one of them RECURSIVE under agents/nested/), + an embedded DECOY copy that MUST be
# excluded (H3: skills/sdlc/commands/**). Optionally committed in a git repo (HEAD).
$FIXFILES = @{
    'skills/sdlc/SKILL.md'                 = "---`nname: sdlc`n---`nroot skill`n"
    'skills/sdlc-verify/SKILL.md'          = "---`nname: sdlc-verify`n---`nverify skill`n"
    'skills/sdlc/commands/sdlc/decoy.md' = "embedded DECOY — must NEVER be deployed`n"
    'commands/sdlc/brainstorm.md'          = "brainstorm cmd`n"
    'commands/sdlc/dev.md'                 = "dev cmd`n"
    'agents/sdlc-architect.md'             = "architect agent`n"
    'agents/nested/sdlc-deep.md'           = "deep nested agent`n"
}

function New-InstallCase {
    param([string]$Name, [switch]$Git)
    $c    = Join-Path $root $Name
    $repo = Join-Path $c 'repo'
    $ref  = Join-Path $repo 'claude'
    $live = Join-Path $c 'live'
    New-Item -ItemType Directory -Path $ref  -Force | Out-Null
    New-Item -ItemType Directory -Path $live -Force | Out-Null
    foreach ($rel in $FIXFILES.Keys) {
        $native = $rel -replace '/', ([string][System.IO.Path]::DirectorySeparatorChar)
        New-TextFile -Path (Join-Path $ref $native) -Text $FIXFILES[$rel]
    }
    if ($Git) {
        Invoke-Git2 -RepoDir $repo -GitArgs @('init', '-q')                        | Out-Null
        Invoke-Git2 -RepoDir $repo -GitArgs @('config', 'user.email', 't@t')       | Out-Null
        Invoke-Git2 -RepoDir $repo -GitArgs @('config', 'user.name', 'test')       | Out-Null
        Invoke-Git2 -RepoDir $repo -GitArgs @('config', 'commit.gpgsign', 'false') | Out-Null
        Invoke-Git2 -RepoDir $repo -GitArgs @('add', '--', 'claude')               | Out-Null
        Invoke-Git2 -RepoDir $repo -GitArgs @('commit', '-q', '-m', 'seed ref')    | Out-Null
    }
    return [pscustomobject]@{ Dir = $c; Repo = $repo; Ref = $ref; Live = $live }
}

# Runs Invoke-Install, separating the return code (int) from the text (Write-Host). 5.1/7.
function Invoke-InstallCase {
    param([hashtable]$P)
    $streamed = Invoke-Install @P *>&1
    $ints = @($streamed | Where-Object { $_ -is [int] })
    $rc = if ($ints.Count -gt 0) { $ints[$ints.Count - 1] } else { -999 }
    $text = (@($streamed | Where-Object { $_ -isnot [int] }) | ForEach-Object { $_.ToString() }) -join "`n"
    return [pscustomobject]@{ Rc = $rc; Text = $text }
}

function Read-Text { param([string]$Path) if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path) } return $null }
function Test-Live { param($Case, [string]$Rel) Test-Path -LiteralPath (Join-Path $Case.Live ($Rel -replace '/', ([string][System.IO.Path]::DirectorySeparatorChar))) }

try {
    Write-Host ""
    Write-Host "=== test-install: self-check P015:A011 ===" -ForegroundColor Cyan

    # =======================================================================
    # (C0) source invariants
    # =======================================================================
    Write-Host "-- (C0) source invariants --" -ForegroundColor Cyan
    $src = Get-Content -LiteralPath $installPath -Raw
    # Targets destructive INVOCATIONS (not descriptive mentions in comments).
    Assert-True ($src -notmatch '&\s*robocopy')             "C0. no robocopy invocation (destructive mirror)"
    Assert-True ($src -match "sync-lib\.ps1")               "C0. dot-sources sync-lib.ps1"
    Assert-True ($src -match 'Get-DomainRelPaths')          "C0. deployment via the Get-DomainRelPaths greenlist"
    Assert-True ($src -match 'Get-SyncDomainSkill')         "C0. skills DERIVED via Get-SyncDomainSkill (no hard-coded list)"
    Assert-True ($src -match 'Copy-Tree')                   "C0. deployment via Copy-Tree (atomic per relpath)"
    Assert-True ($src -match 'Invoke-VerifyPostCheck')      "C0. verify post-check present"
    Assert-True ($src -match 'Invoke-Install')              "C0. logic wrapped in Invoke-Install (testable)"
    Assert-True ($src -match "InvocationName -ne '\.'")     "C0. auto-run guard (skipped when dot-sourced)"
    Assert-True ($src -match '\.\.\\\.\.\\claude')          "C0. default SourceRoot = ..\..\claude (the canonical ref)"
    # The historical bug referenced the embedded copy via a backslash Join-Path 'sdlc\commands\sdlc'.
    Assert-True ($src -notmatch 'sdlc\\commands\\sdlc') "C0. commands NOT from the embedded copy (Join-Path sdlc\commands\sdlc)"
    Assert-True ($src -match "'commands'\) 'sdlc'")       "C0. commands source = top-level commands/sdlc"

    # =======================================================================
    # (C1) real ref: DERIVED floors 10 / 12 / 18 (read-only, no writes)
    # =======================================================================
    Write-Host "-- (C1) derived floors on the real ref (read-only) --" -ForegroundColor Cyan
    $realRef = Join-Path (Split-Path -Parent (Split-Path -Parent $scriptsDir)) 'claude'
    if (Test-Path -LiteralPath $realRef) {
        $realSkills = @(Get-SyncDomainSkill -Root $realRef)
        $realGreen  = @(Get-DomainRelPaths -Root $realRef)
        $realCmd    = @($realGreen | Where-Object { $_ -like 'commands/sdlc/*' }).Count
        $realAgents = @($realGreen | Where-Object { $_ -like 'agents/*' }).Count
        $realCore   = @($realGreen | Where-Object { $_ -eq 'NESTOR.md' }).Count
        Assert-Eq 10 $realSkills.Count "C1. real ref: 10 sdlc* skills (derived)"
        Assert-Eq 18 $realCmd          "C1. real ref: 18 commands (derived)"
        Assert-Eq 12 $realAgents       "C1. real ref: 12 agents (sdlc-*, derived)"
        Assert-Eq 0  $realCore         "C1. real ref: 0 NESTOR.md core (outside the SDLC domain)"
    } else {
        Write-Host "  (C1 skipped: real ref not found at $realRef)" -ForegroundColor DarkYellow
    }

    # =======================================================================
    # (C2) empty live bootstrap (GIT): greenlist deployed + recursion + H3 + verify 0 drift
    # =======================================================================
    Write-Host "-- (C2) empty live bootstrap (git fixture) --" -ForegroundColor Cyan
    $k2 = New-InstallCase -Name 'c2' -Git
    $green2 = @(Get-DomainRelPaths -Root $k2.Ref)
    $r2 = Invoke-InstallCase -P @{ SourceRoot = $k2.Ref; ClaudeRoot = $k2.Live }
    Assert-Eq 0 $r2.Rc "C2. git bootstrap: exit 0 (deploys + verify post-check 0 drift)"
    Assert-True (Test-Live $k2 'skills/sdlc/SKILL.md')          "C2. root skill deployed"
    Assert-True (Test-Live $k2 'skills/sdlc-verify/SKILL.md')   "C2. sdlc-verify skill deployed"
    Assert-True (Test-Live $k2 'commands/sdlc/brainstorm.md')   "C2. top-level command deployed"
    Assert-True (Test-Live $k2 'commands/sdlc/dev.md')          "C2. top-level command deployed (2)"
    Assert-True (Test-Live $k2 'agents/sdlc-architect.md')      "C2. agent deployed"
    Assert-True (Test-Live $k2 'agents/nested/sdlc-deep.md')    "C2. RECURSIVE agent (subfolder) deployed"
    Assert-True (-not (Test-Live $k2 'skills/sdlc/commands/sdlc/decoy.md')) "C2. embedded copy (H3) NOT deployed"
    # deployed == greenlist (the decoy is outside the greenlist)
    $liveDomain2 = @(Get-DomainRelPaths -Root $k2.Live)
    Assert-Eq $green2.Count $liveDomain2.Count "C2. live domain file count == ref greenlist"
    Assert-True ($r2.Text -match '0 drift') "C2. verify post-check reports 0 drift"
    # manifest written (idempotence)
    Assert-True (Test-Path -LiteralPath (Join-Path $k2.Live 'skills/sdlc/.install-manifest.json')) "C2. .install-manifest.json manifest written"

    # =======================================================================
    # (C3) verify unavailable (NON-git): deployment done, not fatal -> exit 0
    # =======================================================================
    Write-Host "-- (C3) non-git source: verify unavailable, not fatal --" -ForegroundColor Cyan
    $k3 = New-InstallCase -Name 'c3'   # no git
    $r3 = Invoke-InstallCase -P @{ SourceRoot = $k3.Ref; ClaudeRoot = $k3.Live }
    Assert-Eq 0 $r3.Rc "C3. non-git source: exit 0 (verify unavailable is NOT fatal)"
    Assert-True (Test-Live $k3 'skills/sdlc/SKILL.md')      "C3. deployment done despite verify being unavailable"
    Assert-True (Test-Live $k3 'agents/nested/sdlc-deep.md') "C3. recursive agent deployed (non-git)"
    Assert-True ($r3.Text -match 'unavailable') "C3. 'verify unavailable' message present (distinct from drift)"

    # =======================================================================
    # (C4) idempotence: 2nd install (unchanged source) -> already up to date, no redeploy
    # =======================================================================
    Write-Host "-- (C4) idempotence (2nd install) --" -ForegroundColor Cyan
    $r4 = Invoke-InstallCase -P @{ SourceRoot = $k2.Ref; ClaudeRoot = $k2.Live }
    Assert-Eq 0 $r4.Rc "C4. 2nd install: exit 0"
    Assert-True ($r4.Text -match 'Already up to date') "C4. 2nd install: 'Already up to date' (checksum unchanged)"
    Assert-True ($r4.Text -notmatch 'deployed') "C4. 2nd install: no (re)deployment"

    # =======================================================================
    # (C5) -Force: reinstalls despite an unchanged checksum -> timestamped backup created
    # =======================================================================
    Write-Host "-- (C5) -Force reinstalls + timestamped backup --" -ForegroundColor Cyan
    $r5 = Invoke-InstallCase -P @{ SourceRoot = $k2.Ref; ClaudeRoot = $k2.Live; Force = $true }
    Assert-Eq 0 $r5.Rc "C5. -Force: exit 0 (reinstalls despite an unchanged checksum)"
    Assert-True ($r5.Text -notmatch 'Already up to date') "C5. -Force: bypasses idempotence"
    $backups5 = @(Get-ChildItem -LiteralPath (Join-Path $k2.Live '_backups') -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'SKILL.md' -or $_.Name -like '*.md' })
    Assert-True ($backups5.Count -gt 0) "C5. -Force: timestamped backup of live files before replacement"

    # =======================================================================
    # (C6) third-party skill guard: target SKILL.md not sdlc* -> ABORT exit 3
    # =======================================================================
    Write-Host "-- (C6) third-party skill guard (ABORT exit 3) --" -ForegroundColor Cyan
    $k6 = New-InstallCase -Name 'c6' -Git
    # pre-seed live: a third-party skill squats the skills/sdlc folder
    New-TextFile -Path (Join-Path $k6.Live 'skills/sdlc/SKILL.md') -Text "---`nname: evil-third-party`n---`nSQUAT`n"
    $r6 = Invoke-InstallCase -P @{ SourceRoot = $k6.Ref; ClaudeRoot = $k6.Live }
    Assert-Eq 3 $r6.Rc "C6. third-party skill -> ABORT exit 3"
    Assert-True ($r6.Text -match 'ABORT') "C6. ABORT reported"
    Assert-Eq "---`nname: evil-third-party`n---`nSQUAT`n" (Read-Text (Join-Path $k6.Live 'skills/sdlc/SKILL.md')) "C6. third-party skill NOT overwritten (live intact)"
    Assert-True (-not (Test-Live $k6 'agents/sdlc-architect.md')) "C6. no deployment (abort before writing)"

    # =======================================================================
    # (C7) -DryRun: 0 writes (no file / manifest / backup on the live side)
    # =======================================================================
    Write-Host "-- (C7) -DryRun: 0 writes --" -ForegroundColor Cyan
    $k7 = New-InstallCase -Name 'c7' -Git
    $r7 = Invoke-InstallCase -P @{ SourceRoot = $k7.Ref; ClaudeRoot = $k7.Live; DryRun = $true }
    Assert-Eq 0 $r7.Rc "C7. dry-run: exit 0"
    $dry7 = @(Get-ChildItem -LiteralPath $k7.Live -Recurse -File -ErrorAction SilentlyContinue)
    Assert-Eq 0 $dry7.Count "C7. dry-run: no file written on the live side"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $k7.Live '_backups'))) "C7. dry-run: no backup"
    Assert-True ($r7.Text -match 'DRY-RUN') "C7. dry-run reported (would-deploy list)"

    # =======================================================================
    # (C8) 8.3 short path robustness: ClaudeRoot in short form -> install normalizes
    #      to the long form, verify post-check 0 drift (regression of the absolute
    #      relPaths bug when root != Get-ChildItem.FullName).
    # =======================================================================
    Write-Host "-- (C8) 8.3 short path robustness (ClaudeRoot in short form) --" -ForegroundColor Cyan
    # $env:TEMP is often the SHORT form (C:\Users\JOHN-D~1\...) whereas GetTempPath()
    # is the long form. This case only runs when the two differ.
    $envTemp = $env:TEMP
    if ($envTemp -and ([System.IO.Path]::GetFullPath($envTemp).TrimEnd('\','/') -ne $envTemp.TrimEnd('\','/'))) {
        $k8 = New-InstallCase -Name 'c8' -Git
        # LIVE target expressed through the SHORT form of $env:TEMP (same volume as the fixture).
        $shortLive = Join-Path $envTemp ('c8live-' + [System.Guid]::NewGuid().ToString('N'))
        try {
            $r8 = Invoke-InstallCase -P @{ SourceRoot = $k8.Ref; ClaudeRoot = $shortLive }
            Assert-Eq 0 $r8.Rc "C8. short-form ClaudeRoot: exit 0 (normalized -> verify 0 drift)"
            Assert-True ($r8.Text -match '0 drift') "C8. verify post-check 0 drift despite the short path"
            Assert-True (Test-Path -LiteralPath (Join-Path $shortLive 'agents\nested\sdlc-deep.md')) "C8. actual deployment under the short path"
        }
        finally { Remove-Item -LiteralPath $shortLive -Recurse -Force -ErrorAction SilentlyContinue }
    } else {
        Write-Host "  (C8 skipped: \$env:TEMP already canonical on this machine)" -ForegroundColor DarkYellow
    }

    # =======================================================================
    # (C9) upgrade with a domain ORPHAN (extra): additive install ->
    #      NOT fatal (F6, no more wrong exit 7 "real DRIFT"). The post-check classifies
    #      extra-only as orphans ("run restore"), not as drift.
    # =======================================================================
    Write-Host "-- (C9) F6: extra orphan -> not fatal (no exit 7) --" -ForegroundColor Cyan
    $k9 = New-InstallCase -Name 'c9' -Git
    $r9a = Invoke-InstallCase -P @{ SourceRoot = $k9.Ref; ClaudeRoot = $k9.Live }
    Assert-Eq 0 $r9a.Rc "C9. initial install: exit 0"
    # Domain ORPHAN on the live side, absent from ref HEAD (leftover from a previous version).
    New-TextFile -Path (Join-Path $k9.Live 'commands/sdlc/oldcmd.md') -Text "orphan cmd`n"
    # -Force to bypass idempotence and reach the post-check of the deployment path.
    $r9b = Invoke-InstallCase -P @{ SourceRoot = $k9.Ref; ClaudeRoot = $k9.Live; Force = $true }
    Assert-Eq 0 $r9b.Rc "C9. upgrade+orphan: exit 0, NOT fatal (F6: no more exit 7)"
    Assert-True ($r9b.Text -match 'EXTRA' -or $r9b.Text -match 'orphan') "C9. orphan classified as extra (not fatal, 'run restore')"
    Assert-True (Test-Live $k9 'commands/sdlc/oldcmd.md') "C9. additive install: orphan NOT removed"
    Assert-True (Test-Path -LiteralPath (Join-Path $k9.Live 'skills/sdlc/.install-manifest.json')) "C9. manifest written despite the extra file (acceptable post-check)"

    # =======================================================================
    # (C10) SELF-REPAIR (F4): damaged live + intact manifest -> idempotence must NOT
    #       wrongly report "already up to date": verify detects the damage -> redeploy.
    # =======================================================================
    Write-Host "-- (C10) F4: self-heal of a damaged live install (intact manifest) --" -ForegroundColor Cyan
    $k10 = New-InstallCase -Name 'c10' -Git
    $r10a = Invoke-InstallCase -P @{ SourceRoot = $k10.Ref; ClaudeRoot = $k10.Live }
    Assert-Eq 0 $r10a.Rc "C10. initial install: exit 0"
    Assert-True (Test-Live $k10 'agents/nested/sdlc-deep.md') "C10. file present before damage"
    # DAMAGE: a domain file is deleted on the live side (the manifest stays intact).
    Remove-Item -LiteralPath (Join-Path $k10.Live ('agents/nested/sdlc-deep.md' -replace '/', ([string][System.IO.Path]::DirectorySeparatorChar))) -Force
    Assert-True (-not (Test-Live $k10 'agents/nested/sdlc-deep.md')) "C10. file damaged (deleted) before repair"
    # RE-INSTALL without -Force: source checksum unchanged, BUT verify sees the MISSING file -> REPAIR.
    $r10b = Invoke-InstallCase -P @{ SourceRoot = $k10.Ref; ClaudeRoot = $k10.Live }
    Assert-Eq 0 $r10b.Rc "C10. re-install: exit 0 (self-heal)"
    Assert-True ($r10b.Text -match 'REPAIR') "C10. damage detected -> REPAIR (no false 'already up to date')"
    Assert-True ($r10b.Text -notmatch 'Already up to date') "C10. F4: no 'already up to date' shortcut on a damaged live install"
    Assert-True (Test-Live $k10 'agents/nested/sdlc-deep.md') "C10. F4: file RESTORED by the self-heal"

    # =======================================================================
    # (C11) DIRTY REF (F3): deploy = working tree, verify = HEAD. A difference with an
    #       uncommitted REF tree "cannot be confirmed against HEAD", it is NOT fatal
    #       drift — and the message must not claim the difference is "expected".
    # =======================================================================
    Write-Host "-- (C11) F3: dirty ref -> integrity not confirmed (not fatal) --" -ForegroundColor Cyan
    $k11 = New-InstallCase -Name 'c11' -Git
    $r11a = Invoke-InstallCase -P @{ SourceRoot = $k11.Ref; ClaudeRoot = $k11.Live }
    Assert-Eq 0 $r11a.Rc "C11. initial install: exit 0"
    # DIRTY the REF tree: change a domain file WITHOUT committing (worktree != HEAD).
    New-TextFile -Path (Join-Path $k11.Ref 'skills/sdlc/SKILL.md') -Text "---`nname: sdlc`n---`nMODIFIED not committed`n"
    $r11b = Invoke-InstallCase -P @{ SourceRoot = $k11.Ref; ClaudeRoot = $k11.Live; Force = $true }
    Assert-Eq 0 $r11b.Rc "C11. dirty ref + verify difference: exit 0, NOT fatal (F3: no exit 7)"
    Assert-True ($r11b.Text -match 'NOT confirmed' -or $r11b.Text -match 'worktree') "C11. F3: message 'integrity NOT confirmed against HEAD' (honest, not 'expected')"

    # =======================================================================
    # (C12) FAIL-CLOSED GUARD (F2): a target SKILL.md without a readable 'name:' is
    #       treated as an unidentifiable THIRD-PARTY skill -> ABORT exit 3 (never overwritten).
    # =======================================================================
    Write-Host "-- (C12) F2: fail-closed guard on an unreadable 'name:' --" -ForegroundColor Cyan
    $k12 = New-InstallCase -Name 'c12' -Git
    New-TextFile -Path (Join-Path $k12.Live 'skills/sdlc/SKILL.md') -Text "# no name frontmatter`nopaque content`n"
    $r12 = Invoke-InstallCase -P @{ SourceRoot = $k12.Ref; ClaudeRoot = $k12.Live }
    Assert-Eq 3 $r12.Rc "C12. F2: target SKILL.md without 'name:' -> ABORT exit 3 (fail-closed)"
    Assert-True ($r12.Text -match 'unreadable' -or $r12.Text -match 'fail-closed') "C12. F2: abort reported (unidentifiable skill)"
    Assert-Eq "# no name frontmatter`nopaque content`n" (Read-Text (Join-Path $k12.Live 'skills/sdlc/SKILL.md')) "C12. F2: unidentifiable target NOT overwritten"

    # =======================================================================
    # (C13) -NoBackup (F8, non-regression): on a non-empty live tree, deploys WITHOUT
    #       creating a _backups folder.
    # =======================================================================
    Write-Host "-- (C13) F8: -Force -NoBackup -> no backup --" -ForegroundColor Cyan
    $k13 = New-InstallCase -Name 'c13' -Git
    $r13a = Invoke-InstallCase -P @{ SourceRoot = $k13.Ref; ClaudeRoot = $k13.Live }
    Assert-Eq 0 $r13a.Rc "C13. initial install: exit 0"
    $r13b = Invoke-InstallCase -P @{ SourceRoot = $k13.Ref; ClaudeRoot = $k13.Live; Force = $true; NoBackup = $true }
    Assert-Eq 0 $r13b.Rc "C13. -Force -NoBackup: exit 0"
    # -NoBackup ONLY governs the backup of DOMAIN files ('sdlc-' prefix, step 6-8 of
    # Invoke-Install) — separate from the independent Set-GenericImport backup
    # ('nestor-import-' prefix, P022/A019, never gated by -NoBackup), which can legitimately
    # appear here: r13a adds 2 markers (@NESTOR.md + @CLAUDE.local.md, P033:A029) to a freshly
    # created CLAUDE.md, and the 2nd marker finds an "existing" file (created by the 1st call
    # in the same run) -> backup outside the -NoBackup scope.
    $domainBackups13 = @(Get-ChildItem -LiteralPath (Join-Path $k13.Live '_backups') -Directory -Filter 'sdlc-*' -ErrorAction SilentlyContinue)
    Assert-Eq 0 $domainBackups13.Count "C13. F8: -NoBackup -> no DOMAIN backup folder (sdlc-*) created"
    Assert-True (Test-Live $k13 'skills/sdlc/SKILL.md') "C13. F8: deployment done despite -NoBackup"

    # =======================================================================
    # (C14) P022:A019 — no '@NESTOR.md' import in ClaudeRoot/CLAUDE.md at the end of a
    #       nominal run; -RemoveImport removes it instead of installing.
    # =======================================================================
    Write-Host "-- (C14) P022:A019: @NESTOR.md import added/removed --" -ForegroundColor Cyan
    $k14 = New-InstallCase -Name 'c14' -Git
    $claudeMd14 = Join-Path $k14.Live 'CLAUDE.md'
    $r14a = Invoke-InstallCase -P @{ SourceRoot = $k14.Ref; ClaudeRoot = $k14.Live }
    Assert-Eq 0 $r14a.Rc "C14a. nominal install: exit 0"
    Assert-True (Test-Path -LiteralPath $claudeMd14) "C14a. CLAUDE.md created at the end of a nominal run"
    $txt14a = [System.IO.File]::ReadAllText($claudeMd14)
    Assert-Eq 0 (@([regex]::Matches($txt14a, '(?m)^\s*@NESTOR\.md\s*$')).Count) "C14a. no @NESTOR.md line added (the core import is not part of this repo)"
    # CLAUDE.md NEVER enters the sync domain (greenlist), even when present.
    $domain14 = @(Get-DomainRelPaths -Root $k14.Live)
    Assert-True (-not ($domain14 -contains 'CLAUDE.md')) "C14a. CLAUDE.md OUTSIDE the sync domain (never in the greenlist)"
    # 2nd install (idempotent, unchanged checksum): does not duplicate the line.
    $r14b = Invoke-InstallCase -P @{ SourceRoot = $k14.Ref; ClaudeRoot = $k14.Live }
    Assert-Eq 0 $r14b.Rc "C14b. 2nd install (already up to date): exit 0"
    $txt14b = [System.IO.File]::ReadAllText($claudeMd14)
    Assert-Eq 0 (@([regex]::Matches($txt14b, '(?m)^\s*@NESTOR\.md\s*$')).Count) "C14b. 2nd install: still no @NESTOR.md line (idempotent)"
    # -RemoveImport: removes the line and does NOT run the rest of the installation.
    $r14c = Invoke-InstallCase -P @{ SourceRoot = $k14.Ref; ClaudeRoot = $k14.Live; RemoveImport = $true }
    Assert-Eq 0 $r14c.Rc "C14c. -RemoveImport: exit 0"
    $txt14c = [System.IO.File]::ReadAllText($claudeMd14)
    Assert-Eq 0 (@([regex]::Matches($txt14c, '(?m)^\s*@NESTOR\.md\s*$')).Count) "C14c. -RemoveImport: line removed"
    # -DryRun: 0 writes to CLAUDE.md (C7 already covers the rest of the live tree).
    $k14d = New-InstallCase -Name 'c14d' -Git
    $claudeMd14d = Join-Path $k14d.Live 'CLAUDE.md'
    $r14d = Invoke-InstallCase -P @{ SourceRoot = $k14d.Ref; ClaudeRoot = $k14d.Live; DryRun = $true }
    Assert-Eq 0 $r14d.Rc "C14d. -DryRun: exit 0"
    Assert-True (-not (Test-Path -LiteralPath $claudeMd14d)) "C14d. -DryRun: CLAUDE.md NOT created"

    # =======================================================================
    # (C15) P033:A029 — install calls Set-LocalOverlayImport in addition to Set-NestorImport:
    #       CLAUDE.local.md created (empty) on an empty live tree, idempotent on the 2nd run,
    #       never overwritten when it already has private content, -DryRun = 0 writes.
    # =======================================================================
    Write-Host "-- (C15) P033:A029: CLAUDE.local.md ensured by install --" -ForegroundColor Cyan
    $claudeLocal14 = Join-Path $k14.Live 'CLAUDE.local.md'
    Assert-True (Test-Path -LiteralPath $claudeLocal14 -PathType Leaf) "C15a. CLAUDE.local.md created at the end of a nominal run (empty live)"
    Assert-Eq '' ([System.IO.File]::ReadAllText($claudeLocal14)) "C15a. CLAUDE.local.md created EMPTY"
    $txt15a = [System.IO.File]::ReadAllText($claudeMd14)
    Assert-Eq 1 (@([regex]::Matches($txt15a, '(?m)^\s*@CLAUDE\.local\.md\s*$')).Count) "C15a. exactly 1 @CLAUDE.local.md line"
    $domain15 = @(Get-DomainRelPaths -Root $k14.Live)
    Assert-True (-not ($domain15 -contains 'CLAUDE.local.md')) "C15a. CLAUDE.local.md OUTSIDE the sync domain (never in the greenlist)"

    # C15b. Private content written to CLAUDE.local.md BEFORE a reinstall (-Force): never overwritten.
    New-TextFile -Path $claudeLocal14 -Text "private content`n"
    $r15b = Invoke-InstallCase -P @{ SourceRoot = $k14.Ref; ClaudeRoot = $k14.Live; Force = $true }
    Assert-Eq 0 $r15b.Rc "C15b. reinstall -Force: exit 0"
    Assert-Eq "private content`n" ([System.IO.File]::ReadAllText($claudeLocal14)) "C15b. existing NON-empty CLAUDE.local.md: never overwritten by install"
    $txt15b = [System.IO.File]::ReadAllText($claudeMd14)
    Assert-Eq 1 (@([regex]::Matches($txt15b, '(?m)^\s*@CLAUDE\.local\.md\s*$')).Count) "C15b. reinstall: still exactly 1 line (idempotent)"

    # C15c. -DryRun on an empty live tree: neither CLAUDE.md nor CLAUDE.local.md created.
    $k15c = New-InstallCase -Name 'c15c' -Git
    $claudeMd15c = Join-Path $k15c.Live 'CLAUDE.md'
    $claudeLocal15c = Join-Path $k15c.Live 'CLAUDE.local.md'
    $r15c = Invoke-InstallCase -P @{ SourceRoot = $k15c.Ref; ClaudeRoot = $k15c.Live; DryRun = $true }
    Assert-Eq 0 $r15c.Rc "C15c. -DryRun: exit 0"
    Assert-True (-not (Test-Path -LiteralPath $claudeMd15c)) "C15c. -DryRun: CLAUDE.md NOT created"
    Assert-True (-not (Test-Path -LiteralPath $claudeLocal15c)) "C15c. -DryRun: CLAUDE.local.md NOT created"

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
Write-Host "OK: install.ps1 compliant (P015:A011)." -ForegroundColor Green
exit 0
