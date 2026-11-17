# tests/harness-switch.ps1
# Ad-hoc verification harness for phpup.ps1's `switch` verb (stack handover).
# Disposable proof run, not a suite: it extracts the REAL function bodies from
# phpup.ps1 and stubs only the leaves (process table, ports, sc.exe, config
# writes), so nothing on this machine is touched.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests/harness-switch.ps1

$ErrorActionPreference = 'Stop'
$repo   = Split-Path -Parent $PSScriptRoot
$target = Join-Path $repo 'phpup.ps1'

$PASS = 0
$FAIL = 0
function ok($m)  { Write-Host "  [PASS] $m"; $script:PASS++ }
function bad($m) { Write-Host "  [FAIL] $m"; $script:FAIL++ }
function Check($cond, $m) {
    if ($cond) { ok $m } else { bad $m }
}

Write-Host ""
Write-Host "phpup switch harness - $target"
Write-Host "PowerShell $($PSVersionTable.PSVersion)"
Write-Host ""

# ---- Gate 1: parse ------------------------------------------------------
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$parseErrors)
Check ($parseErrors.Count -eq 0) "phpup.ps1 parses clean (errors: $($parseErrors.Count))"
if ($parseErrors.Count -gt 0) {
    Write-Host "RESULT: $PASS passed, $FAIL failed (aborting: parse gate failed)"
    exit 1
}

$bom = [System.IO.File]::ReadAllBytes($target)[0..2]
Check (($bom[0] -eq 0xEF) -and ($bom[1] -eq 0xBB) -and ($bom[2] -eq 0xBF)) 'phpup.ps1 still starts with a UTF-8 BOM'

# ---- Gate 2: extract the real functions --------------------------------
$wanted = @(
    'Test-ForeignStack', 'Get-ForeignStacks', 'Get-ForeignAlias', 'Set-ForeignStacks',
    'Register-ForeignStack', 'Set-ForeignHandoverState',
    'Get-PortOwnerPid', 'Get-ProcessExePath', 'Get-PortOwnerKind', 'Get-PortOwner',
    'Wait-PortState', 'Get-ServiceStartType', 'Set-ServiceStartType',
    'Get-PhpupServiceStartTypes', 'Start-ForeignStack', 'Stop-ForeignStack',
    'Switch-ToForeign', 'Switch-ToPhpup', 'Resolve-SwitchTarget',
    'New-SwitchPayload', 'Get-SwitchPortSummary', 'Save-Config'
)
$defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$loaded = @()
foreach ($def in $defs) {
    if ($wanted -contains $def.Name) {
        . ([scriptblock]::Create($def.Extent.Text))
        $loaded += $def.Name
    }
}
$missing = @($wanted | Where-Object { $loaded -notcontains $_ })
Check ($missing.Count -eq 0) "extracted $($loaded.Count)/$($wanted.Count) real function bodies (missing: $($missing -join ', '))"

# ---- Harness globals the extracted code reads --------------------------
$BASE            = 'C:\phpup'
$DEFAULT_BASE    = 'C:\phpup'
$SERVICE_APACHE  = 'phpup_Apache'
$SERVICE_MARIADB = 'phpup_MariaDB'
$script:STATUS_SCHEMA = 1

