# ============================================================
#  getPHP — Windows 11 Web Stack Installer & Dashboard
#  Inspired by getphp.org (Mac) — PowerShell Edition
#  Github: https://github.com/getphporg/getphp
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

function Test-ApacheRunning {
    return (Get-Process -Name "httpd" -ErrorAction SilentlyContinue) -ne $null
}

function Test-MariaDbRunning {
    return ((Get-Process -Name "mysqld" -ErrorAction SilentlyContinue) -ne $null) -or
           ((Get-Process -Name "mariadbd" -ErrorAction SilentlyContinue) -ne $null)
}

function Test-StackComplete {
    return (Test-ApacheInstalled) -and (Test-PhpInstalled) -and (Test-MariaDbInstalled) -and (Test-PhpMyAdminInstalled)
}

# ============================================================
#  URL RESOLUTION — Latest Stable Versions
# ============================================================

function Get-LatestApacheUrl {
    Write-Info "Resolving Apache (Apache Lounge - latest VS18 x64 build)..."

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
        Write-Err "Failed to resolve Apache URL: $($_.Exception.Message)"
        throw
    }
}

function Get-LatestPhpUrl {
    Write-Info "Resolving PHP (latest 8.x stable, thread-safe x64 - preferring VS17)..."

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
        Write-Err "Failed to resolve PHP URL: $($_.Exception.Message)"
        throw
    }
}

function Get-LatestMariadbUrl {
    Write-Info "Resolving MariaDB (latest stable, Windows x64)..."

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
        Write-Err "Failed to resolve MariaDB URL: $($_.Exception.Message)"
        throw
    }
}

