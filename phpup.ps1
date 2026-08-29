# =======================================================================
#  phpup — Windows 11 x64 a bare-metal PHP local development environment
#  Inspired by getphp.org
#  Github: https://github.com/DaFa66/phpup
#  Author: Simon Field (aka - DaFa)
#  License: MIT
#  Date: 2026-08-28
#  Version: 2.4.2
# =======================================================================

param(
    [switch]$Offline  # Skip URL resolution — use pre-downloaded zips
)

# ---- Config -----------------------------------------------------------
$BASE = "C:\phpup"
$DOWNLOAD_CACHE  = "$BASE\downloads"

# ---- Shared constants --------------------------------------------------
$UA_STRING        = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
$VC_MIN_VERSION   = [version]"14.51.36231"   # required by Apache Lounge VS18 + MariaDB 12.x

# ---- Banner -----------------------------------------------------------
$BANNER_ART = @'
┌─────────────────────────────┐
│    ____  _   _ ____         │
│   |  _ \| | | |  _ \  /\    │
│   | |_) | |_| | |_) | || |  │
│   |  __/|  _  |  __/| || |  │
│   |_|   |_| |_|_|    ||_|   │
│         ▲ ▲ ▲               │
│         phpup               │
└─────────────────────────────┘
'@

# Pinned fallback URLs — used when live scraping/API resolution fails.
$FALLBACK_URLS = @{
    Redist     = "https://aka.ms/vc14/vc_redist.x64.exe"
    Apache     = "https://www.apachelounge.com/download/VS18/binaries/httpd-2.4.68-260617-Win64-VS18.zip"
    PHP        = "https://windows.php.net/downloads/releases/php-8.5.9-Win32-vs17-x64.zip"
    MariaDB    = "https://archive.mariadb.org/mariadb-12.3.2/winx64-packages/mariadb-12.3.2-winx64.zip"
    phpMyAdmin = "https://files.phpmyadmin.net/phpMyAdmin/5.2.3/phpMyAdmin-5.2.3-all-languages.zip"
}

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

function Get-PhpVersionLabel {
# Installed PHP version including pre-release suffix, e.g. "8.6.0 beta1".
# Display-only: keeps numeric Get-PhpVersion for version comparisons.
    if (Test-PhpInstalled) {
        $out = & "$PHP_PATH\php.exe" -v 2>&1 | Select-Object -First 1
        if ($out -match "PHP\s+([\d.]+[a-zA-Z0-9]*)") {
            $raw = $matches[1]
            if ($raw -match '^([\d.]+)(RC\d+|alpha\d+|beta\d+)$') {
                return "$($matches[1]) $($matches[2])"
            }
            return $raw
        }
    }
    return $null
}

function Test-PhpIsPreRelease([string]$label) {
# True when a PHP display label carries a pre-release suffix (alpha/beta/RC).
    return ($label -match ' (RC\d+|alpha\d+|beta\d+)$')
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

# Extract version string from a cached zip filename (offline mode)
function Get-VersionFromZipName([string]$filename, [string]$component) {
    $ver = $null
    switch ($component) {
        'apache'     { if ($filename -match 'httpd-([\d.]+)-') { $ver = $matches[1] } }
        'php'        { if ($filename -match 'php-([\d.]+)(?:RC\d+|alpha\d+|beta\d+)?-')  { $ver = $matches[1] } }
        'mariadb'    { if ($filename -match 'mariadb-([\d.]+)-') { $ver = $matches[1] } }
        'phpmyadmin' { if ($filename -match 'phpMyAdmin-([\d.]+)') { $ver = $matches[1] } }
    }
    if ($ver) {
        # Normalize to at least 3 version parts (e.g. 6.0 → 6.0.0)
        $parts = $ver -split '\.'
        while ($parts.Count -lt 3) { $parts += '0' }
        return ($parts -join '.')
    }
    return $null
}

function Get-PhpZipLabel([string]$filename) {
# Human-readable PHP version label including pre-release suffix, e.g.
# php-8.6.0alpha3-Win32-vs18-x64.zip → "8.6.0 alpha3". Stable builds
# return the plain version ("8.5.9").
    if ($filename -match 'php-([\d.]+)(RC\d+|alpha\d+|beta\d+)?-') {
        if ($matches[2]) { return "$($matches[1]) $($matches[2])" }
        return $matches[1]
    }
    return $filename
}

function Get-PhpPreReleaseRank($pv) {
# Release-cycle rank for sorting same-numeric-version builds:
# stable (1) < alpha (2) < beta (3) < RC (4) — newest wins on a tie.
    if ($pv.Label -match ' RC')   { return 4 }
    if ($pv.Label -match ' beta') { return 3 }
    if ($pv.Label -match ' alpha'){ return 2 }
    return 1
}

# ---- Config Persistence --------------------------------------

$CONFIG_FILE_LEGACY = "$env:APPDATA\phpup\config.json"

function Get-ConfigFilePath {
    # Canonical location: inside the stack folder so the config travels
    # with the install. $BASE is re-pointed by Get-Config when the stack
    # lives elsewhere (custom/moved install path).
    return "$BASE\config.json"
}

function Read-ConfigFile([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try {
        $config = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($config.install_path) { return $config }
    }
    catch {
        # Corrupted config — treat as missing
    }
    return $null
}

function Get-Config {
    # Canonical probe: stack folder. If its install_path differs from the
    # current $BASE, re-point $BASE and re-read (covers a moved/custom stack).
    $canonical = Get-ConfigFilePath
    $config = Read-ConfigFile $canonical
    if ($config -and $config.install_path -and ([string]$config.install_path -ne $BASE)) {
        $script:BASE = [string]$config.install_path
        $config = Read-ConfigFile (Get-ConfigFilePath)
    }
    if ($config) { return $config }

    # Discovery pointer (pre-1.2.0 location, kept fresh by Save-Config):
    # tells us where the stack lives when $BASE is wrong/unknown. If it still
    # holds a full pre-1.2.0 config (no canonical yet), migrate it over.
    if (Test-Path $CONFIG_FILE_LEGACY) {
        $legacy = Read-ConfigFile $CONFIG_FILE_LEGACY
        if ($legacy -and $legacy.install_path) {
            $script:BASE = [string]$legacy.install_path
            $canonical = Get-ConfigFilePath
            if (-not (Test-Path $canonical)) {
                $configDir = Split-Path $canonical -Parent
                if (-not (Test-Path $configDir)) {
                    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
                }
                Copy-Item $CONFIG_FILE_LEGACY $canonical -Force
                Write-Info "Migrated phpup config to $canonical"
            }
            $result = Read-ConfigFile $canonical
            if ($result) { return $result }
            # Canonical exists but is corrupt — fall back to the pointer's copy
            return $legacy
        }
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

    $configFile = Get-ConfigFilePath
    $configDir = Split-Path $configFile -Parent
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    }

    # Preserve the fu download floor (php_min_series): keep an existing
    # user-set value, else persist the 8.2 default so it is visible/editable.
    $existingConfig = Get-Config
    $minSeries = '8.2'
    if ($existingConfig -and $existingConfig.php_min_series) {
        $minSeries = [string]$existingConfig.php_min_series
    }

    # Start with base structure (always fresh)
    $config = [ordered]@{
        install_path        = $InstallPath
        installed_at        = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        services_registered = $ServicesRegistered
        php_min_series      = $minSeries
        paths               = @{
            apache     = "$InstallPath\apache"
            php        = "$InstallPath\php"
            mariadb    = "$InstallPath\mariadb"
            www        = "$InstallPath\www"
            phpmyadmin = "$InstallPath\phpmyadmin"
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

    $config | ConvertTo-Json -Depth 4 | Out-File $configFile -Encoding UTF8

    # Keep the discovery pointer fresh so a moved/custom stack is still
    # findable when $BASE is wrong on a future run.
    $legacyDir = Split-Path $CONFIG_FILE_LEGACY -Parent
    if (-not (Test-Path $legacyDir)) {
        New-Item -ItemType Directory -Force -Path $legacyDir | Out-Null
    }
    @{ install_path = $InstallPath } | ConvertTo-Json | Out-File $CONFIG_FILE_LEGACY -Encoding UTF8
}

function Clear-Config {
    if (Test-Path (Get-ConfigFilePath)) {
        Remove-Item (Get-ConfigFilePath) -Force
    }
    if (Test-Path $CONFIG_FILE_LEGACY) {
        Remove-Item $CONFIG_FILE_LEGACY -Force
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
    $minVersion = $VC_MIN_VERSION

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
# Uses winget (handles upgrades correctly where the direct installer skips them).
    if (Test-VcRedistInstalled) {
        Write-Ok "Visual C++ Redistributable already meets minimum version requirement"
        return
    }

    Write-Info "Installing/upgrading Visual C++ Redistributable (VS 2017-2026) x64..."

    # winget handles upgrades correctly (direct installer skips when already present).
    # The stack is x64-only, so force x64 even on ARM64 hosts (x64 binaries run
    # under emulation there and still need the x64 runtime — the arm64 redist is
    # for native ARM64 apps, which this stack has none of).
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        $proc = Start-Process -FilePath 'winget.exe' -ArgumentList @(
            'install', '--id', 'Microsoft.VCRedist.2015+.x64',
            '--architecture', 'x64',
            '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements'
        ) -Wait -PassThru -NoNewWindow

        if ($proc.ExitCode -eq 0) {
            Write-Ok "Visual C++ Redistributable installed/upgraded via winget"
            return
        }
        Write-Warn "winget exited with code $($proc.ExitCode). Trying direct download..."
    }

    # Fallback: direct download (for systems without winget)
    $installer = "$DOWNLOAD_CACHE\vc_redist.x64.exe"
    New-Item -ItemType Directory -Force -Path $DOWNLOAD_CACHE | Out-Null

    if (Test-Path $installer) {
        Write-Ok "VC++ Redistributable installer already cached — using $installer"
    }
    else {
        $maxRetries = 3
        $retryDelay = 5
        $downloaded = $false

        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                if ($attempt -gt 1) {
                    Write-Info "  Retry $attempt of $maxRetries..."
                }
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $FALLBACK_URLS.Redist -OutFile $installer
                $downloaded = $true
                break
            }
            catch {
                if ($attempt -lt $maxRetries) {
                    Write-Warn "Download attempt $attempt failed. Retrying in $retryDelay seconds..."
                    Start-Sleep -Seconds $retryDelay
                }
                else {
                    Write-Err "Failed to download VC++ Redistributable after $maxRetries attempts: $_"
                    Write-Info "Install manually: $($FALLBACK_URLS.Redist)"
                    return
                }
            }
        }

        if (-not $downloaded) { return }
    }

    Write-Info "Running installer (silent -- this may take a moment)..."
    $proc = Start-Process -FilePath $installer -ArgumentList "/install", "/quiet", "/norestart" -Wait -PassThru
    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
        Write-Ok "Visual C++ Redistributable installed successfully"
    }
    else {
        Write-Warn "Installer exited with code $($proc.ExitCode). Install manually:"
        Write-Info "  $($FALLBACK_URLS.Redist)"
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

            $ua = $UA_STRING
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
                Write-Warn "Live resolution failed after $maxRetries attempts."
                if ($FALLBACK_URLS.Apache) {
                    Write-Info "  Falling back to pinned Apache URL: $($FALLBACK_URLS.Apache)"
                    return $FALLBACK_URLS.Apache
                }
                Write-Err "Failed to resolve Apache URL and no fallback URL is configured."
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
                Write-Warn "Live resolution failed after $maxRetries attempts."
                if ($FALLBACK_URLS.PHP) {
                    Write-Info "  Falling back to pinned PHP URL: $($FALLBACK_URLS.PHP)"
                    return $FALLBACK_URLS.PHP
                }
                Write-Err "Failed to resolve PHP URL and no fallback URL is configured."
                Write-Info "  Check https://windows.php.net/ or try again later."
                throw
            }
        }
    }
}