# ---- Stubbed leaves ----------------------------------------------------
$script:SCRATCH = Join-Path ([System.IO.Path]::GetTempPath()) ("phpup-switch-harness-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $script:SCRATCH
$script:NOOP = Join-Path $script:SCRATCH 'noop.ps1'
Set-Content -LiteralPath $script:NOOP -Value '# deliberately empty: stands in for a native stop/start binary'

# A stack-shaped object whose "binaries" are the no-op script, for the paths
# that invoke them directly. Stubbing Start-Process is enough for the start
# path, but Stop-ForeignStack shells out to apache/mysqladmin by path, and a
# harness must never run a real httpd.
$fakeStack = [pscustomobject]@{
    path = 'C:\xampp'; kind = 'xampp'
    apache = $script:NOOP; mariadb = $script:NOOP; mysqladmin = $script:NOOP
    php = $null; htdocs = $null; httpd_conf = $null; my_ini = $null
}

$script:PHASE            = 'before'
$script:PHPUP_PIDS       = @{ 80 = 4001; 3306 = 4002 }
$script:FOREIGN_PIDS     = @{ 80 = 5001; 3306 = 5002 }
$script:PROCS            = @()
$script:KILLED           = @()
$script:START_PROCESS    = @()
$script:SC_CALLS         = @()
$script:SC_START_TEXT    = '2   AUTO_START'
$script:SERVICES_INSTALLED = $true
$script:STOP_PHPUP_CALLED  = $false
$script:START_PHPUP_CALLED = $false
$script:CONFIG_JSON        = $null
$script:CONFIG_CANNED      = $null

Set-Item -Path function:Test-TcpPortListening -Value {
    param([int]$Port)
    if ($script:PHASE -eq 'free')      { return $false }
    if ($script:PHASE -eq 'before')    { return $true }
    if ($script:PHASE -eq 'started')   { return $true }
    if ($script:PHASE -eq 'phpup_again') { return $true }
    return $false
}

Set-Item -Path function:Get-PortOwnerPid -Value {
    param([int]$Port)
    if ($script:PHASE -eq 'before') { return $script:PHPUP_PIDS[$Port] }
    if ($script:PHASE -eq 'started' -or $script:PHASE -eq 'foreign_only') { return $script:FOREIGN_PIDS[$Port] }
    if ($script:PHASE -eq 'phpup_again') { return $script:PHPUP_PIDS[$Port] }
    return $null
}

Set-Item -Path function:Get-Process -Value {
    param([string[]]$Name, [int]$Id, $ErrorAction)
    if ($PSBoundParameters.ContainsKey('Id') -and $Id) {
        $hit = @($script:PROCS | Where-Object { $_.Id -eq $Id })
        if ($hit.Count -gt 0) { return $hit[0] }
        return $null
    }
    if ($PSBoundParameters.ContainsKey('Name') -and $Name) {
        return @($script:PROCS | Where-Object { $Name -contains $_.ProcessName })
    }
    return @()
}

Set-Item -Path function:Stop-Process -Value {
    param([int]$Id, [switch]$Force, $ErrorAction)
    $script:KILLED += $Id
    # Killing the foreign processes is what frees the ports in reality.
    $script:PHASE = 'free'
}

Set-Item -Path function:Start-Process -Value {
    param([string]$FilePath, $ArgumentList, [string]$WorkingDirectory, [string]$WindowStyle)
    $script:START_PROCESS += [pscustomobject]@{
        FilePath = $FilePath
        Args     = ($ArgumentList -join ' ')
        WorkDir  = $WorkingDirectory
    }
    if ($FilePath -like '*mysqld.exe') { $script:PHASE = 'started' }
}

Set-Item -Path function:Start-Sleep -Value { param($Seconds, $Milliseconds) }

Set-Item -Path function:Test-ServicesInstalled -Value { return $script:SERVICES_INSTALLED }
Set-Item -Path function:Get-ServicePid -Value { param([string]$ServiceName) return $null }
Set-Item -Path function:Test-CliIsAdmin -Value { return $true }
Set-Item -Path function:Stop-WebStackServices -Value {
    $script:STOP_PHPUP_CALLED = $true
    $script:PHASE = 'free'
}
Set-Item -Path function:Start-WebStackServices -Value {
    $script:START_PHPUP_CALLED = $true
    $script:PHASE = 'phpup_again'
}

Set-Item -Path function:sc.exe -Value {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ScArgs)
    $script:SC_CALLS += ,($ScArgs -join ' ')
    if ($ScArgs[0] -eq 'qc') {
        return @("SERVICE_NAME: $($ScArgs[1])", "        START_TYPE         : $($script:SC_START_TEXT)")
    }
    if ($ScArgs[0] -eq 'config') {
        $type = $ScArgs[$ScArgs.Count - 1]
        switch ($type) {
            'disabled'     { $script:SC_START_TEXT = '4   DISABLED' }
            'auto'         { $script:SC_START_TEXT = '2   AUTO_START' }
            'delayed-auto' { $script:SC_START_TEXT = '2   AUTO_START  (DELAYED)' }
            'manual'       { $script:SC_START_TEXT = '3   DEMAND_START' }
        }
        return @('[SC] ChangeServiceConfig SUCCESS')
    }
    return @()
}

Set-Item -Path function:Get-ConfigFilePath -Value { return (Join-Path $script:SCRATCH 'config.json') }
Set-Item -Path function:Write-Utf8File -Value {
    param([string]$Path, [string]$Content)
    if ($Path -like '*config.json') { $script:CONFIG_JSON = $Content }
}
Set-Item -Path function:Get-Config -Value { return $script:CONFIG_CANNED }

