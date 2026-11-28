# Contract checks for the hidden `restore` verb on Windows. Source-level, so it
# needs no live stack; the live behaviour is proven separately.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'phpup.ps1'
$source = [System.IO.File]::ReadAllText($script)

$pass = 0; $fail = 0
function Assert([string]$Name, [bool]$Ok) {
    if ($Ok) { $script:pass++; Write-Host "  [PASS] $Name" }
    else     { $script:fail++; Write-Host "  [FAIL] $Name" }
}

Write-Host 'The hidden restore verb:'

Assert 'is a CLI verb'                     ($source -match "(?m)^\s+'restore'\s*\{")
Assert 'takes a positional target'         ($source -match "\`$Target")
Assert 'lists when given no target'        ($source -match 'Show-RestoreList')
Assert 'refuses a target it cannot find'   ($source -match 'no dump matches')
Assert 'takes a safety copy first'         ($source -match 'Taking a safety copy before restoring')
Assert 'stops when the copy fails'         ($source -match 'could not take a safety copy')
Assert 'asks for a typed yes'              ($source -match 'Read-Host "Type yes to continue"')
Assert 'never trusts a yes-prefix'         ($source -match "\`$answer -ne 'yes'")
Assert 'tolerates pre-existing accounts'   ($source -match "'--force'")
Assert 'ignores only account collisions'   ($source -match "ERROR 1396")
Assert 'verifies the databases exist'      ($source -match 'Get-DumpDatabases' -and $source -match 'missing after restore')
Assert 'supports -DryRun'                  ($source -match 'Invoke-Restore[^\n]*-DryRun')
Assert 'emits JSON from the verb'          ($source.Contains('Write-CliJson $r.payload'))
Assert 'exit 2 for an unknown file'        ($source -match "\`$r\.code -eq 'no_such_file'\) \{ 2 \}")

# Hidden: the usage text must not advertise it.
$usage = [regex]::Match($source, "(?s)function Write-CliUsage \{.*?'@\s*\n\}").Value
Assert 'is not advertised in help'         ($usage -ne '' -and $usage -notmatch 'restore')

Write-Host ''
Write-Host "RESULT: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
