# tests/harness-prerelease-menu.ps1
# Ad-hoc verification for the fu menu's pre-release handling: series tagging, the
# no-op guards and variant ordering, so an installed RC7 is never mistaken for the
# 8.6.0 final. Extracts the REAL function bodies by AST and stubs only the prompt
# and the cache scan; nothing on this machine is touched.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests/harness-prerelease-menu.ps1

$ErrorActionPreference = 'Stop'
function T([string]$m) { [Console]::WriteLine($m) }

$global:OUT = @()
$global:INPUT_Q = New-Object System.Collections.Queue
function Write-Ok($m)   { $global:OUT += "[OK] $m" }
function Write-Info($m) { $global:OUT += "[..] $m" }
function Write-Warn($m) { $global:OUT += "[!!] $m" }
function Write-Err($m)  { $global:OUT += "[EE] $m" }
function Write-Host($m) { if ($null -ne $m) { $global:OUT += "$m" } }
function Read-Host([string]$Prompt) {
    if ($global:INPUT_Q.Count -eq 0) { throw "Read-Host called with empty input queue (prompt: '$Prompt')" }
    return [string]$global:INPUT_Q.Dequeue()
}
$script:Offline = $false
$script:TEST_CONFIG = $null
function Get-Config { return $script:TEST_CONFIG }

$script:SCRATCH = Join-Path $env:TEMP ("fu_pre_scratch_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $script:SCRATCH | Out-Null
$script:DOWNLOAD_CACHE = $script:SCRATCH
function CachePath([string]$file) { return Join-Path $script:SCRATCH $file }
foreach ($f in @('php-8.6.0RC7-Win32-vs18-x64.zip','php-8.6.0-Win32-vs18-x64.zip','php-8.5.13-Win32-vs17-x64.zip','php-8.4.27-Win32-vs17-x64.zip')) {
    New-Item -ItemType File -Force -Path (Join-Path $script:SCRATCH $f) | Out-Null
}

$repo = Split-Path -Parent $PSScriptRoot
$path = Join-Path $repo 'phpup.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { T ("PARSE Line " + $_.Extent.StartLineNumber + ": " + $_.Message) }
    exit 1
}
T "PARSE OK"

$want = @('Get-PhpZipLabel', 'Get-PhpPreReleaseRank', 'Get-VersionTag', 'Test-PhpIsPreRelease',
          'Show-PhpSwitchMenu', 'Show-PhpVariantSubMenu', 'Show-PhpVariantList')
$funcText = @()
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -contains $fn.Name) { $funcText += $fn.Extent.Text }
}
foreach ($n in $want) { if (-not ($funcText -match "function $([regex]::Escape($n))\b")) { throw "missing function $n" } }

$funcText += @'
function Get-PhpReleasesJson { return $script:TEST_JSON }
function Get-PhpPreReleaseBuilds { param($MinSeries) return @() }
function Resolve-PhpSeriesUrl($json, [string]$series) {
    $entry = $json.$series
    if (-not $entry -or -not $entry.version) { return $null }
    if ($entry.version -notmatch '^\d+\.\d+\.\d+$') { return $null }
    foreach ($key in @('ts-vs17-x64','ts-vs16-x64')) {
        if ($entry.$key -and $entry.$key.zip) {
            $zipPath = $entry.$key.zip.path
            return @{ Version = $entry.version; Url = "https://windows.php.net/downloads/releases/$zipPath"; File = $zipPath }
        }
    }
    return $null
}
'@
Invoke-Expression ($funcText -join "`n")

$pass = 0; $fail = 0
function Assert([bool]$cond, [string]$name) {
    if ($cond) { $script:pass++; T "  [PASS] $name" } else { $script:fail++; T "  [FAIL] $name" }
}

$script:TEST_JSON = @{
    '8.6' = @{ version = '8.6.0'; 'ts-vs17-x64' = @{ zip = @{ path = 'php-8.6.0-Win32-vs17-x64.zip' } } }
    '8.5' = @{ version = '8.5.13'; 'ts-vs17-x64' = @{ zip = @{ path = 'php-8.5.13-Win32-vs17-x64.zip' } } }
}

$cacheBoth = @(
    @{ Path = CachePath 'php-8.6.0RC7-Win32-vs18-x64.zip'; Version = '8.6.0';  Label = '8.6.0 RC7' },
    @{ Path = CachePath 'php-8.6.0-Win32-vs18-x64.zip';   Version = '8.6.0';  Label = '8.6.0' },
    @{ Path = CachePath 'php-8.5.13-Win32-vs17-x64.zip';  Version = '8.5.13'; Label = '8.5.13' }
)

