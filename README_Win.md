# getPHP for Windows — Local Web Stack. One Script. Done.

Launch your local PHP web stack on Windows 11 with a single PowerShell script. Enjoy a full development environment without the bloat of a desktop application like XAMPP.

> **This is the official Windows port of [getPHP.org](https://getphp.org).**  
> The original Mac/Linux script lives at [getphporg/getphp](https://github.com/getphporg/getphp).

## Quick Start

```powershell
# Right-click PowerShell → Run as Administrator, then:
& "D:\dev\getphp\install_webstack.ps1"
```

Press **I** to install. That's it.

## What It Installs

| Component | Source | Latest? |
|-----------|--------|---------|
| **Apache** | [Apache Lounge](https://www.apachelounge.com/download/) | ✅ Resolves latest VS18 build dynamically |
| **PHP** | [windows.php.net](https://windows.php.net/downloads/releases/) | ✅ Parses releases.json for latest 8.x TS VS17 (falls back to VS16) |
| **MariaDB** | [mariadb.org](https://downloads.mariadb.org/rest-api/mariadb/) | ✅ Queries REST API for latest Stable (Rolling > LTS) |
| **phpMyAdmin** | [phpmyadmin.net](https://www.phpmyadmin.net/downloads/) | ✅ Scrapes downloads page for latest stable |

All installed to `D:\webstack\` — no system-wide changes, no services registered, no cruft.

## Directory Layout

```
D:\webstack\
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
└── www\             # ← Your websites go here
    ├── phpinfo.php  # (auto-created test file)
    └── phpmyadmin\  # phpMyAdmin
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
MariaDB ------> 11.4.5
PHP ----------> 8.4.7
phpMyAdmin ---> available

Service Status:
~~~~~~~~~~~~~~~
Apache -------> running
MariaDB ------> running
PHP ----------> CLI available

Stack Commands:
~~~~~~~~~~~~~~~
U  Update all components
R  Restart all services
S  Stop all services
T  Start all services
D  Delete the web stack
Q  Quit
```

| Key | Action |
|-----|--------|
| **I** | Install the web stack (download + configure + start) |
| **U** | Update all components to their latest stable versions |
| **R** | Restart Apache + MariaDB |
| **S** | Stop all services |
| **T** | Start all services |
| **D** | Delete the web stack (preserves `www\` files and MariaDB data) |
| **Q** | Quit |

## After Installation

| Question | Answer |
|----------|--------|
| Where to put website files? | `D:\webstack\www` |
| How to test your PHP setup? | http://localhost/phpinfo.php |
| Where to access phpMyAdmin? | http://localhost/phpmyadmin |
| How to log into phpMyAdmin? | Username: `root` / Password: *(blank)* |

## What the Installer Configures

### Apache
- Port 80, ServerName `localhost:80` (suppresses AH00558 warnings)
- DocumentRoot `D:/webstack/www` with `Options Indexes FollowSymLinks`
- `mod_rewrite` enabled with `AllowOverride All` — Trongate, Laravel, WordPress `.htaccess` rewrites work out of the box
- PHP module loaded from the installed PHP path
- phpMyAdmin alias at `/phpmyadmin`
- Error and access logs written to `www/`
- Stale `httpd.pid` cleaned before each start (no "unclean shutdown" warnings)
- Graceful shutdown via `httpd.exe -k stop` (force kill only as fallback)

### PHP
- **Extensions enabled:** `curl`, `fileinfo`, `gd`, `intl`, `mbstring`, `mysqli`, `openssl`, `pdo_mysql`, `pdo_sqlite`, `sqlite3`
- `display_errors = On` for development
- **Error logging:** `error_log = D:/webstack/www/php_errors.log`
- **OPCache:** Enabled with 256 MB memory, 16 MB interned strings, 20,000 files — production-ready out of the box
- **DLL compatibility:** PHP dependency DLLs (ICU, libssh2, nghttp2, etc.) are automatically copied to Apache's `bin/` to resolve extension loading warnings under Windows DLL search order

### SQLite3 DLL Fix
- VS17 PHP builds (8.5+) bundle an incompatible `libsqlite3.dll` that causes a blocking "Entry Point Not Found" popup when loading `pdo_sqlite` or `sqlite3` extensions
- The installer downloads the latest compatible `sqlite3.dll` from sqlite.org and replaces the bundled version in both the PHP root AND Apache's `bin/` directory — allowing both SQLite extensions to load cleanly

### MariaDB
- Data directory initialised with blank root password
- Latest stable release resolved via REST API (Rolling > LTS)
- Debug-symbols-only zip excluded from download filter

### phpMyAdmin
- Auto-generated `config.inc.php` with blowfish secret, blank-password root login, and correct 1-based server indexing (`$i = 1`)

## Prerequisites

- **Windows 10/11** (64-bit)
- **Run as Administrator** (required for port 80 binding)
- **Visual C++ Redistributable** — Apache Lounge VS18 binaries require the [latest VC++ Redistributable (x64)](https://aka.ms/vs/17/release/vc_redist.x64.exe). The script will warn you about this during install if it's needed.

## Zero Footprint

The `install_webstack.ps1` script runs entirely in-memory and never installs itself on your machine. Only the web stack is added to `D:\webstack\` if you choose to install it. To manage services, update, or uninstall the stack, simply re-run the script at any time.

## Uninstalling

Run the script and press **D** (Delete). This removes Apache, PHP, MariaDB, and phpMyAdmin but **preserves** your website files in `D:\webstack\www\` and your MariaDB data directory. To perform a complete wipe, delete `D:\webstack\` manually after running Delete.

## How It Resolves Latest Versions

Unlike most installers that hardcode version numbers, `install_webstack.ps1` dynamically resolves the latest stable version of every component every time you install or update:

- **Apache** — Scrapes the Apache Lounge download page, finds all VS## x64 zips, picks the highest VS version × Apache version combination
- **PHP** — Queries the `releases.json` API from windows.php.net, filters for PHP 8.x thread-safe x64, prefers VS17 builds over VS16
- **MariaDB** — Queries the MariaDB REST API (`/rest-api/mariadb/`), sorts stable releases by support policy (Rolling > LTS), then by version number. Excludes debug-symbols-only zips.
- **phpMyAdmin** — Scrapes the phpMyAdmin downloads page, finds all stable `all-languages.zip` files (excluding snapshots), picks the highest version

## Known Quirks & Fixes

### XAMPP Service Conflict
If you have XAMPP installed, its `Apache2.4` Windows service may auto-restart and claim port 80 when the webstack stops. To switch: stop the XAMPP service (`net stop Apache2.4`), then start the webstack Apache directly.

### Trongate / Framework Subdirectory Apps
The webstack's Apache config supports `.htaccess` rewrites out of the box (`AllowOverride All` + `Options FollowSymLinks`). Clone any Trongate app under `www/` and the `public/` front controller is routed automatically.

### PHP Extension `pdo_firebird`
Not enabled by default — requires a separate Firebird client library (`fbclient.dll`) not bundled with PHP.

## Support & Contributions

If you run into any errors or bugs, please open an [issue](https://github.com/getphporg/getphp/issues) or send a [pull request](https://github.com/getphporg/getphp/pulls).

You can also contact us through the [Support Page](https://getphp.org/support.php) at [getPHP.org](https://getphp.org).

---

> **Disclaimer:** getPHP is an independent, open-source tool and is not affiliated with, sponsored by, or endorsed by the PHP Group, the PHP Foundation, Apache Lounge, MariaDB Foundation, or phpMyAdmin.
