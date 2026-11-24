<#
.SYNOPSIS
    SDLC uninstaller v3.2 - removes skills + slash commands (+ agents/core
    optionally) from ~/.claude/.

.DESCRIPTION
    Reads the .install-manifest.json manifest for a precise removal.
    Always takes an automatic backup before removing (removal is irreversible).

    Without a manifest: refuses by default (the origin of the files cannot be guaranteed).
    Override: -Discover (expert mode, removes by naming convention).

    P025:A023 - -RemoveCore (additive flag, OPT-IN): on top of the default behavior
    (skills + commands/sdlc/), also removes the claude/agents/sdlc-* agents PRESENT
    IN LIVE, in the SAME backup/removal pass. CLAUDE.md is never modified. Without the flag: behavior
    STRICTLY identical to before (agents and core untouched) - non-regression.

    The agents/core scope is DERIVED from Get-DomainRelPaths (sync-lib, single
    source of the domain) - never a hard-coded list of agent names (M4).

.PARAMETER ClaudeRoot
    Claude Code root. Default: $env:USERPROFILE\.claude.

.PARAMETER Force
    Skip the interactive confirmation.

.PARAMETER Discover
    Without a manifest, allows heuristic discovery (sdlc* skills +
    commands/sdlc/). Expert mode.

.PARAMETER RemoveCore
    Also removes the sdlc-* agents present in live. CLAUDE.md is never modified.
    Default: off (non-regression).

.EXAMPLE
    pwsh ./scripts/uninstall.ps1
    pwsh ./scripts/uninstall.ps1 -Force
    pwsh ./scripts/uninstall.ps1 -Discover -Force
    pwsh ./scripts/uninstall.ps1 -RemoveCore -Force
#>

[CmdletBinding()]
param(
    [string]$ClaudeRoot = (Join-Path $env:USERPROFILE ".claude"),
    [switch]$Force,
    [switch]$Discover,
    [switch]$RemoveCore
)

# --- Shared foundation (single source A002/A004; Get-DomainRelPaths) ---
. (Join-Path $PSScriptRoot 'sync-lib.ps1')

$SKILLS_DEFAULT = @("sdlc", "sdlc-wave-orchestrator", "sdlc-lang-dispatcher", "sdlc-asvs-auditor")
$COMMANDS_NS = "sdlc"

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
    # LONG canonical form of a path (matches Get-ChildItem.FullName). See
    # install.ps1: same EXACT resolution, required to target the same CLAUDE.md
    # as -RemoveImport (install) even when ClaudeRoot is passed in 8.3 short
    # form (Windows).
    param([Parameter(Mandatory)][string]$Path)
    Set-StrictMode -Version Latest
    if (Test-Path -LiteralPath $Path) { return (Get-Item -LiteralPath $Path).FullName }
    return [System.IO.Path]::GetFullPath($Path)
}