function Reset-Harness {
    $script:PHASE = 'before'
    $script:KILLED = @()
    $script:START_PROCESS = @()
    $script:SC_CALLS = @()
    $script:SC_START_TEXT = '2   AUTO_START'
    $script:SERVICES_INSTALLED = $true
    $script:STOP_PHPUP_CALLED = $false
    $script:START_PHPUP_CALLED = $false
    $script:CONFIG_JSON = $null
    $script:CONFIG_CANNED = $null
    $script:PROCS = @()
    # Restore every leaf the individual sections override, so one section's
    # stubs cannot leak into the next (that leak produced 4 false failures on
    # the first run).
    Set-Item -Path function:Get-PortOwnerPid -Value {
        param([int]$Port)
        if ($script:PHASE -eq 'before')      { return $script:PHPUP_PIDS[$Port] }
        if ($script:PHASE -eq 'started')     { return $script:FOREIGN_PIDS[$Port] }
        if ($script:PHASE -eq 'foreign_only') { return $script:FOREIGN_PIDS[$Port] }
        if ($script:PHASE -eq 'phpup_again') { return $script:PHPUP_PIDS[$Port] }
        return $null
    }
    Set-Item -Path function:Get-ServicePid -Value { param([string]$ServiceName) return $null }
    Set-Item -Path function:Test-TcpPortListening -Value {
        param([int]$Port)
        switch ($script:PHASE) {
            'before'       { return $true }
            'started'      { return $true }
            'foreign_only' { return $true }
            'phpup_again'  { return $true }
            default        { return $false }
        }
    }
    Set-Item -Path function:Test-CliIsAdmin -Value { return $true }
}

# ======================================================================
Write-Host ""
Write-Host "1. Foreign stack detection"
Reset-Harness
$real = Test-ForeignStack -Path 'C:\xampp'
Check ($null -ne $real) 'C:\xampp is recognised as a switchable stack'
if ($real) {
    Check ($real.kind -eq 'xampp') 'kind is xampp'
    Check ($real.apache -like '*\apache\bin\httpd.exe') 'apache binary resolved'
    Check ($real.mariadb -like '*\mysql\bin\mysqld.exe') 'mysqld binary resolved'
    Check ($real.my_ini -like '*\mysql\bin\my.ini') 'my.ini resolved'
}
Check ($null -eq (Test-ForeignStack -Path 'C:\Windows')) 'C:\Windows is refused (no apache/httpd.exe footprint)'
Check ($null -eq (Test-ForeignStack -Path 'C:\definitely-not-here')) 'a missing path is refused'
Check ((Get-ForeignAlias 'C:\xampp_v7.4.33') -eq 'xampp_v7_4_33') 'alias derived from folder name'
Check ((Get-ForeignAlias 'D:\xampp') -eq 'xampp') 'second root collapses to the same alias as the first'

# ======================================================================
Write-Host ""
Write-Host "2. Port ownership classification"
Reset-Harness
$script:PROCS = @(
    [pscustomobject]@{ Id = 4001; ProcessName = 'httpd';    ExecutablePath = 'C:\phpup\apache\bin\httpd.exe' },
    [pscustomobject]@{ Id = 4002; ProcessName = 'mariadbd'; ExecutablePath = 'C:\phpup\mariadb\bin\mariadbd.exe' },
    [pscustomobject]@{ Id = 5001; ProcessName = 'httpd';    ExecutablePath = 'C:\xampp\apache\bin\httpd.exe' },
    [pscustomobject]@{ Id = 5002; ProcessName = 'mysqld';   ExecutablePath = 'C:\xampp\mysql\bin\mysqld.exe' },
    [pscustomobject]@{ Id = 6001; ProcessName = 'httpd';    ExecutablePath = 'C:\other\nginx.exe' },
    [pscustomobject]@{ Id = 6002; ProcessName = 'mysqld';   ExecutablePath = $null }
)
Check ((Get-PortOwnerKind -Port 80 -ForeignRoot 'C:\xampp') -eq 'phpup') 'phpup-owned port 80 reads as phpup'
Set-Item -Path function:Get-PortOwnerPid -Value { param([int]$Port) return 6001 }
Check ((Get-PortOwnerKind -Port 80 -ForeignRoot 'C:\xampp') -eq 'other') 'a third-party stack reads as other'
$script:PHASE = 'free'
Check ((Get-PortOwnerKind -Port 80 -ForeignRoot 'C:\xampp') -eq 'free') 'a released port reads as free'