function Get-PhpReleasesJson {
# Fetches windows.php.net releases.json once. Returns $null if unreachable.
    $maxRetries = 3
    $retryDelay = 5

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            return Invoke-RestMethod -Uri "https://windows.php.net/downloads/releases/releases.json"
        }
        catch {
            if ($attempt -lt $maxRetries) {
                Write-Warn "Attempt $attempt failed: $($_.Exception.Message)"
                Write-Info "  Retrying in $retryDelay seconds..."
                Start-Sleep -Seconds $retryDelay
            }
            else {
                Write-Warn "Could not reach windows.php.net — running with cached versions only."
                return $null
            }
        }
    }
    return $null
}

function Resolve-PhpSeriesUrl($json, [string]$series) {
# Returns the latest stable TS x64 zip for one PHP series (e.g. "8.4")
# from an already-fetched releases.json. Prefers VS17, falls back to VS16,
# then VC15 (the toolchain used for 7.x builds). Returns $null if the series
# has no stable build.
    $entry = $json.$series
    if (-not $entry -or -not $entry.version) { return $null }
    if ($entry.version -notmatch '^\d+\.\d+\.\d+$') { return $null }  # not a stable patch

    # Prefer VS17, fall back to VS16, then VC15 (7.x)
    foreach ($key in @('ts-vs17-x64', 'ts-vs16-x64', 'ts-vc15-x64')) {
        if ($entry.$key -and $entry.$key.zip) {
            $path = $entry.$key.zip.path
            return @{
                Version = $entry.version
                Url     = "https://windows.php.net/downloads/releases/$path"
                File    = $path
            }
        }
    }
    return $null
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
                    # Construct direct archive URL — bypass REST API redirector
                    $archiveUrl = "https://archive.mariadb.org/mariadb-$version/winx64-packages/$($file.file_name)"
                    Write-Ok "MariaDB -> $archiveUrl"
                    return $archiveUrl
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
                Write-Warn "Live resolution failed after $maxRetries attempts."
                if ($FALLBACK_URLS.MariaDB) {
                    Write-Info "  Falling back to pinned MariaDB URL: $($FALLBACK_URLS.MariaDB)"
                    return $FALLBACK_URLS.MariaDB
                }
                Write-Err "Failed to resolve MariaDB URL and no fallback URL is configured."
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

            $ua = $UA_STRING
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
                Write-Warn "Live resolution failed after $maxRetries attempts."
                if ($FALLBACK_URLS.phpMyAdmin) {
                    Write-Info "  Falling back to pinned phpMyAdmin URL: $($FALLBACK_URLS.phpMyAdmin)"
                    return $FALLBACK_URLS.phpMyAdmin
                }
                Write-Err "Failed to resolve phpMyAdmin URL and no fallback URL is configured."
                Write-Info "  Check https://www.phpmyadmin.net/ or try again later."
                throw
            }
        }
    }
}

# ============================================================
#  DOWNLOAD & EXTRACT
# ============================================================

function Invoke-DownloadToCache($url, $label) {
# Downloads a zip into the download cache without extracting (used by fu).
# Returns the full cache path, or $null on failure. Uses the cached copy if present.
    New-Item -ItemType Directory -Force -Path $DOWNLOAD_CACHE | Out-Null
    $filename = [IO.Path]::GetFileName($url)
    $zipPath  = Join-Path $DOWNLOAD_CACHE $filename

    if (Test-Path $zipPath) {
        Write-Ok "$label zip already cached — using $filename"
        return $zipPath
    }

    $ua = $UA_STRING
    $maxRetries = 3
    $retryDelay = 5

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            if ($attempt -gt 1) {
                Write-Info "  Retry $attempt of $maxRetries..."
            }
            try {
                Invoke-WebRequest -Uri $url -OutFile $zipPath -Headers @{ "User-Agent" = $ua }
            }
            catch [System.Management.Automation.MethodInvocationException] {
                Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -Headers @{ "User-Agent" = $ua }
            }
            Write-Ok "Downloaded $label -> $filename"
            return $zipPath
        }
        catch {
            if ($attempt -lt $maxRetries) {
                Write-Warn "  Download attempt $attempt failed: $($_.Exception.Message)"
                Write-Info "  Retrying in $retryDelay seconds..."
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds $retryDelay
            }
            else {
                Write-Err "Download failed for $label after $maxRetries attempts: $($_.Exception.Message)"
                return $null
            }
        }
    }
    return $null
}

