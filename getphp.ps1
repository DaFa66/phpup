# ============================================================
#  getPHP — Windows 11 x64 Web Stack Installer & Dashboard
#  Inspired by getphp.org (Mac & Linux) — PowerShell Edition
#  Github: https://github.com/getphporg/getphp
#  Author: Simon Field (aka - DaFa)
#  License: MIT
#  Date: 2026-06-07
#  Version: 1.0.3
# ============================================================
#Requires -RunAsAdministrator

# ---- Config -------------------------------------------------
$TEMP_DOWNLOADS  = "$env:TEMP\webstack_downloads"

# ---- Colours -----------------------------------------------
function Write-Ok($msg)    { Write-Host "[  OK  ]  $msg" -ForegroundColor Green }
function Write-Err($msg)   { Write-Host "[ Error ]  $msg" -ForegroundColor Red }
function Write-Info($msg)  { Write-Host $msg -ForegroundColor Cyan }
function Write-Warn($msg)  { Write-Host $msg -ForegroundColor Yellow }
function Write-Bold($msg)  { Write-Host $msg -ForegroundColor White }

# ---- Detection Helpers -------------------------------------
function Test-ApacheInstalled  { return Test-Path "$APACHE_PATH\bin\httpd.exe" }
function Test-PhpInstalled     { return Test-Path "$PHP_PATH\php.exe" }
function Test-MariaDbInstalled { return (Test-Path "$MARIADB_PATH\bin\mysqld.exe") -or (Test-Path "$MARIADB_PATH\bin\mariadbd.exe") }
function Test-PhpMyAdminInstalled { return Test-Path "$PHPMYADMIN_PATH\index.php" }

function Get-ApacheVersion {
    if (Test-ApacheInstalled) {
        $out = & "$APACHE_PATH\bin\httpd.exe" -v 2>&1 | Out-String
        if ($out -match "Apache/([\d.]+)") { return $matches[1] }
    }
    return $null
}

function Get-PhpVersion {
    if (Test-PhpInstalled) {
        $out = & "$PHP_PATH\php.exe" -v 2>&1 | Select-Object -First 1
        if ($out -match "PHP\s+([\d.]+)") { return $matches[1] }
    }
    return $null
}

function Get-MariaDbVersion {
    if (Test-MariaDbInstalled) {
        $exe = if (Test-Path "$MARIADB_PATH\bin\mariadbd.exe") { "$MARIADB_PATH\bin\mariadbd.exe" } else { "$MARIADB_PATH\bin\mysqld.exe" }
        $out = & $exe --version 2>&1 | Out-String
        if ($out -match "([\d]+\.[\d]+\.[\d]+)") { return $matches[1] }
    }
    return $null
}

function Get-PhpMyAdminVersion {
    # phpMyAdmin stores its version in the README file (e.g. "Version 5.2.3")
    if (-not (Test-PhpMyAdminInstalled)) { return $null }
    $readme = "$PHPMYADMIN_PATH\README"
    if (Test-Path $readme) {
        $content = (Get-Content $readme -First 5 -ErrorAction SilentlyContinue) -join "`n"
        if ($content -match "Version\s+([\d.]+)") {
            return $matches[1]
        }
    }
    return "unknown"
}

function Test-ApacheRunning {
    return $null -ne (Get-Process -Name "httpd" -ErrorAction SilentlyContinue)
}

function Test-MariaDbRunning {
    return ($null -ne (Get-Process -Name "mysqld" -ErrorAction SilentlyContinue)) -or
           ($null -ne (Get-Process -Name "mariadbd" -ErrorAction SilentlyContinue))
}

function Test-StackComplete {
    return (Test-ApacheInstalled) -and (Test-PhpInstalled) -and (Test-MariaDbInstalled) -and (Test-PhpMyAdminInstalled)
}

# Extract version string from a download URL
function Get-VersionFromUrl([string]$url, [string]$component) {
    switch ($component) {
        'apache'     { if ($url -match 'httpd-([\d.]+)-\d+-') { return $matches[1] } }
        'php'        { if ($url -match 'php-([\d.]+)-Win32-')  { return $matches[1] } }
        'mariadb'    { if ($url -match 'mariadb-([\d.]+)-winx64') { return $matches[1] } }
        'phpmyadmin' { if ($url -match 'phpMyAdmin-([\d.]+)-all-languages') { return $matches[1] } }
    }
    return $null
}

# ---- Config Persistence --------------------------------------

$CONFIG_FILE = "$env:APPDATA\getphp\config.json"

function Get-Config {
    if (-not (Test-Path $CONFIG_FILE)) { return $null }
    try {
        $config = Get-Content $CONFIG_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($config.install_path) { return $config }
    }
    catch {
        # Corrupted config — treat as missing
    }
    return $null
}

function Save-Config {
    param(
        [Parameter(Mandatory=$true)]
        [string]$InstallPath,

        $Versions,

        [string[]]$PathEntries,

        [bool]$ServicesRegistered = $false
    )

    $configDir = Split-Path $CONFIG_FILE -Parent
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    }

    # Start with base structure (always fresh)
    $config = [ordered]@{
        install_path        = $InstallPath
        installed_at        = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        services_registered = $ServicesRegistered
        paths               = @{
            apache     = "$InstallPath\apache"
            php        = "$InstallPath\php"
            mariadb    = "$InstallPath\mariadb"
            www        = "$InstallPath\www"
            phpmyadmin = "$InstallPath\www\phpmyadmin"
        }
    }

    if ($Versions) {
        if ($Versions -is [hashtable]) {
            $config.versions = [PSCustomObject]$Versions
        }
        else {
            # Convert from PSCustomObject (JSON round-trip)
            $v = @{}
            foreach ($prop in $Versions.PSObject.Properties) {
                $v[$prop.Name] = $prop.Value
            }
            $config.versions = [PSCustomObject]$v
        }
    }
    if ($PathEntries) { $config.path_entries = $PathEntries }

    $config | ConvertTo-Json -Depth 4 | Out-File $CONFIG_FILE -Encoding UTF8
}

function Clear-Config {
    if (Test-Path $CONFIG_FILE) {
        Remove-Item $CONFIG_FILE -Force
    }
}

# ---- PATH Management -----------------------------------------

function Add-ToPath {
    <#
    .SYNOPSIS
    Adds PHP and MariaDB bin directories to the user PATH.
    Removes any previous webstack entries stored in config first.
    #>
    $phpBin    = "$BASE\php"
    $mariadbBin = "$BASE\mariadb\bin"

    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    $entries = if ($currentPath) { $currentPath -split ';' | Where-Object { $_ } } else { @() }

    # Remove old webstack entries (from previous install at a different path)
    $oldEntries = @()
    $savedConfig = Get-Config
    if ($savedConfig -and $savedConfig.path_entries) {
        $oldEntries = $savedConfig.path_entries
        $entries = $entries | Where-Object { $oldEntries -notcontains $_ }
    }

    # Build list of new entries to add (avoid duplicates)
    $toAdd = @()
    foreach ($p in @($phpBin, $mariadbBin)) {
        if ($entries -notcontains $p) {
            $toAdd += $p
            Write-Ok "Added to PATH: $p"
        }
    }

    if ($toAdd.Count -eq 0) {
        Write-Info "PATH entries already present"
        return @()
    }

    $newPath = (@($entries) + @($toAdd)) -join ';'
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")

    # Also update the current session
    $env:PATH = $newPath

    return $toAdd
}

function Remove-FromPath {
    <#
    .SYNOPSIS
    Removes webstack PATH entries (PHP + MariaDB bin) from the user PATH.
    #>
    $toRemove = @("$BASE\php", "$BASE\mariadb\bin")

    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if (-not $currentPath) { return }

    $entries = $currentPath -split ';' | Where-Object { $_ } | Where-Object { $toRemove -notcontains $_ }
    $newPath = $entries -join ';'

    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
    $env:PATH = $newPath

    Write-Ok "Webstack entries removed from PATH"
}

# ---- VC++ Redistributable Check ------------------------------

function Test-VcRedistInstalled {
# Checks whether Visual C++ Redistributable 14.51+ (VS 2017-2026) x64 is installed.
# Required by Apache Lounge VS18 and MariaDB 12.x.
    $minVersion = [version]"14.51.36231"

    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($path in $uninstallPaths) {
        $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match "Microsoft Visual C\+\+ .*Redistributable.*x64" }

        foreach ($item in $items) {
            if ($item.DisplayVersion) {
                try {
                    $ver = [version]$item.DisplayVersion
                    if ($ver -ge $minVersion) {
                        return $true
                    }
                }
                catch {
                    # Version string couldn't be parsed — skip this entry
                }
            }
        }
    }
    return $false
}

function Get-VcRedistVersion {
# Returns the installed VC++ Redistributable version, or $null if not found.
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $latest = [version]"0.0.0.0"
    foreach ($path in $uninstallPaths) {
        $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match "Microsoft Visual C\+\+ .*Redistributable.*x64" }
        foreach ($item in $items) {
            if ($item.DisplayVersion) {
                try {
                    $ver = [version]$item.DisplayVersion
                    if ($ver -gt $latest) { $latest = $ver }
                } catch { }
            }
        }
    }
    if ($latest -eq [version]"0.0.0.0") { return $null }
    return $latest
}