# service-hosted PIDs cannot be read by path when unelevated; SCM must answer
Reset-Harness
$script:PROCS = @([pscustomobject]@{ Id = 7001; ProcessName = 'httpd'; ExecutablePath = $null })
Set-Item -Path function:Get-PortOwnerPid -Value { param([int]$Port) return 7001 }
Set-Item -Path function:Get-ServicePid -Value {
    param([string]$ServiceName)
    if ($ServiceName -eq 'phpup_Apache') { return 7001 }
    return $null
}
Check ((Get-PortOwnerKind -Port 80 -ForeignRoot 'C:\xampp') -eq 'phpup') 'a service PID with an unreadable path still resolves to phpup via the SCM'
Set-Item -Path function:Get-PortOwnerPid -Value {
    param([int]$Port)
    if ($script:PHASE -eq 'before') { return $script:PHPUP_PIDS[$Port] }
    if ($script:PHASE -eq 'started' -or $script:PHASE -eq 'foreign_only') { return $script:FOREIGN_PIDS[$Port] }
    if ($script:PHASE -eq 'phpup_again') { return $script:PHPUP_PIDS[$Port] }
    return $null
}
Set-Item -Path function:Get-ServicePid -Value { param([string]$ServiceName) return $null }

# ======================================================================
Write-Host ""
Write-Host "3. Stopping a foreign stack kills only its own processes"
Reset-Harness
$script:PROCS = @(
    [pscustomobject]@{ Id = 8001; ProcessName = 'httpd';    ExecutablePath = 'C:\xampp\apache\bin\httpd.exe' },
    [pscustomobject]@{ Id = 8002; ProcessName = 'mysqld';   ExecutablePath = 'D:\other\bin\mysqld.exe' },
    [pscustomobject]@{ Id = 8003; ProcessName = 'mariadbd'; ExecutablePath = $null }
)
$stopResult = Stop-ForeignStack -Stack $fakeStack
Check ($script:KILLED.Count -eq 1) "exactly one process killed (got $($script:KILLED.Count))"
Check ($script:KILLED -contains 8001) 'the XAMPP process was killed'
Check (-not ($script:KILLED -contains 8002)) 'the decoy mysqld in D:\other survived'
Check ($stopResult.untouchable.Count -eq 1) 'the unidentifiable process was reported, not killed'
Check ($stopResult.forced -eq $true) 'the kill was flagged as forced'

# ======================================================================
Write-Host ""
Write-Host "4. Dry run changes nothing"
Reset-Harness
$script:PROCS = @(
    [pscustomobject]@{ Id = 4001; ProcessName = 'httpd';    ExecutablePath = 'C:\phpup\apache\bin\httpd.exe' },
    [pscustomobject]@{ Id = 4002; ProcessName = 'mariadbd'; ExecutablePath = 'C:\phpup\mariadb\bin\mariadbd.exe' }
)
$script:CONFIG_CANNED = [pscustomobject]@{ install_path = 'C:\phpup'; php_min_series = '7.4'; services_registered = $true }
$dry = Switch-ToForeign -Stack $fakeStack -Alias 'xampp' -DryRun
Check ($dry.code -eq 0) "dry run exits 0 (got $($dry.code))"
Check ($dry.changed -eq $false) 'dry run reports changed=false'
Check ($dry.steps.Count -ge 4) "dry run lists the plan ($($dry.steps.Count) steps)"
Check ($script:START_PROCESS.Count -eq 0) 'dry run started nothing'
Check ($script:KILLED.Count -eq 0) 'dry run killed nothing'
Check ($script:STOP_PHPUP_CALLED -eq $false) 'dry run did not stop phpup'
Check ($script:SC_CALLS.Count -eq 0) 'dry run did not touch any service start type'
Check ($script:CONFIG_JSON -eq $null) 'dry run wrote no config'