function Get-LatestPhpMyAdminUrl {
    Write-Info "Resolving phpMyAdmin (latest stable, all-languages)..."

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
        Write-Err "Failed to resolve phpMyAdmin URL: $($_.Exception.Message)"
        throw
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

    try {
        # MariaDB uses HTTP redirects that Invoke-WebRequest can't handle reliably.
        # Use manual redirect-following downloader instead.
        if ($url -like "*mariadb*") {
            Write-Info "  (using redirect-resolving downloader)"

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

                # Final URL reached — stream to file
                $stream = $response.GetResponseStream()
                $fileStream = [System.IO.File]::Create($zipPath)
                $stream.CopyTo($fileStream)
                $fileStream.Close()
                $stream.Close()
                $response.Close()
                break
            }

            if ($i -ge $max_redirects) {
                throw "Too many redirects resolving MariaDB download"
            }
        }
        elseif ($url -like "*files.phpmyadmin*") {
            Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -MaximumRedirection 10 -Headers @{ "User-Agent" = $ua }
        }
        else {
            Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -Headers @{ "User-Agent" = $ua }
        }
    }
    catch {
        throw "Download failed for $label : $($_.Exception.Message)"
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
    $apacheUnix = $APACHE_PATH -replace '\', '/'

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
    $phpModuleUnix = "$($PHP_PATH -replace '\','/')/php8apache2_4.dll"
    $phpIniUnix    = $PHP_PATH -replace '\','/'

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
        $pmaUnix = $PHPMYADMIN_PATH -replace '\', '/'
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
    $conf = $conf -replace 'ErrorLog\s+".*"', "ErrorLog `"$wwwUnix/error_log`""
    $conf = $conf -replace 'CustomLog\s+".*"\s+common', "CustomLog `"$wwwUnix/access_log`" common"
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
        'extention=intl',
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
    $ini = $ini -replace ';?opcache\.enable_cli\s*=\s*\d', 'opcache.enable_cli=0'
    $ini = $ini -replace ';?opcache\.memory_consumption\s*=\s*\d+', 'opcache.memory_consumption=256'
    $ini = $ini -replace ';?opcache\.interned_strings_buffer\s*=\s*\d+', 'opcache.interned_strings_buffer=16'
    $ini = $ini -replace ';?opcache\.max_accelerated_files\s*=\s*\d+', 'opcache.max_accelerated_files=20000'
    $ini = $ini -replace ';?opcache\.validate_timestamps\s*=\s*\d', 'opcache.validate_timestamps=1'
    $ini = $ini -replace ';?opcache\.revalidate_freq\s*=\s*\d+', 'opcache.revalidate_freq=2'
    Write-Ok "OPCache enabled (256 MB, production-ready)"

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
        if ($html.Content -match '[/\w]*sqlite-dll-win-x64-(\d+)\.zip') {
            $zipPath = $matches[0]
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
    Write-Warn "Configuring phpMyAdmin..."

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
"@

    Set-Content -Path $configPath -Value $config
    Write-Ok "phpMyAdmin configured (root / blank password)"
}

# ============================================================
#  SERVICE MANAGEMENT
# ============================================================

function Start-WebStackServices {
    Write-Host ""
    Write-Warn "Starting services..."

    # Apache
    if (Test-ApacheRunning) {
        Write-Info "Apache is already running"
    }
    else {
        # Quick syntax check first - captures config errors before daemonizing
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
            Write-Err "Apache failed to start - check error_log in $WWW_PATH"
            Write-Info "Common causes: port 80 in use, missing VC++ Redistributable, or config error."
        }
    }

    # MariaDB
    if (Test-MariaDbRunning) {
        Write-Info "MariaDB is already running"
    }
    else {
        $dataDir = "$MARIADB_PATH\data"
        $mysqld  = if (Test-Path "$MARIADB_PATH\bin\mariadbd.exe") { "$MARIADB_PATH\bin\mariadbd.exe" } else { "$MARIADB_PATH\bin\mysqld.exe" }

        $proc = Start-Process -FilePath $mysqld `
            -ArgumentList "--datadir=`"$dataDir`"", "--console" `
            -WindowStyle Hidden `
            -PassThru

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

    if (Test-ApacheRunning) {
        # Try graceful shutdown first, fall back to force kill
        $graceful = & "$APACHE_PATH\bin\httpd.exe" -k stop 2>&1
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

    if (Test-MariaDbRunning) {
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

# ============================================================
#  INSTALL
# ============================================================

function Invoke-InstallWebStack {
    Write-Host ""
    Write-Bold "========================================"
    Write-Bold "  Installing PHP Web Stack on Windows"
    Write-Bold "========================================"

    # Pre-flight: VS18 Redistributable notice
    Write-Host ""
    Write-Warn "Apache Lounge VS18 binaries require the latest Visual C++ Redistributable."
    Write-Info "  If Apache fails to start, download and install:"
    Write-Info "  https://aka.ms/vs/17/release/vc_redist.x64.exe"
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

    # Download and extract
    Invoke-DownloadAndExtract $apacheUrl  $APACHE_PATH     "Apache"
    Invoke-DownloadAndExtract $phpUrl     $PHP_PATH        "PHP"
    Invoke-DownloadAndExtract $mariadbUrl $MARIADB_PATH    "MariaDB"
    Invoke-DownloadAndExtract $pmaUrl     $PHPMYADMIN_PATH "phpMyAdmin"

    # Copy PHP dependency DLLs to Apache bin (ICU, curl deps, etc.)
    # Windows DLL search starts from httpd.exe's directory, not PHP's.
    Invoke-CopyPhpDlls

    # Configure
    Invoke-ConfigureApache
    Invoke-ConfigurePhp
    Invoke-FixSqliteDll
    Invoke-ConfigureMariaDb
    Invoke-ConfigurePhpMyAdmin

    # Create test file
    "<?php phpinfo(); ?>" | Out-File -FilePath "$WWW_PATH\phpinfo.php" -Encoding ASCII
    Write-Ok "Created $WWW_PATH\phpinfo.php"

    # Start services
    Start-WebStackServices

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

    $currentApacheVer  = Get-ApacheVersion
    $currentPhpVer     = Get-PhpVersion
    $currentMariadbVer = Get-MariaDbVersion

    Write-Host ""
    Write-Info "Current versions:"
    Write-Info "  Apache:  $currentApacheVer"
    Write-Info "  PHP:     $currentPhpVer"
    Write-Info "  MariaDB: $currentMariadbVer"

    $confirm = Read-Host "Re-download and re-install all components? This will overwrite current configs [y/N]"

    if ($confirm -notmatch '^[yY]') {
        Write-Info "Update cancelled."
        return
    }

    Stop-WebStackServices

    # Clean and re-download
    Write-Host ""
    Write-Warn "Removing old installations..."
    Remove-Item $APACHE_PATH -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $PHP_PATH -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $MARIADB_PATH -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $PHPMYADMIN_PATH -Recurse -Force -ErrorAction SilentlyContinue

    # Re-install
    Invoke-DownloadAndExtract $latestApacheUrl  $APACHE_PATH     "Apache"
    Invoke-DownloadAndExtract $latestPhpUrl     $PHP_PATH        "PHP"
    Invoke-DownloadAndExtract $latestMariadbUrl $MARIADB_PATH    "MariaDB"
    Invoke-DownloadAndExtract $latestPmaUrl     $PHPMYADMIN_PATH "phpMyAdmin"

    Invoke-ConfigureApache
    Invoke-ConfigurePhp
    Invoke-FixSqliteDll
    Invoke-ConfigureMariaDb
    Invoke-ConfigurePhpMyAdmin

    Start-WebStackServices
    Write-Ok "Update complete"
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

    if ($confirm -ne "DELETE") {
        Write-Info "Nothing was deleted."
        return
    }

    Stop-WebStackServices

    # Preserve MariaDB data before removing
    $dataDir = "$MARIADB_PATH\data"
    $backupDir = "$BASE\data_backup"
    if (Test-Path $dataDir) {
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
        Write-Host "available" -ForegroundColor Green
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
        Write-Host "T  Start all services" -ForegroundColor Cyan
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

# Prompt for install location
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  getPHP Web Stack Install Location" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Info "Where should the web stack be installed?"
Write-Info "Press Enter to accept the default, or type a custom path."
Write-Host ""

$userPath = Read-Host "Install path [D:\webstack]"

if ([string]::IsNullOrWhiteSpace($userPath)) {
    $BASE = "D:\webstack"
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

# Derive all paths from $BASE
$APACHE_PATH     = "$BASE\apache"
$PHP_PATH        = "$BASE\php"
$MARIADB_PATH    = "$BASE\mariadb"
$WWW_PATH        = "$BASE\www"
$PHPMYADMIN_PATH = "$WWW_PATH\phpmyadmin"

Write-Host ""
Write-Ok "Web stack will be installed to: $BASE"
Write-Info "  Websites:  $WWW_PATH"
Write-Info "  phpMyAdmin: http://localhost/phpmyadmin"
Write-Host ""

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
            if ($stackComplete) { Stop-WebStackServices }
            else { Write-Err "Stack not installed." }
        }
        "t" {
            if ($stackComplete) { Start-WebStackServices }
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