T ""
T "TEST 1: RC7 installed, final cached -> tagged newer, installing it is allowed"
$global:OUT = @()
$global:INPUT_Q.Clear()
$global:INPUT_Q.Enqueue('1')   # series 8.6
$global:INPUT_Q.Enqueue('1')   # newest variant = the 8.6.0 final (stable now ranks above RC)
$r1 = Show-PhpSwitchMenu -PhpVersions $cacheBoth -Installed '8.6.0' -InstalledLabel '8.6.0 RC7'
$o1 = ($global:OUT -join "`n") -replace "`r", ''
$flat1 = $o1 -replace '\s+', ' '
T $o1
Assert ($flat1 -match '8\.6\.0 \(newer\)') 'series row tagged (newer)'
Assert ($r1 -ne $null -and $r1.Chosen) 'selecting the final is not a no-op'
Assert ($r1.Version -eq '8.6.0') 'returns the 8.6.0 final'
Assert ($o1 -notmatch 'is already installed') 'no false "already installed"'
Assert ($flat1 -match 'current: 8\.6\.0 RC7') 'row still says which build is installed'

T ""
T "TEST 2: stable installed -> unchanged behaviour (current tag, no-op)"
$global:OUT = @()
$global:INPUT_Q.Clear()
$global:INPUT_Q.Enqueue('1')
$global:INPUT_Q.Enqueue('1')
$r2 = Show-PhpSwitchMenu -PhpVersions $cacheBoth -Installed '8.6.0' -InstalledLabel '8.6.0'
$o2 = ($global:OUT -join "`n") -replace "`r", ''
$flat2 = $o2 -replace '\s+', ' '
T $o2
Assert ($flat2 -match '8\.6\.0 \(current\)') 'series row tagged (current)'
Assert ($null -eq $r2) 'selecting it is a no-op'
Assert ($o2 -match 'is already installed') 'says already installed'
Assert ($flat2 -match '8\.6\.0 RC7 \(older\)') 'the RC reads older than the final that replaced it'

T ""
T "TEST 3: RC7 installed, picking the RC7 variant is still a no-op"
$global:OUT = @()
$global:INPUT_Q.Clear()
$global:INPUT_Q.Enqueue('1')
$global:INPUT_Q.Enqueue('2')   # second variant = RC7
$r3 = Show-PhpSwitchMenu -PhpVersions $cacheBoth -Installed '8.6.0' -InstalledLabel '8.6.0 RC7'
$o3 = ($global:OUT -join "`n") -replace "`r", ''
$flat3 = $o3 -replace '\s+', ' '
T $o3
Assert ($null -eq $r3) 'RC7 selection is a no-op'
Assert ($o3 -match 'is already installed') 'says already installed for the same build'
Assert ($flat3 -match '8\.6\.0 RC7 \(current\)') 'the installed RC reads current, not newer'

T ""
T "TEST 4: regression, older patch installed (no label supplied)"
$script:TEST_JSON = @{
    '8.5' = @{ version = '8.5.13'; 'ts-vs17-x64' = @{ zip = @{ path = 'php-8.5.13-Win32-vs17-x64.zip' } } }
    '8.4' = @{ version = '8.4.27'; 'ts-vs17-x64' = @{ zip = @{ path = 'php-8.4.27-Win32-vs17-x64.zip' } } }
}
$cacheOld = @(
    @{ Path = CachePath 'php-8.5.13-Win32-vs17-x64.zip'; Version = '8.5.13'; Label = '8.5.13' },
    @{ Path = CachePath 'php-8.4.27-Win32-vs17-x64.zip'; Version = '8.4.27'; Label = '8.4.27' }
)
$global:OUT = @()
$global:INPUT_Q.Clear()
$global:INPUT_Q.Enqueue('1')
$r4 = Show-PhpSwitchMenu -PhpVersions $cacheOld -Installed '8.4.27'
$o4 = ($global:OUT -join "`n") -replace "`r", ''
$flat4 = $o4 -replace '\s+', ' '
T $o4
Assert ($r4 -ne $null -and $r4.Chosen) '8.5.13 still installable'
Assert ($r4.Version -eq '8.5.13') 'returns 8.5.13'
Assert ($flat4 -match '8\.5\.13 \(newer\)') 'tagged (newer)'

T ""
T "RESULT: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
exit 0
