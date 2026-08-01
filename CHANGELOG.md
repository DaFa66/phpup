# Changelog

All notable changes to phpup will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Hybrid Calendar Versioning](https://calver.org/) (Windows: `Major.Feature.Patch`, Mac/Linux: `Major.Feature.Patch`).

Versions for `phpup.ps1` (Windows) and `phpup.sh` (Mac/Linux) are tracked independently.

---

## [2.2.2] / [0.5.11-beta] — 2026-08-01

### Linux (phpup.sh v0.5.11-beta)

**Added**
- Apache `<Directory>` grant for custom DocumentRoot (default Ubuntu policy denies non-`/var/www` paths)
- phpMyAdmin Apache alias auto-creation (`/etc/apache2/conf-available/phpmyadmin.conf`)
- phpMyAdmin conf.d override system (`/etc/phpmyadmin/conf.d/phpup.php`) — works across all versions without fragile sed
- Home directory traversal fix (`chmod o+x "$HOME"`) — allows `www-data` to reach `~/phpup/www`
- `DEBIAN_FRONTEND=noninteractive` on all apt install commands — suppresses debconf prompts (phpMyAdmin password popup)

**Changed**
- Linux platform status: 🧪 Untested → ✅ Stable (Ubuntu/WSL)
- Service status colours: Running = Green, Stopped = Red, Not available = Red
- PHP-FPM dashboard: now shows "Active (mod_php)" when using `libapache2-mod-php` (apt default)
- Quit command uses `return` instead of `exit` — no longer closes the terminal when script is sourced

**Fixed**
- Removed non-existent `php-sodium` from apt package lists (sodium is built into PHP core)
- MariaDB root auth plugin: switched from `unix_socket` to `mysql_native_password` for phpMyAdmin TCP login
- phpMyAdmin `AllowNoPassword` now iterates all servers (was targeting stale `$i` index)
- Suppressed apt "N packages can be upgraded" noise in update checks

---

## [2.2.2] / [0.4.8-beta] — 2026-07-30

### Windows (phpup.ps1 v2.2.2)

**Changed**
- Banner "phpup" text colour Cyan → Blue (matches colour spec: arrows Yellow/Green/Cyan, text Blue)

### macOS (phpup.sh v0.4.8-beta)

**Added**
- Service start health checks — MariaDB and PHP-FPM verify startup with `pgrep` retry loops (5s timeout)
- Full phpMyAdmin storage database setup (`pma` database with 18 configuration tables)
- `pma@localhost` database user for PMA storage tables
- macOS version check on install — warns pre-Big Sur users that PHP compiles from source
- `sudo -v` at install start to establish credential timeout upfront

**Changed**
- Banner arrows now coloured (Yellow/Green/Cyan) and "phpup" in Blue — matches Windows
- Dashboard version numbers and status indicators now use colour (Green for installed/running)
- PMA config directives (`VersionCheck`, `SendErrorReports`, `LoginCookieValidity`, `TempDir`) now use append-if-missing — handles brew configs that omit these directives
- Apache PHP module loading guarded by `libphp.so` existence check
- Configure functions bail early if component not detected
- `brew update` suppressed during update checks (less noise)
- `HOMEBREW_NO_ENV_HINTS=1` on all brew installs — suppresses Caveats output
- `brew link --overwrite --force phpmyadmin` after install — fixes stale Cellar linking
- Delete confirmation lists preserved paths with colour-coding

**Fixed**
- MariaDB socket authentication now reset to native password — brew 12.3.2 defaults to `unix_socket` which blocks PHP/PMA access
- Service stop now kills processes with `pkill` after `brew services stop` — ensures actual termination
- Apache stop only runs when service is detected running (no more "not running" noise)
- PMA blowfish secret regex now handles brew's trailing comment after `'';`
- Document root permissions use `sudo sh -c` single invocation instead of separate sudo calls
- Delete now force-uninstalls lingering Cellar kegs (PMA twig cache owned by `_www` blocks `rm -rf`)
- Delete removes stale LaunchAgent plists and MariaDB data directory
- Delete warns about remaining Cellar skeletons
- `detect_all` called after service toggle — dashboard reflects actual state

**Removed**
- Config backup/restore on delete (brew preserves configs natively)
- Offline/cache info from main loop

### Linux (phpup.sh v0.4.8-beta)

**Added**
- Service start health checks — Apache, MariaDB, PHP-FPM verified after start
- Full phpMyAdmin storage database setup

**Changed**
- Dashboard version numbers and status indicators now coloured
- PMA config directives use append-if-missing pattern
- Configure functions bail early if component not detected
- `brew update` suppressed (n/a on apt but code path shared)

**Fixed**
- PMA config `sed` escaping corrected for `sudo` context (extra backslash layers)
- Service stop now more aggressive — ensures all processes terminate
- Delete removes logs directory

---

## [2.2.1] / [1.1.1] — 2026-07-26

### Windows (phpup.ps1 v2.2.1)

**Added**
- Upload limits: `upload_max_filesize=50M`, `post_max_size=55M`, `max_execution_time=300`, `max_input_time=300`
- `session.gc_maxlifetime=14400` in php.ini (matches PMA `LoginCookieValidity`)

**Changed**
- PMA config: `ShowStats=false`, `LoginCookieValidity=14400`, `SendErrorReports=never`, `VersionCheck=false`

**Fixed**
- PMA storage database name corrected to `pma` (was `phpmyadmin`)
- `ShowStats` directive name (was incorrectly `ShowDbStats` in earlier attempts)
- `TempDir` created with correct group ownership for template cache

### macOS & Linux (phpup.sh v1.1.1)

**Added**
- `session.gc_maxlifetime=14400` in php.ini

**Changed**
- PMA config: `ShowStats`, `LoginCookieValidity`, `SendErrorReports`, `VersionCheck`
- PMA tmp directory created with `chgrp` for web server user

**Fixed**
- PMA `ShowStats` directive name corrected

---

## [2.2.0] / [1.1.0] — 2026-07-25

### Windows (phpup.ps1 v2.2.0)

**Added**
- Upload limits: 50 MB files, 300s timeout (for large PMA imports)
- Config backup/restore on delete — preserves httpd.conf, php.ini, my.ini, config.inc.php
- `config_backup/` directory in delete preserved paths

**Changed**
- `Save-PostUpdateConfig` now detects all versions from live filesystem (self-healing)
- Forced update (`fu`) summary shows all cached versions per component
- ICU DLLs discovered dynamically (no hardcoded versions — survives PHP version switches)

**Fixed**
- `$env:VAR` interpolation for literal paths (`C:\phpup` — not `$env:c`)
- Save-Config no longer wipes version data on toggle/register/install-path changes
- Install-AsServices no longer stops services before registering when nothing is running
- NTS PHP builds excluded from forced update selection with cyan info message

### macOS & Linux (phpup.sh v1.1.0)

**Added**
- PHP upload limits: `upload_max_filesize=50M`, `post_max_size=55M`, `max_execution_time=300`, `max_input_time=300`

---

## [2.1.1] — 2026-07-05

### Windows (phpup.ps1 v2.1.1)

**Added**
- PowerShell alias installation instructions in README Quick Start

**Changed**
- VC++ section header suppressed when prerequisite already met (cleaner dashboard)

---

## [2.1.0] — 2026-07-05

### Windows (phpup.ps1 v2.1.0)

**Changed**
- `S` and `T` commands merged into a single `S` toggle (four-state: start/stop × registered/process)
- Dashboard sections reordered: Prerequisites → Stack → Process Status → Services → Info → Commands
- "Service Status" renamed to "Process Status" to disambiguate from "Windows Services"

**Fixed**
- VC++ section header hidden when already installed
- Dashboard Info block labels aligned at 30-character column

---

## [2.0.0] — 2026-06-28

### Windows (phpup.ps1 v2.0.0)

**Changed**
- **Rebranded from getPHP to phpup** — new identity, new repo (`DaFa66/phpup`)
- Default install path: `C:\phpup` (was `C:\getphp`)
- Service names: `phpup_Apache`, `phpup_MariaDB` (was `getPHP_Apache`, `getPHP_MariaDB`)
- Download cache: `C:\phpup\downloads\` (was `%TEMP%\webstack_downloads` — no longer cleaned by Disk Cleanup)
- phpMyAdmin at stack root: `C:\phpup\phpmyadmin\` (was under `www\`)
- Config file: `%APPDATA%\phpup\config.json`

**Fixed**
- Apache Lounge fallback URL updated to current build
- Banner phpup text aligned with arrows
- Cyan border bleed in multi-colour banner rendering

---

## [1.0.6] — 2026-06-20

### Windows (getphp.ps1 v1.0.6)

**Changed**
- "pro" tag added to ASCII banner
- Banner removed from VC++ prerequisite check (cleaner output)

**Fixed**
- `#Requires -RunAsAdministrator` removed — custom admin check with friendly message now works
- `Get-VersionFromZipName` PHP regex handles RC releases (e.g. `php-8.5.8RC1-Win32-vs17-x64.zip`)

---

## [1.0.5] — 2026-06-16

### Windows (getphp.ps1 v1.0.5)

**Added**
- Forced update (`fu`) — offline version switching from cached zips
- Multi-version selection per component with colour-coded tags (current/newer/older)
- `Get-VersionFromZipName` with 3-part version normalisation
- `Backup-MariaDbData` and `Restore-MariaDbData` shared helpers
- Database backup during updates (`data_backup_update/`)

**Fixed**
- NTS PHP builds excluded from forced update (incompatible with Apache)
- phpMyAdmin snapshot filename regex (handles `+snapshot` suffix)
- PHP prerelease filename regex (handles `RC1`, `alpha2`, `beta1` without dash separator)
- Empty cache fallback uses `Write-Info` (cyan) instead of `Write-Err` (red)

---

## [1.0.4] — 2026-06-14

### Windows (getphp.ps1 v1.0.4)

**Added**
- Sodium PHP extension enabled
- `-Offline` switch — installs from cached zips only, no network
- `Invoke-ExtractZip` — offline zip extractor with wrapper flattening

**Changed**
- Extraction skip logic: only skips when destination already populated AND using cached zip

**Fixed**
- `Invoke-ExtractZip` handles multi-file zips with known wrapper patterns (Apache Lounge, PHP, MariaDB)
- Progress bars suppressed during bulk file flattening (preserves download progress)

---

## [1.0.3] — 2026-06-13

### Windows (getphp.ps1 v1.0.3)

**Added**
- Downloaded zip caching in `%TEMP%\webstack_downloads` for reuse on reinstall
- PHP fallback URL
- VC++ installer cached (not deleted after use)
- SQLite3 DLL zip cached in download directory

**Changed**
- VC++ redistributable URL standardised to `aka.ms/vc14/vc_redist.x64.exe`
- Service registration de-duplicated — routes through `Install-AsServices`
- Logs consolidated to `C:\getphp\logs\`

**Fixed**
- Logs directory removed on delete
- phpMyAdmin zip extracted in offline mode
- MariaDB download uses archive URL (not REST API redirector)

---

## [1.0.2] — 2026-06-08

### Windows (getphp.ps1 v1.0.2)

**Added**
- PHP JIT compilation enabled (tracing JIT, 100 MB buffer)
- OPCache enabled for CLI (JIT requirement)
- Service registration state persisted in config.json
- Dashboard "Windows Services" section showing registration status
- ARM64/ARM CPU architectures blocked at startup

**Changed**
- VC++ prerequisite check is now blocking (minimum version 14.51.36231 required)
- CPU architecture detection uses `PROCESSOR_ARCHITECTURE` env var (not .NET API)
- Asset resolution hardened — fallback URLs, retry logic, offline mode

**Fixed**
- JIT directives appended when absent from default php.ini
- MariaDB download retry on failure
- Config serialization for complex objects

---

## [1.0.1] — 2026-06-06

### Windows (getphp.ps1 v1.0.1)

**Added**
- Smart update — checks all components for newer versions, updates selectively
- Optional Windows service registration for auto-start on boot
- `data_backup/` preservation on delete with restore offer on reinstall
- Delete output cleaned up — no duplicate stop banner or service warnings

**Changed**
- Shared helper functions extracted and consolidated
- Constants consolidated at script top

**Fixed**
- `Get-Service` null reference when service doesn't exist
- CPU architecture check uses .NET API for robustness
- Pre-existing `data_backup` on delete handled gracefully (archived with timestamp)

---

## [1.0.0] — 2026-06-05

### Windows (getphp.ps1 v1.0.0)

**Added**
- Initial PowerShell release
- Apache, PHP, MariaDB, phpMyAdmin install/update/delete
- Interactive dashboard with command menu (I, U, S, T, R, D, Q)
- VC++ Redistributable auto-check and install
- Config persistence (`%APPDATA%\getphp\config.json`)
- PATH management for PHP and MariaDB CLI tools
- phpMyAdmin version detection
- Database backup on delete (`data_backup/`)

---

## Pre-fork History — getphp.sh (Mac)

*The original `getphp.sh` was created by Balázs Zatik for the [getphp.org](https://getphp.org) project. phpup's Mac/Linux script began as a fork of this work.*

### macOS (getphp.sh — Balázs Zatik, 2026-03-26 to 2026-07-19)

- Initial ZAMPP Dashboard (v1.0.0, 2026-03-26)
- Homebrew-based Apache, PHP, MariaDB, phpMyAdmin install
- Interactive dashboard with service management
- Linux compatibility (Ubuntu, Debian, Mint) via Homebrew on Linux
- Delete with confirmation prompt
- Platform detection and Homebrew PATH management

*phpup forked from upstream on 2026-07-19, adding native apt support for Linux, service hardening, and extensive configuration fixes.*

---

## Version History Summary

### Windows (phpup.ps1)

| Version | Date | Key Changes |
|---------|------|-------------|
| **2.2.2** | 2026-07-27 | Banner colour fix |
| **2.2.1** | 2026-07-26 | PMA config, upload limits, session lifetime |
| **2.2.0** | 2026-07-25 | Forced update, config persistence, upload limits |
| **2.1.1** | 2026-07-05 | PowerShell alias, VC++ section fix |
| **2.1.0** | 2026-07-05 | S+T toggle merge, dashboard reorder |
| **2.0.0** | 2026-06-28 | Rebrand to phpup |
| **1.0.6** | 2026-06-20 | RC regex, admin message fix |
| **1.0.5** | 2026-06-16 | Forced update (`fu`) |
| **1.0.4** | 2026-06-14 | Sodium, offline switch, extraction fixes |
| **1.0.3** | 2026-06-13 | Zip caching, MariaDB fixes, log consolidation |
| **1.0.2** | 2026-06-08 | JIT, fallback URLs, service registration |
| **1.0.1** | 2026-06-06 | Smart update, service registration |
| **1.0.0** | 2026-06-05 | Initial release |

### Mac & Linux (phpup.sh)

| Version | Date | Key Changes |
|---------|------|-------------|
| **0.5.11-beta** | 2026-08-01 | Linux apt support, 8 fixes (php-sodium, MariaDB auth, PMA config) |
| **0.4.8-beta** | 2026-07-30 | Service overhaul, PMA storage, delete hardening, MariaDB auth |
| **1.1.1** | 2026-07-26 | PMA config, session lifetime |
| **1.1.0** | 2026-07-25 | PHP upload limits |
| **1.0.0** | 2026-07-19 | Initial phpup fork — native apt, 19 fixes |

[0.5.11-beta]: https://github.com/DaFa66/phpup/releases/tag/v0.5.11-beta
[2.2.2]: https://github.com/DaFa66/phpup/releases/tag/v2.2.2+0.4.8-beta
[2.2.1]: https://github.com/DaFa66/phpup/releases/tag/v2.2.1+1.1.1
[2.2.0]: https://github.com/DaFa66/phpup/releases/tag/v2.2.0+1.1.0
[2.1.1]: https://github.com/DaFa66/phpup/releases/tag/v2.1.1
[2.1.0]: https://github.com/DaFa66/phpup/releases/tag/v2.1.0
[2.0.0]: https://github.com/DaFa66/phpup/releases/tag/v2.0.0
[1.0.6]: https://github.com/DaFa66/phpup/releases/tag/v1.0.6
[1.0.5]: https://github.com/DaFa66/phpup/releases/tag/v1.0.5
[1.0.2]: https://github.com/DaFa66/phpup/releases/tag/v1.0.2
[1.0.0]: https://github.com/DaFa66/phpup/releases/tag/v1.0.0-win
