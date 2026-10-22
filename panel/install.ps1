#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the phpup desktop panel from a release zip.

.DESCRIPTION
    Copies phpup-panel.exe into the phpup bin directory and reports how to run it.
    No elevation and no registry changes. Starting with Windows is a toggle in the
    panel's own Settings, backed by a per-user Run entry.

.PARAMETER Destination
    Directory to install into. Defaults to <install_path>\bin from phpup's
    config.json, or C:\phpup\bin when that cannot be read.

.PARAMETER NoStart
    Install only; do not launch the panel afterwards.

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -Destination 'D:\tools\phpup\bin' -NoStart
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'phpup-panel.exe'
if (-not (Test-Path -LiteralPath $source)) {
    throw "phpup-panel.exe not found next to this script: $source"
}

if (-not $Destination) {
    $installPath = 'C:\phpup'
    $config = Join-Path $installPath 'config.json'
    if (Test-Path -LiteralPath $config) {
        try {
            $parsed = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
            if ($parsed.install_path) { $installPath = $parsed.install_path }
        }
        catch {
            Write-Warning "Could not read $config, using $installPath."
        }
    }
    $Destination = Join-Path $installPath 'bin'
}

$target = Join-Path $Destination 'phpup-panel.exe'

# The exe is locked while the panel runs, so stop an instance using this file.
$running = @(Get-Process phpup-panel -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    $paths = $running | ForEach-Object { $_.Path }
    if (($paths -contains $target) -or ($paths -contains $source)) {
        Write-Host "Stopping the running panel so the file can be replaced." -ForegroundColor DarkGray
        $running | Stop-Process -Force
        Start-Sleep -Milliseconds 800
    }
}

if (-not (Test-Path -LiteralPath $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}

Copy-Item -LiteralPath $source -Destination $target -Force

$info = Get-Item -LiteralPath $target
$hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLower()

Write-Host ""
Write-Host "phpup panel installed" -ForegroundColor Green
Write-Host "  path    : $target"
Write-Host "  size    : $([math]::Round($info.Length / 1MB, 1)) MB"
Write-Host "  sha256  : $hash"
Write-Host ""
Write-Host "Run it with:" -ForegroundColor Cyan
Write-Host "  $target"
Write-Host ""
Write-Host "Optional, from the panel itself under Settings:"
Write-Host "  Window  -> Start hidden in the tray   no window and no taskbar button at launch"
Write-Host "  Startup -> Start with Windows         per-user Run entry, no elevation"
Write-Host ""

if (-not $NoStart) {
    Start-Process -FilePath $target
    Write-Host "Started." -ForegroundColor DarkGray
}