# ======================================================================
Write-Host ""
Write-Host "5. Handover to the foreign stack (stubbed leaves, real orchestration)"
Reset-Harness
$script:PROCS = @(
    [pscustomobject]@{ Id = 4001; ProcessName = 'httpd';    ExecutablePath = 'C:\phpup\apache\bin\httpd.exe' },
    [pscustomobject]@{ Id = 4002; ProcessName = 'mariadbd'; ExecutablePath = 'C:\phpup\mariadb\bin\mariadbd.exe' },
    [pscustomobject]@{ Id = 5001; ProcessName = 'httpd';    ExecutablePath = 'C:\xampp\apache\bin\httpd.exe' },
    [pscustomobject]@{ Id = 5002; ProcessName = 'mysqld';   ExecutablePath = 'C:\xampp\mysql\bin\mysqld.exe' }
)
$script:CONFIG_CANNED = [pscustomobject]@{ install_path = 'C:\phpup'; php_min_series = '7.4'; services_registered = $true; versions = [pscustomobject]@{ php = '8.6.0RC7' }; path_entries = @('C:\phpup\php'); foreign_stacks = @([pscustomobject]@{ alias = 'xampp'; path = 'C:\xampp'; kind = 'xampp' }) }
# The REAL stack object is used here on purpose: the assertions are about which
# binary gets started, so the paths must be genuine. It is safe because
# Start-Process is stubbed (nothing is launched) and this section never reaches
# Stop-ForeignStack. Every call that can shell out to a stack binary uses
# $fakeStack instead. (Learned the hard way: an earlier version passed $real to
# Switch-ToPhpup, whose Stop-ForeignStack called the real mysqladmin and shut
# down the machine's own MariaDB.)
$to = Switch-ToForeign -Stack $real -Alias 'xampp'
Check ($to.code -eq 0) "handover exits 0 (got $($to.code), error: $($to.error))"
Check ($to.changed -eq $true) 'handover reports changed=true'
Check ($script:STOP_PHPUP_CALLED -eq $true) 'phpup was stopped'
Check ($script:START_PROCESS.Count -eq 2) "exactly two processes started (got $($script:START_PROCESS.Count))"
Check (@($script:START_PROCESS | Where-Object { $_.FilePath -like '*xampp\apache\bin\httpd.exe' }).Count -eq 1) 'XAMPP Apache was started by path'
Check (@($script:START_PROCESS | Where-Object { $_.FilePath -like '*xampp\mysql\bin\mysqld.exe' }).Count -eq 1) 'XAMPP MariaDB was started by path'
Check (@($script:START_PROCESS | Where-Object { $_.Args -like '*--defaults-file=*my.ini*' }).Count -eq 1) 'mysqld was given its own my.ini'
Check (@($script:START_PROCESS | Where-Object { $_.WorkDir -like '*xampp' }).Count -ge 1) 'mysqld started with the stack root as working directory'
$disabled = @($script:SC_CALLS | Where-Object { $_ -like '*config*disabled*' })
Check ($disabled.Count -eq 2) "both phpup services set to disabled (got $($disabled.Count))"
Check ($script:CONFIG_JSON -like '*foreign_stacks*') 'the registry was written to config'
Check ($script:CONFIG_JSON -like '*saved_start*') 'the release point recorded the service start types'
Check ($script:CONFIG_JSON -like '*8.6.0RC7*') 'existing version data survived the config write'
Check ($to.warnings.Count -ge 1) 'the reboot caveat is disclosed'

# ======================================================================
Write-Host ""
Write-Host "6. Second press is idempotent"
Reset-Harness
$script:PHASE = 'foreign_only'
$script:PROCS = @(
    [pscustomobject]@{ Id = 5001; ProcessName = 'httpd';  ExecutablePath = 'C:\xampp\apache\bin\httpd.exe' },
    [pscustomobject]@{ Id = 5002; ProcessName = 'mysqld'; ExecutablePath = 'C:\xampp\mysql\bin\mysqld.exe' }
)
$again = Switch-ToForeign -Stack $fakeStack -Alias 'xampp'
Check ($again.code -eq 0) "second handover exits 0 (got $($again.code))"
Check ($again.changed -eq $false) 'second handover reports changed=false'
Check ($script:STOP_PHPUP_CALLED -eq $false) 'second handover did not stop phpup again'
Check ($script:START_PROCESS.Count -eq 0) 'second handover started nothing'

