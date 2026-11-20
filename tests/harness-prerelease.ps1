# tests/harness-prerelease.ps1
# Ad-hoc verification for phpup.ps1's pre-release handling: Test-PhpOutdated, the
# decision behind `u` and `I`. Extracts the REAL function bodies by AST, so the
# whole script is never executed and nothing on this machine is touched.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests/harness-prerelease.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$path = Join-Path $repo 'phpup.ps1'

$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errs)
if ($errs.Count -gt 0) {
    $errs | ForEach-Object { Write-Host ("PARSE Line " + $_.Extent.StartLineNumber + ": " + $_.Message) }
    exit 1
}
Write-Host "PARSE OK"

foreach ($name in @('Test-PhpIsPreRelease', 'Test-PhpOutdated')) {
    $fn = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
    }, $true) | Select-Object -First 1
    if (-not $fn) { throw "function not found: $name" }
    . ([scriptblock]::Create($fn.Extent.Text))
}

$pass = 0; $fail = 0
function Assert([string]$label, $actual, $expected) {
    if ($actual -eq $expected) {
        $script:pass++
        Write-Host "  [PASS] $label"
    } else {
        $script:fail++
        Write-Host "  [FAIL] $label (got [$actual] expected [$expected])"
    }
}

Write-Host "`nPre-release vs the matching stable (the reported bug):"
Assert 'RC7 installed, 8.6.0 final out'   (Test-PhpOutdated '8.6.0' '8.6.0 RC7'   '8.6.0') $true
Assert 'beta1 installed, final out'       (Test-PhpOutdated '8.6.0' '8.6.0 beta1' '8.6.0') $true
Assert 'alpha3 installed, final out'      (Test-PhpOutdated '8.6.0' '8.6.0 alpha3' '8.6.0') $true

Write-Host "`nMust NOT nag when already correct:"
Assert 'stable 8.6.0 installed'           (Test-PhpOutdated '8.6.0' '8.6.0'       '8.6.0') $false
Assert 'newer branch RC, older stable'    (Test-PhpOutdated '8.7.0' '8.7.0 RC1'   '8.6.0') $false

Write-Host "`nOrdinary upgrades still work:"
Assert '8.5.13 -> 8.6.0'                  (Test-PhpOutdated '8.5.13' '8.5.13'     '8.6.0') $true
Assert '8.4.27 -> 8.6.0'                  (Test-PhpOutdated '8.4.27' '8.4.27'     '8.6.0') $true

Write-Host "`nDegenerate input stays quiet:"
Assert 'no installed version'             (Test-PhpOutdated ''       ''             '8.6.0') $false
Assert 'latest unresolved'                (Test-PhpOutdated '8.6.0'  '8.6.0 RC7'    '')      $false
Assert 'null label, equal numbers'        (Test-PhpOutdated '8.6.0'  $null          '8.6.0') $false

Write-Host ""
Write-Host "RESULT: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
exit 0