function Install-VcRedist {
# Installs or upgrades the Visual C++ Redistributable (VS 2017-2026) x64.
# Required by Apache Lounge VS18 and MariaDB 12.x — minimum version 14.51.36231.
# Uses winget (handles upgrades correctly where the direct installer skips them).
    if (Test-VcRedistInstalled) {
        Write-Ok "Visual C++ Redistributable already meets minimum version requirement"
        return
    }

    Write-Info "Installing/upgrading Visual C++ Redistributable (VS 2017-2026) x64..."

    # winget handles upgrades correctly (direct installer skips when already present)
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        $proc = Start-Process -FilePath 'winget.exe' -ArgumentList @(
            'install', '--id', 'Microsoft.VCRedist.2015+.x64',
            '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements'
        ) -Wait -PassThru -NoNewWindow

        if ($proc.ExitCode -eq 0) {
            Write-Ok "Visual C++ Redistributable installed/upgraded via winget"
            return
        }
        Write-Warn "winget exited with code $($proc.ExitCode). Trying direct download..."
    }

    # Fallback: direct download (for systems without winget)
    $installer = "$env:TEMP\vc_redist.x64.exe"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $installer
        Write-Info "Running installer (silent -- this may take a moment)..."
        $proc = Start-Process -FilePath $installer -ArgumentList "/install", "/quiet", "/norestart" -Wait -PassThru
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
            Write-Ok "Visual C++ Redistributable installed successfully"
        }
        else {
            Write-Warn "Installer exited with code $($proc.ExitCode). Install manually:"
            Write-Info "  https://aka.ms/vs/17/release/vc_redist.x64.exe"
        }
    }
    catch {
        Write-Err "Failed to download or install VC++ Redistributable: $_"
        Write-Info "Install manually: https://aka.ms/vs/17/release/vc_redist.x64.exe"
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
#  URL RESOLUTION — Latest Stable Versions
# ============================================================

function Get-LatestApacheUrl {
    Write-Info "Resolving Apache (Apache Lounge - latest VS18 x64 build)..."

    $maxRetries = 3
    $retryDelay = 5

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

            $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
            $html = Invoke-WebRequest -Uri "https://www.apachelounge.com/download/" -UseBasicParsing -Headers @{ "User-Agent" = $ua }

            $bestScore = $null
            $bestUrl   = $null

            # Match Apache Lounge download links: /download/VS##/binaries/httpd-X.Y.Z-BUILD-Win64-VS##.zip
            $pattern = 'href="(/download/VS(\d+)/binaries/httpd-([\d.]+)-(\d+)-Win64-VS\d+\.zip)"'
            $rxMatches = [regex]::Matches($html.Content, $pattern)

            foreach ($m in $rxMatches) {
                $vsVer    = [int]$m.Groups[2].Value
                $httpdVer = $m.Groups[3].Value
                $build    = [int]$m.Groups[4].Value

                # Prefer VS18 (VS2022), fall back to VS17
                $score = ($vsVer * 1000000) + ([version]$httpdVer).Major * 10000 + ([version]$httpdVer).Minor * 100 + $build

                if ($null -eq $bestScore -or $score -gt $bestScore) {
                    $bestScore = $score
                    $bestUrl   = "https://www.apachelounge.com" + $m.Groups[1].Value
                }
            }

            if ($bestUrl) {
                Write-Ok "Apache -> $bestUrl"
                return $bestUrl
            }

            throw "No Apache Lounge VS18 x64 download found"
        }
        catch {
            if ($attempt -lt $maxRetries) {
                Write-Warn "Attempt $attempt failed: $($_.Exception.Message)"
                Write-Info "  Retrying in $retryDelay seconds..."
                Start-Sleep -Seconds $retryDelay
            }
            else {
                Write-Err "Failed to resolve Apache URL after $maxRetries attempts."
                Write-Info "  Apache Lounge may be temporarily offline."
                Write-Info "  Check https://www.apachelounge.com/ or try again later."
                throw
            }
        }
    }
}

function Get-LatestPhpUrl {
    Write-Info "Resolving PHP (latest 8.x stable, thread-safe x64 - preferring VS17)..."

    $maxRetries = 3
    $retryDelay = 5

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $json = Invoke-RestMethod -Uri "https://windows.php.net/downloads/releases/releases.json"

            $latestVs17Version = $null
            $latestVs17File    = $null
            $latestVs16Version = $null
            $latestVs16File    = $null

            foreach ($key in $json.PSObject.Properties.Name) {
                $entry = $json.$key

                if (-not $entry.version) { continue }
                if ($entry.version -notmatch '^8\.\d+\.\d+$') { continue }

                # Check VS17 thread-safe x64 (newer PHP 8.5+)
                if ($entry.'ts-vs17-x64') {
                    $ver = [version]$entry.version
                    if ($null -eq $latestVs17Version -or $ver -gt $latestVs17Version) {
                        $latestVs17Version = $ver
                        $latestVs17File    = $entry.'ts-vs17-x64'.zip.path
                    }
                }

                # Check VS16 thread-safe x64 (fallback)
                if ($entry.'ts-vs16-x64') {
                    $ver = [version]$entry.version
                    if ($null -eq $latestVs16Version -or $ver -gt $latestVs16Version) {
                        $latestVs16Version = $ver
                        $latestVs16File    = $entry.'ts-vs16-x64'.zip.path
                    }
                }
            }

            # Prefer VS17, fall back to VS16
            if ($latestVs17File) {
                $url = "https://windows.php.net/downloads/releases/$latestVs17File"
                Write-Ok "PHP $latestVs17Version (VS17) -> $url"
                return $url
            }
            elseif ($latestVs16File) {
                $url = "https://windows.php.net/downloads/releases/$latestVs16File"
                Write-Ok "PHP $latestVs16Version (VS16) -> $url"
                return $url
            }

            throw "No compatible PHP 8.x TS x64 build found (VS17 or VS16)"
        }
        catch {
            if ($attempt -lt $maxRetries) {
                Write-Warn "Attempt $attempt failed: $($_.Exception.Message)"
                Write-Info "  Retrying in $retryDelay seconds..."
                Start-Sleep -Seconds $retryDelay
            }
            else {
                Write-Err "Failed to resolve PHP URL after $maxRetries attempts."
                Write-Info "  Check https://windows.php.net/ or try again later."
                throw
            }
        }
    }
}

function Get-LatestMariadbUrl {
    Write-Info "Resolving MariaDB (latest stable, Windows x64)..."

    $maxRetries = 5
    $retryDelay = 8

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

            $json = Invoke-RestMethod -Uri "https://downloads.mariadb.org/rest-api/mariadb/"

            $candidates = $json.major_releases | Where-Object { $_.release_status -eq "Stable" }

        if (-not $candidates) {
            throw "No Stable MariaDB releases found"
        }

        # Prefer Rolling, then LTS, then others; pick newest
        $best = $candidates |
            Sort-Object @{
                Expression = {
                    if ($_.release_support_type -eq "Rolling") { 2 }
                    elseif ($_.release_support_type -like "*Long Term Support*") { 1 }
                    else { 0 }
                }
            }, @{ Expression = { [version]$_.release_id } } -Descending |
            Select-Object -First 1

        $version = $best.release_id
        Write-Info "Selected MariaDB $version ($($best.release_support_type))"

        # Fetch version details
        $detail = Invoke-RestMethod -Uri "https://downloads.mariadb.org/rest-api/mariadb/$version/"

        $releaseKeys = $detail.releases.PSObject.Properties.Name |
            Sort-Object { [version]$_ } -Descending

        foreach ($key in $releaseKeys) {
            $release = $detail.releases.$key
            foreach ($file in $release.files) {
                $name = $file.file_name.ToLower()
                if ($name -like "*winx64*" -and $name -like "*.zip" -and $name -notlike "*debugsymbols*") {
                    Write-Ok "MariaDB -> $($file.file_download_url)"
                    return $file.file_download_url
                }
            }
        }

        throw "Could not resolve MariaDB Windows x64 download URL"
        }
        catch {
            if ($attempt -lt $maxRetries) {
                Write-Warn "Attempt $attempt failed: $($_.Exception.Message)"
                Write-Info "  Retrying in $retryDelay seconds..."
                Start-Sleep -Seconds $retryDelay
            }
            else {
                Write-Err "Failed to resolve MariaDB URL after $maxRetries attempts."
                Write-Info "  Check https://mariadb.org/download/ or try again later."
                throw
            }
        }
    }
}

function Get-LatestPhpMyAdminUrl {
    Write-Info "Resolving phpMyAdmin (latest stable, all-languages)..."

    $maxRetries = 3
    $retryDelay = 5

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

            $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
            $html = Invoke-WebRequest -Uri "https://www.phpmyadmin.net/downloads/" -UseBasicParsing -Headers @{ "User-Agent" = $ua }

            $bestVersion = $null
            $bestUrl     = $null

            # Match stable releases only (not snapshots)
            $pattern = 'href="(https://files\.phpmyadmin\.net/phpMyAdmin/([\d.]+)/phpMyAdmin-[\d.]+-all-languages\.zip)"'
            $rxMatches = [regex]::Matches($html.Content, $pattern)

            foreach ($m in $rxMatches) {
                $url = $m.Groups[1].Value
                $ver = $m.Groups[2].Value

                # Skip snapshots
                if ($url -match "snapshot") { continue }

                if ($null -eq $bestVersion -or [version]$ver -gt [version]$bestVersion) {
                    $bestVersion = $ver
                    $bestUrl     = $url
                }
            }

            if ($bestUrl) {
                Write-Ok "phpMyAdmin $bestVersion -> $bestUrl"
                return $bestUrl
            }

            throw "No phpMyAdmin stable download found"
        }
        catch {
            if ($attempt -lt $maxRetries) {
                Write-Warn "Attempt $attempt failed: $($_.Exception.Message)"
                Write-Info "  Retrying in $retryDelay seconds..."
                Start-Sleep -Seconds $retryDelay
            }
            else {
                Write-Err "Failed to resolve phpMyAdmin URL after $maxRetries attempts."
                Write-Info "  Check https://www.phpmyadmin.net/ or try again later."
                throw
            }
        }
    }
}

# ============================================================
#  DOWNLOAD & EXTRACT
# ============================================================