# ======================================================================
Write-Host ""
Write-Host "7. Switching back restores what the user had"
Reset-Harness
$script:PHASE = 'foreign_only'
$script:PROCS = @(
    [pscustomobject]@{ Id = 5001; ProcessName = 'httpd';  ExecutablePath = 'C:\xampp\apache\bin\httpd.exe' },
    [pscustomobject]@{ Id = 5002; ProcessName = 'mysqld'; ExecutablePath = 'C:\xampp\mysql\bin\mysqld.exe' }
)
$script:CONFIG_CANNED = [pscustomobject]@{
    install_path = 'C:\phpup'; php_min_series = '7.4'; services_registered = $true
    foreign_stacks = @([pscustomobject]@{ alias = 'xampp'; path = 'C:\xampp'; kind = 'xampp'
                                          saved_start = [pscustomobject]@{ apache = 'auto'; mariadb = 'delayed-auto' } })
}
$back = Switch-ToPhpup -Stack $fakeStack
Check ($back.code -eq 0) "switch back exits 0 (got $($back.code), error: $($back.error))"
Check ($back.changed -eq $true) 'switch back reports changed=true'
Check ($script:KILLED.Count -eq 2) "both foreign processes were stopped (got $($script:KILLED.Count))"
Check ($script:START_PHPUP_CALLED -eq $true) 'phpup was started'
$auto = @($script:SC_CALLS | Where-Object { $_ -like '*config*phpup_Apache*auto*' })
Check ($auto.Count -eq 1) 'phpup_Apache was restored to auto'
$delayed = @($script:SC_CALLS | Where-Object { $_ -like '*delayed-auto*' })
Check ($delayed.Count -eq 1) 'the delayed-auto start type was restored rather than flattened to auto'
Check ($script:CONFIG_JSON -like '*foreign_stacks*') 'the registry survived the switch back'
Check (-not ($script:CONFIG_JSON -like '*saved_start*')) 'the release point was cleared after switching back'

# ======================================================================
Write-Host ""
Write-Host "8. Save-Config never drops the registry"
Reset-Harness
$script:CONFIG_CANNED = $null
$foreign = @([ordered]@{ alias = 'xampp'; path = 'C:\xampp'; kind = 'xampp' })
Save-Config -InstallPath 'C:\phpup' -ForeignStacks $foreign -Versions ([pscustomobject]@{ php = '8.6.0RC7'; mariadb = '13.0.2' }) -PathEntries @('C:\phpup\php')
$first = $script:CONFIG_JSON
Check ($first -like '*foreign_stacks*') 'Save-Config writes the registry when given it'
$script:CONFIG_CANNED = ($first | ConvertFrom-Json)
Save-Config -InstallPath 'C:\phpup' -Versions ([pscustomobject]@{ php = '8.6.0RC7'; mariadb = '13.0.2' }) -PathEntries @('C:\phpup\php')
Check ($script:CONFIG_JSON -like '*foreign_stacks*') 'a later Save-Config without the parameter preserves the registry'
Check ($script:CONFIG_JSON -like '*13.0.2*') 'version data still survives an unrelated save'

# ======================================================================
Write-Host ""
Write-Host "9. Refusals"
Reset-Harness
$script:PHASE = 'before'
$script:PROCS = @([pscustomobject]@{ Id = 9101; ProcessName = 'httpd'; ExecutablePath = 'C:\other\nginx.exe' })
Set-Item -Path function:Get-PortOwnerPid -Value { param([int]$Port) return 9101 }
$refused = Switch-ToForeign -Stack $fakeStack -Alias 'xampp'
Check ($refused.code -eq 5) "a port held by a third party is refused with exit 5 (got $($refused.code))"
Check ($refused.error -like '*held by*') 'the refusal names the holder'
Check ($script:STOP_PHPUP_CALLED -eq $false) 'a refused handover stops nothing'

Reset-Harness
$script:PROCS = @(
    [pscustomobject]@{ Id = 4001; ProcessName = 'httpd';    ExecutablePath = 'C:\phpup\apache\bin\httpd.exe' },
    [pscustomobject]@{ Id = 4002; ProcessName = 'mariadbd'; ExecutablePath = 'C:\phpup\mariadb\bin\mariadbd.exe' }
)
Set-Item -Path function:Test-CliIsAdmin -Value { return $false }
$noAdmin = Switch-ToForeign -Stack $fakeStack -Alias 'xampp'
Check ($noAdmin.code -eq 4) "handover without admin returns 4 (got $($noAdmin.code))"
Check ($script:STOP_PHPUP_CALLED -eq $false) 'an unelevated handover stops nothing'
Set-Item -Path function:Test-CliIsAdmin -Value { return $true }

# ---- summary -----------------------------------------------------------
Remove-Item -Recurse -Force $script:SCRATCH -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "RESULT: $PASS passed, $FAIL failed"
if ($FAIL -eq 0) { Write-Host 'ALL CHECKS PASSED (ad-hoc, stubbed leaves)'; exit 0 }
Write-Host 'CHECKS FAILED'
exit $FAIL