function Invoke-DownloadAndExtract($url, $dest, $label) {
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    Write-Host ""
    Write-Host "Downloading $label..." -ForegroundColor Yellow
    Write-Info "  $url"

    New-Item -ItemType Directory -Force -Path $DOWNLOAD_CACHE | Out-Null
    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    $filename = [IO.Path]::GetFileName($url)
    $zipPath  = Join-Path $DOWNLOAD_CACHE $filename

    # Check if we already have this exact version cached
    if (Test-Path $zipPath) {
        Write-Ok "$label zip already cached — using $filename"
        Write-Info "Extracting to $dest..."
        Expand-Archive -Path $zipPath -DestinationPath $dest -Force
    } else {
        $ua = $UA_STRING

        $maxRetries = 3
        $retryDelay = 5

        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                if ($attempt -gt 1) {
                    Write-Info "  Retry $attempt of $maxRetries..."
                }

                # Try with progress bar first, fall back if IE not available
                try {
                    Invoke-WebRequest -Uri $url -OutFile $zipPath -Headers @{ "User-Agent" = $ua }
                }
                catch [System.Management.Automation.MethodInvocationException] {
                    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -Headers @{ "User-Agent" = $ua }
                }

                # Download succeeded — break out of retry loop
                break
            }
            catch {
                Write-Progress -Activity "Downloading $label" -Completed
                if ($attempt -lt $maxRetries) {
                    Write-Warn "  Download attempt $attempt failed: $($_.Exception.Message)"
                    Write-Info "  Retrying in $retryDelay seconds..."
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
    }

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

    $ProgressPreference = $prevProgress

    Write-Ok "$label extracted"
}

# Offline-only: extract a pre-downloaded zip directly (no download step).
function Invoke-ExtractZip($zipPath, $dest, $label) {
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    Write-Host ""
    Write-Info "Extracting $label from $zipPath..."
    Expand-Archive -Path $zipPath -DestinationPath $dest -Force

    # Flatten wrapper folder if present
    $allItems = @(Get-ChildItem $dest -Force)
    $dirsOnly = @($allItems | Where-Object { $_ -is [System.IO.DirectoryInfo] })
    $filesOnly = @($allItems | Where-Object { $_ -is [System.IO.FileInfo] })

    if ($dirsOnly.Count -eq 1 -and $filesOnly.Count -eq 0) {
        $inner = $dirsOnly[0].FullName
        Write-Info "Flattening wrapper folder: $($dirsOnly[0].Name)"
        Get-ChildItem $inner -Force | ForEach-Object {
            Move-Item $_.FullName $dest -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $inner -Recurse -Force -ErrorAction SilentlyContinue
    }
    elseif ($dirsOnly.Count -ge 1) {
        # Multiple directories or mixed files/dirs — try known wrapper patterns
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

    $ProgressPreference = $prevProgress
    Write-Ok "$label extracted"
}

# ============================================================
#  CONFIGURATION
# ============================================================

function Get-PhpApacheModuleName([string]$version = (Get-PhpVersion)) {
# Apache module DLL for a PHP major version: php7apache2_4.dll for 7.x,
# php8apache2_4.dll for 8.x (the file name differs per major).
    if ($version -match '^7\.') { return 'php7apache2_4.dll' }
    return 'php8apache2_4.dll'
}

function Get-PhpApacheModuleSymbol([string]$version = (Get-PhpVersion)) {
# LoadModule directive name for a PHP major version. Apache matches the
# directive name to the symbol exported by the module DLL, and the exports
# differ: php7apache2_4.dll exports php7_module, php8apache2_4.dll exports
# php_module (that is the symbol the official docs use for PHP 8+).
    if ($version -match '^7\.') { return 'php7_module' }
    return 'php_module'
}

function Test-PhpApacheModuleWired {
# True when httpd.conf references the PHP LoadModule line for the CURRENT
# installed PHP major AND the DLL it points at exists. Catches a broken
# version switch: php.exe may exist while the LoadModule line still names
# the previous major's DLL (or a path that no longer exists).
    $confPath = "$APACHE_PATH\conf\httpd.conf"
    if (-not (Test-Path $confPath)) { return $false }
    $conf = Get-Content $confPath -Raw -ErrorAction SilentlyContinue
    if (-not $conf) { return $false }
    $symbol = Get-PhpApacheModuleSymbol
    if ($conf -match "LoadModule\s+$symbol\s+`"([^`"]+)`"") {
        return Test-Path $matches[1]
    }
    return $false
}

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
    $oldDocRoot = ''
    if ($conf -match 'DocumentRoot\s+"([^"]*)"') { $oldDocRoot = $Matches[1] }
    $conf = $conf -replace 'DocumentRoot\s+".*"', "DocumentRoot `"$wwwUnix`""
    Write-Ok "DocumentRoot set to $WWW_PATH"

    # 4. Directory block for www — rewrite ONLY the old DocumentRoot's own
    # <Directory> block. A blanket '<Directory\s+"…">' replace rewrites EVERY
    # quoted Directory block (cgi-bin, and phpMyAdmin's on a re-run), which
    # orphans phpMyAdmin's grant → 403 (Apache 2.4 "Require all denied").
    if ($oldDocRoot) {
        $oldDocEscaped = [regex]::Escape($oldDocRoot)
        $conf = $conf -replace "<Directory\s+`"$oldDocEscaped`">", "<Directory `"$wwwUnix`">"
    }

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

    # 8. PHP integration — module DLL name AND LoadModule symbol depend on the
    # PHP major version (7.x: php7apache2_4.dll/php7_module; 8.x: php8apache2_4.dll/
    # php_module). Rewrite the existing line when present so version switches
    # keep Apache loadable.
    $phpModuleName   = Get-PhpApacheModuleName
    $phpModuleSymbol = Get-PhpApacheModuleSymbol
    $phpModuleUnix   = "$($PHP_PATH -replace '\\','/')/$phpModuleName"
    $phpIniUnix      = $PHP_PATH -replace '\\','/'

    if ($conf -match 'LoadModule\s+php\d*_module\s+"[^"]*"') {
        $conf = $conf -replace 'LoadModule\s+php\d*_module\s+"[^"]*"', "LoadModule $phpModuleSymbol `"$phpModuleUnix`""
        Write-Ok "PHP module updated to $phpModuleName ($phpModuleSymbol)"
    }
    elseif ($conf -notmatch 'php\d*_module') {
        $phpBlock = @"

# PHP integration (phpup)
LoadModule $phpModuleSymbol "$phpModuleUnix"
AddHandler application/x-httpd-php .php
PHPIniDir "$phpIniUnix"
"@
        $conf += $phpBlock
        Write-Ok "PHP module loaded"
    }
    else {
        Write-Ok "PHP module already configured"
    }

    # 9. phpMyAdmin Alias + access grant (self-healing)
    #    The Alias alone is not enough on Apache 2.4 — a matching <Directory>
    #    block with "Require all granted" is required, or the root "Require all
    #    denied" applies and phpMyAdmin 403s. Add whichever piece is missing.
    $pmaUnix = $PHPMYADMIN_PATH -replace '\\', '/'
    if ($conf -notmatch 'Alias /phpmyadmin') {
        $conf += "`r`n# phpMyAdmin (phpup)`r`nAlias /phpmyadmin `"$pmaUnix`"`r`n"
    }
    if ($conf -notmatch "<Directory\s+`"$pmaUnix`">") {
        $conf += "<Directory `"$pmaUnix`">`r`n    Options Indexes FollowSymLinks MultiViews`r`n    AllowOverride All`r`n    Require all granted`r`n</Directory>`r`n"
    }
    Write-Ok "phpMyAdmin alias configured"

    # 10. Error/access logs in logs folder
    $logsUnix = $LOGS_PATH -replace '\\', '/'
    $conf = $conf -replace 'ErrorLog\s+".*"', "ErrorLog `"$logsUnix/apache_error.log`""
    $conf = $conf -replace 'CustomLog\s+".*"\s+common', "CustomLog `"$logsUnix/apache_access.log`" common"
    Write-Ok "Log files directed to $LOGS_PATH"

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
        'extension=sodium', 
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
    $errorLogPath = "$LOGS_PATH\php_errors.log"
    $errorLogPathUnix = $errorLogPath -replace '\\', '/'
    if ($ini -match ';?error_log\s*=') {
        $ini = $ini -replace ';?error_log\s*=\s*.*', "error_log = `"$errorLogPathUnix`""
    }
    Write-Ok "PHP error_log -> $errorLogPath"

    # Enable OPCache for performance
    $ini = $ini -replace ';?opcache\.enable\s*=\s*\d', 'opcache.enable=1'
    $ini = $ini -replace ';?opcache\.enable_cli\s*=\s*\d', 'opcache.enable_cli=0'
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

    # File upload limits (50 MB import for phpMyAdmin, etc.)
    if ($ini -match 'upload_max_filesize\\s*=') {
        $ini = $ini -replace 'upload_max_filesize\\s*=\\s*\\S+', 'upload_max_filesize = 50M'
    }
    else {
        $ini += "`nupload_max_filesize = 50M"
    }
    if ($ini -match 'post_max_size\\s*=') {
        $ini = $ini -replace 'post_max_size\\s*=\\s*\\S+', 'post_max_size = 55M'
    }
    else {
        $ini += "`npost_max_size = 55M"
    }
    if ($ini -match 'max_execution_time\\s*=') {
        $ini = $ini -replace 'max_execution_time\\s*=\\s*\\S+', 'max_execution_time = 300'
    }
    else {
        $ini += "`nmax_execution_time = 300"
    }
    if ($ini -match 'max_input_time\\s*=') {
        $ini = $ini -replace 'max_input_time\\s*=\\s*\\S+', 'max_input_time = 300'
    }
    else {
        $ini += "`nmax_input_time = 300"
    }
    Write-Ok "Upload limits set: 50 MB files, 300s timeout"

    # Session GC lifetime (match PMA LoginCookieValidity)
    if ($ini -match 'session\.gc_maxlifetime\s*=') {
        $ini = $ini -replace 'session\.gc_maxlifetime\s*=\s*\d+', 'session.gc_maxlifetime = 14400'
    }
    else {
        $ini += "`nsession.gc_maxlifetime = 14400"
    }
    Write-Ok "Session GC lifetime: 4 hours"

    Set-Content -Path $iniPath -Value $ini
    Write-Ok "PHP extensions enabled: curl, fileinfo, gd, intl, mbstring, mysqli, openssl, pdo_mysql, pdo_sqlite, sodium, sqlite3"
}

function Invoke-FixSqliteDll {
    Write-Host ""
    Write-Warn "Checking SQLite3 DLL..."

    $dllPath = "$PHP_PATH\libsqlite3.dll"

    # Scrape sqlite.org for the latest x64 DLL
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ua = $UA_STRING
        $html = Invoke-WebRequest "https://www.sqlite.org/download.html" -UseBasicParsing -Headers @{ "User-Agent" = $ua }

        # Find the x64 DLL zip path — sqlite.org changed their page layout.
        # The path is now embedded in a CSV line or JS call, e.g.:
        #   PRODUCT,3.53.1,2026/sqlite-dll-win-x64-3530100.zip,...
        #   d391('a11','2026/sqlite-dll-win-x64-3530100.zip');
        if ($html.Content -match 'PRODUCT,\d+\.\d+\.\d+,(\d{4}/sqlite-dll-win-x64-\d+\.zip)') {
            $zipPath = $matches[1]
            $url = "https://www.sqlite.org/$zipPath"
            $zipFile = "$DOWNLOAD_CACHE\sqlite3_dll.zip"

            Write-Info "Syncing latest SQLite3 DLL..."
            if (-not (Test-Path $zipFile)) {
                Invoke-WebRequest $url -OutFile $zipFile -UseBasicParsing -Headers @{ "User-Agent" = $ua }
            }

            $extractDir = "$DOWNLOAD_CACHE\sqlite3_dll_extract"
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

    $phpDlls = @(Get-ChildItem "$PHP_PATH\icu*.dll" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $phpDlls += @('libssh2.dll', 'nghttp2.dll', 'libsodium.dll')

    foreach ($dll in $phpDlls) {
        $src = "$PHP_PATH\$dll"
        $dst = "$APACHE_PATH\bin\$dll"
        if (Test-Path $src) {
            Copy-Item $src $dst -Force
            Write-Ok "Copied $dll"
        }
    }
}

function Invoke-ConfigureMariaDb {
    Write-Host ""
    Write-Warn "Configuring MariaDB..."

    $dataDir = "$MARIADB_PATH\data"
    $logsUnix = $LOGS_PATH -replace '\\', '/'

    # Write my.ini with log-error (always, even if data dir exists)
    $myIniPath = "$MARIADB_PATH\my.ini"
    $myIni = @"
[mysqld]
datadir=$dataDir
log-error=$logsUnix/mariadb_error.log

[client]
plugin-dir=$MARIADB_PATH\lib\plugin
"@
    if (-not (Test-Path $myIniPath) -or (Get-Content $myIniPath -Raw) -notmatch 'log-error') {
        Set-Content -Path $myIniPath -Value $myIni
        Write-Ok "MariaDB my.ini written (log-error -> $LOGS_PATH\mariadb_error.log)"
    }

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
    Write-Warn "Configuring phpMyAdmin & Test Script..."

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
/* phpup - phpMyAdmin configuration */
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
`$cfg['VersionCheck'] = false;
`$cfg['SendErrorReports'] = 'never';
`$cfg['LoginCookieValidity'] = 14400;
`$cfg['TempDir'] = '$PHPMYADMIN_PATH/tmp';
"@

    Set-Content -Path $configPath -Value $config
    Write-Ok "phpMyAdmin configured (root / blank password)"

    # Ensure tmp directory for Twig template cache
    $pmaTmp = "$PHPMYADMIN_PATH\tmp"
    if (-not (Test-Path $pmaTmp)) {
        New-Item -ItemType Directory -Path $pmaTmp -Force | Out-Null
        Write-Ok "phpMyAdmin tmp directory created"
    }
}

function Invoke-ConfigurePmaStorage {
# Creates the phpmyadmin config storage database and imports the schema.
# Enables bookmarks, query history, table tracking, designer, etc.

    # Check if already configured
    $testResult = & "$MARIADB_PATH\bin\mariadb.exe" -u root --skip-password -e "SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA='pma' AND TABLE_NAME='pma__bookmark'" 2>&1
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
    Write-Info "Creating phpMyAdmin storage database (pma)..."
    & "$MARIADB_PATH\bin\mariadb.exe" -u root --skip-password -e "CREATE DATABASE IF NOT EXISTS pma" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to create pma database"
        return
    }

    Write-Info "Importing phpMyAdmin storage schema..."
    Get-Content $sqlFile | & "$MARIADB_PATH\bin\mariadb.exe" -u root --skip-password pma 2>&1 | Out-Null
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
`$cfg['Servers'][`$i]['pmadb']           = 'pma';
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
            Write-Info "  $($FALLBACK_URLS.Redist)"
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
            Write-Err "Apache failed to start - check apache_error.log in $LOGS_PATH"
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
        $logsUnix = $LOGS_PATH -replace '\\', '/'

        Start-Process -FilePath $mysqld `
            -ArgumentList "--datadir=`"$dataDir`" --log-error=`"$logsUnix/mariadb_error.log`"" `
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

$SERVICE_APACHE  = "phpup_Apache"
$SERVICE_MARIADB = "phpup_MariaDB"

function Test-ServicesInstalled {
    $service = Get-Service -Name $SERVICE_APACHE -ErrorAction SilentlyContinue
    return $null -ne $service
}

function Install-AsServices {
    Write-Host ""
    Write-Info "Registering Windows services (auto-start on boot)..."

    # Stop any running process-mode instances first
    if ((Test-ApacheRunning) -or (Test-MariaDbRunning)) {
        Stop-WebStackServices
    }

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
        & $mysqld --install $SERVICE_MARIADB --datadir="$dataDir" --log-error="$LOGS_PATH\mariadb_error.log" 2>&1 | Out-Null
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
    New-Item -ItemType Directory -Force -Path $LOGS_PATH | Out-Null
    New-Item -ItemType Directory -Force -Path $DOWNLOAD_CACHE | Out-Null

    # Resolve URLs (or use local zips in offline mode)
    Write-Host ""
    if ($Offline) {
        Write-Bold "Offline mode — using pre-downloaded zips from: $DOWNLOAD_CACHE"
        Write-Host ""

        $zipFiles = Get-ChildItem -Path $DOWNLOAD_CACHE -Filter "*.zip" -ErrorAction SilentlyContinue
        if (-not $zipFiles -or $zipFiles.Count -lt 4) {
            Write-Err "Offline mode requires 4 zip files in $DOWNLOAD_CACHE (Apache, PHP, MariaDB, phpMyAdmin)."
            Write-Info "  Run the script online once to download them, or place them manually."
            return
        }

        Write-Ok "Found $($zipFiles.Count) zip files — skipping URL resolution and download."

        foreach ($zip in $zipFiles) {
            $name = $zip.BaseName.ToLower()
            if ($name -like "*httpd*" -or $name -like "*apache*") {
                $apacheZip = $zip.FullName
            }
            elseif ($name -like "*php-*" -and $name -notlike "*phpmyadmin*") {
                $phpZip = $zip.FullName
            }
            elseif ($name -like "*mariadb*") {
                $mariadbZip = $zip.FullName
            }
            elseif ($name -like "*phpmyadmin*") {
                $pmaZip = $zip.FullName
            }
        }

        # Extract directly
        if ($apacheZip)   { Invoke-ExtractZip $apacheZip   $APACHE_PATH      "Apache" }
        if ($phpZip)      { Invoke-ExtractZip $phpZip      $PHP_PATH         "PHP" }
        if ($mariadbZip)  { Invoke-ExtractZip $mariadbZip  $MARIADB_PATH     "MariaDB" }
        if ($pmaZip)      { Invoke-ExtractZip $pmaZip      $PHPMYADMIN_PATH  "phpMyAdmin" }

        if (-not $apacheZip -or -not $phpZip -or -not $mariadbZip) {
            Write-Err "Could not identify all required zips by filename convention."
            Write-Info "  Expected: *httpd* or *apache*, *php-* (not phpmyadmin), *mariadb*, *phpmyadmin*"
            return
        }
    }
    else {
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

        # Download and extract (Apache, PHP, MariaDB only — PMA deferred).
        # Skip components already at the latest version.
        $resolvedApacheVer  = Get-VersionFromUrl $apacheUrl  'apache'
        $resolvedPhpVer     = Get-VersionFromUrl $phpUrl     'php'
        $resolvedMariadbVer = Get-VersionFromUrl $mariadbUrl 'mariadb'

        $installedApacheVer  = Get-ApacheVersion
        $installedPhpVer     = Get-PhpVersion
        $installedMariadbVer = Get-MariaDbVersion

        if ($installedApacheVer -and $resolvedApacheVer -and ([version]$resolvedApacheVer -le [version]$installedApacheVer)) {
            Write-Ok "Apache $installedApacheVer already installed — skipping download"
        } else {
            if ($installedApacheVer) { Write-Info "Apache $installedApacheVer -> $resolvedApacheVer" }
            Invoke-DownloadAndExtract $apacheUrl  $APACHE_PATH  "Apache"
        }

        if ($installedPhpVer -and $resolvedPhpVer -and ([version]$resolvedPhpVer -le [version]$installedPhpVer)) {
            Write-Ok "PHP $installedPhpVer already installed — skipping download"
        } else {
            if ($installedPhpVer) { Write-Info "PHP $installedPhpVer -> $resolvedPhpVer" }
            Invoke-DownloadAndExtract $phpUrl     $PHP_PATH     "PHP"
        }

        if ($installedMariadbVer -and $resolvedMariadbVer -and ([version]$resolvedMariadbVer -le [version]$installedMariadbVer)) {
            Write-Ok "MariaDB $installedMariadbVer already installed — skipping download"
        } else {
            if ($installedMariadbVer) { Write-Info "MariaDB $installedMariadbVer -> $resolvedMariadbVer" }
            Invoke-DownloadAndExtract $mariadbUrl $MARIADB_PATH "MariaDB"
        }
    }

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

    if (-not $Offline) {
        # ── phpMyAdmin ──────────────────────────────────────────
        Write-Host ""
        Write-Bold "── phpMyAdmin ──"
        Invoke-DownloadAndExtract $pmaUrl     $PHPMYADMIN_PATH "phpMyAdmin"
    }
    Invoke-ConfigurePhpMyAdmin

    # Restore config files from previous install if available
    $configBackupDir = "$BASE\config_backup"
    if (Test-Path $configBackupDir) {
        Write-Host ""
        Write-Info "Found config backup from previous install:"
        $restored = @()
        $configMap = @(
            @{ Src = "$configBackupDir\httpd.conf";    Dst = "$APACHE_PATH\conf\httpd.conf" },
            @{ Src = "$configBackupDir\php.ini";        Dst = "$PHP_PATH\php.ini" },
            @{ Src = "$configBackupDir\my.ini";         Dst = "$MARIADB_PATH\my.ini" },
            @{ Src = "$configBackupDir\config.inc.php"; Dst = "$PHPMYADMIN_PATH\config.inc.php" }
        )
        foreach ($cfg in $configMap) {
            if (Test-Path $cfg.Src) {
                Copy-Item $cfg.Src $cfg.Dst -Force
                $restored += [System.IO.Path]::GetFileName($cfg.Dst)
            }
        }
        if ($restored.Count -gt 0) {
            Write-Ok "Restored: $($restored -join ', ')"
        }
        Remove-Item $configBackupDir -Recurse -Force -ErrorAction SilentlyContinue
    }

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
    Write-Host ""
    Write-Warn "Configuring paths (this may take a moment)..."
    # Add PHP + MariaDB to user PATH (removes old entries from previous install)
    $pathEntries = Add-ToPath

    Write-Host ""
    # Ask about Windows services BEFORE starting (avoids start-stop-restart cycle)
    if (-not (Test-ServicesInstalled)) {
        $svcChoice = Read-Host "Install as Windows services (auto-start on boot)? [y/N]"
        if ($svcChoice -match "^[Yy]") {
            Install-AsServices
        }
        else {
            Write-Info "Services will run as processes (started via this script)."
        }
    }

    # Start services (uses service control if registered, process mode otherwise)
    Start-WebStackServices

    # phpMyAdmin configuration storage (bookmarks, history, designer, etc.)
    Invoke-ConfigurePmaStorage

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

    # Save config with final state (including service registration decision)
    Save-Config -InstallPath $BASE -Versions $versions -PathEntries $pathEntries -ServicesRegistered:(Test-ServicesInstalled)
}

# ============================================================
#  UPDATE
# ============================================================

function Backup-MariaDbData {
    $dataDir = "$MARIADB_PATH\data"
    $backupDir = "$BASE\data_backup_update"
    if (Test-Path $dataDir) {
        Write-Info "Backing up databases before MariaDB update..."
        if (Test-Path $backupDir) {
            Remove-Item $backupDir -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        Get-ChildItem $dataDir | ForEach-Object {
            Move-Item $_.FullName $backupDir -Force
        }
        Write-Ok "Databases backed up"
    }
}

function Restore-MariaDbData {
    $backupDir = "$BASE\data_backup_update"
    if (Test-Path $backupDir) {
        $newDataDir = "$MARIADB_PATH\data"
        New-Item -ItemType Directory -Force -Path $newDataDir | Out-Null
        Get-ChildItem $backupDir | ForEach-Object {
            Move-Item $_.FullName $newDataDir -Force
        }
        Remove-Item $backupDir -Force
        Write-Ok "Databases restored"
    }
}

function Save-PostUpdateConfig {
    $existingConfig = Get-Config
    $versions = @{
        apache     = Get-ApacheVersion
        php        = Get-PhpVersionLabel
        mariadb    = Get-MariaDbVersion
        phpmyadmin = Get-PhpMyAdminVersion
    }
    $pathEntries = $existingConfig.path_entries

    if (-not (Test-ServicesInstalled)) {
        Write-Host ""
        $svcChoice = Read-Host "Install as Windows services (auto-start on boot)? [y/N]"
        if ($svcChoice -match "^[Yy]") {
            Install-AsServices
        }
    }

    Save-Config -InstallPath $BASE -Versions $versions -PathEntries $pathEntries -ServicesRegistered:(Test-ServicesInstalled)
}

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
    Start-Sleep -Seconds 2

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
        Backup-MariaDbData

        Remove-Item $MARIADB_PATH -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-DownloadAndExtract $latestMariadbUrl $MARIADB_PATH "MariaDB"

        Restore-MariaDbData

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

    Save-PostUpdateConfig
}

# ============================================================
#  FORCED UPDATE (offline — scans $DOWNLOAD_CACHE only)
# ============================================================

function Show-PhpSwitchMenu {
# Series-aware PHP version switcher for fu.
#
# Lists cached PHP zips grouped by series (8.2 → newest stable), with:
#   - pre-release labels (8.6.0 alpha3, 8.6.0 beta1)
#   - newer/older/current tags vs the installed version
#   - stale hints when a newer patch exists ("8.2.32 (older → 8.2.33 is available)")
#   - '*' on entries whose series has multiple cached variants
#   - offers to download & install series that are missing from the cache
#
# Selecting an entry with multiple variants opens a sub-menu where each
# variant can be installed or deleted ([d] delete). Selecting a stale entry
# offers to install the newer patch (download + delete-or-keep the old) or
# use the cached one as-is.
#
# Returns $null if nothing chosen, otherwise a hashtable:
#   @{ Chosen = $true; Version = '8.5.9'; Path = 'C:\...zip' }            — install cached
#   @{ Chosen = $true; Version = '8.2.33'; Download = 'https://...'; PruneOld = 'C:\...\8.2.32.zip' } — download then install
    param(
        [object[]]$PhpVersions,
        [string]$Installed
    )

    # 1. Resolve latest stable per series (online only; offline = cached-only hints)
    $latestBySeries = @{}
    $phpJson = $null
    if (-not $Offline) {
        $phpJson = Get-PhpReleasesJson
        if ($phpJson) {
            # releases.json arrives as PSCustomObject (Invoke-RestMethod); accept
            # hashtable-shaped test doubles too.
            if ($phpJson -is [System.Collections.IDictionary]) {
                $seriesKeys = @($phpJson.Keys)
            } else {
                $seriesKeys = @($phpJson.PSObject.Properties.Name)
            }
            # Optional floor from config (php_min_series, default 8.2) — series
            # below it are never offered as download candidates.
            $minSeries = [version]'8.2'
            $config = Get-Config
            if ($config -and $config.php_min_series) {
                try { $minSeries = [version]$config.php_min_series } catch { }
            }
            foreach ($key in $seriesKeys) {
                # Any N.M series (7.4, 8.0, ...) that the JSON actually lists;
                # the config floor (php_min_series) is the only gate below.
                if ($key -match '^\d+\.\d+$' -and ([version]$key -ge $minSeries)) {
                    $resolved = Resolve-PhpSeriesUrl $phpJson $key
                    if ($resolved) { $latestBySeries[$key] = $resolved }
                }
            }
        }
    }

    # 2. Series for each cached zip: "8.5.9" → "8.5"
    function Get-PhpSeries([string]$version) {
        if ($version -match '^(\d+\.\d+)\.') { return $matches[1] }
        return $version
    }

    # 3. Group cached by series (descending version), keep labels
    $seriesMap = @{}
    foreach ($pv in $PhpVersions) {
        $series = Get-PhpSeries $pv.Version
        if (-not $seriesMap.ContainsKey($series)) { $seriesMap[$series] = @() }
        $seriesMap[$series] += $pv
    }

    # 4. Determine candidate series: every cached series + every stable series with a resolved latest
    $allSeries = @()
    foreach ($s in $seriesMap.Keys) { $allSeries += $s }
    foreach ($s in $latestBySeries.Keys) { $allSeries += $s }
    $allSeries = @($allSeries | Sort-Object { [version]$_ } -Descending | Select-Object -Unique)

    # 5. Build menu rows — ONE row per series (newest cached variant as the
    #    label, '*' when the series has multiple cached variants).
    $rows = @()   # @{ Series; Kind='cached'|'missing'; Label; Version; Path; Latest; Stale; Variants }
    foreach ($series in $allSeries) {
        $latest = $null
        if ($latestBySeries.ContainsKey($series)) { $latest = $latestBySeries[$series] }

        $cached = @()
        if ($seriesMap.ContainsKey($series)) { $cached = @($seriesMap[$series]) }
        if ($cached.Count -gt 0) {
            # Newest cached variant: version desc, then pre-release rank desc
            # (RC > beta > alpha) for same-numeric-version builds.
            $newest = @($cached | Sort-Object @{ Expression = { [version]$_.Version }; Descending = $true }, @{ Expression = { Get-PhpPreReleaseRank $_ }; Descending = $true })[0]

            $stale = $false
            if ($latest) {
                try { $stale = ([version]$newest.Version -lt [version]$latest.Version) } catch { }
            }
            $rows += @{
                Series    = $series
                Kind      = 'cached'
                Label     = if ($newest.Label) { $newest.Label } else { $newest.Version }
                Version   = $newest.Version
                Path      = $newest.Path
                Latest    = if ($latest) { $latest.Version } else { $null }
                LatestUrl = if ($latest) { $latest.Url } else { $null }
                Stale     = $stale
                Variants  = $cached.Count
            }
        }
        elseif ($latest) {
            # Series has a stable target but nothing cached → offer to download & install
            $rows += @{
                Series    = $series
                Kind      = 'missing'
                Label     = $latest.Version
                Version   = $latest.Version
                Path      = $null
                Latest    = $latest.Version
                LatestUrl = $latest.Url
                Stale     = $false
                Variants  = 0
            }
        }
    }

    if ($rows.Count -eq 0) {
        Write-Info "No PHP versions cached and nothing to download."
        return $null
    }

    # 6. Render menu
    Write-Host ""
    Write-Host "PHP:" -ForegroundColor White
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        $tag = ""
        $tagColor = "Cyan"

        if ($r.Kind -eq 'missing') {
            $tag = " (not cached — download & install)"
            $tagColor = "Yellow"
        }
        else {
            # Tag relative to the newest cached patch
            if ($Installed) {
                try {
                    if ([version]$r.Version -gt [version]$Installed) { $tag = " (newer)"; $tagColor = "Yellow" }
                    elseif ([version]$r.Version -lt [version]$Installed) { $tag = " (older)"; $tagColor = "DarkGray" }
                    else { $tag = " (current)"; $tagColor = "Green" }
                } catch { }
            }
            # The installed build lives in this series but is not the newest
            # cached patch — keep the "current" visible in the list.
            if ($Installed -and (Get-PhpSeries $Installed) -eq $r.Series) {
                try {
                    if ([version]$r.Version -eq [version]$Installed) {
                        $tag = " (current)"; $tagColor = "Green"
                    }
                    elseif ($tag -notmatch 'current') {
                        $tag += " — current: $Installed"
                    }
                } catch { }
            }
            if ($r.Stale -and $r.Latest) {
                $tag += " → $($r.Latest) is available"
                # Keep "(current)" green even when a newer patch is hinted
                if ($tag -notmatch 'current') { $tagColor = "Yellow" }
            }
            if ($r.Variants -gt 1) { $tag += " *" }
        }

        Write-Host "  [$($i + 1)] $($r.Label)" -NoNewline -ForegroundColor Cyan
        if ($tag) { Write-Host $tag -ForegroundColor $tagColor } else { Write-Host "" }
    }
    Write-Host "  [S] skip" -ForegroundColor DarkGray

    # 7. Selection — strict: only a plain number is accepted (rejects "2d" etc.)
    $choice = Read-Host "  Choose"
    if ($choice -match '^[Ss]$' -or [string]::IsNullOrWhiteSpace($choice)) { return $null }
    if ($choice -notmatch '^\d+$') { Write-Warn "  Invalid choice — skipping PHP"; return $null }
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $rows.Count) { Write-Warn "  Invalid choice — skipping PHP"; return $null }

    $row = $rows[$idx]

    # 8a. Missing series → download & install
    if ($row.Kind -eq 'missing') {
        return @{ Chosen = $true; Version = $row.Version; Download = $row.LatestUrl }
    }

    # 8b. Multiple variants in this series → sub-menu
    if ($row.Variants -gt 1) {
        $sub = Show-PhpVariantSubMenu -Series $row.Series -Variants @($seriesMap[$row.Series]) -LatestVersion $row.Latest -LatestUrl $row.LatestUrl -Installed $Installed
        if (-not $sub) { return $null }
        return $sub
    }

    # 8c. Single cached entry, stale → offer newer patch
    if ($row.Stale -and $row.Latest) {
        Write-Host ""
        Write-Info "$($row.Latest) is available for PHP $($row.Series)."
        $ans = Read-Host "  [I]nstall latest / [U]se existing ($($row.Version))"
        if ($ans -match '^[Ii]$') {
            Write-Host ""
            $del = Read-Host "  Delete cached $($row.Version)? [Y]es/[N]o (keep both)"
            $prune = $null
            if ($del -match '^[Yy]$') { $prune = $row.Path }
            return @{ Chosen = $true; Version = $row.Latest; Download = $row.LatestUrl; PruneOld = $prune }
        }
        # fall through → use existing
    }

    # Selecting the already-installed build is a no-op
    if ($Installed) {
        try {
            if ([version]$row.Version -eq [version]$Installed) {
                Write-Info "$($row.Version) is already installed — no changes made."
                return $null
            }
        } catch { }
    }

    # 8d. Single cached entry (or user chose "use existing")
    return @{ Chosen = $true; Version = $row.Version; Path = $row.Path }
}

function Show-PhpVariantList {
# Renders the variant sub-menu list (shared by the initial render and the
# re-render after a delete, so both obey the same rules: pre-release labels,
# newer/older/current tags, no delete on the installed build, and the
# "newer — download" row only when the latest patch is NOT already cached).
    param(
        [string]$Series,
        [object[]]$Sorted,
        [string]$LatestVersion,
        [string]$Installed
    )

    Write-Host ""
    Write-Host "PHP $Series — variants:" -ForegroundColor White
    for ($i = 0; $i -lt $Sorted.Count; $i++) {
        $v = $Sorted[$i]
        $vLabel = if ($v.Label) { $v.Label } else { $v.Version }
        $tag = ""
        $tagColor = "Cyan"
        if ($Installed) {
            try {
                if ([version]$v.Version -gt [version]$Installed) { $tag = " (newer)"; $tagColor = "Yellow" }
                elseif ([version]$v.Version -lt [version]$Installed) { $tag = " (older)"; $tagColor = "DarkGray" }
                else { $tag = " (current)"; $tagColor = "Green" }
            } catch { }
        }
        Write-Host "  [$($i + 1)] $vLabel" -NoNewline -ForegroundColor Cyan
        if ($tag) { Write-Host $tag -ForegroundColor $tagColor } else { Write-Host "" }
        # Never offer to delete the currently installed build
        $isCurrent = $false
        if ($Installed) {
            try { $isCurrent = ([version]$v.Version -eq [version]$Installed) } catch { }
        }
        if (-not $isCurrent) {
            Write-Host "        [d] delete this cached copy" -ForegroundColor DarkGray
        }
    }

    # Offer a download row only when the series' latest patch is NOT already cached
    $latestCached = $false
    if ($LatestVersion) {
        foreach ($v in $Sorted) {
            try { if ([version]$v.Version -eq [version]$LatestVersion) { $latestCached = $true } } catch { }
        }
    }
    if ($LatestVersion -and -not $latestCached) {
        Write-Host "  [$($Sorted.Count + 1)] $LatestVersion (newer — download)" -ForegroundColor Yellow
    }
    Write-Host "  [S] skip" -ForegroundColor DarkGray
}

function Show-PhpVariantSubMenu {
# Sub-menu for a PHP series with multiple cached variants. Each variant can be
# installed (by number) or deleted ([d] delete with Yes/No confirm). If a newer
# patch is available it is offered as an extra option.
    param(
        [string]$Series,
        [object[]]$Variants,
        [string]$LatestVersion,
        [string]$LatestUrl,
        [string]$Installed
    )

    $sorted = @($Variants | Sort-Object @{ Expression = { [version]$_.Version }; Descending = $true }, @{ Expression = { Get-PhpPreReleaseRank $_ }; Descending = $true })

    Show-PhpVariantList -Series $Series -Sorted $sorted -LatestVersion $LatestVersion -Installed $Installed

    $anyDelete = $false

    while ($true) {
        $choice = Read-Host "  Choose"
        if ($choice -match '^[Ss]$' -or [string]::IsNullOrWhiteSpace($choice)) {
            if ($anyDelete) { return @{ Refresh = $true } }
            return $null
        }

        # Bare "d" — explain the delete format
        if ($choice -match '^[Dd]$') {
            Write-Info "  To delete a cached copy, type d<number> — e.g. d2 deletes variant [2]."
            continue
        }

        # Delete action: "d2" or "2d" (bare "d" explains the format)
        $deleteRow = -1
        if ($choice -match '^[Dd](\d+)$')    { $deleteRow = [int]$matches[1] - 1 }
        elseif ($choice -match '^(\d+)[Dd]$') { $deleteRow = [int]$matches[1] - 1 }
        if ($deleteRow -ge 0) {
            if ($deleteRow -ge $sorted.Count) {
                Write-Warn "  Invalid delete choice."
                continue
            }
            $dIdx = $deleteRow
            $target = $sorted[$dIdx]
            $targetLabel = if ($target.Label) { $target.Label } else { $target.Version }
            # Never delete the currently installed build
            $targetIsCurrent = $false
            if ($Installed) {
                try { $targetIsCurrent = ([version]$target.Version -eq [version]$Installed) } catch { }
            }
            if ($targetIsCurrent) {
                Write-Warn "  $targetLabel is the installed build — cannot delete it."
                continue
            }
            Write-Host ""
            $confirm = Read-Host "  Delete $targetLabel from cache? [Y]es/[N]o"
            if ($confirm -match '^[Yy]$') {
                Remove-Item $target.Path -Force -ErrorAction SilentlyContinue
                Write-Ok "Deleted $targetLabel from cache."
                $anyDelete = $true
                # Rebuild list
                $sorted = @($sorted | Where-Object { $_.Path -ne $target.Path })
                if ($sorted.Count -eq 0) {
                    Write-Info "No PHP variants left for $Series."
                    return @{ Refresh = $true }
                }
                # If nothing actionable remains (only the installed build left),
                # bounce back to the version-switch menu instead of a dead end.
                $actionable = $false
                foreach ($v in $sorted) {
                    if (-not $Installed) { $actionable = $true; break }
                    try {
                        if ([version]$v.Version -ne [version]$Installed) { $actionable = $true; break }
                    } catch { $actionable = $true; break }
                }
                if (-not $actionable) {
                    Write-Info "Only the installed build remains for PHP $Series — returning to the version list."
                    return @{ Refresh = $true }
                }
                Show-PhpVariantList -Series $Series -Sorted $sorted -LatestVersion $LatestVersion -Installed $Installed
                continue
            }
            Write-Info "Keeping $($target.Version)."
            continue
        }

        # Install choice — strict: only a plain number is accepted. This
        # rejects garbage like "2d" that [int] would silently parse as 2.
        if ($choice -notmatch '^\d+$') {
            Write-Warn "  Invalid choice."
            continue
        }
        $idx = [int]$choice - 1
        if ($idx -lt 0 -or $idx -ge $sorted.Count) {
            # "newer — download" row, only valid when the latest is not cached
            $latestCached2 = $false
            if ($LatestVersion) {
                foreach ($v in $sorted) {
                    if ([version]$v.Version -eq [version]$LatestVersion) { $latestCached2 = $true; break }
                }
            }
            if ($LatestVersion -and -not $latestCached2 -and $idx -eq ($sorted.Count)) {
                return @{ Chosen = $true; Version = $LatestVersion; Download = $LatestUrl }
            }
            Write-Warn "  Invalid choice."
            continue
        }

        $target = $sorted[$idx]

        # Selecting the already-installed build is a no-op
        if ($Installed) {
            try {
                if ([version]$target.Version -eq [version]$Installed) {
                    Write-Info "$($target.Version) is already installed — no changes made."
                    return $null
                }
            } catch { }
        }

        # Stale variant → offer the newer patch
        if ($LatestVersion) {
            try {
                if ([version]$target.Version -lt [version]$LatestVersion) {
                    Write-Host ""
                    Write-Info "$($LatestVersion) is available for PHP $Series."
                    $ans = Read-Host "  [I]nstall latest / [U]se existing ($($target.Version))"
                    if ($ans -match '^[Ii]$') {
                        # If the latest is already cached, install it from cache
                        $latestZip = $null
                        foreach ($v in $sorted) {
                            if ([version]$v.Version -eq [version]$LatestVersion) { $latestZip = $v; break }
                        }
                        if ($latestZip) {
                            Write-Host ""
                            $del = Read-Host "  Delete cached $($target.Version)? [Y]es/[N]o (keep both)"
                            $prune = $null
                            if ($del -match '^[Yy]$') { $prune = $target.Path }
                            return @{ Chosen = $true; Version = $LatestVersion; Path = $latestZip.Path; PruneOld = $prune }
                        }
                        Write-Host ""
                        $del = Read-Host "  Delete cached $($target.Version)? [Y]es/[N]o (keep both)"
                        $prune = $null
                        if ($del -match '^[Yy]$') { $prune = $target.Path }
                        return @{ Chosen = $true; Version = $LatestVersion; Download = $LatestUrl; PruneOld = $prune }
                    }
                }
            } catch { }
        }
        return @{ Chosen = $true; Version = $target.Version; Path = $target.Path }
    }
}

function Get-CachedPhpVersions {
# Scans the download cache for PHP TS builds, sorted by version descending
# then pre-release rank (RC > beta > alpha). Skips NTS builds. Used both for
# the initial fu listing and to re-scan after a variant delete.
    $result = @()
    foreach ($zip in (Get-ChildItem -Path $DOWNLOAD_CACHE -Filter "*.zip" -ErrorAction SilentlyContinue)) {
        $name = $zip.BaseName
        if ($name -like "*php-*" -and $name -notlike "*phpmyadmin*") {
            if ($name -like "*-nts-*") {
                Write-Info "Skipping non-thread-safe (NTS) PHP build (incompatible with Apache): $($zip.Name)"
                Write-Host ""
                continue
            }
            $ver = Get-VersionFromZipName $name 'php'
            if ($ver) { $result += @{ Path = $zip.FullName; Version = $ver; Label = Get-PhpZipLabel $name } }
        }
    }
    return @($result | Sort-Object @{ Expression = { [version]$_.Version }; Descending = $true }, @{ Expression = { Get-PhpPreReleaseRank $_ }; Descending = $true })
}

function Invoke-ForcedUpdate {
    Write-Host ""
    Write-Warn "PHP version switching — scanning $DOWNLOAD_CACHE for cached versions..."
    Write-Host ""

    $zipFiles = Get-ChildItem -Path $DOWNLOAD_CACHE -Filter "*.zip" -ErrorAction SilentlyContinue
    if (-not $zipFiles) {
        Write-Err "No cached zip files found in $DOWNLOAD_CACHE"
        return
    }

    # Collect ALL cached versions per component (not just the newest)
    $apacheVersions  = @()
    $phpVersions     = @()
    $mariadbVersions = @()
    $pmaVersions     = @()

    foreach ($zip in $zipFiles) {
        $name = $zip.BaseName
        if ($name -like "*httpd*" -or $name -like "*apache*") {
            $ver = Get-VersionFromZipName $name 'apache'
            if ($ver) { $apacheVersions += @{ Path = $zip.FullName; Version = $ver } }
        }
        elseif ($name -like "*php-*" -and $name -notlike "*phpmyadmin*") {
            if ($name -like "*-nts-*") {
                Write-Info "Skipping non-thread-safe (NTS) PHP build (incompatible with Apache): $($zip.Name)"
                Write-Host ""
                continue
            }
            $ver = Get-VersionFromZipName $name 'php'
            if ($ver) { $phpVersions += @{ Path = $zip.FullName; Version = $ver; Label = Get-PhpZipLabel $name } }
        }
        elseif ($name -like "*mariadb*") {
            $ver = Get-VersionFromZipName $name 'mariadb'
            if ($ver) { $mariadbVersions += @{ Path = $zip.FullName; Version = $ver } }
        }
        elseif ($name -like "*phpmyadmin*") {
            $ver = Get-VersionFromZipName $name 'phpmyadmin'
            if ($ver) { $pmaVersions += @{ Path = $zip.FullName; Version = $ver } }
        }
    }

    # Sort each by version descending
    $apacheVersions  = @($apacheVersions  | Sort-Object { [version]$_.Version } -Descending)
    # PHP: break numeric-version ties by pre-release rank (RC > beta > alpha)
    $phpVersions     = @($phpVersions | Sort-Object @{ Expression = { [version]$_.Version }; Descending = $true }, @{ Expression = { Get-PhpPreReleaseRank $_ }; Descending = $true })
    $mariadbVersions = @($mariadbVersions | Sort-Object { [version]$_.Version } -Descending)
    $pmaVersions     = @($pmaVersions     | Sort-Object { [version]$_.Version } -Descending)

    # Get installed versions
    $currentApacheVer  = Get-ApacheVersion
    $currentPhpVer     = Get-PhpVersion
    $currentMariadbVer = Get-MariaDbVersion
    $currentPmaVer     = Get-PhpMyAdminVersion

    # ---- Summary ----
    Write-Host "Cached versions in $DOWNLOAD_CACHE`:" -ForegroundColor White
    Write-Host ""

    function Show-ComponentSummary($label, $installed, $cachedList) {
        Write-Host "$label" -NoNewline -ForegroundColor White
        Write-Host " — installed: " -NoNewline
        if ($installed) {
            # Flag pre-release builds (newer than the latest stable)
            if (Test-PhpIsPreRelease $installed) {
                Write-Host "$installed (pre-release)".PadRight(20) -NoNewline -ForegroundColor Yellow
            } else {
                Write-Host $installed.PadRight(7) -NoNewline -ForegroundColor Green
            }
        } else {
            Write-Host "none    " -NoNewline -ForegroundColor DarkGray
        }
        Write-Host " |  cache: " -NoNewline
        if ($cachedList.Count -eq 0) {
            Write-Host "none" -ForegroundColor DarkGray
        } else {
            $labels = @($cachedList | ForEach-Object { if ($_.Label) { $_.Label } else { $_.Version } })
            Write-Host ($labels -join ", ") -ForegroundColor Cyan
        }
    }

    Show-ComponentSummary "Apache    " $currentApacheVer  $apacheVersions
    Show-ComponentSummary "PHP       " (Get-PhpVersionLabel) $phpVersions
    Show-ComponentSummary "MariaDB   " $currentMariadbVer $mariadbVersions
    Show-ComponentSummary "phpMyAdmin" $currentPmaVer     $pmaVersions

    # ---- Interactive selection ----
    # PHP gets its own series-aware menu; the other three keep the flat list.
    $selectedApache  = $null
    $selectedPhp     = $null
    $selectedMariadb = $null
    $selectedPma     = $null

    $anyChoice = $false

    # --- PHP: series-aware version switching (loop: variant deletes refresh
    # the listing, since the cache changed under us) ---
    while ($true) {
        $phpMenu = Show-PhpSwitchMenu -PhpVersions $phpVersions -Installed $currentPhpVer
        if ($phpMenu -and $phpMenu.Refresh) {
            # A variant was deleted from the cache — re-scan and re-show the menu
            $phpVersions = @(Get-CachedPhpVersions)
            continue
        }
        if ($phpMenu -and $phpMenu.Chosen) {
            $selectedPhp = $phpMenu
            $anyChoice = $true
            Write-Ok "PHP → $($phpMenu.Version)"
        }
        break
    }
    Write-Host ""

    # --- Apache / MariaDB / phpMyAdmin: flat cached list ---
    $components = @(
        @{ Name = 'Apache';     Installed = $currentApacheVer;  Cached = $apacheVersions;  Var = 'selectedApache' }
        @{ Name = 'MariaDB';    Installed = $currentMariadbVer; Cached = $mariadbVersions; Var = 'selectedMariadb' }
        @{ Name = 'phpMyAdmin'; Installed = $currentPmaVer;     Cached = $pmaVersions;     Var = 'selectedPma' }
    )

    foreach ($comp in $components) {
        if ($comp.Cached.Count -eq 0) { continue }

        # If only one cached version and it matches installed, skip
        if ($comp.Cached.Count -eq 1 -and $comp.Installed -and $comp.Cached[0].Version -eq $comp.Installed) {
            continue
        }

        Write-Host "$($comp.Name):" -ForegroundColor White

        for ($i = 0; $i -lt $comp.Cached.Count; $i++) {
            $v = $comp.Cached[$i].Version
            $tag = ""
            $tagColor = "Cyan"
            if ($comp.Installed) {
                try {
                    if ([version]$v -gt [version]$comp.Installed) { $tag = " (newer)"; $tagColor = "Yellow" }
                    elseif ([version]$v -lt [version]$comp.Installed) { $tag = " (older)"; $tagColor = "DarkGray" }
                    else { $tag = " (current)"; $tagColor = "Green" }
                } catch { }
            }
            Write-Host "  [$($i + 1)] $v" -NoNewline -ForegroundColor Cyan
            if ($tag) {
                Write-Host $tag -ForegroundColor $tagColor
            } else {
                Write-Host ""
            }
        }
        Write-Host "  [S] skip" -ForegroundColor DarkGray

        $choice = Read-Host "  Choose"
        if ($choice -match '^[Ss]$' -or [string]::IsNullOrWhiteSpace($choice)) {
            continue
        }
        try {
            $idx = [int]$choice - 1
            if ($idx -ge 0 -and $idx -lt $comp.Cached.Count) {
                Set-Variable -Name $comp.Var -Value $comp.Cached[$idx]
                $anyChoice = $true
                Write-Ok "$($comp.Name) → $($comp.Cached[$idx].Version)"
            } else {
                Write-Warn "  Invalid choice — skipping $($comp.Name)"
            }
        } catch {
            Write-Warn "  Invalid choice — skipping $($comp.Name)"
        }
    }

    if (-not $anyChoice) {
        Write-Host ""
        Write-Info "Nothing selected — no changes made."
        return
    }

    # ---- Apply ----
    $needsApache  = ($null -ne $selectedApache)
    $needsPhp     = ($null -ne $selectedPhp)
    $needsMariadb = ($null -ne $selectedMariadb)
    $needsPma     = ($null -ne $selectedPma)

    # If PHP chose a fresh download, fetch it into the cache before stopping services
    if ($needsPhp -and $selectedPhp.Download) {
        Write-Host ""
        Write-Info "Downloading PHP $($selectedPhp.Version)..."
        $zipPath = Invoke-DownloadToCache $selectedPhp.Download "PHP $($selectedPhp.Version)"
        if (-not $zipPath) {
            Write-Err "PHP download failed — aborting."
            return
        }
        $selectedPhp.Path = $zipPath
        if ($selectedPhp.PruneOld) {
            Write-Ok "Deleted old cached zip: $($selectedPhp.PruneOld)"
            Remove-Item $selectedPhp.PruneOld -Force -ErrorAction SilentlyContinue
            $selectedPhp.PruneOld = $null
        }
    }

    Stop-WebStackServices
    Start-Sleep -Seconds 2

    Write-Host ""
    Write-Warn "Applying selected versions..."

    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    if ($needsApache) {
        Remove-Item $APACHE_PATH -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-ExtractZip $selectedApache.Path $APACHE_PATH "Apache"
        Invoke-ConfigureApache
        Write-Host ""
    }
    if ($needsPhp) {
        Remove-Item $PHP_PATH -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-ExtractZip $selectedPhp.Path $PHP_PATH "PHP"
        Invoke-ConfigurePhp
        Invoke-FixSqliteDll
        Invoke-CopyPhpDlls
        # PHP major may have changed (e.g. 8.x → 7.x): the Apache module DLL
        # name follows the major version, so re-point httpd.conf at it.
        Invoke-ConfigureApache
        Write-Host ""
    }
    if ($needsMariadb) {
        Backup-MariaDbData

        Remove-Item $MARIADB_PATH -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-ExtractZip $selectedMariadb.Path $MARIADB_PATH "MariaDB"

        Restore-MariaDbData

        Invoke-ConfigureMariaDb
    }
    if ($needsPma) {
        Remove-Item $PHPMYADMIN_PATH -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-ExtractZip $selectedPma.Path $PHPMYADMIN_PATH "phpMyAdmin"
        Invoke-ConfigurePhpMyAdmin
    }

    Start-WebStackServices
    $ProgressPreference = $prevProgress

    if ($needsPma) { Invoke-ConfigurePmaStorage }

    Write-Host ""
    Write-Host "Forced update complete"

    Save-PostUpdateConfig
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
    Write-Warn "  - Log files ($LOGS_PATH)"
    Write-Host ""
    Write-Info "The following will NOT be deleted:"
    Write-Info "  - Your website files in $WWW_PATH"
    Write-Info "  - Your databases in $MARIADB_PATH\data (moved to $BASE\data_backup)"
    Write-Info "  - Your config files (moved to $BASE\config_backup)"
    Write-Info "  - Cached downloads in $DOWNLOAD_CACHE"
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
        Write-Host ""
        Write-Info "Backing up database data to $backupDir ..."
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        Get-ChildItem $dataDir | ForEach-Object {
            Move-Item $_.FullName $backupDir -Force
        }
        Write-Ok "Database data preserved at $backupDir"
        Write-Host ""
    }

    # Backup config files before removal
    $configBackupDir = "$BASE\config_backup"
    New-Item -ItemType Directory -Force -Path $configBackupDir | Out-Null
    $configs = @(
        @{ Src = "$APACHE_PATH\conf\httpd.conf";   Name = "httpd.conf" },
        @{ Src = "$PHP_PATH\php.ini";               Name = "php.ini" },
        @{ Src = "$MARIADB_PATH\my.ini";             Name = "my.ini" },
        @{ Src = "$PHPMYADMIN_PATH\config.inc.php";  Name = "config.inc.php" }
    )
    foreach ($cfg in $configs) {
        if (Test-Path $cfg.Src) {
            Copy-Item $cfg.Src "$configBackupDir\$($cfg.Name)" -Force
        }
    }
    Write-Ok "Config files backed up to $configBackupDir"

    Remove-Item $APACHE_PATH -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Apache removed"

    Remove-Item $PHP_PATH -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "PHP removed"

    Remove-Item $MARIADB_PATH -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "MariaDB removed"

    Remove-Item $PHPMYADMIN_PATH -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "phpMyAdmin removed"

    Remove-Item $LOGS_PATH -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Log files removed"
    Write-Host ""

    # Unregister Windows services if present
    Remove-Services

    # Remove webstack from user PATH
    Remove-FromPath

    # Clear saved config so next run prompts for a fresh location
    Clear-Config
    Write-Info "Installer config cleared — next run will prompt for a new path."

    Write-Host ""
    Write-Host "========================================" -ForegroundColor White
    Write-Host "  Stack Deleted — Cleanup Complete" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor White
    Write-Host ""
    Write-Info "Website files preserved: $WWW_PATH"
    Write-Info "Database backup:         $backupDir"
    Write-Info "Config backup:           $configBackupDir"
    Write-Info "Download cache:          $DOWNLOAD_CACHE"
    Write-Host ""
}

# ============================================================
#  DASHBOARD
# ============================================================

function Show-Dashboard {
    Clear-Host

    Write-Host ""
    # Render banner with multi-colour: white text, coloured arrows, cyan "phpup"
    $bannerLines = $BANNER_ART -split "`n"
    foreach ($line in $bannerLines) {
        if ($line -match '^\│\s+▲') {
            Write-Host "│         " -NoNewline -ForegroundColor White
            Write-Host "▲" -NoNewline -ForegroundColor Yellow
            Write-Host " " -NoNewline -ForegroundColor White
            Write-Host "▲" -NoNewline -ForegroundColor Green
            Write-Host " " -NoNewline -ForegroundColor White
            Write-Host "▲" -NoNewline -ForegroundColor Cyan
            Write-Host "               │" -ForegroundColor White
        }
        elseif ($line -match 'phpup') {
            Write-Host "│         " -NoNewline -ForegroundColor White
            Write-Host "phpup" -NoNewline -ForegroundColor Blue
            Write-Host "               │" -ForegroundColor White
        }
        else {
            Write-Host $line -ForegroundColor White
        }
    }
    Write-Host ""

    # ---- Architecture / OS line ----
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -eq "AMD64") { $arch = "x86_64" }
    $osCaption = (Get-CimInstance Win32_OperatingSystem).Caption
    if ($osCaption -match "Microsoft Windows (.*)") { $osCaption = $matches[1] }
    Write-Host "Architecture: " -NoNewline
    Write-Host "$arch" -ForegroundColor Cyan -NoNewline
    Write-Host " | Windows: " -NoNewline
    Write-Host "$osCaption" -ForegroundColor Cyan
    Write-Host ""

    # ---- System Prerequisites ----
    Write-Host "System Prerequisites:" -ForegroundColor White
    Write-Host "~~~~~~~~~~~~~~~~~~~~~"
    Write-Host "VC++ Redist --> " -NoNewline
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

    # ---- Stack Status ----
    Write-Host ""
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
        $phpInstalledLabel = Get-PhpVersionLabel
        if (Test-PhpIsPreRelease $phpInstalledLabel) {
            Write-Host "$phpInstalledLabel (pre-release)" -ForegroundColor Yellow
        }
        else {
            Write-Host $phpInstalledLabel -ForegroundColor Green
        }
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

    # ---- Process Status ----
    Write-Host ""
    Write-Host "Process Status:" -ForegroundColor White
    Write-Host "~~~~~~~~~~~~~~~"

    Write-Host "Apache -------> " -NoNewline
    if (Test-ApacheRunning) {
        Write-Host "running" -ForegroundColor Green
    }
    else {
        Write-Host "stopped" -ForegroundColor Red
    }

    Write-Host "mod_php ------> " -NoNewline
    if (Test-PhpInstalled) {
        if (Test-PhpApacheModuleWired) {
            if (Test-ApacheRunning) {
                Write-Host "active" -ForegroundColor Green
            }
            else {
                Write-Host "stopped" -ForegroundColor Red
            }
        }
        else {
            Write-Host "not wired" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "not installed" -ForegroundColor Red
    }

    Write-Host "MariaDB ------> " -NoNewline
    if (Test-MariaDbRunning) {
        Write-Host "running" -ForegroundColor Green
    }
    else {
        Write-Host "stopped" -ForegroundColor Red
    }

    # Windows Services (always shown when stack is complete)
    Write-Host ""
    Write-Host "Windows Services:" -ForegroundColor White
    Write-Host "~~~~~~~~~~~~~~~~"
    $svcRegistered = Test-ServicesInstalled
    Write-Host "phpup_Apache   " -NoNewline
    if ($svcRegistered) {
        Write-Host "registered" -ForegroundColor Green
    }
    else {
        Write-Host "not registered" -ForegroundColor DarkGray
    }
    Write-Host "phpup_MariaDB  " -NoNewline
    if ($svcRegistered) {
        Write-Host "registered" -ForegroundColor Green
    }
    else {
        Write-Host "not registered" -ForegroundColor DarkGray
    }

    # ---- Info ----
    if (Test-StackComplete) {
        Write-Host ""
        Write-Host "Where to put website files?  " -NoNewline
        Write-Host $WWW_PATH -ForegroundColor Cyan
        Write-Host "How to test your PHP setup?  " -NoNewline
        Write-Host "http://localhost/phpinfo.php" -ForegroundColor Cyan
        Write-Host "Where to access phpMyAdmin?  " -NoNewline
        Write-Host "http://localhost/phpmyadmin" -ForegroundColor Cyan
        Write-Host "How to log into phpMyAdmin?  " -NoNewline
        Write-Host "Username: root | Password: [blank]" -ForegroundColor Cyan
        Write-Host "Where is the download cache? " -NoNewline
        Write-Host $DOWNLOAD_CACHE -ForegroundColor Cyan
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
        Write-Host "S  Start / Stop services" -NoNewline -ForegroundColor Cyan
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

# CPU architecture check.
# 32-bit Windows cannot run this stack at all — hard block.
if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Err "A 64-bit version of Windows is required."
    exit 1
}

# ARM64 is not natively supported: Apache Lounge, PHP and MariaDB ship no
# ARM64 Windows binaries, so the x64 stack runs under Windows-on-ARM
# emulation (Prism). Warn and continue — it usually works, but it is
# untested territory and slower than native x64.
$cpu_arch = $env:PROCESSOR_ARCHITECTURE

if ($cpu_arch -ne 'AMD64') {
    Write-Host ""
    Write-Warn "Architecture: $cpu_arch — not natively supported."
    Write-Info "phpup's stack is x64-only (Apache Lounge, PHP, MariaDB ship no"
    Write-Info "native ARM64 Windows binaries). On ARM64 it runs under x64"
    Write-Info "emulation: expected to work, but untested and slower than x64."
    Write-Host ""
}

# ---- VC++ Redistributable: system prerequisite (BLOCKING) ----

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
        Write-Info "Delete the config and re-run: Remove-Item '$(Get-ConfigFilePath)'"
        Write-Host ""
        Pause
        exit 1
    }
}
else {
    # First run — prompt for install location
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  phpup Install Location" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Info "Where should the web stack be installed?"
    Write-Info "Press Enter to accept the default, or type a custom path."
    Write-Host ""

    $userPath = Read-Host "Install path [C:\phpup]"

    if ([string]::IsNullOrWhiteSpace($userPath)) {
        $BASE = "C:\phpup"
    }
    else {
        # Strip trailing backslash if present
        $BASE = $userPath.TrimEnd('\')

        # Reject paths with spaces (can break mysqld --datadir)
        if ($BASE -match '\s') {
            Write-Err "Paths containing spaces are not supported (can cause issues with MariaDB)."
            Write-Info "Please use a path without spaces, e.g. C:\phpup"
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
$LOGS_PATH       = "$BASE\logs"
$PHPMYADMIN_PATH = "$BASE\phpmyadmin"

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
                if ((Test-ApacheRunning) -or (Test-MariaDbRunning)) {
                    # Services are running — stop them
                    Stop-WebStackServices
                    if (Test-ServicesInstalled) {
                        $choice = Read-Host "Remove Windows service registration? [y/N]"
                        if ($choice -match "^[Yy]") {
                            Remove-Services
                            Save-Config -InstallPath $BASE -ServicesRegistered:$false -Versions $config.versions -PathEntries $config.path_entries
                            Write-Ok "Windows services removed"
                        }
                    }
                    else {
                        Write-Info "Not registered as Windows services — press S again to register"
                    }
                }
                else {
                    # Services are stopped — start them
                    if (-not (Test-ServicesInstalled)) {
                        Write-Host ""
                        Write-Warn "Services are not registered as Windows services."
                        Write-Info "  Without service registration, Apache and MariaDB won't auto-start on boot."
                        Write-Info "  You'll need to run this script and press 'S' after every reboot."
                        $choice = Read-Host "Register as Windows services now? [y/N]"
                        if ($choice -match "^[Yy]") {
                            Install-AsServices
                            Save-Config -InstallPath $BASE -ServicesRegistered:$true -Versions $config.versions -PathEntries $config.path_entries
                        }
                        else {
                            Start-WebStackServices
                        }
                    }
                    else {
                        Start-WebStackServices
                    }
                }
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
            return
        }
        "fu" {
            if ($stackComplete) { Invoke-ForcedUpdate }
            else { Write-Err "Stack not installed. Use 'I' to install first." }
        }
        default {
            Write-Err "Command not recognised."
        }
    }

    Write-Host ""
    Pause
}