# Removes ONLY the files that belong to the bundle (Get-DomainRelPaths, plus the install
# manifest). A personal file added in the directory is kept and reported; the directory
# is removed only if it ends up empty (T6: no more recursive delete of a whole folder).
function Get-ExpectedFileHashes {
    # path (relative to ClaudeRoot, '/') -> sha256, from the install manifest ("file_hashes").
    # $null when the manifest has no per-file record (legacy install).
    param([Parameter(Mandatory)][string]$Root)
    Set-StrictMode -Version Latest
    $mf = Join-Path $Root 'skills\sdlc\.install-manifest.json'
    if (-not (Test-Path -LiteralPath $mf)) { return $null }
    $json = Get-Content -LiteralPath $mf -Encoding UTF8 -Raw | ConvertFrom-Json
    if (-not $json.PSObject.Properties['file_hashes']) { return $null }
    $map = @{}
    foreach ($p in $json.file_hashes.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
    return $map
}

function Test-OwnedFile {
    # $true when the file may be removed: no per-file record (legacy), or its hash matches.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root, $Expected)
    Set-StrictMode -Version Latest
    if ($null -eq $Expected) { return $true }
    $rootFull = (Get-Item -LiteralPath $Root).FullName.TrimEnd('\')
    $rel = $Path.Substring($rootFull.Length + 1) -replace '\\', '/'
    if (-not $Expected.ContainsKey($rel)) { return $false }
    return ($Expected[$rel] -eq (Get-FileHashByteExact -Path $Path))
}

# Removes ONLY the files that belong to the bundle (Get-DomainRelPaths) and whose hash matches
# the manifest (file_hashes), plus the install manifest. A personal or modified file is kept
# and reported; the directory is removed only if it ends up empty (T6, T10-independent).
function Remove-OwnedTree {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Root, $Expected)
    Set-StrictMode -Version Latest
    $expected = $Expected
    $rootFull = (Get-Item -LiteralPath $Root).FullName
    $owned = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rel in @(Get-DomainRelPaths -Root $Root)) { [void]$owned.Add((Join-Path $rootFull ($rel -replace '/', '\'))) }
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force)) {
        if ($f.Name -eq '.install-manifest.json' -or ($owned.Contains($f.FullName) -and (Test-OwnedFile -Path $f.FullName -Root $Root -Expected $expected))) {
            Write-Step "rm -f $($f.FullName)"
            Remove-Item -LiteralPath $f.FullName -Force
        }
        else { Write-Warn "kept (not from the bundle, or modified): $($f.FullName)" }
    }
    Get-ChildItem -LiteralPath $Dir -Recurse -Directory -Force |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object { if (-not (Get-ChildItem -LiteralPath $_.FullName -Force)) { Remove-Item -LiteralPath $_.FullName -Force } }
    if (Test-Path -LiteralPath $Dir) {
        if (Get-ChildItem -LiteralPath $Dir -Force) { Write-Warn "kept (not empty): $Dir" }
        else { Remove-Item -LiteralPath $Dir -Force }
    }
}


function Invoke-Uninstall {
    param(
        [string]$ClaudeRoot = (Join-Path $env:USERPROFILE ".claude"),
        [switch]$Force,
        [switch]$Discover,
        [switch]$RemoveCore
    )
    Set-StrictMode -Version Latest

    Write-Header "SDLC - Uninstaller"

    $targetSkillsDir = Join-Path $ClaudeRoot "skills"
    $targetCommandsDir = Join-Path $ClaudeRoot "commands\$COMMANDS_NS"
    $manifestPath = Join-Path $targetSkillsDir "sdlc\.install-manifest.json"

    # --- 1. Read the manifest ---
    $skills = @()
    $manifestVersion = "(unknown)"
    if (Test-Path $manifestPath) {
        try {
            $manifest = Get-Content -Path $manifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
            $skills = @($manifest.skills)
            $manifestVersion = $manifest.version
            Write-Ok "Manifest found: v$manifestVersion ($($skills.Count) skills)"
        } catch {
            Write-Err "Corrupt manifest: $_"
            if (-not $Discover) { return 2 }
        }
    } else {
        if (-not $Discover) {
            Write-Err "Manifest missing: $manifestPath"
            Write-Err "Refusing to uninstall without a manifest (the origin cannot be guaranteed)."
            Write-Host "  To force heuristic discovery: -Discover -Force" -ForegroundColor Yellow
            return 2
        }
        Write-Warn "-Discover mode: heuristic search for sdlc* skills"
        $skills = $SKILLS_DEFAULT
    }

    # --- 2. List what will be removed ---
    # $backupName: FullPath -> relative name/path used for the timestamped backup.
    $toRemove = @()
    $backupName = @{}
    foreach ($skill in $skills) {
        $p = Join-Path $targetSkillsDir $skill
        if (Test-Path $p) { $toRemove += $p; $backupName[$p] = (Join-Path 'skills' $skill) }
    }
    if (Test-Path $targetCommandsDir) {
        $toRemove += $targetCommandsDir
        $backupName[$targetCommandsDir] = (Join-Path 'commands' (Split-Path -Leaf $targetCommandsDir))
    }

    # --- P025:A023: -RemoveCore - sdlc-* agents IN LIVE.
    #     Scope DERIVED from Get-DomainRelPaths (never a hard-coded list of names, M4).
    #     Backup name = full relPath (avoids any basename collision between agents
    #     in different subfolders, see the recursive get_domain_relpaths).
    if ($RemoveCore -and (Test-Path -LiteralPath $ClaudeRoot)) {
        $sep = [string][System.IO.Path]::DirectorySeparatorChar
        foreach ($rel in @(Get-DomainRelPaths -Root $ClaudeRoot)) {
            if ($rel -notlike 'agents/*' -or (Split-Path -Leaf $rel) -notlike 'sdlc-*') { continue }
            $native = $rel -replace '/', $sep
            $full = Join-Path $ClaudeRoot $native
            if ((Test-Path -LiteralPath $full) -and (-not $backupName.ContainsKey($full))) {
                $toRemove += $full
                $backupName[$full] = $native
            }
        }
    }

    if ($toRemove.Count -eq 0) {
        Write-Warn "No SDLC artifact found under $ClaudeRoot. Nothing to remove."
        return 0
    }

    # Loaded ONCE, before anything is removed: the skill folder (which holds the manifest) goes first.
    $expectedHashes = Get-ExpectedFileHashes -Root $ClaudeRoot
    if ($null -eq $expectedHashes) {
        Write-Warn "Legacy install (manifest has no file_hashes): every file in the SDLC folders will be removed, personal files included. A backup is made first."
    }

    Write-Host ""
    Write-Host "  Will be removed:" -ForegroundColor White
    foreach ($p in $toRemove) {
        Write-Host "    - $p" -ForegroundColor Gray
    }
    Write-Host ""

    # --- 3. Confirmation ---
    if (-not $Force) {
        $resp = Read-Host "  Confirm uninstall? (yes/N)"
        if ($resp -notmatch '^(oui|o|yes|y)$') {
            Write-Warn "Cancelled."
            return 0
        }
    }

    # --- 4. Automatic backup, always (removal is irreversible) ---
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupRoot = Join-Path $targetSkillsDir "_backups\sdlc-uninstall-$ts"
    Write-Step "Backup to $backupRoot"
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    foreach ($p in $toRemove) {
        $name = $backupName[$p]
        $dst = Join-Path $backupRoot $name
        $dstParent = Split-Path -Parent $dst
        if ($dstParent -and -not (Test-Path -LiteralPath $dstParent)) {
            New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
        }
        Copy-Item -Path $p -Destination $dst -Recurse -Force
    }
    Write-Ok "Backup created"

    # --- 5. Targeted removal ---
    Write-Header "Removal"
    foreach ($p in $toRemove) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            Remove-OwnedTree -Dir $p -Root $ClaudeRoot -Expected $expectedHashes
        }
        elseif (Test-OwnedFile -Path $p -Root $ClaudeRoot -Expected $expectedHashes) {
            Write-Step "rm -f $p"
            Remove-Item -LiteralPath $p -Force
        }
        else { Write-Warn "kept (modified or not from the bundle): $p" }
    }

    # --- 6. Remove commands/ if empty ---
    $commandsParent = Join-Path $ClaudeRoot "commands"
    if ((Test-Path -LiteralPath $commandsParent) -and (@(Get-ChildItem -Path $commandsParent).Count -eq 0)) {
        Write-Step "Removing empty commands/"
        Remove-Item -Path $commandsParent -Force
    }

    Write-Header "Uninstall complete"
    Write-Host "  Removed version   : $manifestVersion" -ForegroundColor White
    Write-Host "  Removed artifacts : $($toRemove.Count)" -ForegroundColor White
    Write-Host "  Backup            : $backupRoot" -ForegroundColor White
    Write-Host ""
    Write-Host "  To reinstall: pwsh `"$PSScriptRoot\install.ps1`"" -ForegroundColor Cyan
    Write-Host "  To restore the backup: copy it back manually from $backupRoot" -ForegroundColor Cyan
    Write-Host ""

    return 0
}

# --- Auto-run (script) - skipped when dot-sourced (tests) -------------------
if ($MyInvocation.InvocationName -ne '.') {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $rc = Invoke-Uninstall -ClaudeRoot $ClaudeRoot -Force:$Force -Discover:$Discover -RemoveCore:$RemoveCore
    exit $rc
}
