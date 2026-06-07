# getPHP for Windows x64 — Local Web Stack. One Script. Done.

Launch your local PHP web stack on Windows 11 with a single PowerShell script. Enjoy a full development environment without the bloat of other desktop application and a replacement for a stale XAMPP install.

> **This Windows x64 port of [getPHP.org](https://getphp.org)**
> by Simon Field (aka DaFa)  
> The original Mac/Linux script lives at [getphporg/getphp](https://github.com/getphporg/getphp).

## Quick Start

```powershell
# Right-click PowerShell → Run as Administrator, then:
irm https://raw.githubusercontent.com/getphporg/getphp/HEAD/getphp.ps1 | iex
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

All installed to `C:\webstack\` by default — no system-wide changes, no cruft. Optionally register as Windows services for auto-start on boot.

## Directory Layout

```
C:\webstack\
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
│   ├── phpinfo.php  # (auto-created test file)
│   └── phpmyadmin\  # phpMyAdmin
└── data_backup\     # (created on delete — databases preserved here)
```

## Dashboard Commands

After running the script, you'll see the getPHP dashboard:

```
┌────────────────────────────────────┐
│             _   ____  _   _ ____   │
│   __ _  ___| |_|  _ \| | | |  _ \  │
│  / _` |/ _ \ __| |_) | |_| | |_) | │
│ | (_| |  __/ |_|  __/|  _  |  __/  │
│  \__, |\___|\__|_|   |_| |_|_|     │
│  |___/              www.getPHP.org │
└────────────────────────────────────┘

Your Web Stack:
~~~~~~~~~~~~~~~
Apache -------> 2.4.67
MariaDB ------> 12.3.2
PHP ----------> 8.5.7
phpMyAdmin ---> 5.2.3

Service Status:
~~~~~~~~~~~~~~~
Apache -------> running
MariaDB ------> running
PHP ----------> CLI available

Windows Services:
~~~~~~~~~~~~~~~~
getPHP_Apache   registered
getPHP_MariaDB  registered

Stack Commands:
~~~~~~~~~~~~~~~
U  Update outdated components
R  Restart all services
S  Stop all services
T  Start all services (offers Windows service registration)
D  Delete the web stack
Q  Quit
```

| Key   | Action                                                                    |
| ----- | ------------------------------------------------------------------------- |
| **I** | Install the web stack (download + configure + start)                      |
| **U** | Update outdated components (compares installed vs latest online versions) |
| **R** | Restart Apache + MariaDB                                                  |
| **S** | Stop all services (offers to unregister if Windows services installed)    |
| **T** | Start all services (offers Windows service registration if not installed) |
| **D** | Delete the web stack (preserves `www\` files and MariaDB data)            |
| **Q** | Quit                                                                      |

## After Installation

| Question                    | Answer                                 |
| --------------------------- | -------------------------------------- |
| Where to put website files? | `C:\webstack\www`                      |
| How to test your PHP setup? | http://localhost/phpinfo.php           |
| Where to access phpMyAdmin? | http://localhost/phpmyadmin            |
| How to log into phpMyAdmin? | Username: `root` / Password: _(blank)_ |
| PHP from terminal?          | `php` and `mysql` added to user PATH   |

## Persistent Config

The script saves your install path and component versions to `%APPDATA%\getphp\config.json`. This means:

- **One-time path prompt** — asked only on first run; subsequent runs go straight to the dashboard
- **Version tracking** — Apache, PHP, MariaDB, and phpMyAdmin versions are recorded after each install/update
- **Service registration** — whether Apache and MariaDB are registered as Windows services is persisted between runs
- **PATH management** — the config tracks which directories were added to your user PATH
- **Reset on delete** — pressing `D` clears the config entirely, so the next run prompts for a fresh location

Example `config.json`:

```json
{
  "install_path": "C:\\webstack",
  "installed_at": "2026-06-05T20:45:00",
  "services_registered": true,
  "paths": {
    "apache": "C:\\webstack\\apache",
    "php": "C:\\webstack\\php",
    "mariadb": "C:\\webstack\\mariadb",
    "www": "C:\\webstack\\www",
    "phpmyadmin": "C:\\webstack\\www\\phpmyadmin"
  },
  "versions": {
    "apache": "2.4.67",
    "php": "8.5.7",
    "mariadb": "12.3.2",
    "phpmyadmin": "5.2.3"
  },
  "path_entries": ["C:\\webstack\\php", "C:\\webstack\\mariadb\\bin"]
}
```

## What the Installer Configures

### Apache

- Port 80, ServerName `localhost:80` (suppresses AH00558 warnings)
- DocumentRoot `C:/webstack/www` with `Options Indexes FollowSymLinks`
- `mod_rewrite` enabled with `AllowOverride All` — Trongate, Laravel, WordPress `.htaccess` rewrites work out of the box
- PHP module loaded from the installed PHP path
- phpMyAdmin alias at `/phpmyadmin`
- Error and access logs written to `www/`
- Stale `httpd.pid` cleaned before each start (no "unclean shutdown" warnings)
- Graceful shutdown via `httpd.exe -k stop` (force kill only as fallback)

### PHP

- **Extensions enabled:** `curl`, `fileinfo`, `gd`, `intl`, `mbstring`, `mysqli`, `openssl`, `pdo_mysql`, `pdo_sqlite`, `sqlite3`
- `display_errors = On` for development
- **Error logging:** `error_log = C:/webstack/www/php_errors.log`
- **OPCache:** Enabled with 256 MB memory, 16 MB interned strings, 20,000 files, JIT tracing with 100 MB buffer — production-ready out of the box
- **DLL compatibility:** PHP dependency DLLs (ICU, libssh2, nghttp2, etc.) are automatically copied to Apache's `bin/` to resolve extension loading warnings under Windows DLL search order
- **Added to user PATH** — `php` command works from any new terminal window

### SQLite3 DLL Fix

- VS17 PHP builds (8.5+) bundle an incompatible `libsqlite3.dll` that causes a blocking "Entry Point Not Found" popup when loading `pdo_sqlite` or `sqlite3` extensions
- The installer downloads the latest compatible `sqlite3.dll` from [sqlite.org](https://sqlite.org/) and replaces the bundled version in both the PHP root AND Apache's `bin/` directory — allowing both SQLite extensions to load cleanly

### MariaDB

- Data directory initialised with blank root password
- Latest stable release resolved via REST API (Rolling > LTS)
- Debug-symbols-only zip excluded from download filter
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
3. Apache, PHP, MariaDB, and phpMyAdmin are removed
4. `www\` (your websites) is left untouched
5. If `data_backup\` already exists from a previous delete, it is timestamped (`data_backup_20260605_213000`) to avoid collisions

When you reinstall (`I`), the script detects the orphaned `data_backup\` and offers to restore your databases:

```
Found database backup from a previous install: C:\webstack\data_backup
Restore previous databases? [Y/n]
```

Say **yes** and your databases are moved back — MariaDB picks them up without re-initialisation.

## Windows Service Registration

During install, the script asks whether to register Apache and MariaDB as Windows services **before** starting them — avoiding any start-stop-restart cycle:

```
Install as Windows services (auto-start on boot)? [y/N]
```

Say **yes** and two services are created — `getPHP_Apache` and `getPHP_MariaDB` — set to auto-start. After a reboot your stack is running without opening the script. The config file records the choice so the dashboard always reflects current state.

If you skip registration during install, the **T** (Start) command will offer to register them on first use. The hint `(offers Windows service registration)` appears next to **T** in the dashboard until services are installed — then it disappears. A **Windows Services** block always appears below Service Status, showing `registered` or `not registered` for each service.

**S** (Stop) works in reverse — if services are registered, it offers to unregister them. Say yes to remove the Windows service entries and revert to process mode.

Services are automatically removed when you delete the stack (`D`).

## Zero Footprint

The `getphp.ps1` script runs entirely in-memory and never installs itself on your machine. Only the web stack is added to `C:\webstack\` if you choose to install it, plus a small config file at `%APPDATA%\getphp\config.json`. To manage services, update, or uninstall the stack, simply re-run the script at any time.

## Uninstalling

Run the script and press **D** (Delete). This removes Apache, PHP, MariaDB, and phpMyAdmin but **preserves** your website files in `C:\webstack\www\` and your MariaDB data in `C:\webstack\data_backup\`. PATH entries are removed and the config is cleared. To perform a complete wipe, delete `C:\webstack\` and `%APPDATA%\getphp\` manually after running Delete.

## How It Resolves Latest Versions

Unlike most installers that hardcode version numbers, `getphp.ps1` dynamically resolves the latest stable version of every component every time you install or update:

- **Apache** — Scrapes the Apache Lounge download page, finds all VS## x64 zips, picks the highest VS version × Apache version combination
- **PHP** — Queries the `releases.json` API from windows.php.net, filters for PHP 8.x thread-safe x64, prefers VS17 builds over VS16
- **MariaDB** — Queries the MariaDB REST API (`/rest-api/mariadb/`), sorts stable releases by support policy (Rolling > LTS), then by version number. Excludes debug-symbols-only zips.
- **phpMyAdmin** — Scrapes the phpMyAdmin downloads page, finds all stable `all-languages.zip` files (excluding snapshots), picks the highest version

## Known Quirks & Fixes

### ARM64 / Snapdragon / Apple Silicon (Windows VM)

Not supported. getPHP requires x64 (Intel/AMD 64-bit) — Apache Lounge and MariaDB do not provide native ARM64 Windows binaries. The script detects ARM64 at startup and exits with a clear message.

## Support & Contributions

If you run into any errors or bugs, please open an [issue](https://github.com/getphporg/getphp/issues) or send a [pull request](https://github.com/getphporg/getphp/pulls).

You can also contact us through the [Support Page](https://getphp.org/support.php) at [getPHP.org](https://getphp.org).

---

> **Disclaimer:** getPHP is an independent, open-source tool and is not affiliated with, sponsored by, or endorsed by the PHP Group, the PHP Foundation, Apache Lounge, MariaDB Foundation, or phpMyAdmin.
