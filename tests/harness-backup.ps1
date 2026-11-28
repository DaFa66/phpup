# tests/harness-backup.ps1
# The `B` backup command on Windows: it must refuse when the database is down,
# it must write to <base>\dumps, and the dump must be version-portable — users as
# CREATE USER/GRANT, not raw mysql grant-table rows.
#
# Runs without a live MariaDB: the refusal path is driven with a stub, and the
# dump flags are asserted against the real source.
#
#   pwsh -NoProfile -ExecutionPolicy Bypass -File tests/harness-backup.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repo 'phpup.ps1'
if (-not (Test-Path $scriptPath)) { Write-Host 'ABORT: phpup.ps1 not found'; exit 2 }

$pass = 0; $fail = 0
function Assert($label, $cond) {
    if ($cond) { $script:pass++; Write-Host "  [PASS] $label" }
    else       { $script:fail++; Write-Host "  [FAIL] $label" }
}

$source = Get-Content $scriptPath -Raw

Write-Host ''
Write-Host 'Portable, not backend-specific:'
Assert 'users dumped as CREATE USER/GRANT'   ($source -match '--system=users')
Assert 'consistent snapshot of a live server' ($source -match '--single-transaction')
Assert 'routines, events and triggers kept'   (($source -match '--routines') -and ($source -match '--events') -and ($source -match '--triggers'))
Assert 'does not use --all-databases'         (-not ($source -match '--all-databases'))
Assert 'writes under the stack dumps dir'     ($source -match 'Join-Path \$BASE "dumps"')
Assert 'picks a tool version for the file name' ($source -match 'Get-MariaDbVersion')

Write-Host ''
Write-Host 'Reachable from the dashboard:'
Assert 'menu shows a B entry'   ($source -match 'Write-Host "B  Backup all databases and users"')
Assert 'b is dispatched'        ($source -match '(?m)^\s+"b"\s*\{')
Assert 'dispatch runs the backup' ($source -match 'Invoke-DatabaseBackup')

Write-Host ''
Write-Host 'Refuses when the database is not running:'

$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-DatabaseBackup' }, $true)
if ($fn.Count -ne 1) { Write-Host "  [FAIL] Invoke-DatabaseBackup found exactly once (found $($fn.Count))"; $fail++ }
else {
    . ([scriptblock]::Create($fn[0].Extent.Text))
    $BASE = Join-Path ([System.IO.Path]::GetTempPath()) ("phpup-bk-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $MARIADB_PATH = $BASE
    New-Item -ItemType Directory -Path $MARIADB_PATH -Force | Out-Null
    function Read-Host { param([string]$Prompt) return '' }
    function Write-Ok($m) { } function Write-Err($m) { $script:err = $m }
    function Write-Info($m) { } function Write-Note($m) { }
    function Test-MariaDbInstalled { return $true }
    function Test-MariaDbRunning { return $false }
    function Get-MariaDbVersion { return $null }

    $script:err = ''
    $out = Invoke-DatabaseBackup *>&1 | Out-String
    Assert 'prints the "not running" message' (($script:err + $out) -match 'MariaDB is not running')
    Assert 'writes no file' (-not (Test-Path (Join-Path $BASE 'dumps')))
    Remove-Item $BASE -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'The CLI verb:'
Assert 'backup is dispatched as a verb'   ($source -match "(?m)^\s+'backup'\s*\{")
Assert 'runs without the dashboard pause' ($source -match 'Invoke-DatabaseBackup -NoPause')
Assert 'returns a result object'          ($source -match 'param\(\[switch\]\$NoPause\)')
Assert 'lists itself in the usage text'   ($source -match 'phpup\.ps1 backup \[-Json\]')

Write-Host ''
Write-Host "RESULT: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 } else { exit 0 }
