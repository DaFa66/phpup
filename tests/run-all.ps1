# tests/run-all.ps1
# The Windows gate in one command: parse, encoding, then every harness.
#
#   .\tests\run-all.ps1             everything (what CI and a release run)
#   .\tests\run-all.ps1 -Quick      skip the slower switch suite
#
# The harnesses run under the SAME interpreter that runs this file, so the CI
# matrix proves both PowerShell 7 and Windows PowerShell 5.1. Exit status is 0
# only when every gate passes.

param([switch]$Quick)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$checks = 0; $failures = 0; $suites = 0; $skipped = 0
function Pass($m) { Write-Host "  [PASS] $m"; $script:checks++ }
function Fail($m) { Write-Host "  [FAIL] $m"; $script:checks++; $script:failures++ }
function Skip($m) { Write-Host "  [SKIP] $m"; $script:skipped++ }

$files = @('phpup.ps1')
$files += @(Get-ChildItem tests -Filter *.ps1 | Sort-Object Name | ForEach-Object { "tests/$($_.Name)" })

Write-Host '== syntax =='
foreach ($f in $files) {
    $tok = $null; $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $f), [ref]$tok, [ref]$errs)
    if ($errs.Count -eq 0) { Pass "parse $f" } else { Fail "parse $f ($($errs.Count) errors)" }
}

Write-Host '== encoding (the streamed installer needs a UTF-8 BOM) =='
foreach ($f in $files) {
    $b = [System.IO.File]::ReadAllBytes((Join-Path $repo $f))
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
        Pass "$f has the BOM"
    } else {
        Fail "$f is missing the UTF-8 BOM"
    }
}

$hostExe = (Get-Process -Id $PID).Path
$hostName = [System.IO.Path]::GetFileName($hostExe)
Write-Host "== harnesses ($hostName $($PSVersionTable.PSVersion)) =="

$toRun = @()
if ($Quick) { Skip 'tests/harness-switch.ps1 (-Quick)' } else { $toRun += 'tests/harness-switch.ps1' }
$toRun += 'tests/harness-prerelease.ps1'
$toRun += 'tests/harness-prerelease-menu.ps1'

foreach ($s in $toRun) {
    $suites++
    Write-Host "== $s =="
    & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo $s)
    if ($LASTEXITCODE -eq 0) { Pass "suite $s" } else { Fail "suite $s (exit $LASTEXITCODE)" }
}

Write-Host ''
Write-Host ("RESULT: {0} gates, {1} failed, {2} suites, {3} skipped" -f $checks, $failures, $suites, $skipped)
if ($failures -eq 0) { exit 0 }
exit 1