function Invoke-DownloadAndExtract($url, $dest, $label) {
    Write-Host ""
    Write-Host "Downloading $label..." -ForegroundColor Yellow
    Write-Info "  $url"

    New-Item -ItemType Directory -Force -Path $TEMP_DOWNLOADS | Out-Null
    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    $filename = [IO.Path]::GetFileName($url)
    $zipPath  = Join-Path $TEMP_DOWNLOADS $filename
    $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

    $maxRetries = 3
    $retryDelay = 5

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            if ($attempt -gt 1) {
                Write-Info "  Retry $attempt of $maxRetries..."
            }

            # MariaDB uses HTTP redirects that Invoke-WebRequest can't handle reliably.
            if ($url -like "*mariadb*") {
                $current_url = $url
                $max_redirects = 10
                $i = 0

                while ($i -lt $max_redirects) {
                    $request = [System.Net.HttpWebRequest]::Create($current_url)
                    $request.Method = "GET"
                    $request.AllowAutoRedirect = $false
                    $request.UserAgent = $ua

                    $response = $request.GetResponse()
                    $status = [int]$response.StatusCode

                    if ($status -ge 300 -and $status -lt 400) {
                        $location = $response.Headers["Location"]
                        if (-not $location) {
                            $response.Close()
                            throw "Redirect without Location header"
                        }
                        $current_url = $location
                        $response.Close()
                        $i++
                        continue
                    }

                    # Final URL reached — stream to file with progress
                    $totalBytes = $response.ContentLength
                    $stream = $null
                    $fileStream = $null
                    try {
                        $stream = $response.GetResponseStream()
                        $fileStream = [System.IO.File]::Create($zipPath)
                        $buffer = New-Object byte[] 8192
                        $bytesRead = 0
                        $totalRead = 0
                        $lastReport = 0

                        while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                            $fileStream.Write($buffer, 0, $bytesRead)
                            $totalRead += $bytesRead
                            # Report progress every 1MB to avoid flooding
                            if ($totalBytes -gt 0 -and ($totalRead - $lastReport) -ge 1048576) {
                                $pct = [int](($totalRead / $totalBytes) * 100)
                                Write-Progress -Activity "Downloading $label" -Status "$([math]::Round($totalRead/1MB,1)) MB / $([math]::Round($totalBytes/1MB,1)) MB" -PercentComplete $pct
                                $lastReport = $totalRead
                            }
                        }
                        Write-Progress -Activity "Downloading $label" -Completed
                    }
                    finally {
                        if ($fileStream) { $fileStream.Close(); $fileStream.Dispose() }
                        if ($stream)     { $stream.Close(); $stream.Dispose() }
                        $response.Close()
                    }
                    break
                }

                if ($i -ge $max_redirects) {
                    throw "Too many redirects resolving MariaDB download"
                }
            }
            else {
                # Try with progress bar first (no -UseBasicParsing), fall back if IE not available
                try {
                    Invoke-WebRequest -Uri $url -OutFile $zipPath -Headers @{ "User-Agent" = $ua }
                }
                catch [System.Management.Automation.MethodInvocationException] {
                    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -Headers @{ "User-Agent" = $ua }
                }
            }

            # Download succeeded — break out of retry loop
            break
        }
        catch {
            Write-Progress -Activity "Downloading $label" -Completed
            if ($attempt -lt $maxRetries) {
                Write-Warn "  Download attempt $attempt failed: $($_.Exception.Message)"
                Write-Info "  Retrying in $retryDelay seconds..."
                # Force cleanup of any lingering file handles before delete
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds $retryDelay
            }
            else {
                throw "Download failed for $label after $maxRetries attempts: $($_.Exception.Message)"
            }
        }
    }

    if (-not (Test-Path $zipPath)) {
        throw "Download failed - file not found: $zipPath"
    }

    Write-Info "Extracting to $dest..."
    Expand-Archive -Path $zipPath -DestinationPath $dest -Force

    # Flatten wrapper folder if present.
    # Apache Lounge = Apache24/  |  PHP = php-8.x.x-Win32-vs17-x64/
    # MariaDB = mariadb-12.x.x-winx64/  |  phpMyAdmin = phpMyAdmin-x.x.x-all-languages/
    $allItems = @(Get-ChildItem $dest -Force)
    $dirsOnly = @($allItems | Where-Object { $_ -is [System.IO.DirectoryInfo] })
    $filesOnly = @($allItems | Where-Object { $_ -is [System.IO.FileInfo] })

    # Strategy: if there's exactly one directory and no loose files, flatten it
    if ($dirsOnly.Count -eq 1 -and $filesOnly.Count -eq 0) {
        $inner = $dirsOnly[0].FullName
        Write-Info "Flattening wrapper folder: $($dirsOnly[0].Name)"
        Get-ChildItem $inner -Force | ForEach-Object {
            Move-Item $_.FullName $dest -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $inner -Recurse -Force -ErrorAction SilentlyContinue
    }
    elseif ($dirsOnly.Count -ge 1) {
        # Multiple directories or mixed files/dirs — try to find known wrapper patterns
        $knownWrappers = @('Apache24', 'php-*', 'mariadb-*', 'phpMyAdmin-*')
        foreach ($pattern in $knownWrappers) {
            $match = @($dirsOnly | Where-Object { $_.Name -like $pattern })
            if ($match.Count -eq 1) {
                $inner = $match[0].FullName
                Write-Info "Flattening wrapper folder: $($match[0].Name)"
                Get-ChildItem $inner -Force | ForEach-Object {
                    Move-Item $_.FullName $dest -Force -ErrorAction SilentlyContinue
                }
                Remove-Item $inner -Recurse -Force -ErrorAction SilentlyContinue
                break
            }
        }
    }

    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Write-Ok "$label extracted"
}

# ============================================================
#  CONFIGURATION
# ============================================================

function Invoke-ConfigureApache {
    Write-Host ""
    Write-Warn "Configuring Apache..."

    $confPath = "$APACHE_PATH\conf\httpd.conf"

    if (-not (Test-Path $confPath)) {
        Write-Err "httpd.conf not found at $confPath"
        return
    }

    # Backup original
    Copy-Item $confPath "$confPath.bak" -Force

    $conf = Get-Content $confPath -Raw

    # Normalise line endings — .NET (?m)$ only matches before \n, not \r\n
    $conf = $conf -replace "`r`n", "`n"

    $wwwUnix  = $WWW_PATH -replace '\\', '/'
    $apacheUnix = $APACHE_PATH -replace '\\', '/'

    # 1. Set ServerRoot and SRVROOT
    $newSrvRoot = "Define SRVROOT `"$apacheUnix`""
    if ($conf -match '(?m)^Define SRVROOT') {
        $conf = $conf -replace '(?m)^Define SRVROOT ".*"$', $newSrvRoot
    }
    else {
        $conf = $newSrvRoot + "`r`n" + $conf
    }

    # Also fix literal ServerRoot (some configs don't use ${SRVROOT})
    if ($conf -match '(?m)^ServerRoot\s+".*"') {
        $conf = $conf -replace '(?m)^ServerRoot\s+".*"', "ServerRoot `"$apacheUnix`""
    }
    Write-Ok "ServerRoot configured"

    # 2. Listen on port 80
    if ($conf -match '(?m)^Listen\s+\d+') {
        $conf = $conf -replace '(?m)^Listen\s+\d+', 'Listen 80'
    }
    else {
        $conf += "`r`nListen 80`r`n"
    }
    Write-Ok "Port 80 configured"

    # 2b. Set ServerName to suppress AH00558 warnings
    if ($conf -match '(?m)^#ServerName') {
        $conf = $conf -replace '(?m)^#ServerName\s+.*$', 'ServerName localhost:80'
        Write-Ok "ServerName set to localhost:80"
    }

    # 3. DocumentRoot
    $conf = $conf -replace 'DocumentRoot\s+".*"', "DocumentRoot `"$wwwUnix`""
    Write-Ok "DocumentRoot set to $WWW_PATH"

    # 4. Directory block for www
    $conf = $conf -replace '<Directory\s+".*">', "<Directory `"$wwwUnix`">"

    # 5. DirectoryIndex - PHP first
    if ($conf -match 'DirectoryIndex\s+index.html') {
        $conf = $conf -replace '(DirectoryIndex\s+)index\.html', '${1}index.php index.html'
    }
    Write-Ok "DirectoryIndex: index.php before index.html"

    # 6. Enable mod_rewrite (handle both "#LoadModule" and "# LoadModule" variants)
    $conf = $conf -replace '#\s*LoadModule rewrite_module modules/mod_rewrite\.so', 'LoadModule rewrite_module modules/mod_rewrite.so'
    Write-Ok "mod_rewrite enabled"

    # 7. AllowOverride All
    $conf = $conf -replace 'AllowOverride None', 'AllowOverride All'
    Write-Ok "AllowOverride All"

    # 7b. Ensure Options FollowSymLinks (required for mod_rewrite in .htaccess)
    # The default Apache Lounge config has this, but some variants may set Options None
    $wwwBlockStart = [regex]::Escape("<Directory `"$wwwUnix`">")
    $optionsPattern = "$wwwBlockStart[\s\S]*?Options\s+"
    if ($conf -match "$optionsPattern") {
        $conf = $conf -replace "($optionsPattern)\S+", '${1}Indexes FollowSymLinks'
        Write-Ok "Options Indexes FollowSymLinks set"
    }

    # 8. PHP integration
    $phpModuleUnix = "$($PHP_PATH -replace '\\','/')/php8apache2_4.dll"
    $phpIniUnix    = $PHP_PATH -replace '\\','/'

    if ($conf -notmatch 'php_module') {
        $phpBlock = @"

# PHP integration (getPHP)
LoadModule php_module "$phpModuleUnix"
AddHandler application/x-httpd-php .php
PHPIniDir "$phpIniUnix"
"@
        $conf += $phpBlock
    }
    Write-Ok "PHP module loaded"

    # 9. phpMyAdmin Alias
    if ($conf -notmatch 'Alias /phpmyadmin') {
        $pmaUnix = $PHPMYADMIN_PATH -replace '\\', '/'
        $pmaBlock = @"

# phpMyAdmin (getPHP)
Alias /phpmyadmin "$pmaUnix"
<Directory "$pmaUnix">
    Options Indexes FollowSymLinks MultiViews
    AllowOverride All
    Require all granted
</Directory>
"@
        $conf += $pmaBlock
    }
    Write-Ok "phpMyAdmin alias configured"

    # 10. Error/access logs in www folder
    $conf = $conf -replace 'ErrorLog\s+".*"', "ErrorLog `"$wwwUnix/error.log`""
    $conf = $conf -replace 'CustomLog\s+".*"\s+common', "CustomLog `"$wwwUnix/access.log`" common"
    Write-Ok "Log files directed to $WWW_PATH"

    Set-Content -Path $confPath -Value $conf
    Write-Ok "Apache configuration complete"
}

function Invoke-ConfigurePhp {
    Write-Host ""
    Write-Warn "Configuring PHP..."

    $iniDev = Get-ChildItem "$PHP_PATH" -Filter "php.ini-development" -ErrorAction SilentlyContinue | Select-Object -First 1
    $iniProd = Get-ChildItem "$PHP_PATH" -Filter "php.ini-production" -ErrorAction SilentlyContinue | Select-Object -First 1

    $iniSrc = if ($iniDev) { $iniDev.FullName } elseif ($iniProd) { $iniProd.FullName } else { $null }

    if (-not $iniSrc) {
        Write-Err "No php.ini-development or php.ini-production found in $PHP_PATH"
        return
    }

    $iniPath = "$PHP_PATH\php.ini"
    Copy-Item $iniSrc $iniPath -Force

    $ini = Get-Content $iniPath

    # Set extension_dir
    $extDir = "$PHP_PATH\ext"
    $ini = $ini -replace ';?\s*extension_dir\s*=\s*".*"', "extension_dir = `"$extDir`""

    # Enable essential extensions
    # Note: pdo_sqlite + sqlite3 require Invoke-FixSqliteDll to replace
    # the bundled libsqlite3.dll (VS17 builds have an incompatible version).
    $extensions = @(
        'extension=curl',
        'extension=fileinfo',
        'extension=gd',
        'extension=intl',
        'extension=mbstring',
        'extension=mysqli',
        'extension=openssl',
        'extension=pdo_mysql',
        'extension=pdo_sqlite',
        'extension=sqlite3'
    )

    foreach ($ext in $extensions) {
        $ini = $ini -replace ";$ext", $ext
    }

    # Development-friendly settings
    $ini = $ini -replace 'display_errors\s*=\s*Off', 'display_errors = On'
    $ini = $ini -replace 'display_startup_errors\s*=\s*Off', 'display_startup_errors = On'
    $ini = $ini -replace 'error_reporting\s*=\s*E_ALL & ~E_DEPRECATED & ~E_STRICT', 'error_reporting = E_ALL'

    # Enable PHP error logging to file
    $errorLogPath = "$WWW_PATH\php_errors.log"
    $errorLogPathUnix = $errorLogPath -replace '\\', '/'
    if ($ini -match ';?error_log\s*=') {
        $ini = $ini -replace ';?error_log\s*=\s*.*', "error_log = `"$errorLogPathUnix`""
    }
    Write-Ok "PHP error_log -> $errorLogPath"

    # Enable OPCache for performance
    $ini = $ini -replace ';?opcache\.enable\s*=\s*\d', 'opcache.enable=1'
    $ini = $ini -replace ';?opcache\.enable_cli\s*=\s*\d', 'opcache.enable_cli=1'
    $ini = $ini -replace ';?opcache\.memory_consumption\s*=\s*\d+', 'opcache.memory_consumption=256'
    $ini = $ini -replace ';?opcache\.interned_strings_buffer\s*=\s*\d+', 'opcache.interned_strings_buffer=16'
    $ini = $ini -replace ';?opcache\.max_accelerated_files\s*=\s*\d+', 'opcache.max_accelerated_files=20000'
    $ini = $ini -replace ';?opcache\.validate_timestamps\s*=\s*\d', 'opcache.validate_timestamps=1'
    $ini = $ini -replace ';?opcache\.revalidate_freq\s*=\s*\d+', 'opcache.revalidate_freq=2'

    # Enable JIT compilation (these directives aren't in default php.ini — append if missing)
    if ($ini -match 'opcache\.jit\s*=') {
        $ini = $ini -replace ';?opcache\.jit\s*=\s*\S+', 'opcache.jit=tracing'
    }
    else {
        $ini += "`nopcache.jit=tracing"
    }
    if ($ini -match 'opcache\.jit_buffer_size\s*=') {
        $ini = $ini -replace ';?opcache\.jit_buffer_size\s*=\s*\S+', 'opcache.jit_buffer_size=100M'
    }
    else {
        $ini += "`nopcache.jit_buffer_size=100M"
    }
    Write-Ok "OPCache enabled (256 MB, JIT tracing, production-ready)"

    Set-Content -Path $iniPath -Value $ini
    Write-Ok "PHP extensions enabled: curl, fileinfo, gd, intl, mbstring, mysqli, openssl, pdo_mysql, pdo_sqlite, sqlite3"
}

