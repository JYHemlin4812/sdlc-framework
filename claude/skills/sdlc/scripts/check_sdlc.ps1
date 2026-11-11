<#
.SYNOPSIS
    PowerShell wrapper for check_sdlc.py (SDLC AQ validator).

.DESCRIPTION
    Forces UTF-8 encoding, runs check_sdlc.py with Python, parses the output
    and returns a structured object (useful for CI/CD or pre-commit hooks).

.PARAMETER Json
    When set, prints JSON instead of the human-readable output.

.PARAMETER ProjectRoot
    Root of the project to validate. Default: current directory.

.EXAMPLE
    pwsh check_sdlc.ps1
    pwsh check_sdlc.ps1 -Json
    pwsh check_sdlc.ps1 -ProjectRoot "C:\dev\myproject"

.NOTES
    Exit codes: 0=PASS, 1=FAIL, 2=ERROR
#>

[CmdletBinding()]
param(
    [switch]$Json,
    [string]$ProjectRoot = (Get-Location).Path,
    [ValidateSet("plan", "release")][string]$Phase = "release",
    [string]$Today = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pyScript = Join-Path $scriptDir "check_sdlc.py"

if (-not (Test-Path $pyScript)) {
    if ($Json) {
        @{status="ERROR"; message="check_sdlc.py not found: $pyScript"; exitCode=2} | ConvertTo-Json -Compress
    } else {
        Write-Error "check_sdlc.py not found: $pyScript"
    }
    exit 2
}

$pythonCmd = $null
foreach ($candidate in @("python", "python3", "py")) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) {
        $pythonCmd = $candidate
        break
    }
}
if (-not $pythonCmd) {
    if ($Json) {
        @{status="ERROR"; message="Python not found in PATH"; exitCode=2} | ConvertTo-Json -Compress
    } else {
        Write-Error "Python not found in PATH"
    }
    exit 2
}

$prevLocation = Get-Location
try {
    Set-Location $ProjectRoot
    $pyArgs = @("--phase", $Phase)
    if ($Today) { $pyArgs += @("--today", $Today) }
    # Windows PowerShell 5.1 turns native stderr into error records; with "Stop" the first one
    # would abort the script before the JSON response is built (AQ-EDGE-003).
    $ErrorActionPreference = "Continue"
    $output = @(& $pythonCmd $pyScript @pyArgs 2>&1 | ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = "Stop"
    Set-Location $prevLocation
}

$skipped = ($exitCode -eq 0) -and [bool]($output | Where-Object { $_ -match '^⏭ AQ SKIPPED' })
$status = if ($skipped) { "SKIPPED" } else { switch ($exitCode) {
    0 { "PASS" }
    1 { "FAIL" }
    default { "ERROR" }
} }

$errors = @($output | Where-Object { $_ -match '^❌' })
$warnings = @($output | Where-Object { $_ -match '^⚠️' })
$message = if ($skipped) { "AQ Gate skipped: documentation_tier none, nothing checked" }
    elseif ($exitCode -eq 0) { "AQ Gate passed" }
    else { "AQ Gate failed: $($errors.Count) error(s)" }

if ($Json) {
    @{
        timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        status = $status
        exitCode = $exitCode
        message = $message
        errors = $errors
        warnings = $warnings
        projectRoot = $ProjectRoot
    } | ConvertTo-Json -Depth 4
} else {
    $output | ForEach-Object { Write-Output $_ }
}

exit $exitCode
