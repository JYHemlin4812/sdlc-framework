# Variante AVEC Codex (PowerShell) — équivalent de test-retrait-nestor-codex.sh.
# Attendus : tout passe après correction. Racines temporaires uniquement ; ~/.claude jamais touché.
$ErrorActionPreference = 'Stop'
$scriptsDir = Split-Path -Parent $PSScriptRoot
$install = Join-Path $scriptsDir 'install.ps1'
$uninstall = Join-Path $scriptsDir 'uninstall.ps1'
$lib = Join-Path $scriptsDir 'sync-lib.ps1'
$claudeRef = Join-Path (Split-Path -Parent $scriptsDir) '..\claude'
$T = Join-Path ([System.IO.Path]::GetTempPath()) ('retrait-ps-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $T -Force | Out-Null
$script:pass = 0; $script:unexpected = 0
function Report([string]$Name, [string]$Expect, [bool]$Ok) {
    $res = if ($Ok) { 'ok' } else { 'ko' }
    if (($Expect -eq 'pass' -and $Ok) -or ($Expect -eq 'FAIL' -and -not $Ok)) {
        Write-Host ("ATTENDU   {0,-4} {1}" -f $res, $Name); $script:pass++
    } else {
        Write-Host ("INATTENDU {0,-4} (attendu {1}) {2}" -f $res, $Expect, $Name); $script:unexpected++
    }
}
function New-Root([string]$R) {
    if (Test-Path -LiteralPath $R) { Remove-Item -LiteralPath $R -Recurse -Force }
    foreach ($d in 'skills\sdlc', 'commands\sdlc', 'agents\nested') { New-Item -ItemType Directory -Path (Join-Path $R $d) -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $R 'skills\sdlc\SKILL.md') -Value "---`nname: sdlc`n---" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $R 'commands\sdlc\dev.md') -Value 'x' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $R 'agents\sdlc-a.md') -Value 'a' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $R 'agents\nested\sdlc-deep.md') -Value 'deep' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $R 'NESTOR.md') -Value 'core' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $R 'agents\nestor-b.md') -Value 'other' -Encoding UTF8
    [System.IO.File]::WriteAllText((Join-Path $R 'CLAUDE.md'), "@NESTOR.md`nmes consignes`n", (New-Object System.Text.UTF8Encoding($false)))
}
function Run-Pwsh([string]$Script, [string[]]$CliArgs) {
    # Child output (stderr included) must not become a terminating error in this suite.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & pwsh -NoProfile -File $Script @CliArgs 2>&1
        $rc = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Rc = $rc; Out = ($out | Out-String) }
}

# T1 (pass) : aucune mention de Nestor hors tests
$hitsOut = @(Get-ChildItem -LiteralPath $scriptsDir -Recurse -File | Where-Object { $_.FullName -notmatch '\\tests\\' } | Select-String -Pattern 'nestor' -SimpleMatch)
Report 'T1 aucune mention de Nestor hors tests' pass ($hitsOut.Count -eq 0)

# T2 (pass) : aucune mention de Nestor dans les AUTRES tests
$hitsTests = @(Get-ChildItem -LiteralPath (Join-Path $scriptsDir 'tests') -File | Where-Object { $_.Name -notlike 'test-retrait-nestor*' } | Select-String -Pattern 'nestor' -SimpleMatch)
Report 'T2 aucune mention de Nestor dans les autres tests' pass ($hitsTests.Count -eq 0)

# T3 (pass) : -RemoveImport refusé par le parseur (paramètre inconnu)
$r3 = Join-Path $T 'r3'; New-Root $r3
$o3 = Run-Pwsh $install @('-ClaudeRoot', $r3, '-RemoveImport')
Report 'T3 install.ps1 : -RemoveImport refusé (code != 0)' pass ($o3.Rc -ne 0)

# T4 (pass) : -RemoveCore : rc 0, NESTOR.md, agent nestor-* et CLAUDE.md intacts (octets)
$r4 = Join-Path $T 'r4'; New-Root $r4
$before4 = [System.IO.File]::ReadAllBytes((Join-Path $r4 'CLAUDE.md'))
$o4 = Run-Pwsh $uninstall @('-ClaudeRoot', $r4, '-Discover', '-Force', '-RemoveCore')
$same4 = [System.Linq.Enumerable]::SequenceEqual([byte[]]$before4, [byte[]][System.IO.File]::ReadAllBytes((Join-Path $r4 'CLAUDE.md')))
Report 'T4 -RemoveCore rc0, NESTOR.md/nestor-*/CLAUDE.md intacts' pass (($o4.Rc -eq 0) -and $same4 -and (Test-Path (Join-Path $r4 'NESTOR.md')) -and (Test-Path (Join-Path $r4 'agents\nestor-b.md')))

# T5 (pass) : -RemoveCore retire agents/sdlc-a.md
$r5 = Join-Path $T 'r5'; New-Root $r5
$null = Run-Pwsh $uninstall @('-ClaudeRoot', $r5, '-Discover', '-Force', '-RemoveCore')
Report 'T5 -RemoveCore retire agents/sdlc-a.md' pass (-not (Test-Path (Join-Path $r5 'agents\sdlc-a.md')))

