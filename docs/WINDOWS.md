# phpup on Windows

> Bare-metal PHP development environment for Windows 10/11 x64.
> Apache, PHP, MariaDB, and phpMyAdmin — installed, configured, and ready to use.

## Prerequisites

- **Windows 10 or 11** (x64 — Intel/AMD 64-bit; ARM64 devices run the x64 stack under emulation, see [ARM64 & Emulation](#arm64--emulation))
- **Run as Administrator** (required for port 80 binding and service registration)
- **Visual C++ Redistributable** — [VC++ 2015–2022 x64](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170), minimum version 14.51.36231. phpup checks on startup and offers a one-click upgrade if needed.

## Quick Start

Right-click PowerShell → **Run as Administrator**, then:

```powershell
irm https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.ps1 | iex
```

After launching, press **I** to install. On subsequent runs the script remembers your setup and goes straight to the dashboard.

### PowerShell Alias (Optional)

Add this to your PowerShell profile for a quick `phpup` command:

```powershell
function phpup {
    $command = "irm https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.ps1 | iex"
    Start-Process pwsh `
        -Verb RunAs `
        -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $command
}
```

> **Note:** `pwsh` is PowerShell 7+. For Windows PowerShell 5.1, replace with `powershell`.

## Directory Layout

All components install to `C:\phpup\` by default:

```
C:\phpup\
├── apache\          # Apache Lounge (VS18, port 80)
├── php\             # PHP 8.x thread-safe x64
├── mariadb\         # MariaDB
├── www\             # ← Your websites go here
│   └── phpinfo.php  # (auto-created test file)
├── phpmyadmin\      # phpMyAdmin (at stack root)
├── downloads\       # Cached component zips
├── logs\            # All log files
│   ├── apache_error.log
│   ├── apache_access.log
│   ├── php_errors.log
│   └── mariadb_error.log
├── data_backup\     # (created on delete — databases preserved)
└── config_backup\   # (created on delete — config files preserved)
```

## Component Sources

| Component      | Source                                                         |
| -------------- | -------------------------------------------------------------- |
| **Apache**     | [Apache Lounge](https://www.apachelounge.com/download/)        |
| **PHP**        | [windows.php.net](https://windows.php.net/downloads/releases/) |
| **MariaDB**    | [mariadb.org](https://downloads.mariadb.org/rest-api/mariadb/) |
| **phpMyAdmin** | [phpmyadmin.net](https://www.phpmyadmin.net/downloads/)        |

## Version Resolution

phpup doesn't hardcode version numbers. Every install and update dynamically resolves the latest stable release:

| Component      | Source          | Method                                                           |
| -------------- | --------------- | ---------------------------------------------------------------- |
| **Apache**     | Apache Lounge   | Scrapes download page, picks highest VS version × Apache version |
| **PHP**        | windows.php.net | Queries `releases.json`, filters for 8.x TS x64, prefers VS17    |
| **MariaDB**    | mariadb.org     | REST API, sorts by support policy (Rolling > LTS), then version  |
| **phpMyAdmin** | phpmyadmin.net  | Scrapes downloads page for latest stable `all-languages.zip`     |

## What the Installer Configures

### Apache

- Port 80, ServerName `localhost:80`
- DocumentRoot with `Options Indexes FollowSymLinks`
- `mod_rewrite` enabled with `AllowOverride All` — `.htaccess` rewrites work out of the box
- PHP module loaded automatically
- phpMyAdmin alias at `/phpmyadmin`
- Error and access logs written to `logs/`

### PHP

- **Extensions:** `curl`, `fileinfo`, `gd`, `intl`, `mbstring`, `mysqli`, `openssl`, `pdo_mysql`, `pdo_sqlite`, `sodium`, `sqlite3`
- `display_errors = On`
- Error log routed to `logs/php_errors.log`
- OPCache enabled with 256 MB memory, JIT tracing, 100 MB buffer — web server only; CLI runs with opcache off so phar tools (Composer, artisan) work reliably
- PHP dependency DLLs copied to Apache `bin/` for clean extension loading
- Added to user PATH

#### SQLite3 DLL Fix

VS17 PHP builds bundle an incompatible `libsqlite3.dll` that causes "Entry Point Not Found" popups. The installer downloads a compatible DLL from [sqlite.org](https://sqlite.org/) and replaces it in both the PHP root and Apache `bin/`.

### MariaDB

- Data directory initialized with blank root password
- `my.ini` with error log routed to `logs/mariadb_error.log`
- Latest stable release resolved via REST API
- Added to user PATH

### phpMyAdmin

- Auto-generated `config.inc.php` with blowfish secret and blank-password root login
- Version check disabled (no phoning home on login)
- 4-hour session timeout
- Template cache directory configured
- Configuration storage database (`pma`) with bookmark, history, and designer support

## Offline Mode & Version Switching

Run with `-Offline` to skip all network activity:

```powershell
.\phpup.ps1 -Offline
```

Requires pre-downloaded zips in `C:\phpup\downloads\`. Run the script online once to populate the cache, then all subsequent installs skip downloads entirely.

Once multiple versions are cached, the hidden **`fu`** command lets you switch between them interactively — upgrades, downgrades, or snapshots — without touching the network. MariaDB databases are automatically backed up and restored across version changes.

### `fu` on Windows — PHP series management

`fu` manages **PHP only** on Windows (Apache, MariaDB, and phpMyAdmin keep the simple cached-zip list). It groups cached PHP builds by series (8.2 → newest stable) and:

- **Pre-release labels** — alpha/beta/RC builds show their suffix (e.g. `8.6.0 alpha3` vs `8.6.0 beta1`) instead of collapsing to the same version
- **Pre-release installs flagged** — the dashboard stack list and the fu cache summary show the full label (`8.6.0 beta1 (pre-release)`, yellow) when the installed PHP is newer than the latest stable (alpha/beta/RC)
- **Missing series** — a series with nothing cached is offered as `(not cached — download & install)`; choosing it downloads the latest stable patch and installs it. Any `N.M` series listed by windows.php.net is a candidate, bounded by `php_min_series` (default `8.2`); 7.x builds resolve via their VC15 toolchain builds
- **Newer patch hints** — a cached version behind the latest in its series is flagged: `8.2.32 (older → 8.2.33 is available)`. Selecting it asks whether to install the newer patch (downloading it first, with an option to delete the old cached copy) or use the cached one as-is
- **Multiple variants** — when a series has more than one cached patch, entries show `*`; selecting one opens a sub-menu of the variants, where each can be installed or deleted (`[d]` + row number, with a Yes/No confirm). Delete accepts both `d<number>` and `<number>d` (`d2` and `2d` both work); a bare `d` prints a format hint. After a delete that leaves only the installed build, `fu` returns you to the series list (re-scanning the cache) instead of showing a dead-end list
- **Strict input** — menu choices must be plain numbers. `2d`/`2x`/garbage are rejected with "Invalid choice" rather than being silently coerced
- **Selection confirmation** — picking a PHP version prints `PHP → 8.2.33` before the next component menu, matching the Apache/MariaDB/phpMyAdmin confirmations

Online, `fu` checks windows.php.net for the latest stable per series. Run with `-Offline` to skip the network check — the menu then lists cached versions only (labels and variant markers still apply, but no hints or download offers).

A configurable floor (`php_min_series` in `%APPDATA%\phpup\config.json`, default `8.2`) controls the oldest PHP series offered as a download candidate — set it to `8.0` to keep offering EOL series, or raise it to narrow the list. Cached zips are always listed regardless of the floor. The key is written to config.json automatically (visible and editable), and an older config that predates the key simply falls back to the `8.2` default.

Apache's PHP module follows the installed PHP major: 7.x loads `php7apache2_4.dll` with `LoadModule php7_module`, 8.x loads `php8apache2_4.dll` with `LoadModule php_module` (the symbol PHP 8 actually exports — there is no `php8_module`). httpd.conf is re-pointed automatically after any PHP switch, so going 8 ↔ 7 keeps Apache loadable.

The dashboard's **Process Status** section groups the web server with its PHP engine (`Apache` → `mod_php` → `MariaDB`). The PHP row reports the real integration state instead of a generic CLI message: `mod_php ------> active` (green) when the module line is wired and Apache is running, `stopped` (red) when Apache is down, `not wired` (yellow) when the LoadModule line is missing or points at a dead DLL (a stale module line after a broken version switch), and `not installed` (red) when php.exe is absent.

## Partial Stack Recovery

If one or more components are missing (a failed `fu` apply, a manually deleted folder, an interrupted install), the dashboard shows a **partial stack detected** notice and offers **I** Install as the recovery path. Install skips components already at or above the latest version (Apache, PHP, MariaDB, and phpMyAdmin are all checked) and installs only what's missing — websites, databases, and settings are preserved.

MariaDB upgrades are data-safe: the install path stops the services, backs up the data directory to `data_backup_update\`, extracts the new version, and restores the data before restarting. This applies to both online installs and `-Offline` cached-zip installs.

## Service Registration

During install, you're prompted to register Apache and MariaDB as Windows services for auto-start on boot. If you skip it, the **S** toggle will offer registration later. Services are named `phpup_Apache` and `phpup_MariaDB`. The dashboard shows current registration state and the **S** command works in both directions — it can also unregister services when they're no longer needed.

## Safe Delete

Pressing **D** stops services, backs up your config files (`httpd.conf`, `php.ini`, `my.ini`, `config.inc.php`) to `config_backup\` and MariaDB data to `data_backup\`, then removes Apache, PHP, MariaDB, and phpMyAdmin. Your website files in `www\` are untouched.

On reinstall, the script detects both backups and offers to restore your databases and config files — MariaDB picks up the restored data without re-initialisation, and your Apache, PHP, and phpMyAdmin settings are preserved.

## Persistent Config

The script saves state to **`config.json` in the install folder** (e.g. `C:\phpup\config.json`), so the config travels with the stack:

- **Install path** — prompted once, remembered thereafter
- **Component versions** — tracked after each install/update (PHP records the full label, e.g. `8.6.0 beta1`)
- **Service registration state** — persisted between runs
- **PATH entries** — tracked for clean uninstall
- **PHP floor (`php_min_series`)** — written on first save (default `8.2`); edit it to change the oldest PHP series `fu` offers as a download candidate

A discovery pointer (`%APPDATA%\phpup\config.json`) is written only when the install path differs from the default `C:\phpup` — it lets a custom/moved stack be found on later runs. Default-path installs don't create it.

Example:

```json
{
  "install_path": "C:\\phpup",
  "installed_at": "2026-06-05T20:45:00",
  "services_registered": true,
  "php_min_series": "8.2",
  "versions": {
    "apache": "2.4.68",
    "php": "8.5.9",
    "mariadb": "12.3.2",
    "phpmyadmin": "5.2.3"
  }
}
```

Config is cleared when you delete the stack. The next run prompts for a fresh install path.

## After Installation

| Question                    | Answer                                 |
| --------------------------- | -------------------------------------- |
| Where to put website files? | `C:\phpup\www`                         |
| Test your PHP setup?        | http://localhost/phpinfo.php           |
| Access phpMyAdmin?          | http://localhost/phpmyadmin            |
| Login to phpMyAdmin?        | Username: `root` / Password: _(blank)_ |
| PHP from terminal?          | `php` and `mysql` available in PATH    |

## Uninstalling

Press **D** to delete the stack. Your website files in `www\` and databases in `data_backup\` are preserved. PATH entries are removed and config is cleared.

For a complete wipe, delete `C:\phpup\` and `%APPDATA%\phpup\` manually after running Delete.

## ARM64 & Emulation

phpup's stack is **x64-only** — Apache Lounge, PHP, and MariaDB do not ship native ARM64 Windows binaries, so there is nothing native to install on ARM64 devices (Snapdragon laptops, Surface Pro X, Apple Silicon running Windows, etc.).

On ARM64, phpup installs the x64 stack anyway, and Windows runs it under its built-in **x64 emulation (Prism)**:

- **Expected to work** — x64 emulation is a mature, general-purpose Windows feature; the stack behaves like it does on x64 hardware.
- **Untested by phpup** — we have no ARM64 device in the test loop, so treat it as best-effort.
- **Slower than native x64** — emulated code carries an overhead; expect a measurable performance hit, especially for CPU-bound PHP work (JIT is still active, but emulated).
- **The VC++ Redistributable** is installed as x64 regardless of host — the emulated x64 binaries load the x64 runtime. The arm64 redist is only for native ARM64 apps, which this stack has none of.

phpup prints a warning on ARM64 at startup (rather than refusing to run) so you know what you're getting into. 32-bit Windows is still hard-blocked — the stack cannot run there at all.

## Known Limitations

- **Windows ARM64 is emulation-only, not natively supported.** Apache Lounge, PHP, and MariaDB provide no native ARM64 Windows binaries. phpup warns and continues under x64 emulation — see [ARM64 & Emulation](#arm64--emulation).

## Support

Open an [issue](https://github.com/DaFa66/phpup/issues) or submit a [pull request](https://github.com/DaFa66/phpup/pulls).
