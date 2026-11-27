# Ad-hoc verification for Get-LatestMariadbUrl's archive path.
# The MariaDB REST API reports release_id as a SERIES ('13.1') while the builds
# are the keys of `releases` ('13.1.2'). archive.mariadb.org is keyed by the
# build, so a path built from the series 404s and `u` deleted MariaDB before
# discovering it (2026-11-27). This harness pins the build-based path offline.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests/harness-mariadb-url.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$path = Join-Path $repo 'phpup.ps1'

$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errs)
if ($errs.Count -gt 0) {
    $errs | ForEach-Object { Write-Host ("PARSE Line " + $_.Extent.StartLineNumber + ": " + $_.Message) }
    exit 1
}

foreach ($name in @('Get-LatestMariadbUrl')) {
    $fn = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
    }, $true) | Select-Object -First 1
    if (-not $fn) { throw "function not found: $name" }
    . ([scriptblock]::Create($fn.Extent.Text))
}

# Stubs: the script's own writers, the reachability probe and the REST client.
function Write-Info($m) { }
function Write-Ok($m)   { }
function Write-Warn($m) { }
function Write-Err($m)  { }
$script:unavailable = @()
function Test-UrlAvailable($url) {
    foreach ($bad in $script:unavailable) { if ($url -like $bad) { return $false } }
    return $true
}
function Invoke-RestRetry {
    param([string]$Uri, [int]$MaxRetries = 3, [int]$RetryDelay = 5)
    if ($Uri -match '/rest-api/mariadb/$') {
        return [pscustomobject]@{
            major_releases = @(
                [pscustomobject]@{ release_id = '13.2'; release_status = 'RC';     release_support_type = 'Rolling' }
                [pscustomobject]@{ release_id = '13.1'; release_status = 'Stable'; release_support_type = 'Rolling' }
                [pscustomobject]@{ release_id = '12.3'; release_status = 'Stable'; release_support_type = 'Long Term Support' }
            )
        }
    }
    return [pscustomobject]@{
        releases = [pscustomobject]@{
            '13.1.2' = [pscustomobject]@{ files = @([pscustomobject]@{ file_name = 'mariadb-13.1.2-winx64.zip' }) }
            '13.1.1' = [pscustomobject]@{ files = @([pscustomobject]@{ file_name = 'mariadb-13.1.1-winx64.zip' }) }
        }
    }
}
$FALLBACK_URLS = @{ MariaDB = 'https://archive.mariadb.org/mariadb-13.0.2/winx64-packages/mariadb-13.0.2-winx64.zip' }

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

Write-Host "`nArchive path uses the BUILD, not the series:"
$url = Get-LatestMariadbUrl
Assert 'newest build in the path'  $url 'https://archive.mariadb.org/mariadb-13.1.2/winx64-packages/mariadb-13.1.2-winx64.zip'
Assert 'series-only path rejected' ($url -match 'mariadb-13\.1/winx64') $false

Write-Host "`nAn unavailable build falls through to the next one:"
$script:unavailable = @('*/mariadb-13.1.2/*')
$url = Get-LatestMariadbUrl
Assert 'falls back to 13.1.1' $url 'https://archive.mariadb.org/mariadb-13.1.1/winx64-packages/mariadb-13.1.1-winx64.zip'

Write-Host ""
Write-Host "RESULT: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