function Invoke-FixSqliteDll {
    Write-Host ""
    Write-Warn "Checking SQLite3 DLL..."

    $dllPath = "$PHP_PATH\libsqlite3.dll"

    # Scrape sqlite.org for the latest x64 DLL
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
        $html = Invoke-WebRequest "https://www.sqlite.org/download.html" -UseBasicParsing -Headers @{ "User-Agent" = $ua }

        # Find the x64 DLL zip path — sqlite.org changed their page layout.
        # The path is now embedded in a CSV line or JS call, e.g.:
        #   PRODUCT,3.53.1,2026/sqlite-dll-win-x64-3530100.zip,...
        #   d391('a11','2026/sqlite-dll-win-x64-3530100.zip');
        if ($html.Content -match 'PRODUCT,\d+\.\d+\.\d+,(\d{4}/sqlite-dll-win-x64-\d+\.zip)') {
            $zipPath = $matches[1]
            $url = "https://www.sqlite.org/$zipPath"
            $zipFile = "$TEMP_DOWNLOADS\sqlite3_dll.zip"

            Write-Info "Downloading latest SQLite3 DLL..."
            Invoke-WebRequest $url -OutFile $zipFile -UseBasicParsing -Headers @{ "User-Agent" = $ua }

            $extractDir = "$TEMP_DOWNLOADS\sqlite3_dll_extract"
            New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
            Expand-Archive $zipFile $extractDir -Force

            $srcDll = Get-ChildItem $extractDir -Filter "sqlite3.dll" -Recurse | Select-Object -First 1
            if ($srcDll) {
                Copy-Item $srcDll.FullName $dllPath -Force
                # Also copy to Apache bin — Windows DLL search starts from httpd.exe's dir
                Copy-Item $srcDll.FullName "$APACHE_PATH\bin\libsqlite3.dll" -Force
                Write-Ok "SQLite3 DLL updated (PHP root + Apache bin)"
            }
            else {
                Write-Warn "Could not find sqlite3.dll in downloaded archive - skipping"
            }

            Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
            Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Warn "Could not resolve latest SQLite3 DLL URL - skipping"
        }
    }
    catch {
        Write-Warn "SQLite3 DLL update failed ($($_.Exception.Message)) - pdo_sqlite may not load"
    }
}

function Invoke-CopyPhpDlls {
    Write-Host ""
    Write-Warn "Copying PHP dependency DLLs to Apache bin..."

    $phpDlls = @(
        'icudt77.dll',
        'icuin77.dll',
        'icuio77.dll',
        'icuuc77.dll',
        'libssh2.dll',
        'nghttp2.dll',
        'libzstd.dll',
        'libsodium.dll'
    )

    foreach ($dll in $phpDlls) {
        $src = "$PHP_PATH\$dll"
        $dst = "$APACHE_PATH\bin\$dll"
        if (Test-Path $src) {
            Copy-Item $src $dst -Force
            Write-Ok "Copied $dll"
        } else {
            Write-Warn "$dll not found in PHP root - skipping"
        }
    }
}