# Fixture à empreintes réelles (même format que install.ps1 : file_hashes)
. $lib
function New-HashedRoot([string]$R, [bool]$ModifyAfter) {
    New-Root $R
    $rels = @('skills/sdlc/SKILL.md', 'commands/sdlc/dev.md', 'agents/sdlc-a.md')
    $lines = foreach ($rel in $rels) { '    "' + $rel + '": "' + (Get-FileHashByteExact -Path (Join-Path $R ($rel -replace '/', '\'))) + '"' }
    $json = "{`n  `"version`": `"4.0`",`n  `"skills`": [`"sdlc`"],`n  `"file_hashes`": {`n" + ($lines -join ",`n") + "`n  },`n  `"checksum_sha256`": `"0`"`n}`n"
    Set-Content -LiteralPath (Join-Path $R 'skills\sdlc\.install-manifest.json') -Value $json -Encoding UTF8
    if ($ModifyAfter) { Set-Content -LiteralPath (Join-Path $R 'commands\sdlc\dev.md') -Value 'modified by hand' -Encoding UTF8 }
}

# T6 (pass, corrigé DES2-02) : fichier personnel dans skills/sdlc conservé (manifeste à empreintes)
$r6 = Join-Path $T 'r6'; New-HashedRoot $r6 $false
Set-Content -LiteralPath (Join-Path $r6 'skills\sdlc\mes-notes.md') -Value 'mes notes' -Encoding UTF8
$null = Run-Pwsh $uninstall @('-ClaudeRoot', $r6, '-Force')
Report 'T6 fichier personnel dans skills/sdlc conservé' pass (Test-Path (Join-Path $r6 'skills\sdlc\mes-notes.md'))

# T6b (pass) : fichier du bundle modifié à la main conservé (empreinte différente)
$r6b = Join-Path $T 'r6b'; New-HashedRoot $r6b $true
$null = Run-Pwsh $uninstall @('-ClaudeRoot', $r6b, '-Force')
Report 'T6b fichier du bundle modifié à la main conservé' pass (Test-Path (Join-Path $r6b 'commands\sdlc\dev.md'))

# T7 (pass, corrigé REV-07) : Write-FileAtomic vers un répertoire : erreur
$r7 = Join-Path $T 'r7'; New-Item -ItemType Directory -Path (Join-Path $r7 '.install-manifest.json') -Force | Out-Null
$threw7 = $false; try { Write-FileAtomic -Path (Join-Path $r7 '.install-manifest.json') -Content 'x' | Out-Null } catch { $threw7 = $true }
Report 'T7 Write-FileAtomic vers répertoire : erreur levée' pass $threw7

# T8 (pass) : sans manifeste ni -Discover : refus, rien supprimé
$r8 = Join-Path $T 'r8'; New-Root $r8
$o8 = Run-Pwsh $uninstall @('-ClaudeRoot', $r8, '-Force')
Report 'T8 sans manifeste ni -Discover : refus, rien supprimé' pass (($o8.Rc -ne 0) -and (Test-Path (Join-Path $r8 'skills\sdlc\SKILL.md')))

# T9 (pass, corrigé R06) : -RemoveCore retire aussi agents/nested/sdlc-deep.md
$r9 = Join-Path $T 'r9'; New-Root $r9
$null = Run-Pwsh $uninstall @('-ClaudeRoot', $r9, '-Discover', '-Force', '-RemoveCore')
Report 'T9 -RemoveCore retire agents/nested/sdlc-deep.md' pass (-not (Test-Path (Join-Path $r9 'agents\nested\sdlc-deep.md')))

# T10 (pass, corrigé REV-01) : deux fichiers homonymes (skills/sdlc/dev.md et commands/sdlc/dev.md) conservés
$r10 = Join-Path $T 'r10'; New-Root $r10
Set-Content -LiteralPath (Join-Path $r10 'skills\sdlc\dev.md') -Value 'XBYTES' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $r10 'commands\sdlc\dev.md') -Value 'YBYTES' -Encoding UTF8
$null = Run-Pwsh $uninstall @('-ClaudeRoot', $r10, '-Discover', '-Force')
$all10 = @(Get-ChildItem -LiteralPath $r10 -Recurse -File | Select-String -Pattern 'XBYTES', 'YBYTES' -SimpleMatch)
$hasX = @($all10 | Where-Object { $_.Line -match 'XBYTES' }).Count -gt 0
$hasY = @($all10 | Where-Object { $_.Line -match 'YBYTES' }).Count -gt 0
Report 'T10 sauvegarde : les deux fichiers homonymes sont conservés' pass ($hasX -and $hasY)

# T11 (pass) : dry-run install n'écrit rien (racine cible inexistante)
$r11 = Join-Path $T 'r11'
$null = Run-Pwsh $install @('-SourceRoot', $claudeRef, '-ClaudeRoot', $r11, '-DryRun')
Report 'T11 dry-run install : aucune racine créée' pass (-not (Test-Path -LiteralPath $r11))

# T12 (pass) : manifeste ancien (sans file_hashes) : avertissement avant suppression
$r12 = Join-Path $T 'r12'; New-Root $r12
Set-Content -LiteralPath (Join-Path $r12 'skills\sdlc\.install-manifest.json') -Value "{`n  `"version`": `"3.9`",`n  `"skills`": [`"sdlc`"]`n}" -Encoding UTF8
$o12 = Run-Pwsh $uninstall @('-ClaudeRoot', $r12, '-Force')
Report 'T12 manifeste sans file_hashes : avertissement affiché' pass ($o12.Out -match 'no file_hashes')

# T13 (pass) : manifeste à empreintes : aucun avertissement
$r13 = Join-Path $T 'r13'; New-HashedRoot $r13 $false
$o13 = Run-Pwsh $uninstall @('-ClaudeRoot', $r13, '-Force')
Report 'T13 manifeste à empreintes : pas d avertissement' pass ($o13.Out -notmatch 'no file_hashes')

Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`nRésumé : $($script:pass) attendus, $($script:unexpected) inattendus"
if ($script:unexpected -gt 0) { exit 1 }
