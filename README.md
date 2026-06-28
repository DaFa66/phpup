# phpup — Local PHP Web Stack. One Script. Done.

> **Acknowledgments**
>
> This project is a Windows x64 port inspired by the original [getPHP.org](https://getphp.org) project founded by Balázs Szabó. The original Mac/Linux shell script — a brilliantly concise sub 300-line installer that delivers a complete PHP stack with a single command — set the standard for simplicity and developer experience that this Windows port aspires to.
>
> Balázs has since launched his own Windows version using Winget as the installer — proving once again that less is more in just under 700 lines of code. Both projects share the same spirit: **no bloat, no desktop app, just a working PHP stack.**
>
> This PowerShell edition takes a different approach — native binary downloads, dynamic version resolution, zip file caching and an interactive dashboard — but the mission is the same. Thank you, Balázs, for getphp.org and for supporting all three operating systems.

Launch your local PHP web stack on Windows 11 with a single PowerShell script.

## Quick Start

Right-click PowerShell → Run as Administrator, then:

```powershell

irm https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.ps1 | iex
```

Press **I** to install. That's it.

On subsequent runs the script remembers your install path and goes straight to the dashboard — no prompts.

## What It Installs

| Component      | Source                                                         | Latest?                                                             |
| -------------- | -------------------------------------------------------------- | ------------------------------------------------------------------- |
| **Apache**     | [Apache Lounge](https://www.apachelounge.com/download/)        | ✅ Resolves latest VS18 build dynamically                           |
| **PHP**        | [windows.php.net](https://windows.php.net/downloads/releases/) | ✅ Parses releases.json for latest 8.x TS VS17 (falls back to VS16) |
| **MariaDB**    | [mariadb.org](https://downloads.mariadb.org/rest-api/mariadb/) | ✅ Queries REST API for latest Stable (Rolling > LTS)               |
| **phpMyAdmin** | [phpmyadmin.net](https://www.phpmyadmin.net/downloads/)        | ✅ Scrapes downloads page for latest stable                         |

All installed to `C:\phpup\` by default. No system-wide changes, no cruft. Optionally register as Windows services for auto-start on boot.

## Directory Layout

```
C:\phpup\
├── apache\          # Apache Lounge (VS18, port 80)
│   ├── bin\
│   ├── conf\
│   └── ...
├── php\             # PHP 8.x thread-safe x64
│   ├── php.exe
│   ├── ext\
│   └── ...
├── mariadb\         # MariaDB
│   ├── bin\
│   ├── data\
│   └── ...
├── www\             # ← Your websites go here
│   └── phpinfo.php  # (auto-created test file)
├── phpmyadmin\      # phpMyAdmin (at stack root)
├── logs\            # All log files
│   ├── apache_error.log
│   ├── apache_access.log
│   ├── php_errors.log
│   └── mariadb_error.log
└── data_backup\     # (created on delete — databases preserved here)
```

## Dashboard Commands

After running the script, you'll see the phpup dashboard:

```
┌─────────────────────────────┐
│    ____  _   _ ____         │
│   |  _ \| | | |  _ \  /\    │
│   | |_) | |_| | |_) | || |  │
│   |  __/|  _  |  __/| || |  │
│   |_|   |_| |_|_|    ||_|   │
│         ▲ ▲ ▲               │
│        phpup                │
└─────────────────────────────┘

Your Web Stack:
~~~~~~~~~~~~~~~
Apache -------> 2.4.68
MariaDB ------> 12.3.2
PHP ----------> 8.5.7
phpMyAdmin ---> 5.2.3

Service Status:
~~~~~~~~~~~~~~~
Apache -------> running
MariaDB ------> running
PHP ----------> CLI available

System Prerequisites:
~~~~~~~~~~~~~~~~~~~~~
VC++ Redist ---> 14.51.36247.0

Windows Services:
~~~~~~~~~~~~~~~~
phpup_Apache   registered
phpup_MariaDB  registered

Where to put website files? C:\phpup\www
How to test your PHP setup? http://localhost/phpinfo.php
Where to access phpMyAdmin? http://localhost/phpmyadmin
How to log into phpMyAdmin? Username: root | Password: [blank]

Stack Commands:
~~~~~~~~~~~~~~~
U  Update outdated components
R  Restart all services
S  Stop all services
T  Start all services (offers Windows service registration)
D  Delete the web stack
Q  Quit
```

| Key    | Action                                                                                                                              |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| **I**  | Install the web stack (download + configure + start)                                                                                |
| **U**  | Update outdated components (compares installed vs latest online versions)                                                           |
| **fu** | _(hidden)_ Forced update — switch components to any cached version from `%TEMP%\\webstack_downloads\\` without touching the network |
| **R**  | Restart Apache + MariaDB                                                                                                            |
| **S**  | Stop all services (offers to unregister if Windows services installed)                                                              |
| **T**  | Start all services (offers Windows service registration if not installed)                                                           |
| **D**  | Delete the web stack (preserves `www\\` files and MariaDB data)                                                                     |
| **Q**  | Quit                                                                                                                                |

## After Installation

| Question                    | Answer                                 |
| --------------------------- | -------------------------------------- |
| Where to put website files? | `C:\phpup\www`                        |
| How to test your PHP setup? | http://localhost/phpinfo.php           |
| Where to access phpMyAdmin? | http://localhost/phpmyadmin            |
| How to log into phpMyAdmin? | Username: `root` / Password: _(blank)_ |
| PHP from terminal?          | `php` and `mysql` added to user PATH   |

## Persistent Config

The script saves your install path and component versions to `%APPDATA%\phpup\config.json`. This means:

- **One-time path prompt** — asked only on first run; subsequent runs go straight to the dashboard
- **Version tracking** — Apache, PHP, MariaDB, and phpMyAdmin versions are recorded after each install/update
- **Service registration** — whether Apache and MariaDB are registered as Windows services is persisted between runs
- **PATH management** — the config tracks which directories were added to your user PATH
- **Reset on delete** — pressing `D` clears the config entirely, so the next run prompts for a fresh location

Example `config.json`:

```json
{
  "install_path": "C:\\phpup",
  "installed_at": "2026-06-05T20:45:00",
  "services_registered": true,
  "paths": {
    "apache": "C:\\phpup\\apache",
    "php": "C:\\phpup\\php",
    "mariadb": "C:\\phpup\\mariadb",
    "www": "C:\\phpup\\www",
    "logs": "C:\\phpup\\logs",
    "phpmyadmin": "C:\\phpup\\phpmyadmin"
  },
  "versions": {
    "apache": "2.4.67",
    "php": "8.5.7",
    "mariadb": "12.3.2",
    "phpmyadmin": "5.2.3"
  },
  "path_entries": ["C:\\phpup\\php", "C:\\phpup\\mariadb\\bin"]
}
```

## What the Installer Configures

### Apache

- Port 80, ServerName `localhost:80` (suppresses AH00558 warnings)
- DocumentRoot with `Options Indexes FollowSymLinks`
- `mod_rewrite` enabled with `AllowOverride All` — Trongate, Laravel, WordPress `.htaccess` rewrites work out of the box
- PHP module loaded from the installed PHP path
- phpMyAdmin alias at `/phpmyadmin`
- Error and access logs written to `logs/` (not `www/`)
- Stale `httpd.pid` cleaned before each start (no "unclean shutdown" warnings)
- Graceful shutdown via `httpd.exe -k stop` (force kill only as fallback)

### PHP

- **Extensions enabled:** `curl`, `fileinfo`, `gd`, `intl`, `mbstring`, `mysqli`, `openssl`, `pdo_mysql`, `pdo_sqlite`, `sodium`, `sqlite3`
- `display_errors = On` for development
- **Error logging:** `error_log = logs/php_errors.log`
- **OPCache:** Enabled with 256 MB memory, 16 MB interned strings, 20,000 files, JIT tracing with 100 MB buffer — production-ready out of the box
- **DLL compatibility:** PHP dependency DLLs (ICU, libssh2, nghttp2, etc.) are automatically copied to Apache's `bin/` to resolve extension loading warnings under Windows DLL search order
- **Added to user PATH** — `php` command works from any new terminal window

### SQLite3 DLL Fix

- VS17 PHP builds (8.5+) bundle an incompatible `libsqlite3.dll` that causes a blocking "Entry Point Not Found" popup when loading `pdo_sqlite` or `sqlite3` extensions
- The installer downloads the latest compatible `sqlite3.dll` from [sqlite.org](https://sqlite.org/) and replaces the bundled version in both the PHP root AND Apache's `bin/` directory — allowing both SQLite extensions to load cleanly

### MariaDB

- Data directory initialised with blank root password
- `my.ini` written with `log-error` → `logs/mariadb_error.log`
- Latest stable release resolved via REST API (Rolling > LTS)
- Debug-symbols-only zip excluded from download filter
- Download URL constructed directly from archive (bypasses REST API redirector)
- **Added to user PATH** — `mysql` command works from any new terminal window

### phpMyAdmin

- Auto-generated `config.inc.php` with blowfish secret, blank-password root login
- Version detected from the installed README and shown in the dashboard
- Click on `Operations` within any user database to setup `pma\_` configuration storage

## Prerequisites

- **Windows 10/11** (x64 only — Intel/AMD 64-bit; ARM64 is not supported)
- **Run as Administrator** (required for port 80 binding)
- **Visual C++ Redistributable** — Apache Lounge VS18 and MariaDB 12.x require the [VC++ Redistributable (VS 2017–2026) x64](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170), minimum version **14.51.36231**. The installer **blocks** until it's installed — checks for outdated versions and offers a one-click upgrade via winget (or direct download as fallback). A reboot may be required after upgrading from an older version.

## Delete / Reinstall — Database Safety

The delete command (`D`) preserves your data:

1. Services are stopped
2. `mariadb\data\` is moved to `data_backup\`
3. Apache, PHP, MariaDB, phpMyAdmin, and log files are removed
4. `www\` (your websites) is left untouched
5. If `data_backup\` already exists from a previous delete, it is timestamped (`data_backup_20260605_213000`) to avoid collisions

When you reinstall (`I`), the script detects the orphaned `data_backup\` and offers to restore your databases:

```
Found database backup from a previous install: C:\phpup\data_backup
Restore previous databases? [Y/n]
```

Say **yes** and your databases are moved back — MariaDB picks them up without re-initialisation.

## Windows Service Registration

During install, the script asks whether to register Apache and MariaDB as Windows services **before** starting them — avoiding any start-stop-restart cycle:

```
Install as Windows services (auto-start on boot)? [y/N]
```

Say **yes** and two services are created — `phpup_Apache` and `phpup_MariaDB` — set to auto-start. After a reboot your stack is running without opening the script. The config file records the choice so the dashboard always reflects current state.

If you skip registration during install, the **T** (Start) command will offer to register them on first use. The hint `(offers Windows service registration)` appears next to **T** in the dashboard until services are installed — then it disappears. A **Windows Services** block always appears below Service Status, showing `registered` or `not registered` for each service.

**S** (Stop) works in reverse — if services are registered, it offers to unregister them. Say yes to remove the Windows service entries and revert to process mode.

Services are automatically removed when you delete the stack (`D`).

## Zero Footprint

The `phpup.ps1` script runs entirely in-memory and never installs itself on your machine. Only the web stack is added to `C:\phpup\` if you choose to install it, plus a small config file at `%APPDATA%\phpup\config.json`. To manage services, update, or uninstall the stack, simply re-run the script at any time.

## Uninstalling

Run the script and press **D** (Delete). This removes Apache, PHP, MariaDB, and phpMyAdmin but **preserves** your website files in `www\` and your MariaDB data in `data_backup\`. PATH entries are removed and the config is cleared. To perform a complete wipe, delete the install directory and `%APPDATA%\phpup\` manually after running Delete.

## How It Resolves Latest Versions

Unlike most installers that hardcode version numbers, `phpup.ps1` dynamically resolves the latest stable version of every component every time you install or update:

- **Apache** — Scrapes the Apache Lounge download page, finds all VS## x64 zips, picks the highest VS version × Apache version combination
- **PHP** — Queries the `releases.json` API from windows.php.net, filters for PHP 8.x thread-safe x64, prefers VS17 builds over VS16
- **MariaDB** — Queries the MariaDB REST API (`/rest-api/mariadb/`), sorts stable releases by support policy (Rolling > LTS), then by version number. Constructs direct archive URL from version and filename (bypasses REST API redirector). Excludes debug-symbols-only zips.
- **phpMyAdmin** — Scrapes the phpMyAdmin downloads page, finds all stable `all-languages.zip` files (excluding snapshots), picks the highest version

## Offline Mode, Download Caching & Version Switching

Run the script with `-Offline` to skip all URL resolution and downloading:

```powershell
.\\phpup.ps1 -Offline
```

Offline mode requires four pre-downloaded zip files in `%TEMP%\webstack_downloads\` (Apache, PHP, MariaDB, phpMyAdmin) — run the script online once to populate the cache, then subsequent installs skip downloads entirely.

All downloaded files are cached permanently in `%TEMP%\webstack_downloads\`:

- Component zips (Apache, PHP, MariaDB, phpMyAdmin) — reused on re-install when the version hasn't changed
- SQLite3 DLL zip — cached and reused
- VC++ Redistributable installer (`.exe`) — cached and reused

Once you have multiple versions cached, the hidden **`fu`** (forced update) command lets you switch between them interactively without touching the network. Type `fu` at the dashboard prompt and you'll see a summary of installed vs cached versions, then choose which version to install per component — upgrades, downgrades, or snapshots. MariaDB databases are automatically backed up and restored across version changes.

## Program Flow Diagram

```mermaid
flowchart TD
    %% ── Entry Point ──
    START(["irm phpup.ps1 | iex"]) --> PARAM{"-Offline?"}
    PARAM -->|"Yes"| OFFLINE_FLAG["Set $Offline = $true"]
    PARAM -->|"No"| ADMIN
    OFFLINE_FLAG --> ADMIN

    %% ── Pre-flight Guards ──
    ADMIN{"Run as Admin?"} -->|"No"| EXIT_ADMIN["Exit: Admin required"]
    ADMIN -->|"Yes"| ARCH{"x64 (AMD64)?"}
    ARCH -->|"No"| EXIT_ARCH["Exit: ARM / 32-bit unsupported"]
    ARCH -->|"Yes"| BANNER["Display Banner"]

    %% ── VC++ Redist Check (blocking) ──
    BANNER --> VCREDIST{"VC++ Redist ≥ 14.51?"}
    VCREDIST -->|"No"| VC_PROMPT["Offer install/update"]
    VC_PROMPT -->|"Accept"| VC_INSTALL["Download & run VC++ installer"]
    VC_INSTALL --> VC_REBOOT{"Reboot needed?"}
    VC_REBOOT -->|"Yes"| VC_OFFER_REBOOT["Offer reboot"]
    VC_OFFER_REBOOT -->|"Yes"| VC_REBOOT_NOW(["Restart-Computer -Force"])
    VC_OFFER_REBOOT -->|"No"| EXIT_REBOOT["Exit: re-run after reboot"]
    VC_REBOOT -->|"No"| VCREDIST
    VC_PROMPT -->|"Decline"| EXIT_VC["Exit: VC++ required"]
    VCREDIST -->|"Yes"| CONFIG

    %% ── Config & Path Resolution ──
    CONFIG{"Saved config exists?"}
    CONFIG -->|"Yes"| VALIDATE["Validate saved path<br/>— no spaces<br/>— derive all sub-paths"]
    VALIDATE -->|"Invalid"| EXIT_PATH["Exit: fix config"]
    VALIDATE -->|"Valid"| SYNC["Sync service state<br/>with reality"]
    CONFIG -->|"No (first run)"| PROMPT_PATH["Prompt for install path<br/>default: C:\phpup"]
    PROMPT_PATH --> SAVE_CONFIG["Save config.json"]
    SAVE_CONFIG --> DERIVE["Derive all sub-paths"]
    SYNC --> DASHBOARD
    DERIVE --> DASHBOARD

    %% ── Main Dashboard Loop ──
    DASHBOARD["**Show Dashboard**<br/>Stack status · Service status<br/>Prerequisites · Commands"]
    DASHBOARD --> CHECK_STACK{"Test-StackComplete<br/>(all 4 components?)"}
    CHECK_STACK --> READ_CMD["Read-Host 'Enter command'"]

    %% ── Command Router ──
    READ_CMD --> ROUTE{"$cmd"}
    ROUTE -->|"I (not installed)"| INSTALL
    ROUTE -->|"I (installed)"| ERR_I["Error: already installed"]
    ROUTE -->|"U (installed)"| UPDATE
    ROUTE -->|"U (not installed)"| ERR_U["Error: not installed"]
    ROUTE -->|"R"| RESTART
    ROUTE -->|"S"| STOP
    ROUTE -->|"T"| START
    ROUTE -->|"D"| DELETE
    ROUTE -->|"fu"| FORCED_UPDATE
    ROUTE -->|"Q"| QUIT(["Write-Ok 'Goodbye!' → return"])
    ROUTE -->|"other"| ERR_CMD["Error: command not recognised"]
    ERR_I --> PAUSE
    ERR_U --> PAUSE
    ERR_CMD --> PAUSE
    PAUSE["Pause"] --> DASHBOARD

    %% ══════════ INSTALL SUB-FLOW ══════════
    INSTALL["**Invoke-InstallWebStack**"] --> INST_VC{"VC++ OK?"}
    INST_VC -->|"No"| INST_FIX_VC["Offer install → install or abort"]
    INST_FIX_VC -->|"Abort"| DASHBOARD
    INST_FIX_VC -->|"Done"| INST_DIRS
    INST_VC -->|"Yes"| INST_DIRS["Create directories<br/>base · www · logs · temp_downloads"]

    INST_DIRS --> INST_MODE{"$Offline?"}
    INST_MODE -->|"Online"| INST_RESOLVE["Resolve latest URLs<br/>Apache · PHP · MariaDB · phpMyAdmin"]
    INST_RESOLVE --> INST_DL_EACH["For each component:<br/>skip if same version already installed<br/>else Invoke-DownloadAndExtract"]
    INST_MODE -->|"Offline"| INST_SCAN["Scan $TEMP_DOWNLOADS for zips<br/>(needs 4: httpd*, php-*, mariadb*, phpmyadmin*)"]
    INST_SCAN --> INST_OFFLINE_EXT["Identify & extract each zip"]

    INST_DL_EACH --> INST_DLL["Copy PHP dependency DLLs<br/>to Apache bin\"]
    INST_OFFLINE_EXT --> INST_DLL
    INST_DLL --> INST_CFG_APACHE["Configure Apache<br/>httpd.conf · mod_rewrite · phpMyAdmin alias"]
    INST_CFG_APACHE --> INST_CFG_PHP["Configure PHP<br/>php.ini · extensions · error log · OPCache"]
    INST_CFG_PHP --> INST_SQLITE["Fix SQLite3 DLL<br/>(VS17 bundled version is broken)"]

    INST_SQLITE --> INST_DB_BACKUP{"Orphaned data_backup?"}
    INST_DB_BACKUP -->|"Yes"| INST_RESTORE["Offer restore → move to mariadb/data"]
    INST_DB_BACKUP -->|"No"| INST_CFG_MDB
    INST_RESTORE --> INST_CFG_MDB["Configure MariaDB<br/>my.ini · data init · blank root password"]

    INST_CFG_MDB --> INST_PMA{"Offline mode?"}
    INST_PMA -->|"Online"| INST_PMA_DL["Download & extract phpMyAdmin"]
    INST_PMA_DL --> INST_CFG_PMA
    INST_PMA -->|"Offline"| INST_CFG_PMA["Configure phpMyAdmin<br/>config.inc.php · blowfish secret"]

    INST_CFG_PMA --> INST_PHPINFO["Create phpinfo.php test file"]
    INST_PHPINFO --> INST_PATH["Add PHP + MariaDB to user PATH"]
    INST_PATH --> INST_SVC{"Install as Windows services?"}
    INST_SVC -->|"Yes"| INST_SVC_REG["Install-AsServices<br/>phpup_Apache<br/>phpup_MariaDB"]
    INST_SVC -->|"No"| INST_START
    INST_SVC_REG --> INST_START["Start services<br/>(service or process mode)"]

    INST_START --> INST_PMA_STOR["Configure phpMyAdmin storage<br/>(pma_ tables)"]
    INST_PMA_STOR --> INST_DONE["Save config.json<br/>Display 'Installation Complete!'"]
    INST_DONE --> PAUSE

    %% ══════════ UPDATE SUB-FLOW ══════════
    UPDATE["**Invoke-UpdateWebStack**"] --> UPD_RESOLVE["Resolve latest URLs for all 4"]
    UPD_RESOLVE --> UPD_COMPARE["Compare installed vs latest versions"]
    UPD_COMPARE --> UPD_OUTDATED{"Any outdated?"}
    UPD_OUTDATED -->|"No"| UPD_OK["Write-Ok 'Stack is up to date'"]
    UPD_OK --> PAUSE
    UPD_OUTDATED -->|"Yes"| UPD_CONFIRM{"Confirm update?"}
    UPD_CONFIRM -->|"No"| PAUSE
    UPD_CONFIRM -->|"Yes"| UPD_STOP["Stop all services"]
    UPD_STOP --> UPD_EACH["For each outdated component:<br/>Remove old → Download new → Configure"]
    UPD_EACH --> UPD_MDB_CHK{"MariaDB updated?"}
    UPD_MDB_CHK -->|"Yes"| UPD_MDB_BACKUP["Backup data → Restore data"]
    UPD_MDB_CHK -->|"No"| UPD_START
    UPD_MDB_BACKUP --> UPD_START["Start services"]
    UPD_START --> UPD_PMA_CHK{"phpMyAdmin updated?"}
    UPD_PMA_CHK -->|"Yes"| UPD_PMA_STOR["Configure phpMyAdmin storage"]
    UPD_PMA_CHK -->|"No"| UPD_SAVE
    UPD_PMA_STOR --> UPD_SAVE["Save-PostUpdateConfig"]
    UPD_SAVE --> PAUSE

    %% ══════════ DELETE SUB-FLOW ══════════
    DELETE["**Invoke-DeleteWebStack**"] --> DEL_CONFIRM{"Type 'DELETE' to confirm?"}
    DEL_CONFIRM -->|"No"| DEL_ABORT["Nothing deleted"]
    DEL_ABORT --> PAUSE
    DEL_CONFIRM -->|"Yes"| DEL_STOP["Stop all services"]
    DEL_STOP --> DEL_BACKUP["Backup mariadb\\data\\ → data_backup\\"]
    DEL_BACKUP --> DEL_EXISTS{"Existing backup?"}
    DEL_EXISTS -->|"Yes"| DEL_RENAME["Timestamp old backup<br/>data_backup_YYYYMMDD_HHmmss"]
    DEL_EXISTS -->|"No"| DEL_REMOVE
    DEL_RENAME --> DEL_REMOVE["Remove: Apache · PHP · MariaDB · phpMyAdmin · logs"]
    DEL_REMOVE --> DEL_SVC["Unregister Windows services"]
    DEL_SVC --> DEL_PATH["Remove from user PATH"]
    DEL_PATH --> DEL_CONFIG["Clear-Config"]
    DEL_CONFIG --> PAUSE

    %% ══════════ RESTART / STOP / START ══════════
    RESTART["Stop-WebStackServices → wait 2s → Start-WebStackServices"] --> PAUSE
    STOP --> STOP_CHK{"Services registered?"}
    STOP_CHK -->|"Yes"| STOP_OFFER["Offer to unregister"]
    STOP_OFFER -->|"Yes"| STOP_UNREG["Remove-Services → Save config: false"]
    STOP_OFFER -->|"No"| STOP_EXEC
    STOP_CHK -->|"No"| STOP_EXEC["Stop-WebStackServices"]
    STOP_UNREG --> PAUSE
    STOP_EXEC --> PAUSE
    START --> START_SVC["Request-ServiceRegistration<br/>(offer if not yet registered)"]
    START_SVC --> START_START["Start-WebStackServices"]
    START_START --> PAUSE

    %% ══════════ FORCED UPDATE (offline) ══════════
    FORCED_UPDATE["**Invoke-ForcedUpdate**"] --> FU_SCAN["Scan $TEMP_DOWNLOADS for cached zips"]
    FU_SCAN --> FU_SHOW["Show installed vs cached versions"]
    FU_SHOW --> FU_PICK["User picks version per component"]
    FU_PICK --> FU_STOP["Stop services"]
    FU_STOP --> FU_EACH["For each changed component:<br/>Remove old → Extract cached zip → Configure"]
    FU_EACH --> FU_START["Start services"]
    FU_START --> FU_SAVE["Save config with new versions"]
    FU_SAVE --> PAUSE

    %% ── Styling ──
    style START fill:#0f0,color:#000
    style QUIT fill:#f66,color:#fff
    style EXIT_ADMIN fill:#f66,color:#fff
    style EXIT_ARCH fill:#f66,color:#fff
    style EXIT_VC fill:#f66,color:#fff
    style EXIT_PATH fill:#f66,color:#fff
    style DASHBOARD fill:#39f,color:#fff
    style INSTALL fill:#3c3,color:#fff
    style UPDATE fill:#3c3,color:#fff
    style DELETE fill:#f93,color:#000
    style FORCED_UPDATE fill:#93f,color:#fff
    style ERR_I fill:#999,color:#fff
    style ERR_U fill:#999,color:#fff
    style ERR_CMD fill:#999,color:#fff
```

## Known Quirks & Fixes

### ARM64 / Snapdragon / Apple Silicon (Windows VM)

Not supported. phpup requires x64 (Intel/AMD 64-bit) — Apache Lounge and MariaDB do not provide native ARM64 Windows binaries. The script detects ARM64 at startup and exits with a clear message.

## Support & Contributions

If you run into any errors or bugs, please open an [issue](https://github.com/DaFa66/phpup/issues) or send a [pull request](https://github.com/DaFa66/phpup/pulls).

You can also contact Balázs Szabó through his [Support Page](https://getphp.org/support.php) at [getPHP.org](https://getphp.org).

---

> **Disclaimer:** phpup is an independent, open-source tool and is not affiliated with, sponsored by, or endorsed by the PHP Group, the PHP Foundation, Apache Lounge, MariaDB Foundation, or phpMyAdmin.