function Invoke-ConfigureMariaDb {
    Write-Host ""
    Write-Warn "Configuring MariaDB..."

    $dataDir = "$MARIADB_PATH\data"

    # Check if already initialised
    if (Test-Path $dataDir) {
        Write-Info "MariaDB data directory already exists - skipping initialisation"
        return
    }

    Write-Info "Initialising MariaDB data directory..."

    # Try mariadb-install-db first (MariaDB 10.5+), fall back to mysqld --initialize-insecure
    $installDb = "$MARIADB_PATH\bin\mariadb-install-db.exe"
    $mysqld    = if (Test-Path "$MARIADB_PATH\bin\mariadbd.exe") { "$MARIADB_PATH\bin\mariadbd.exe" } else { "$MARIADB_PATH\bin\mysqld.exe" }

    if (Test-Path $installDb) {
        # Newer MariaDB: use mariadb-install-db
        Write-Info "  Using mariadb-install-db..."
        & $installDb --datadir="$dataDir" --password= 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
    elseif (Test-Path $mysqld) {
        # Older / MySQL-compatible: --initialize-insecure creates root with no password
        Write-Info "  Using mysqld --initialize-insecure..."
        & $mysqld --initialize-insecure "--datadir=$dataDir" --console 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
    else {
        Write-Err "No MariaDB server executable found in $MARIADB_PATH\bin"
        Write-Err "Check that the MariaDB zip was extracted and flattened correctly."
        return
    }

    if (Test-Path $dataDir) {
        Write-Ok "MariaDB data directory initialised (root password is blank)"
    }
    else {
        Write-Err "MariaDB initialisation failed - check output above for details"
        Write-Info "Common causes: missing Visual C++ Redistributable, or permission denied."
    }
}

function Invoke-ConfigurePhpMyAdmin {
    Write-Host ""
    Write-Warn "Configuring phpMyAdmin, Test Script & System Paths..."

    $configPath = "$PHPMYADMIN_PATH\config.inc.php"

    if (Test-Path $configPath) {
        Write-Info "phpMyAdmin config already exists - skipping"
        return
    }

    # Generate a random blowfish secret
    $chars = 48..57 + 65..90 + 97..122
    $blowfishSecret = -join ($chars | Get-Random -Count 32 | ForEach-Object { [char]$_ })

    $config = @"
<?php
/* getPHP - phpMyAdmin configuration */
`$i = 1;
`$cfg['blowfish_secret'] = '$blowfishSecret';
`$cfg['Servers'][`$i]['host']          = '127.0.0.1';
`$cfg['Servers'][`$i]['port']          = '3306';
`$cfg['Servers'][`$i]['connect_type']  = 'tcp';
`$cfg['Servers'][`$i]['auth_type']     = 'config';
`$cfg['Servers'][`$i]['user']          = 'root';
`$cfg['Servers'][`$i]['password']      = '';
`$cfg['Servers'][`$i]['AllowNoPassword'] = true;
`$cfg['UploadDir'] = '';
`$cfg['SaveDir']   = '';
`$cfg['DefaultConnectionCollation'] = 'utf8mb4_general_ci';
"@

    Set-Content -Path $configPath -Value $config
    Write-Ok "phpMyAdmin configured (root / blank password)"
}

function Invoke-ConfigurePmaStorage {
# Creates the phpmyadmin config storage database and imports the schema.
# Enables bookmarks, query history, table tracking, designer, etc.
    Write-Host ""
    Write-Warn "Configuring phpMyAdmin storage..."

    # Check if already configured
    $testResult = & "$MARIADB_PATH\bin\mariadb.exe" -u root --skip-password -e "SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA='phpmyadmin' AND TABLE_NAME='pma__bookmark'" 2>&1
    if ($LASTEXITCODE -eq 0 -and $testResult -match '1') {
        Write-Ok "phpMyAdmin storage already configured — skipping"
        # Still ensure config.inc.php has the storage directives
        $configPath = "$PHPMYADMIN_PATH\config.inc.php"
        if (Test-Path $configPath) {
            $existing = Get-Content $configPath -Raw -Encoding UTF8
            if ($existing -notmatch "pmadb") {
                $storageConfig = Get-PmaStorageConfig
                Add-Content -Path $configPath -Value $storageConfig -Encoding UTF8
                Write-Ok "Storage config added to config.inc.php"
            }
        }
        return
    }

    # Find create_tables.sql
    $sqlFile = $null
    foreach ($candidate in @("$PHPMYADMIN_PATH\sql\create_tables.sql", "$PHPMYADMIN_PATH\examples\create_tables.sql")) {
        if (Test-Path $candidate) { $sqlFile = $candidate; break }
    }
    if (-not $sqlFile) {
        Write-Warn "create_tables.sql not found in phpMyAdmin. Storage features unavailable."
        return
    }

    # Create database and import schema
    Write-Info "Creating phpmyadmin storage database..."
    & "$MARIADB_PATH\bin\mariadb.exe" -u root --skip-password -e "CREATE DATABASE IF NOT EXISTS phpmyadmin" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to create phpmyadmin database"
        return
    }

    Write-Info "Importing phpMyAdmin storage schema..."
    Get-Content $sqlFile | & "$MARIADB_PATH\bin\mariadb.exe" -u root --skip-password phpmyadmin 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to import storage schema"
        return
    }

    # Append storage config to config.inc.php
    $configPath = "$PHPMYADMIN_PATH\config.inc.php"
    $storageConfig = Get-PmaStorageConfig
    Add-Content -Path $configPath -Value $storageConfig -Encoding UTF8

    Write-Ok "phpMyAdmin storage configured (bookmarks, history, designer, etc.)"
}

function Get-PmaStorageConfig {
# Returns the phpMyAdmin storage configuration block for config.inc.php
    return @"

/* phpMyAdmin configuration storage */
`$cfg['Servers'][`$i]['pmadb']           = 'phpmyadmin';
`$cfg['Servers'][`$i]['bookmarktable']   = 'pma__bookmark';
`$cfg['Servers'][`$i]['relation']        = 'pma__relation';
`$cfg['Servers'][`$i]['table_info']      = 'pma__table_info';
`$cfg['Servers'][`$i]['table_coords']    = 'pma__table_coords';
`$cfg['Servers'][`$i]['pdf_pages']       = 'pma__pdf_pages';
`$cfg['Servers'][`$i]['column_info']     = 'pma__column_info';
`$cfg['Servers'][`$i]['history']         = 'pma__history';
`$cfg['Servers'][`$i]['table_uiprefs']   = 'pma__table_uiprefs';
`$cfg['Servers'][`$i]['tracking']        = 'pma__tracking';
`$cfg['Servers'][`$i]['userconfig']      = 'pma__userconfig';
`$cfg['Servers'][`$i]['recent']          = 'pma__recent';
`$cfg['Servers'][`$i]['favorite']        = 'pma__favorite';
`$cfg['Servers'][`$i]['users']           = 'pma__users';
`$cfg['Servers'][`$i]['usergroups']      = 'pma__usergroups';
`$cfg['Servers'][`$i]['navigationhiding'] = 'pma__navigationhiding';
`$cfg['Servers'][`$i]['savedsearches']   = 'pma__savedsearches';
`$cfg['Servers'][`$i]['central_columns'] = 'pma__central_columns';
`$cfg['Servers'][`$i]['designer_settings'] = 'pma__designer_settings';
`$cfg['Servers'][`$i]['export_templates'] = 'pma__export_templates';
"@
}

# ============================================================
#  SERVICE MANAGEMENT
# ============================================================

function Start-WebStackServices {
    Write-Host ""
    Write-Warn "Starting services..."

    $apacheAsService  = Get-Service -Name $SERVICE_APACHE -ErrorAction SilentlyContinue
    $mariadbAsService = Get-Service -Name $SERVICE_MARIADB -ErrorAction SilentlyContinue

    # Apache
    if (Test-ApacheRunning) {
        Write-Info "Apache is already running"
    }
    elseif ($apacheAsService) {
        # Registered as a Windows service — use service control
        Start-Service $SERVICE_APACHE -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        if ((Get-Service $SERVICE_APACHE).Status -eq "Running") {
            Write-Ok "Apache started (Windows service)"
        }
        else {
            Write-Err "Apache service failed to start — check Windows Event Viewer"
        }
    }
    else {
        # Process mode: quick syntax check before daemonizing
        $testResult = & "$APACHE_PATH\bin\httpd.exe" -t 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Apache configuration error:"
            Write-Host $testResult -ForegroundColor DarkGray
            Write-Info "If the error mentions missing DLLs (VCRUNTIME, MSVCP, etc.),"
            Write-Info "install the Visual C++ Redistributable from:"
            Write-Info "  https://aka.ms/vs/17/release/vc_redist.x64.exe"
            return
        }

        # Remove stale pid file from previous unclean shutdown
        $pidFile = "$APACHE_PATH\logs\httpd.pid"
        if (Test-Path $pidFile) { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue }

        Start-Process -FilePath "$APACHE_PATH\bin\httpd.exe" -WindowStyle Hidden
        Start-Sleep -Seconds 2
        if (Test-ApacheRunning) {
            Write-Ok "Apache started"
        }
        else {
            Write-Err "Apache failed to start - check error.log in $WWW_PATH"
            Write-Info "Common causes: port 80 in use, missing VC++ Redistributable, or config error."
        }
    }

    # MariaDB
    if (Test-MariaDbRunning) {
        Write-Info "MariaDB is already running"
    }
    elseif ($mariadbAsService) {
        Start-Service $SERVICE_MARIADB -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        if ((Get-Service $SERVICE_MARIADB).Status -eq "Running") {
            Write-Ok "MariaDB started (Windows service, root password is blank)"
        }
        else {
            Write-Err "MariaDB service failed to start — check Windows Event Viewer"
        }
    }
    else {
        $dataDir = "$MARIADB_PATH\data"
        $mysqld  = if (Test-Path "$MARIADB_PATH\bin\mariadbd.exe") { "$MARIADB_PATH\bin\mariadbd.exe" } else { "$MARIADB_PATH\bin\mysqld.exe" }

        Start-Process -FilePath $mysqld `
            -ArgumentList "--datadir=`"$dataDir`"", "--console" `
            -WindowStyle Hidden `
            -PassThru | Out-Null

        Start-Sleep -Seconds 3
        if (Test-MariaDbRunning) {
            Write-Ok "MariaDB started (root password is blank)"
        }
        else {
            Write-Err "MariaDB failed to start - check console output"
        }
    }
}

function Stop-WebStackServices {
    Write-Host ""
    Write-Warn "Stopping services..."

    $stopped = $false

    $apacheAsService  = Get-Service -Name $SERVICE_APACHE -ErrorAction SilentlyContinue
    $mariadbAsService = Get-Service -Name $SERVICE_MARIADB -ErrorAction SilentlyContinue

    # Apache
    if ($apacheAsService -and (Get-Service $SERVICE_APACHE).Status -ne "Stopped") {
        Stop-Service $SERVICE_APACHE -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Ok "Apache service stopped"
        $stopped = $true
    }
    elseif (Test-ApacheRunning) {
        # Process mode: try graceful shutdown first, fall back to force kill
        & "$APACHE_PATH\bin\httpd.exe" -k stop 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        if (Test-ApacheRunning) {
            Get-Process -Name "httpd" -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Seconds 1
        }
        Write-Ok "Apache stopped"
        $stopped = $true
    }
    else {
        Write-Info "Apache not running"
    }

    # MariaDB
    if ($mariadbAsService -and (Get-Service $SERVICE_MARIADB).Status -ne "Stopped") {
        Stop-Service $SERVICE_MARIADB -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Ok "MariaDB service stopped"
        $stopped = $true
    }
    elseif (Test-MariaDbRunning) {
        Get-Process -Name "mysqld", "mariadbd" -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 2
        Write-Ok "MariaDB stopped"
        $stopped = $true
    }
    else {
        Write-Info "MariaDB not running"
    }

    if (-not $stopped) {
        Write-Info "No services were running"
    }
}

# ---- Windows Service Helpers ---------------------------------

$SERVICE_APACHE  = "getPHP_Apache"
$SERVICE_MARIADB = "getPHP_MariaDB"

function Test-ServicesInstalled {
    $service = Get-Service -Name $SERVICE_APACHE -ErrorAction SilentlyContinue
    return $null -ne $service
}

function Install-AsServices {
    Write-Host ""
    Write-Info "Registering Windows services (auto-start on boot)..."

    # Stop any running process-mode instances first
    Stop-WebStackServices

    # --- Apache ---
    if (Get-Service -Name $SERVICE_APACHE -ErrorAction SilentlyContinue) {
        Write-Info "$SERVICE_APACHE service already exists — skipping"
    }
    else {
        & "$APACHE_PATH\bin\httpd.exe" -k install -n $SERVICE_APACHE 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            # Set to auto-start
            Set-Service -Name $SERVICE_APACHE -StartupType Automatic -ErrorAction SilentlyContinue
            Write-Ok "$SERVICE_APACHE service installed"
        }
        else {
            Write-Err "Failed to install $SERVICE_APACHE service"
        }
    }

    # --- MariaDB ---
    if (Get-Service -Name $SERVICE_MARIADB -ErrorAction SilentlyContinue) {
        Write-Info "$SERVICE_MARIADB service already exists — skipping"
    }
    else {
        $mysqld  = if (Test-Path "$MARIADB_PATH\bin\mariadbd.exe") { "$MARIADB_PATH\bin\mariadbd.exe" } else { "$MARIADB_PATH\bin\mysqld.exe" }
        $dataDir = "$MARIADB_PATH\data"
        & $mysqld --install $SERVICE_MARIADB --datadir="$dataDir" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Set-Service -Name $SERVICE_MARIADB -StartupType Automatic -ErrorAction SilentlyContinue
            Write-Ok "$SERVICE_MARIADB service installed"
        }
        else {
            Write-Err "Failed to install $SERVICE_MARIADB service"
        }
    }

    # Start services
    Start-Sleep -Seconds 1
    Start-WebStackServices
}

function Request-ServiceRegistration {
    if (Test-ServicesInstalled) { return }

    Write-Host ""
    Write-Warn "Services are not registered as Windows services."
    Write-Info "  Without service registration, Apache and MariaDB won't auto-start on boot."
    Write-Info "  You'll need to run this script and press 'T' after every reboot."

    $choice = Read-Host "Register as Windows services now? [y/N]"
    if ($choice -match "^[Yy]") {
        Write-Info "Registering Windows services..."

        if (-not (Get-Service -Name $SERVICE_APACHE -ErrorAction SilentlyContinue)) {
            & "$APACHE_PATH\bin\httpd.exe" -k install -n $SERVICE_APACHE 2>&1 | Out-Null
            Set-Service -Name $SERVICE_APACHE -StartupType Automatic -ErrorAction SilentlyContinue
            Write-Ok "$SERVICE_APACHE service installed"
        }

        if (-not (Get-Service -Name $SERVICE_MARIADB -ErrorAction SilentlyContinue)) {
            $mysqld = if (Test-Path "$MARIADB_PATH\bin\mariadbd.exe") { "$MARIADB_PATH\bin\mariadbd.exe" } else { "$MARIADB_PATH\bin\mysqld.exe" }
            $dataDir = "$MARIADB_PATH\data"
            & $mysqld --install $SERVICE_MARIADB --datadir="$dataDir" 2>&1 | Out-Null
            Set-Service -Name $SERVICE_MARIADB -StartupType Automatic -ErrorAction SilentlyContinue
            Write-Ok "$SERVICE_MARIADB service installed"
        }

        # Update config to reflect registered services
        Save-Config -InstallPath $BASE -ServicesRegistered:$true
    }
}

function Remove-Services {
    Write-Host ""
    Write-Info "Removing Windows services..."

    # Stop only the services that are actually running (avoid duplicate banner)
    $apacheSvc  = Get-Service -Name $SERVICE_APACHE -ErrorAction SilentlyContinue
    $mariadbSvc = Get-Service -Name $SERVICE_MARIADB -ErrorAction SilentlyContinue

    if ($apacheSvc -and $apacheSvc.Status -ne "Stopped") {
        Stop-Service $SERVICE_APACHE -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    if ($mariadbSvc -and $mariadbSvc.Status -ne "Stopped") {
        Stop-Service $SERVICE_MARIADB -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    if ($apacheSvc) {
        & "$env:SystemRoot\System32\sc.exe" delete $SERVICE_APACHE 2>&1 | Out-Null
        Write-Ok "$SERVICE_APACHE service removed"
    }
    if ($mariadbSvc) {
        & "$env:SystemRoot\System32\sc.exe" delete $SERVICE_MARIADB 2>&1 | Out-Null
        Write-Ok "$SERVICE_MARIADB service removed"
    }
}

# ============================================================
#  INSTALL
# ============================================================

function Invoke-InstallWebStack {
    Write-Host ""
    Write-Bold "========================================"
    Write-Bold "  Installing PHP Web Stack on Windows"
    Write-Bold "========================================"

    # Pre-flight: VC++ Redistributable check (required by Apache VS18 + MariaDB 12.x)
    Write-Host ""
    $vcVer = Get-VcRedistVersion
    if ($vcVer) {
        $minVc = [version]"14.51.36231"
        if ($vcVer -ge $minVc) {
            Write-Ok "Visual C++ Redistributable x64 — $vcVer (meets minimum $minVc)"
        }
        else {
            Write-Warn "Visual C++ Redistributable x64 — $vcVer (BELOW minimum $minVc)"
            Write-Info "  This is required by Apache Lounge VS18 and MariaDB 12.x."
            Write-Host ""
            Write-Bold "  An updated Visual C++ Redistributable must be installed to continue."
            $choice = Read-Host "  Install it now? [Y/n]"
            if ($choice -eq "" -or $choice -match "^[Yy]") {
                Install-VcRedist
                if (-not (Test-VcRedistInstalled)) {
                    Write-Err "VC++ Redistributable upgrade failed or requires reboot. Aborting."
                    return
                }
            }
            else {
                Write-Err "VC++ Redistributable is required. Aborting installation."
                return
            }
        }
    }
    else {
        Write-Warn "Visual C++ Redistributable x64 is NOT installed."
        Write-Info "  This is required by Apache Lounge VS18 and MariaDB 12.x."
        Write-Host ""
        $choice = Read-Host "  Install it now? [Y/n]"
        if ($choice -eq "" -or $choice -match "^[Yy]") {
            Install-VcRedist
            if (-not (Test-VcRedistInstalled)) {
                Write-Err "VC++ Redistributable installation failed or requires reboot. Aborting."
                return
            }
        }
        else {
            Write-Err "VC++ Redistributable is required. Aborting installation."
            return
        }
    }
    Write-Host ""

    # Create base directories
    New-Item -ItemType Directory -Force -Path $BASE | Out-Null
    New-Item -ItemType Directory -Force -Path $WWW_PATH | Out-Null
    New-Item -ItemType Directory -Force -Path $TEMP_DOWNLOADS | Out-Null

    # Resolve URLs
    Write-Host ""
    Write-Bold "Resolving latest stable versions..."
    Write-Host ""

    try {
        $apacheUrl  = Get-LatestApacheUrl
        $phpUrl     = Get-LatestPhpUrl
        $mariadbUrl = Get-LatestMariadbUrl
        $pmaUrl     = Get-LatestPhpMyAdminUrl
    }
    catch {
        Write-Err "Failed to resolve one or more download URLs. Aborting."
        return
    }

    # Download and extract (Apache, PHP, MariaDB only — PMA deferred)
    Invoke-DownloadAndExtract $apacheUrl  $APACHE_PATH     "Apache"
    Invoke-DownloadAndExtract $phpUrl     $PHP_PATH        "PHP"
    Invoke-DownloadAndExtract $mariadbUrl $MARIADB_PATH    "MariaDB"

    # Copy PHP dependency DLLs to Apache bin (ICU, curl deps, etc.)
    # Windows DLL search starts from httpd.exe's directory, not PHP's.
    Invoke-CopyPhpDlls

    # Configure
    Invoke-ConfigureApache
    Invoke-ConfigurePhp
    Invoke-FixSqliteDll

    # Check for orphaned database backup from a previous install
    $backupDir = "$BASE\data_backup"
    if ((Test-Path $backupDir) -and (Get-ChildItem $backupDir -ErrorAction SilentlyContinue)) {
        Write-Host ""
        Write-Warn "Found database backup from a previous install: $backupDir"
        $restore = Read-Host "Restore previous databases? [Y/n]"
        if ($restore -eq "" -or $restore -match "^[Yy]") {
            $dataDir = "$MARIADB_PATH\data"
            New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
            Get-ChildItem $backupDir | ForEach-Object {
                Move-Item $_.FullName $dataDir -Force
            }
            Remove-Item $backupDir -Force
            Write-Ok "Previous databases restored to $dataDir"
        }
        else {
            Write-Info "Skipping restore — backup remains at $backupDir"
        }
    }

    Invoke-ConfigureMariaDb

    # ── phpMyAdmin ──────────────────────────────────────────
    Write-Host ""
    Write-Bold "── phpMyAdmin ──"
    Invoke-DownloadAndExtract $pmaUrl     $PHPMYADMIN_PATH "phpMyAdmin"
    Invoke-ConfigurePhpMyAdmin

    # Create test file
    "<?php phpinfo(); ?>" | Out-File -FilePath "$WWW_PATH\phpinfo.php" -Encoding ASCII
    Write-Ok "Created $WWW_PATH\phpinfo.php"

    # Capture installed versions
    $versions = @{
        apache     = Get-ApacheVersion
        php        = Get-PhpVersion
        mariadb    = Get-MariaDbVersion
        phpmyadmin = (Get-PhpMyAdminVersion)
    }

    # Add PHP + MariaDB to user PATH (removes old entries from previous install)
    $pathEntries = Add-ToPath

    Write-Host ""
    Write-Bold "========================================"
    Write-Bold "  Installation Complete!"
    Write-Bold "========================================"
    Write-Host ""
    Write-Info "  Website root:  $WWW_PATH"
    Write-Info "  PHP test:      http://localhost/phpinfo.php"
    Write-Info "  phpMyAdmin:    http://localhost/phpmyadmin"
    Write-Info "  MariaDB login: root / [blank password]"
    Write-Host ""
    Write-Info "  PHP + MariaDB added to user PATH (new terminals only)"
    Write-Host ""

    # Ask about Windows services BEFORE starting (avoids start-stop-restart cycle)
    if (-not (Test-ServicesInstalled)) {
        $svcChoice = Read-Host "Install as Windows services (auto-start on boot)? [y/N]"
        if ($svcChoice -match "^[Yy]") {
            # Register services now, then Start-WebStackServices will use service control
            Write-Info "Registering Windows services..."
            & "$APACHE_PATH\bin\httpd.exe" -k install -n $SERVICE_APACHE 2>&1 | Out-Null
            Set-Service -Name $SERVICE_APACHE -StartupType Automatic -ErrorAction SilentlyContinue
            Write-Ok "$SERVICE_APACHE service installed"

            $mysqld = if (Test-Path "$MARIADB_PATH\bin\mariadbd.exe") { "$MARIADB_PATH\bin\mariadbd.exe" } else { "$MARIADB_PATH\bin\mysqld.exe" }
            $dataDir = "$MARIADB_PATH\data"
            & $mysqld --install $SERVICE_MARIADB --datadir="$dataDir" 2>&1 | Out-Null
            Set-Service -Name $SERVICE_MARIADB -StartupType Automatic -ErrorAction SilentlyContinue
            Write-Ok "$SERVICE_MARIADB service installed"
        }
        else {
            Write-Info "Services will run as processes (started via this script)."
        }
    }

    # Start services (uses service control if registered, process mode otherwise)
    Start-WebStackServices

    # phpMyAdmin configuration storage (bookmarks, history, designer, etc.)
    Invoke-ConfigurePmaStorage

    # Save config with final state (including service registration decision)
    Save-Config -InstallPath $BASE -Versions $versions -PathEntries $pathEntries -ServicesRegistered:(Test-ServicesInstalled)
}

# ============================================================
#  UPDATE
# ============================================================

function Invoke-UpdateWebStack {
    Write-Host ""
    Write-Warn "Checking for newer versions..."

    # Resolve latest URLs
    $latestApacheUrl  = Get-LatestApacheUrl -ErrorAction SilentlyContinue
    $latestPhpUrl     = Get-LatestPhpUrl -ErrorAction SilentlyContinue
    $latestMariadbUrl = Get-LatestMariadbUrl -ErrorAction SilentlyContinue
    $latestPmaUrl     = Get-LatestPhpMyAdminUrl -ErrorAction SilentlyContinue

    # Extract latest version strings from URLs
    $latestApacheVer  = Get-VersionFromUrl $latestApacheUrl  'apache'
    $latestPhpVer     = Get-VersionFromUrl $latestPhpUrl     'php'
    $latestMariadbVer = Get-VersionFromUrl $latestMariadbUrl 'mariadb'
    $latestPmaVer     = Get-VersionFromUrl $latestPmaUrl     'phpmyadmin'

    # Get installed versions
    $currentApacheVer  = Get-ApacheVersion
    $currentPhpVer     = Get-PhpVersion
    $currentMariadbVer = Get-MariaDbVersion
    $currentPmaVer     = Get-PhpMyAdminVersion

    # Compare and build outdated list
    $outdated = @()
    if ($currentApacheVer -and $latestApacheVer -and ([version]$latestApacheVer -gt [version]$currentApacheVer)) {
        $outdated += "Apache  ($currentApacheVer -> $latestApacheVer)"
    }
    if ($currentPhpVer -and $latestPhpVer -and ([version]$latestPhpVer -gt [version]$currentPhpVer)) {
        $outdated += "PHP     ($currentPhpVer -> $latestPhpVer)"
    }
    if ($currentMariadbVer -and $latestMariadbVer -and ([version]$latestMariadbVer -gt [version]$currentMariadbVer)) {
        $outdated += "MariaDB ($currentMariadbVer -> $latestMariadbVer)"
    }
    if ($currentPmaVer -and $latestPmaVer -and ($currentPmaVer -ne 'unknown') -and ([version]$latestPmaVer -gt [version]$currentPmaVer)) {
        $outdated += "phpMyAdmin ($currentPmaVer -> $latestPmaVer)"
    }

    Write-Host ""
    if ($outdated.Count -eq 0) {
        Write-Ok "Stack is up to date. Nothing to update."
        Write-Info "  Apache:     $currentApacheVer"
        Write-Info "  PHP:        $currentPhpVer"
        Write-Info "  MariaDB:    $currentMariadbVer"
        Write-Info "  phpMyAdmin: $currentPmaVer"
        return
    }

    Write-Warn "Updates available:"
    foreach ($item in $outdated) {
        Write-Info "  * $item"
    }

    $confirm = Read-Host "`nInstall these updates? [y/N]"

    if ($confirm -notmatch '^[yY]') {
        Write-Info "Update cancelled."
        return
    }

    $needsApache  = ($currentApacheVer -and $latestApacheVer -and ([version]$latestApacheVer -gt [version]$currentApacheVer))
    $needsPhp     = ($currentPhpVer -and $latestPhpVer -and ([version]$latestPhpVer -gt [version]$currentPhpVer))
    $needsMariadb = ($currentMariadbVer -and $latestMariadbVer -and ([version]$latestMariadbVer -gt [version]$currentMariadbVer))
    $needsPma     = ($currentPmaVer -and $latestPmaVer -and ($currentPmaVer -ne 'unknown') -and ([version]$latestPmaVer -gt [version]$currentPmaVer))

    Stop-WebStackServices

    Write-Host ""
    Write-Warn "Removing outdated installations..."

    if ($needsApache) {
        Remove-Item $APACHE_PATH -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-DownloadAndExtract $latestApacheUrl $APACHE_PATH "Apache"
        Invoke-ConfigureApache
    }
    if ($needsPhp) {
        Remove-Item $PHP_PATH -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-DownloadAndExtract $latestPhpUrl $PHP_PATH "PHP"
        Invoke-ConfigurePhp
        Invoke-FixSqliteDll
        Invoke-CopyPhpDlls
    }
    if ($needsMariadb) {
        Remove-Item $MARIADB_PATH -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-DownloadAndExtract $latestMariadbUrl $MARIADB_PATH "MariaDB"
        Invoke-ConfigureMariaDb
    }
    if ($needsPma) {
        Remove-Item $PHPMYADMIN_PATH -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-DownloadAndExtract $latestPmaUrl $PHPMYADMIN_PATH "phpMyAdmin"
        Invoke-ConfigurePhpMyAdmin
    }

    Start-WebStackServices

    # phpMyAdmin storage: reconfigure if phpMyAdmin was updated
    if ($needsPma) { Invoke-ConfigurePmaStorage }

    Write-Ok "Update complete"

    # Update config with new versions (preserve existing for components not updated)
    $existingConfig = Get-Config
    $versions = @{
        apache     = $(if ($needsApache)  { Get-ApacheVersion }     else { $existingConfig.versions.apache })
        php        = $(if ($needsPhp)     { Get-PhpVersion }        else { $existingConfig.versions.php })
        mariadb    = $(if ($needsMariadb) { Get-MariaDbVersion }     else { $existingConfig.versions.mariadb })
        phpmyadmin = $(if ($needsPma)     { Get-PhpMyAdminVersion }  else { $existingConfig.versions.phpmyadmin })
    }
    $pathEntries = Add-ToPath

    # Offer Windows services if not already registered
    if (-not (Test-ServicesInstalled)) {
        Write-Host ""
        $svcChoice = Read-Host "Install as Windows services (auto-start on boot)? [y/N]"
        if ($svcChoice -match "^[Yy]") {
            Install-AsServices
        }
    }

    # Save config with final state (including service registration)
    Save-Config -InstallPath $BASE -Versions $versions -PathEntries $pathEntries -ServicesRegistered:(Test-ServicesInstalled)
}

# ============================================================
#  DELETE
# ============================================================

function Invoke-DeleteWebStack {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  DELETE PHP WEB STACK" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Warn "The following WILL be deleted:"
    Write-Warn "  - Apache  ($APACHE_PATH)"
    Write-Warn "  - PHP     ($PHP_PATH)"
    Write-Warn "  - MariaDB binaries ($MARIADB_PATH\bin)"
    Write-Warn "  - phpMyAdmin ($PHPMYADMIN_PATH)"
    Write-Host ""
    Write-Info "The following will NOT be deleted:"
    Write-Info "  - Your website files in $WWW_PATH"
    Write-Info "  - Your databases in $MARIADB_PATH\data (moved to $BASE\data_backup)"
    Write-Host ""

    $confirm = Read-Host "Type 'DELETE' to confirm"

    if ($confirm -cne "DELETE") {
        Write-Info "Nothing was deleted."
        return
    }

    Stop-WebStackServices

    # Preserve MariaDB data before removing
    $dataDir = "$MARIADB_PATH\data"
    $backupDir = "$BASE\data_backup"
    if (Test-Path $dataDir) {
        # If a previous backup already exists, timestamp it to avoid collision
        if (Test-Path $backupDir) {
            $ts = Get-Date -Format "yyyyMMdd_HHmmss"
            $oldBackup = "$BASE\data_backup_$ts"
            Write-Warn "Existing data_backup found — renaming to data_backup_$ts"
            Rename-Item $backupDir $oldBackup
        }

        Write-Info "Backing up database data to $backupDir ..."
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        Get-ChildItem $dataDir | ForEach-Object {
            Move-Item $_.FullName $backupDir -Force
        }
        Write-Ok "Database data preserved at $backupDir"
    }

    Remove-Item $APACHE_PATH -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Apache removed"

    Remove-Item $PHP_PATH -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "PHP removed"

    Remove-Item $MARIADB_PATH -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "MariaDB removed"

    Remove-Item $PHPMYADMIN_PATH -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "phpMyAdmin removed"

    Write-Host ""
    Write-Ok "PHP web stack deleted."
    Write-Info "Your website files in $WWW_PATH were preserved."
    Write-Info "Your database data was backed up to $backupDir"

    # Unregister Windows services if present
    Remove-Services

    # Remove webstack from user PATH
    Remove-FromPath

    # Clear saved config so next run prompts for a fresh location
    Clear-Config
    Write-Info "Installer config cleared — next run will prompt for a new path."
}

# ============================================================
#  DASHBOARD
# ============================================================

function Show-Dashboard {
    Clear-Host

    Write-Host ""

    $banner = @'
┌────────────────────────────────────┐
│             _   ____  _   _ ____   │
│   __ _  ___| |_|  _ \| | | |  _ \  │
│  / _` |/ _ \ __| |_) | |_| | |_) | │
│ | (_| |  __/ |_|  __/|  _  |  __/  │
│  \__, |\___|\__|_|   |_| |_|_|     │
│  |___/              www.getPHP.org │
└────────────────────────────────────┘
'@
    Write-Host $banner -ForegroundColor Cyan
    Write-Host ""

    # ---- Stack Status ----
    Write-Host "Your Web Stack:" -ForegroundColor White
    Write-Host "~~~~~~~~~~~~~~~"

    Write-Host "Apache -------> " -NoNewline
    if (Test-ApacheInstalled) {
        Write-Host (Get-ApacheVersion) -ForegroundColor Green
    }
    else {
        Write-Host "not installed" -ForegroundColor Red
    }

    Write-Host "MariaDB ------> " -NoNewline
    if (Test-MariaDbInstalled) {
        Write-Host (Get-MariaDbVersion) -ForegroundColor Green
    }
    else {
        Write-Host "not installed" -ForegroundColor Red
    }

    Write-Host "PHP ----------> " -NoNewline
    if (Test-PhpInstalled) {
        Write-Host (Get-PhpVersion) -ForegroundColor Green
    }
    else {
        Write-Host "not installed" -ForegroundColor Red
    }

    Write-Host "phpMyAdmin ---> " -NoNewline
    if (Test-PhpMyAdminInstalled) {
        Write-Host (Get-PhpMyAdminVersion) -ForegroundColor Green
    }
    else {
        Write-Host "not installed" -ForegroundColor Red
    }

    # ---- Service Status ----
    Write-Host ""
    Write-Host "Service Status:" -ForegroundColor White
    Write-Host "~~~~~~~~~~~~~~~"

    Write-Host "Apache -------> " -NoNewline
    if (Test-ApacheRunning) {
        Write-Host "running" -ForegroundColor Green
    }
    else {
        Write-Host "stopped" -ForegroundColor Red
    }

    Write-Host "MariaDB ------> " -NoNewline
    if (Test-MariaDbRunning) {
        Write-Host "running" -ForegroundColor Green
    }
    else {
        Write-Host "stopped" -ForegroundColor Red
    }

    Write-Host "PHP ----------> " -NoNewline
    if (Test-PhpInstalled) {
        Write-Host "CLI available" -ForegroundColor Green
    }
    else {
        Write-Host "not available" -ForegroundColor Red
    }

    # ---- System Prerequisites ----
    Write-Host ""
    Write-Host "System Prerequisites:" -ForegroundColor White
    Write-Host "~~~~~~~~~~~~~~~~~~~~~"
    Write-Host "VC++ Redist ---> " -NoNewline
    $vcVer = Get-VcRedistVersion
    if ($vcVer) {
        $minVc = [version]"14.51.36231"
        if ($vcVer -ge $minVc) {
            Write-Host "$vcVer" -ForegroundColor Green
        }
        else {
            Write-Host "$vcVer (update recommended -- press V)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "not installed (press V to install)" -ForegroundColor Red
    }

    # Windows Services (always shown when stack is complete)
    Write-Host ""
    Write-Host "Windows Services:" -ForegroundColor White
    Write-Host "~~~~~~~~~~~~~~~~"
    $svcRegistered = Test-ServicesInstalled
    Write-Host "getPHP_Apache   " -NoNewline
    if ($svcRegistered) {
        Write-Host "registered" -ForegroundColor DarkGray
    }
    else {
        Write-Host "not registered" -ForegroundColor DarkGray
    }
    Write-Host "getPHP_MariaDB  " -NoNewline
    if ($svcRegistered) {
        Write-Host "registered" -ForegroundColor DarkGray
    }
    else {
        Write-Host "not registered" -ForegroundColor DarkGray
    }

    # ---- Info ----
    if (Test-StackComplete) {
        Write-Host ""
        Write-Host "Where to put website files? " -NoNewline
        Write-Host $WWW_PATH -ForegroundColor Cyan
        Write-Host "How to test your PHP setup? " -NoNewline
        Write-Host "http://localhost/phpinfo.php" -ForegroundColor Cyan
        Write-Host "Where to access phpMyAdmin? " -NoNewline
        Write-Host "http://localhost/phpmyadmin" -ForegroundColor Cyan
        Write-Host "How to log into phpMyAdmin? " -NoNewline
        Write-Host "Username: root | Password: [blank]" -ForegroundColor Cyan
    }

    # ---- Commands ----
    Write-Host ""
    Write-Host "Stack Commands:" -ForegroundColor White
    Write-Host "~~~~~~~~~~~~~~~"

    if (-not (Test-StackComplete)) {
        Write-Host "I  Install the web stack" -ForegroundColor Cyan
    }
    else {
        Write-Host "U  Update all components" -ForegroundColor Cyan
        Write-Host "R  Restart all services" -ForegroundColor Cyan
        Write-Host "S  Stop all services" -ForegroundColor Cyan
        Write-Host "T  Start all services" -NoNewline -ForegroundColor Cyan
        if (-not (Test-ServicesInstalled)) {
            Write-Host " (add service registration)" -ForegroundColor DarkGray
        }
        else {
            Write-Host ""
        }
        Write-Host "D  Delete the web stack" -ForegroundColor Cyan
    }
    Write-Host "Q  Quit" -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================
#  MAIN LOOP
# ============================================================

# Ensure we're running as Admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

if (-not $isAdmin) {
    Write-Host ""
    Write-Err "This script requires Administrator privileges."
    Write-Info "Please right-click PowerShell and select 'Run as Administrator',"
    Write-Info "then re-run this script."
    Write-Host ""
    Pause
    exit 1
}

# CPU architecture check — only x64 (AMD64) is supported
if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Err "A 64-bit version of Windows is required."
    exit 1
}

$os_architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture

if ($os_architecture -ne [System.Runtime.InteropServices.Architecture]::X64) {
    Write-Host ""
    Write-Err "Unsupported CPU architecture: $os_architecture"
    Write-Host ""
    Write-Info "getPHP for Windows currently only supports x64 (Intel/AMD 64-bit)."
    Write-Info "ARM64 (Snapdragon, Apple Silicon running Windows, etc.) is not supported."
    Write-Info "Apache Lounge and MariaDB do not currently provide native ARM64 Windows binaries."
    Write-Host ""
    Pause
    exit 1
}

# ---- VC++ Redistributable: system prerequisite (BLOCKING) ----
Write-Host ""
Write-Host "========================================" -ForegroundColor White
Write-Host "  SYSTEM PREREQUISITE CHECK" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White
Write-Host ""

while (-not (Test-VcRedistInstalled)) {
    Write-Warn "Visual C++ Redistributable (VS 2017-2026) x64 is required."
    Write-Info "  Minimum version: 14.51.36231"
    $vcVer = Get-VcRedistVersion
    if ($vcVer) {
        Write-Info "  Installed version: $vcVer (outdated -- update required)"
    }
    else {
        Write-Info "  Status: not installed"
    }
    Write-Info "  This is required by Apache Lounge VS18 and MariaDB 12.x."
    Write-Info "  Without it, Apache and MariaDB cannot start."
    Write-Host ""
    $choice = Read-Host "  Install/update now? [Y/n] (n = exit)"
    if ($choice -eq "" -or $choice -match "^[Yy]") {
        $vcBefore = Get-VcRedistVersion
        Install-VcRedist
        if (-not (Test-VcRedistInstalled)) {
            $vcAfter = Get-VcRedistVersion
            if ($vcAfter -eq $vcBefore) {
                # Installer succeeded but version didn't change — reboot required
                Write-Host ""
                Write-Warn "The installer completed but a reboot is required to finish the update."
                Write-Info "  The new VC++ files are queued for replacement on next boot."
                Write-Host ""
                $rebootChoice = Read-Host "  Reboot now? [Y/n] (n = exit)"
                if ($rebootChoice -eq "" -or $rebootChoice -match "^[Yy]") {
                    Write-Info "Rebooting..."
                    Restart-Computer -Force
                }
                else {
                    Write-Err "Cannot proceed without updated VC++ Redistributable. Exiting."
                    Write-Info "  Re-run this script after reboot."
                    Pause
                    exit 1
                }
            }
        }
    }
    else {
        Write-Host ""
        Write-Err "VC++ Redistributable is required. Exiting."
        Write-Host ""
        Pause
        exit 1
    }
}
Write-Host ""
Write-Ok "Visual C++ Redistributable — OK"

# ---- Install location (config-aware) -------------------------

$config = Get-Config

if ($config) {
    # Previous run detected — use saved path
    $BASE = $config.install_path
    Write-Host ""
    Write-Info "Stack location: $BASE"

    # Validate the saved path is usable
    if ($BASE -match '\s') {
        Write-Err "Saved path contains spaces — this is unsupported."
        Write-Info "Delete the config and re-run: Remove-Item '$CONFIG_FILE'"
        Write-Host ""
        Pause
        exit 1
    }
}
else {
    # First run — prompt for install location
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  getPHP Web Stack Install Location" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Info "Where should the web stack be installed?"
    Write-Info "Press Enter to accept the default, or type a custom path."
    Write-Host ""

    $userPath = Read-Host "Install path [C:\webstack]"

    if ([string]::IsNullOrWhiteSpace($userPath)) {
        $BASE = "C:\webstack"
    }
    else {
        # Strip trailing backslash if present
        $BASE = $userPath.TrimEnd('\')

        # Reject paths with spaces (can break mysqld --datadir)
        if ($BASE -match '\s') {
            Write-Err "Paths containing spaces are not supported (can cause issues with MariaDB)."
            Write-Info "Please use a path without spaces, e.g. C:\webstack"
            Write-Host ""
            Pause
            exit 1
        }
    }

    # Save for future runs so we skip this prompt next time
    Save-Config -InstallPath $BASE
    Write-Host ""
    Write-Ok "Web stack will be installed to: $BASE"
}

# Derive all paths from $BASE
$APACHE_PATH     = "$BASE\apache"
$PHP_PATH        = "$BASE\php"
$MARIADB_PATH    = "$BASE\mariadb"
$WWW_PATH        = "$BASE\www"
$PHPMYADMIN_PATH = "$WWW_PATH\phpmyadmin"

if (-not $config) {
    Write-Info "  Websites:  $WWW_PATH"
    Write-Info "  phpMyAdmin: http://localhost/phpmyadmin"
}


# ---- Sync config service state with reality ----
if ($config -and (Test-StackComplete)) {
    $actualRegistered = Test-ServicesInstalled
    $configRegistered  = if ($config.PSObject.Properties.Name -contains 'services_registered') {
        $config.services_registered
    } else {
        $false
    }
    if ($actualRegistered -ne $configRegistered) {
        Save-Config -InstallPath $BASE -ServicesRegistered:$actualRegistered -Versions $config.versions -PathEntries $config.path_entries
    }
}

while ($true) {
    Show-Dashboard

    $stackComplete = Test-StackComplete
    $cmd = Read-Host "==> Enter command"

    switch ($cmd.ToLower()) {
        "i" {
            if (-not $stackComplete) {
                Invoke-InstallWebStack
            }
            else {
                Write-Err "Stack is already installed. Use 'U' to update or 'D' to delete first."
            }
        }
        "u" {
            if ($stackComplete) { Invoke-UpdateWebStack }
            else { Write-Err "Stack not installed. Use 'I' to install." }
        }
        "r" {
            if ($stackComplete) {
                Stop-WebStackServices
                Start-Sleep -Seconds 2
                Start-WebStackServices
                Write-Ok "Services restarted"
            }
            else { Write-Err "Stack not installed." }
        }
        "s" {
            if ($stackComplete) {
                if (Test-ServicesInstalled) {
                    $choice = Read-Host "Remove Windows service registration? [y/N]"
                    if ($choice -match "^[Yy]") {
                        Stop-WebStackServices
                        Remove-Services
                        Save-Config -InstallPath $BASE -ServicesRegistered:$false
                        Write-Ok "Windows services removed — run 'T' to register again"
                    }
                    else {
                        Stop-WebStackServices
                    }
                }
                else {
                    Stop-WebStackServices
                }
            }
            else { Write-Err "Stack not installed." }
        }
        "t" {
            if ($stackComplete) {
                Request-ServiceRegistration
                Start-WebStackServices
            }
            else { Write-Err "Stack not installed." }
        }
        "d" {
            if ($stackComplete) { Invoke-DeleteWebStack }
            else { Write-Err "Stack not installed." }
        }
        "q" {
            Write-Host ""
            Write-Ok "Goodbye!"
            Write-Host ""
            exit 0
        }
        default {
            Write-Err "Command not recognised."
        }
    }

    Write-Host ""
    Pause
}
